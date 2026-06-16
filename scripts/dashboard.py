#!/usr/bin/env python3
"""Spraxel always-on dashboard. Run in a terminal you leave open.

Polls local state every 5 seconds and re-renders a compact glanceable
view in the terminal. Stdlib only — no Claude tokens, no third-party
deps. Reads from:

  - .cache/continuous-state.json   (cap counter, signal timestamps)
  - .paused                        (pause flag)
  - ps                             (wrapper + dev process info)
  - logs/continuous/<date>.log     (last log line)
  - schedule.yaml                  (next firing times)
  - escalations.md count           (today's failed item count)

Usage:
  python3 ~/SpraxelAiCompany/scripts/dashboard.py
  python3 ~/SpraxelAiCompany/scripts/dashboard.py --interval 10   # poll every 10s

Ctrl+C to exit. Plays nicely in a small terminal window (~70 cols × 25 rows).
"""

import os
import re
import sys
import json
import time
import argparse
import subprocess
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

# Reuse the existing cron matcher + the multi-game config/layout helpers.
sys.path.insert(0, str(Path(__file__).parent))
from cron_match import cron_match
import spx_config

# REPO_DIR is the framework root (one dir above scripts/), == spx_config.REPO.
REPO_DIR = Path(spx_config.REPO)
SCHEDULE = REPO_DIR / "schedule.yaml"

# ── GLOBAL state (account/machine-wide, NOT namespaced by game) ──────────────
# Token/$ accounting and the pause flag reflect the one account / one machine.
TOKEN_USAGE_FILE = REPO_DIR / ".cache" / "token-usage.json"
PAUSED = REPO_DIR / ".paused"
TZ = ZoneInfo("America/Los_Angeles")


# ── PER-GAME state (namespaced under state/<slug>/ and logs/<slug>/) ─────────
# These were flat .cache/… and logs/… paths in the single-game layout; they now
# resolve through spx_config's per-game helpers.
def _state_file(slug: str) -> Path:          # cap counter, signal timestamps
    return Path(spx_config.cache_dir(slug)) / "continuous-state.json"


def _tr_pending(slug: str) -> Path:
    return Path(spx_config.cache_dir(slug)) / "test-runner-pending"


def _tr_active(slug: str) -> Path:
    return Path(spx_config.cache_dir(slug)) / "test-runner-active"


def _tr_progress(slug: str) -> Path:
    return Path(spx_config.cache_dir(slug)) / "test-runner-progress.json"


def _interactive_dev_active(slug: str) -> Path:
    return Path(spx_config.cache_dir(slug)) / "interactive-dev-active"


def _tick_log_dir(slug: str) -> Path:
    return Path(spx_config.game_logs_dir(slug)) / "tick"


def _continuous_log_dir(slug: str) -> Path:
    return Path(spx_config.game_logs_dir(slug)) / "continuous"


def _test_runner_log_dir(slug: str) -> Path:
    return Path(spx_config.game_logs_dir(slug)) / "test_runner"


def enabled_games() -> list:
    """Enabled games from the registry (falls back to all if none flagged)."""
    reg = spx_config.games()
    return [g for g in reg if g.get("enabled")] or reg

# Target render width. The layout is two top-level columns: a LEFT column with
# the status/queue/throughput/agenda panels, and a RIGHT column with recent
# tick activity + ships + last log line. Truncation caps derive from these.
WIDTH = 200
_INDENT = 4                            # leading "    " on every content row
GUTTER = 4                             # blank columns between left and right
LEFT_W = 122                           # left-column content width (incl its indent)
RIGHT_W = WIDTH - LEFT_W - GUTTER      # right-column content width (= 74)
_COL_W = (LEFT_W - _INDENT) // 2       # internal 2-col cell width for LEFT panels

# ANSI color codes (stdlib-only "rich")
RESET = "\033[0m"
BOLD = "\033[1m"
DIM = "\033[2m"
RED = "\033[31m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
BLUE = "\033[34m"
MAGENTA = "\033[35m"
CYAN = "\033[36m"
GRAY = "\033[90m"
ORANGE = "\033[38;5;208m"   # 256-color orange (for "tomorrow" in the schedule)
CLEAR_SCREEN = "\033[2J\033[H"


def sh(cmd: str, cwd: Path | None = None) -> str:
    try:
        r = subprocess.run(
            cmd, shell=True, capture_output=True, text=True,
            cwd=str(cwd) if cwd else None, timeout=5,
        )
        return r.stdout.strip()
    except Exception:
        return ""


def _spx_get(key: str, default: str = "", slug: str | None = None) -> str:
    """Read a MERGED-config value (COMPANY_CONFIG + game GAME_CONFIG) via spx_config.

    `slug` selects which game's GAME_CONFIG.yaml is overlaid (default: current
    game). Continuous/system-level keys are the same across games, so most
    callers omit it; per-game presentational keys (dashboard.*) may pass it.
    """
    g = f" --game {slug}" if slug else ""
    val = sh(f'python3 "{REPO_DIR}/scripts/spx_config.py" get {key}{g}')
    return val if val else default


def token_usage_status() -> dict | None:
    """Read the cached subscription-vs-API-credit split (scripts/token_usage.py)."""
    if not TOKEN_USAGE_FILE.exists():
        return None
    try:
        return json.loads(TOKEN_USAGE_FILE.read_text())
    except Exception:
        return None


def _fmt_tok(n) -> str:
    """Compact token count: 12345678 -> '12.3M', 456789 -> '0.46M'."""
    try:
        n = int(n)
    except (TypeError, ValueError):
        return "?"
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.0f}K"
    return str(n)


def _reset_note(pool: dict) -> str:
    """e.g. 'resets Mon Jun 15 (1d left, 86% through)' from a token-usage pool."""
    rs = pool.get("resets", "")
    try:
        dt = datetime.strptime(rs, "%Y-%m-%d %H:%M:%S %Z")
        when = f"{dt.strftime('%a %b')} {dt.day}"
    except Exception:
        when = rs.split(" ")[0] if rs else "?"
    bits = []
    if pool.get("days_left") is not None:
        bits.append(f"{pool['days_left']}d left")
    if pool.get("pct_elapsed") is not None:
        bits.append(f"{pool['pct_elapsed']}% through")
    extra = f" ({', '.join(bits)})" if bits else ""
    return f"resets {when}{extra}"


_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def _vis_len(s: str) -> int:
    """Visible length of a string, ignoring ANSI color escapes."""
    return len(_ANSI_RE.sub("", s))


def _fit_vis(s: str, w: int) -> str:
    """Truncate/pad `s` to EXACTLY `w` visible columns, preserving ANSI codes
    (so a long left-column line can never push the right column out of place)."""
    out = []
    vis = 0
    i = 0
    saw_ansi = False
    while i < len(s) and vis < w:
        if s[i] == "\x1b":
            m = _ANSI_RE.match(s, i)
            if m:
                out.append(m.group(0)); i = m.end(); saw_ansi = True; continue
        out.append(s[i]); vis += 1; i += 1
    res = "".join(out)
    if saw_ansi:
        res += RESET
    if vis < w:
        res += " " * (w - vis)
    return res


def _compose_columns(left: list, right: list, left_w: int, gutter: int,
                     right_w: int) -> list:
    """Lay two lists of pre-rendered lines side by side. Left lines are fit to
    `left_w` and right lines to `right_w` visible cols (so no row can exceed
    left_w+gutter+right_w), then trailing pad is stripped. Rows past the end of
    either column fall back to blanks on that side."""
    n = max(len(left), len(right))
    out = []
    for i in range(n):
        l = left[i] if i < len(left) else ""
        r = right[i] if i < len(right) else ""
        if r:
            out.append((_fit_vis(l, left_w) + (" " * gutter) + _fit_vis(r, right_w)).rstrip())
        else:
            out.append(l.rstrip())
    return out


def recent_tick_dispatches(slug: str, n: int = 10) -> list:
    """The last N tick runs that actually dispatched an agent (idle
    'dispatched=[] errors=[]' ticks are skipped). Newest first.
    Returns [(hh:mm:ss, what_dispatched, errors)]. Reads the PER-GAME tick log."""
    try:
        files = sorted(_tick_log_dir(slug).glob("*.log"))
    except Exception:
        return []
    rows: list = []
    for f in reversed(files):              # newest day first
        try:
            for ln in reversed(f.read_text().splitlines()):
                m = re.search(r"(\d{2}:\d{2}:\d{2}).*tick dispatched=\[(.*?)\]\s*errors=\[(.*?)\]", ln)
                if not m:
                    continue
                disp = m.group(2).strip()
                if not disp:
                    continue               # idle tick — nothing dispatched
                rows.append((m.group(1), disp, m.group(3).strip()))
                if len(rows) >= n:
                    return rows
        except Exception:
            continue
    return rows


def _schedule_int(key: str, default: int) -> int:
    """Read an integer `key: N` out of schedule.yaml (e.g. max_minutes)."""
    try:
        m = re.search(rf"^\s*{key}:\s*(\d+)", SCHEDULE.read_text(), re.M)
        return int(m.group(1)) if m else default
    except Exception:
        return default


def test_runner_status(now: datetime, slug: str) -> dict | None:
    """Status of the batch test runner, or None when idle. All reads are cheap
    (flag mtime, progress.json, today's log) — never invokes the suite. Reads
    PER-GAME runner flags + log.
    Keys: state ('running'|'pending'), elapsed_s, budget_min, ran, total,
    fail_count, fails (recent test names)."""
    tr_active = _tr_active(slug)
    if tr_active.exists():
        state = "running"
    elif _tr_pending(slug).exists():
        state = "pending"
    else:
        return None
    out = {"state": state, "elapsed_s": None, "budget_min": _schedule_int("max_minutes", 120),
           "ran": None, "total": None, "fail_count": 0, "fails": []}
    if state == "running":
        try:
            start = datetime.fromtimestamp(tr_active.stat().st_mtime, TZ)
            out["elapsed_s"] = int((now - start).total_seconds())
        except Exception:
            pass
    try:
        out["ran"] = len(json.loads(_tr_progress(slug).read_text()).get("ran", []))
    except Exception:
        pass
    try:
        lines = (_test_runner_log_dir(slug) / f"{now:%Y-%m-%d}.log").read_text().splitlines()
    except Exception:
        lines = []
    for ln in reversed(lines):                      # total = last "suite: N tests"
        m = re.search(r"suite:\s*(\d+)\s*tests", ln)
        if m:
            out["total"] = int(m.group(1)); break
    start_idx = 0                                   # only count fails since the last run start
    for i in range(len(lines) - 1, -1, -1):
        if "] start " in lines[i] or "start —" in lines[i]:
            start_idx = i; break
    fails = []
    for ln in lines[start_idx:]:
        m = re.search(r"\bFAIL\s+(\S+)", ln)
        if m:
            fails.append(m.group(1).split("/")[-1].replace(".gd", ""))
    out["fail_count"] = len(fails)
    out["fails"] = fails[-3:]
    return out


def fmt_etime(seconds: int) -> str:
    if seconds < 60: return f"{seconds}s"
    if seconds < 3600: return f"{seconds // 60}m{seconds % 60:02d}s"
    h, r = divmod(seconds, 3600)
    return f"{h}h{r // 60:02d}m"


def process_etime(pid: int) -> int | None:
    out = sh(f"ps -p {pid} -o etime= 2>/dev/null")
    if not out: return None
    parts = out.split("-")
    if len(parts) == 2:
        days, rest = int(parts[0]), parts[1]
    else:
        days, rest = 0, parts[0]
    hms = rest.split(":")
    if len(hms) == 3:
        h, m, s = (int(x) for x in hms)
    elif len(hms) == 2:
        h, m, s = 0, int(hms[0]), int(hms[1])
    else:
        h, m, s = 0, 0, int(hms[0])
    return days * 86400 + h * 3600 + m * 60 + s


def pgrep(pattern: str) -> list[int]:
    out = sh(f"pgrep -f {pattern!r} 2>/dev/null")
    if not out: return []
    return [int(x) for x in out.splitlines() if x.strip().isdigit()]


def real_wrappers() -> dict[int, int]:
    """Return {worker_id: wrapper_pid} for live, real wrapper processes.

    Disambiguates the real wrapper from its dev-watchdog subshell
    (`( sleep …; kill_tree ) &` inside ship_one_item). The subshell
    inherits the parent's $0 so it appears in `ps` with the IDENTICAL
    command line as the wrapper.

    The real wrapper is the one launchd spawned: ppid == 1. The watchdog
    subshell's ppid is the wrapper. We pick by ppid, NOT by min-PID — the
    old min-PID heuristic broke under PID wraparound: a watchdog spawned
    late (after the PID counter wrapped past ~99999) gets a LOWER pid than
    its long-lived wrapper, so min-PID picked the watchdog → its only
    child is `sleep` → the dashboard reported the worker as "idle" while it
    was actually mid-dev (2026-05-27 incident).
    """
    out = sh("ps -eo pid,ppid,command 2>/dev/null")
    cands: dict[int, list[tuple[int, int]]] = {}   # wid -> [(pid, ppid)]
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) < 3: continue
        pid_str, ppid_str, cmd = parts
        if not pid_str.isdigit() or not ppid_str.isdigit(): continue
        if "continuous_dev.sh" not in cmd: continue
        m = re.search(r"--worker-id (\d+)(?:$|\s)", cmd)
        if not m: continue
        cands.setdefault(int(m.group(1)), []).append((int(pid_str), int(ppid_str)))
    result: dict[int, int] = {}
    for wid, lst in cands.items():
        sibling_pids = {p for p, _ in lst}
        # Prefer launchd-spawned (ppid==1); else the one whose parent is NOT
        # a sibling subshell (i.e., the true root); last resort: min pid.
        roots = [p for p, pp in lst if pp == 1] \
             or [p for p, pp in lst if pp not in sibling_pids]
        result[wid] = min(roots) if roots else min(sibling_pids)
    return result


def worker_phase(worker_id: int) -> tuple[str, int | None]:
    """Return (phase_label, seconds_in_phase) for a parallel-dev worker.

    Inspects the worker's wrapper PID + its current child process to infer
    what stage of the ship pipeline it's in:
      - dev    : claude session writing code
      - review : reviewer agent reviewing the diff
      - tests  : actively running godot scenarios
      - wait   : in run_local_tests.sh lock-wait loop (another worker
                 is currently holding the test lock)
      - idle   : sleeping in the main loop between iterations
    Returns ("(not running)", None) if the wrapper isn't alive at all.
    """
    wrapper_pid = real_wrappers().get(worker_id)
    if wrapper_pid is None:
        return ("(not running)", None)
    out = sh(f"pgrep -P {wrapper_pid} 2>/dev/null")
    children = [int(c) for c in out.splitlines() if c.strip().isdigit()] if out else []
    for cpid in children:
        cmd = sh(f"ps -p {cpid} -o command=").strip()
        et = process_etime(cpid)
        if "run_agent.sh developer" in cmd:
            return ("dev", et)
        if "run_agent.sh reviewer" in cmd:
            return ("review", et)
        if "run_local_tests.sh" in cmd:
            # Distinguish actively-testing (godot grandchild exists)
            # from lock-waiting (no godot, just polling the lockdir).
            gc_out = sh(f"pgrep -P {cpid} 2>/dev/null")
            has_godot = False
            if gc_out:
                for gc in gc_out.splitlines():
                    gc = gc.strip()
                    if not gc.isdigit():
                        continue
                    gc_cmd = sh(f"ps -p {gc} -o command=").strip()
                    if "godot" in gc_cmd.lower():
                        has_godot = True
                        break
            return ("tests" if has_godot else "wait", et)
        if "sleep" in cmd and cmd.startswith("sleep"):
            return ("idle", et)
    return ("idle", None)


def worker_commits(worker_id: int, slug: str) -> tuple[int, int] | None:
    """(commits_ahead_of_origin/master, seconds_since_last_commit) for the worker's
    feat branch, read from its PER-GAME worktree — a live "is it actually making
    progress?" signal now that devs commit incrementally. None if no worktree."""
    wt = Path(spx_config.worktrees_dir(slug)) / f"worker-{worker_id}"
    if not wt.is_dir():
        return None
    n_out = sh(f"git -C {wt} rev-list --count origin/master..HEAD 2>/dev/null")
    try:
        n = int((n_out or "0").strip() or "0")
    except ValueError:
        return None
    if n == 0:
        return (0, 0)
    ts = sh(f"git -C {wt} log -1 --format=%ct HEAD 2>/dev/null").strip()
    age = (int(time.time()) - int(ts)) if ts.isdigit() else 0
    return (n, age)


def parse_schedule_yaml() -> list[tuple[str, str]]:
    if not SCHEDULE.exists(): return []
    text = SCHEDULE.read_text()
    m = re.search(r"^agents:\s*\n((?:[ \t]+\S.*\n?)*)", text, re.M)
    if not m: return []
    out = []
    for line in m.group(1).splitlines():
        mm = re.match(r"\s*(\w+):\s*\{[^}]*cron:\s*\"([^\"]+)\"", line)
        if mm: out.append((mm.group(1), mm.group(2)))
    return out


def next_n_fires(now: datetime, n: int = 10) -> list[tuple[datetime, str]]:
    schedule = parse_schedule_yaml()
    if not schedule: return []
    events = []
    for name, cron in schedule:
        scan = now.replace(second=0, microsecond=0) + timedelta(minutes=1)
        end = now + timedelta(days=35)
        # Scan further per-agent so monthly fires (asset-librarian) make it in.
        found = 0
        while scan < end and found < 4:
            try:
                if cron_match(cron, scan):
                    events.append((scan, name))
                    found += 1
            except Exception:
                break
            scan += timedelta(minutes=1)
    events.sort(key=lambda e: e[0])
    return events[:n]


PLAYTESTED_FILE = ".factory/local/playtested.json"   # CEO-local, gitignored, per-day


def _playtest_key(text: str) -> str:
    """Stable key for a play-test item — the leading [slug] if present, else a
    slug of the first few words. Used to match what the CEO marked done."""
    m = re.match(r"^\s*\[([A-Za-z0-9][A-Za-z0-9 _-]*)\]", text)
    if m:
        return m.group(1).strip().lower().replace(" ", "-")
    base = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return "-".join(base.split("-")[:6])


def _playtested_keys(game_dir: Path | None) -> set[str]:
    """Keys the CEO marked play-tested TODAY (auto-resets each day)."""
    if not game_dir:
        return set()
    p = game_dir / PLAYTESTED_FILE
    if not p.exists():
        return set()
    try:
        d = json.loads(p.read_text())
    except Exception:
        return set()
    if d.get("date") != datetime.now(TZ).strftime("%Y-%m-%d"):
        return set()   # stale day → treat as none done
    return set(d.get("slugs", []))


def playtest_texts(game_dir: Path | None, limit: int = 20) -> list[str]:
    """The raw play-test feature lines (no done-filtering). Source: TODAY's
    MORNING.md ▶ Play-test section; falls back to recent git `feat:` ships if
    MORNING.md isn't today's. Shared by the dashboard + playtested.sh."""
    if not game_dir:
        return []
    items: list[str] = []
    mpath = game_dir / ".factory" / "local" / "MORNING.md"
    if mpath.exists():
        try:
            text = mpath.read_text(errors="replace")
        except Exception:
            text = ""
        today = datetime.now(TZ).strftime("%Y-%m-%d")
        # Trust MORNING.md as today's if the date appears anywhere in it OR the
        # file was (re)written today. The briefer overwrites it fresh each
        # morning, so mtime is a reliable freshness signal even when the agent
        # forgets the dated `# Morning — <date>` header (gating on line 1 alone
        # silently dropped us to the git-log fallback, whose slugs don't match
        # the [bracket] keys the CEO sees). A stale file from a prior day fails
        # both checks → we fall back to the git-log ship list as before.
        try:
            mtime_day = datetime.fromtimestamp(mpath.stat().st_mtime,
                                               TZ).strftime("%Y-%m-%d")
        except Exception:
            mtime_day = ""
        if today in text or mtime_day == today:
            sec = re.search(r"^##\s*▶?\s*Play-test.*?\n(.*?)(?=^##\s|\Z)",
                            text, re.S | re.M)
            if sec:
                for m in re.finditer(r"^\s*\d+\.\s+(.*)$", sec.group(1), re.M):
                    t = re.sub(r"\s*—\s*`[0-9a-f]+`\s*$", "", m.group(1).strip())
                    items.append(t)
    if not items:
        out = sh("git log master --grep='^feat:' --author='continuous-bot' --author='Interactive Dev' "
                 "--since='yesterday 21:00' --pretty='%s'", cwd=game_dir)
        for ln in (out.splitlines() if out else []):
            items.append(re.sub(r"^feat(\([^)]*\))?:\s*", "", ln))
    return items[:limit]


def _morning_playtest(game_dir: Path | None, limit: int = 6) -> list[tuple[str, str]]:
    """Play-test to-dos still pending — the overnight features worth verifying,
    MINUS any the CEO marked done today (via scripts/playtested.sh)."""
    tested = _playtested_keys(game_dir)
    out: list[tuple[str, str]] = []
    for t in playtest_texts(game_dir, limit=20):
        if _playtest_key(t) in tested:
            continue
        out.append(("playtest", t))
        if len(out) >= limit:
            break
    return out


def _triage_awaiting(game_dir: Path | None) -> list[tuple[str, str]]:
    """Triage questionnaires awaiting your answers — parsed from the local
    TRIAGE.md '## ⏳ Awaiting your answers' section. Each '### T-xxxx · <title>'
    header under it is one proposal the Architect needs you to answer before
    the item can be built."""
    if not game_dir:
        return []
    tpath = game_dir / ".factory" / "local" / "TRIAGE.md"
    if not tpath.exists():
        return []
    try:
        text = tpath.read_text(errors="replace")
    except Exception:
        return []
    m = re.search(r"^##\s*⏳\s*Awaiting.*?\n(.*?)(?=^##\s|\Z)", text, re.S | re.M)
    if not m:
        return []
    out: list[tuple[str, str]] = []
    for hm in re.finditer(r"^###\s+(T-\S+)\s*·?\s*(.*)$", m.group(1), re.M):
        out.append(("triage", (hm.group(2).strip() or hm.group(1))))
    return out


def pending_ceo_actions(game_dir: Path | None, n: int = 10) -> list[tuple[str, str]]:
    """Return up to n (label, text) CEO to-dos — the dashboard mirror of the
    morning routine — ordered by urgency:
      1. [needs-ceo] — dev asked questions (live WORK.md)
      2. [escalated] — design/PM call manually flagged (live WORK.md; RARE)
      2b. triage     — shaping questionnaires awaiting your answers (TRIAGE.md)
      3. play-test   — overnight features to verify (MORNING.md / git)
      4. [bug]       — bugs to triage (live WORK.md)
      5. [idea]      — designer suggestions to decide (live WORK.md)
      6. MANUAL      — your highest hand-work items (top of the queue)
      7. dictation   — raw notes not yet drained

    Live WORK.md is the source for everything that lives there (so it's never
    stale); MORNING.md only supplies the play-test list, its unique value.
    [retry] items are NOT CEO actions — they auto-retry without you.
    """
    if not game_dir:
        return []
    work_md = game_dir / "WORK.md"
    if not work_md.exists():
        return []
    sys.path.insert(0, str(Path(__file__).parent))
    try:
        from workmd import parse
        wm = parse(work_md)
    except Exception:
        return []

    out: list[tuple[str, str]] = []
    # 1. needs-ceo (blocking)
    for it in wm.todo:
        if it.is_needs_ceo:
            out.append(("needs-ceo", it.title))
    # 2. escalated (blocking)
    for it in wm.todo:
        if it.is_escalated and not it.is_needs_ceo:
            out.append(("escalated", it.title))
    # 2b. triage questionnaires awaiting your answers (local TRIAGE.md)
    out += _triage_awaiting(game_dir)
    # 3. play-test (overnight ships to verify)
    out += _morning_playtest(game_dir, limit=5)
    # 4. bugs to triage (workmd has no is_bug; match the [bug] tag)
    bug_added = 0
    for it in wm.todo:
        if it.title.lstrip().lower().startswith("[bug]") and bug_added < 3:
            out.append(("bug", it.title))
            bug_added += 1
    # 5. ideas to decide
    for it in wm.todo:
        if it.is_idea and not it.is_concern and not it.is_needs_ceo and not it.is_escalated:
            out.append(("idea", it.title))
    # 6. highest MANUAL hand-work (first few in queue order = highest-placed)
    manual_added = 0
    for it in wm.todo:
        if it.is_manual and manual_added < 5:
            out.append(("manual", it.title))
            manual_added += 1
    # 7. dictation backlog
    raw = game_dir / ".factory" / "inbox" / "raw.md"
    if raw.exists() and raw.stat().st_size > 0:
        out.append(("dictation", f"raw.md has {raw.stat().st_size} bytes — run /spraxel-producer"))

    return out[:n]


def last_log_line(slug: str) -> tuple[str, str]:
    """Last meaningful `continuous:` line across ALL per-worker logs.

    Returns (worker_label, line). worker_label is "w1" / "w2" / "w3" /
    "—" for legacy single-wrapper logs. Picks the line with the most
    recent file mtime across the per-worker logs so the dashboard shows
    the truly newest event, not the legacy daily-aggregate file. Reads the
    PER-GAME continuous log dir.
    """
    clog_dir = _continuous_log_dir(slug)
    today = datetime.now(TZ).strftime("%Y-%m-%d")
    yesterday = (datetime.now(TZ) - timedelta(days=1)).strftime("%Y-%m-%d")
    # Collect candidate log files (today's per-worker + yesterday's + legacy).
    candidates: list[tuple[Path, str]] = []
    for stamp in (today, yesterday):
        for p in clog_dir.glob(f"{stamp}-w*.log"):
            m = re.search(r"-w(\d+)\.log$", p.name)
            wid = f"w{m.group(1)}" if m else "—"
            candidates.append((p, wid))
        legacy = clog_dir / f"{stamp}.log"
        if legacy.exists():
            candidates.append((legacy, "—"))
    if not candidates:
        return ("—", "(no log)")
    # Sort by mtime desc — newest log first.
    candidates.sort(key=lambda pair: pair[0].stat().st_mtime, reverse=True)
    for path, wid in candidates:
        try:
            lines = path.read_text().splitlines()
        except Exception:
            continue
        for ln in reversed(lines):
            ln = ln.strip()
            if ln.startswith("continuous:"):
                return (wid, ln[:WIDTH - 10])
    return ("—", "(empty)")


def escalations_today(game_dir: Path | None) -> int:
    if not game_dir: return 0
    today = datetime.now(TZ).strftime("%Y-%m-%d")
    out = sh(f"grep -c '^## Escalated {today}' .factory/escalations.md 2>/dev/null", cwd=game_dir)
    try:
        return int(out)
    except ValueError:
        return 0


def ships_today(game_dir: Path | None) -> int:
    if not game_dir: return 0
    out = sh(
        "git log master --since=midnight --pretty='%h' --grep='^feat:' "
        "--author='continuous-bot' --author='Interactive Dev' | wc -l",
        cwd=game_dir,
    )
    try:
        return int(out)
    except ValueError:
        return 0


def ship_throughput(game_dir: Path | None) -> dict[str, int | float]:
    """Compute lifetime + recent ship counts straight from git log.

    Returns:
      lifetime:  total continuous-bot `feat:` commits ever
      today:     ships since midnight
      seven_day: ships in the last 7 days
      avg_per_day: 7d ships ÷ 7 (rolling average)

    No state file maintenance — git log is the source of truth.
    """
    if not game_dir:
        return {"lifetime": 0, "today": 0, "seven_day": 0, "avg_per_day": 0.0}
    def n(args: str) -> int:
        out = sh(
            f"git log master {args} --pretty='%h' --grep='^feat:' "
            f"--author='continuous-bot' --author='Interactive Dev' | wc -l",
            cwd=game_dir,
        )
        try: return int(out)
        except ValueError: return 0
    lifetime  = n("")
    today     = n("--since=midnight")
    seven_day = n("--since=7.days.ago")
    return {
        "lifetime":   lifetime,
        "today":      today,
        "seven_day":  seven_day,
        "avg_per_day": round(seven_day / 7.0, 1),
    }


def last_n_ships(game_dir: Path | None, n: int = 20) -> list[tuple[str, str, str]]:
    """Return the last n shipped feat commits as (sha, age, subject).

    Reads from git log master, filtered to `feat:` commits authored by the
    continuous-bot. Age is a short relative string ("3h", "yesterday",
    "2d"). Subject is the part after `feat[(scope)]:` so the dashboard
    can show what landed rather than echoing the prefix.
    """
    if not game_dir: return []
    # %h short sha, %cr relative date, %s subject
    out = sh(
        f"git log master --pretty=format:'%h|%cr|%s' --grep='^feat:' "
        f"--author='continuous-bot' --author='Interactive Dev' -n {n}",
        cwd=game_dir,
    )
    if not out:
        return []
    rows: list[tuple[str, str, str]] = []
    for line in out.splitlines():
        parts = line.split("|", 2)
        if len(parts) != 3:
            continue
        sha, age, subject = parts
        # Strip the conventional-commits prefix for display
        m = re.match(r"^feat(?:\([^)]+\))?:\s*(.*)$", subject)
        subject = m.group(1) if m else subject
        # Shorten common age strings ("3 hours ago" → "3h", "yesterday" → "1d",
        # "2 days ago" → "2d", "3 weeks ago" → "3w")
        age = re.sub(r"\s+ago$", "", age).strip()
        age = age.replace("yesterday", "1 day")
        m2 = re.match(r"^(\d+)\s+(second|minute|hour|day|week|month|year)s?$", age)
        if m2:
            n_units, unit = m2.group(1), m2.group(2)
            short = {"second":"s","minute":"m","hour":"h","day":"d","week":"w","month":"mo","year":"y"}[unit]
            age = f"{n_units}{short}"
        elif age == "just now":
            age = "now"
        rows.append((sha, age, subject))
    return rows


def read_config_int(slug: str | None, dotted_key: str, default: int) -> int:
    """Resolve a numeric config value via spx_config (deep-merged COMPANY_CONFIG
    + the game's GAME_CONFIG.yaml).

    `dotted_key` is e.g. "dashboard.recent_ships". `slug` selects which game's
    GAME_CONFIG override to honor (None = current game). Falls back to `default`
    on any error or missing key.
    """
    try:
        val = spx_config.get(dotted_key, default=default, game=slug)
        return int(val)
    except Exception:
        return default


def queue_composition(game_dir: Path | None) -> dict:
    """Composition of WORK.md ## Todo: total item count, eligible (buildable)
    count, and a count by primary tag. eligible == 0 means the buildable queue
    is EXHAUSTED — workers idle for the right reason, not a bug."""
    out = {"total": 0, "eligible": -1, "by_tag": {}}
    if not game_dir:
        return out
    wm_path = game_dir / "WORK.md"
    try:
        from workmd import parse as parse_wm, top_n
        wm = parse_wm(wm_path)
    except Exception:
        return out
    todo = wm.todo
    out["total"] = len(todo)
    counts: dict[str, int] = {}
    for it in todo:
        m = re.match(r"\[([a-z0-9-]+)(?::\d+)?\]", it.title.strip().lower())
        tag = m.group(1) if m else "(untagged)"
        counts[tag] = counts.get(tag, 0) + 1
    out["by_tag"] = counts
    try:
        out["eligible"] = len(top_n(wm_path, n=999))
    except Exception:
        out["eligible"] = -1
    return out


def _token_usage_lines(lines: list) -> None:
    """Append the GLOBAL token/$ usage block to `lines`. Reads token-usage.json
    from the GLOBAL cache (REPO/.cache) — account/machine-wide, NOT per-game."""
    tu = token_usage_status()
    if not tu:
        return
    calc = tu.get("calculated_ts", "?")
    # strip seconds for compactness: "2026-06-14 21:10:38 PDT" -> "2026-06-14 21:10 PDT"
    parts = calc.split(" ")
    calc_short = f"{parts[0]} {parts[1][:5]} {parts[2]}" if len(parts) == 3 else calc
    sub = tu.get("subscription", {})
    api = tu.get("api_credit", {})
    lines.append(f"  Token usage    {DIM}(calc {calc_short}){RESET}")

    # Composition line for a pool — most of any pool's token total is cheap
    # cache_read (the cached prompt re-read every turn), not real output. They
    # all cost (cache_read is just billed cheaply), so this is presentational:
    # it stops the headline token count from looking alarming. Shown under
    # whichever pool actually has tokens this window.
    def _composition_line(pool):
        bd = pool.get("token_breakdown") or {}
        tot = pool.get("total_tokens") or 0
        cr = bd.get("cache_read", 0)
        if not (tot and cr):
            return None
        pct = round(100 * cr / tot)
        return (
            f"    {'':<12} {DIM}↳ {_fmt_tok(cr)} ({pct}%) cache reads (billed cheap) · "
            f"{_fmt_tok(bd.get('output', 0))} output · "
            f"{_fmt_tok(bd.get('cache_write', 0))} cache-write{RESET}"
        )

    # Headline count = UNCACHED tokens (input + output + cache_write) — i.e.
    # total minus the cheap cache_read re-reads. That's the "real work" volume;
    # the cache_read share is shown on the ↳ composition line below.
    def _uncached(pool):
        bd = pool.get("token_breakdown") or {}
        return (pool.get("total_tokens") or 0) - bd.get("cache_read", 0)

    lines.append(
        f"    {'Subscription':<12} {GREEN}{_fmt_tok(_uncached(sub)):>8}{RESET} tokens"
        f" {DIM}(uncached) this week · {_reset_note(sub)}{RESET}"
    )
    sub_comp = _composition_line(sub)
    if sub_comp:
        lines.append(sub_comp)
    cap = api.get("cap_usd") or 0
    spent = api.get("est_usd") or 0
    if cap:
        frac = spent / cap if cap else 0
        cc = RED if frac > 0.85 else (YELLOW if frac > 0.60 else GREEN)
        dollars = f"{cc}~${spent:,.0f} / ${cap:,.0f}{RESET}"
    else:
        dollars = f"{GREEN}~${spent:,.0f}{RESET}"
    lines.append(
        f"    {'API credit':<12} {GREEN}{_fmt_tok(_uncached(api)):>8}{RESET} tokens"
        f" {DIM}(uncached){RESET}  {dollars}  {DIM}this month · {_reset_note(api)}{RESET}"
    )
    api_comp = _composition_line(api)
    if api_comp:
        lines.append(api_comp)
    lines.append("")


def _next_agents_lines(now: datetime, lines: list) -> None:
    """Append the GLOBAL 'Next 10 agents to execute' block. The schedule
    (schedule.yaml) is account/machine-wide, so this is rendered once."""
    lines.append(f"  {BOLD}▸ Next 10 agents to execute{RESET}")
    fires = next_n_fires(now, 10)
    if not fires:
        lines.append(f"    {DIM}(no upcoming runs found){RESET}")
        return

    def _fire_cell(ts, name, cap: int) -> tuple[str, int]:
        # Absolute date+time, 24h, e.g. "20260602 13:00 PST". Whole cell is
        # colored by proximity: today=yellow, tomorrow=orange, later=dim date.
        prefix = f"{ts:%Y%m%d %H:%M} PST"
        nm = name[:cap] + ("…" if len(name) > cap else "")
        vis = len(prefix) + 2 + len(nm)
        if ts.date() == now.date():
            return f"{YELLOW}{prefix}  {nm}{RESET}", vis          # today
        if ts.date() == (now + timedelta(days=1)).date():
            return f"{ORANGE}{prefix}  {nm}{RESET}", vis          # tomorrow
        return f"{DIM}{prefix}{RESET}  {nm}", vis                 # later days

    if len(fires) <= 5:
        for ts, name in fires:
            cell, _ = _fire_cell(ts, name, LEFT_W - 28)
            lines.append(f"    {cell}")
    else:
        # prefix ("20260602 13:00 PST  ") is 20 cols; fill the rest of the column.
        ROWS, CAP, CELL_W = 5, _COL_W - 22, _COL_W
        left, right = fires[:ROWS], fires[ROWS:]
        for i in range(len(left)):
            lcell, lvis = _fire_cell(left[i][0], left[i][1], CAP)
            if i < len(right):
                rcell, _ = _fire_cell(right[i][0], right[i][1], CAP)
                pad = " " * max(1, CELL_W - lvis)
                lines.append(f"    {lcell}{pad}{rcell}")
            else:
                lines.append(f"    {lcell}")


def _cap_counter_line(now: datetime, slug: str) -> str:
    """The 'Cap counter' row for a game — reads the PER-GAME continuous-state.json."""
    cap_line = "?"
    state_file = _state_file(slug)
    if state_file.exists():
        try:
            s = json.loads(state_file.read_text())
            shipped = s.get("shipped_since_last_signal", "?")
            last_sig = s.get("last_signal_ts", "?")
            try:
                ts = datetime.strptime(last_sig, "%Y-%m-%d %H:%M:%S %Z").replace(tzinfo=TZ)
                age = now - ts
                age_str = fmt_etime(int(age.total_seconds()))
            except Exception:
                age_str = ""
            cap_target = read_config_int(slug, "continuous.target_per_batch", 5)
            color = YELLOW if str(shipped) == str(cap_target) else GREEN
            cap_line = f"{color}{shipped}/{cap_target}{RESET} {DIM}since {last_sig} ({age_str} ago){RESET}"
        except Exception:
            pass
    return f"  Cap counter    {cap_line}"


def _per_game_panels(now: datetime, slug: str, game_dir: Path | None,
                     wrapper_pids: list) -> tuple[list, list, list]:
    """Build (left_pre, left_post, right) pre-rendered line lists for ONE game:
      left_pre : Test runner, Current items, Work queue, Throughput
      left_post: CEO action items
      right    : Recent tick dispatches, Last N shipped, Last log line
    The split lets the caller splice the GLOBAL 'Next 10 agents' block between
    Throughput and CEO actions (its historical position). All reads here are
    PER-GAME (resolved through the slug)."""
    ceo_actions_n  = read_config_int(slug, "dashboard.ceo_actions", 10)
    recent_ships_n = read_config_int(slug, "dashboard.recent_ships", 15)
    tick_dispatch_n = read_config_int(slug, "dashboard.tick_dispatches", 10)
    lines: list = []
    post: list = []
    right: list = []

    # Test runner — only while active/pending (it runs exclusively, pausing the
    # dev workers, so it explains an otherwise-idle "Current items" below).
    trs = test_runner_status(now, slug)
    if trs:
        if trs["state"] == "running":
            el = fmt_etime(trs["elapsed_s"]) if trs["elapsed_s"] is not None else "?"
            bm = trs["budget_min"]
            bud = f"{bm // 60}h" if bm and bm % 60 == 0 else (f"{bm}m" if bm else "∞")
            if trs["ran"] is not None and trs["total"]:
                pct = int(100 * trs["ran"] / trs["total"]) if trs["total"] else 0
                prog = f"  ·  {GREEN}{trs['ran']}/{trs['total']}{RESET} tests ({pct}%)"
            elif trs["ran"] is not None:
                prog = f"  ·  {GREEN}{trs['ran']}{RESET} tests run"
            else:
                prog = ""
            fc = trs["fail_count"]
            fcol = RED if fc else GREEN
            lines.append(f"  {BOLD}▸ Test runner{RESET}  {BLUE}▶ running{RESET} "
                         f"{DIM}{el} / {bud}{RESET}{prog}  ·  {fcol}{fc} fail{'' if fc == 1 else 's'}{RESET}")
            lines.append(f"    {DIM}runs exclusively — dev workers paused until it finishes{RESET}")
            for f in trs["fails"]:
                lines.append(f"    {RED}✗{RESET} {f}")
        else:  # pending
            lines.append(f"  {BOLD}▸ Test runner{RESET}  {YELLOW}⏳ scheduled{RESET} "
                         f"{DIM}— will run exclusively on the next tick{RESET}")
        lines.append("")

    # Current items — one row per worker. Combines two sources:
    #  - WORK.md [wip:N] tags → which item each worker claimed
    #  - process tree of each wrapper → what phase (dev/tests/review/idle)
    #                                   and how long the worker has been
    #                                   on the current phase
    lines.append(f"  {BOLD}▸ Current items{RESET}")
    wip_items: dict[int, str] = {}
    if game_dir is not None:
        sys.path.insert(0, str(Path(__file__).parent))
        try:
            from workmd import parse as parse_wm
            wm = parse_wm(game_dir / "WORK.md")
            for it in wm.todo:
                if it.is_wip:
                    wid = it.wip_worker_id
                    # Strip [wip:N] + state/kind tags for display.
                    clean = re.sub(r"^\[wip:\d+\]\s*", "", it.title)
                    clean = re.sub(r"^\[(retry|resume|escalated|bug|feature|chore|game-feature|epic)\]\s*", "", clean)
                    clean = clean[:60] + ("…" if len(clean) > 60 else "")
                    wip_items[wid] = clean
        except Exception:
            pass

    # Worker count comes from the wrapper count. Show every worker even if
    # it has no [wip:N] yet (idle / between items).
    n_workers = len(wrapper_pids)
    if n_workers == 0:
        if PAUSED.exists():
            lines.append(f"    {DIM}(nothing — system paused){RESET}")
        else:
            lines.append(f"    {RED}(nothing — workers not running!){RESET}")
    else:
        # Phase → color
        phase_color = {
            "dev":          MAGENTA,
            "tests":        BLUE,
            "wait":         GRAY,
            "review":       YELLOW,
            "idle":         GRAY,
            "(not running)": RED,
        }
        for wid in range(1, n_workers + 1):
            phase, secs = worker_phase(wid)
            color = phase_color.get(phase, RESET)
            tag = f"{color}{phase:<6}{RESET}"
            age = fmt_etime(secs) if secs is not None else "    "
            age_col = f"{DIM}{age:>5s}{RESET}"
            title = wip_items.get(wid, f"{DIM}(no item claimed){RESET}")
            if wid in wip_items:
                title_disp = f"{CYAN}\"{wip_items[wid]}\"{RESET}"
            else:
                title_disp = f"{DIM}(no item claimed){RESET}"
            # Commit progress: "+Nc <age>" = N commits on the branch, last one
            # <age> ago. Green if a commit landed recently, yellow if it's been
            # a while (possible stall), so you can see real progress at a glance.
            commits = worker_commits(wid, slug)
            cdisp = ""
            if commits and commits[0] > 0:
                n, cage = commits
                ccol = GREEN if cage < 300 else YELLOW
                plural = "commit" if n == 1 else "commits"
                cdisp = f"  {ccol}{n} {plural}, last {fmt_etime(cage)} ago{RESET}"
            lines.append(f"    {DIM}w{wid}{RESET}  {tag} {age_col}  {title_disp}{cdisp}")
    lines.append("")

    # Work queue composition + exhaustion indicator
    qc = queue_composition(game_dir)
    lines.append(f"  {BOLD}▸ Work queue{RESET}  {DIM}({qc['total']} items in Todo){RESET}")
    elig = qc["eligible"]
    if elig == 0:
        lines.append(f"    {YELLOW}⚠ buildable queue EXHAUSTED{RESET} — {DIM}0 eligible; workers idle by design (not a bug){RESET}")
        lines.append(f"    {DIM}refill: accept [idea]s / triage [needs-ceo] / answer TRIAGE; Designer auto-runs when dry{RESET}")
    elif elig > 0:
        lines.append(f"    {GREEN}{elig}{RESET} eligible to build now")
    else:
        lines.append(f"    {DIM}(eligible count unavailable){RESET}")
    if qc["by_tag"]:
        order = sorted(qc["by_tag"].items(), key=lambda kv: (-kv[1], kv[0]))
        breakdown = "  ".join(f"{n}×[{t}]" for t, n in order)
        lines.append(f"    {DIM}{breakdown}{RESET}")
    lines.append("")

    # Throughput — git-log derived, no state file race
    tput = ship_throughput(game_dir)
    lines.append(f"  {BOLD}▸ Throughput{RESET}")
    lines.append(f"    Today:        {GREEN}{tput['today']:>3}{RESET} {DIM}(dev ships — headless + interactive){RESET}")
    lines.append(f"    7-day:        {GREEN}{tput['seven_day']:>3}{RESET} {DIM}avg {tput['avg_per_day']}/day{RESET}")
    lines.append(f"    Lifetime:     {DIM}{tput['lifetime']:>3}{RESET}")
    lines.append(f"    Escalations:  {YELLOW}{escalations_today(game_dir):>3}{RESET} {DIM}(today, CEO-bound){RESET}")
    lines.append("")

    # Next N CEO action items (things blocking on you) — goes in `post`, AFTER
    # the global 'Next 10 agents' block the caller splices in.
    post.append(f"  {BOLD}▸ Next {ceo_actions_n} CEO action items{RESET}")
    actions = pending_ceo_actions(game_dir, ceo_actions_n)
    if not actions:
        post.append(f"    {DIM}(none — queue is clear){RESET}")
    else:
        # Color by category.
        color_map = {
            "needs-ceo": RED,
            "escalated": YELLOW,
            "triage":    MAGENTA,
            "concern":   MAGENTA,
            "playtest":  GREEN,
            "bug":       RED,
            "idea":      BLUE,
            "manual":    CYAN,
            "dictation": CYAN,
        }
        def _ceo_cell(kind: str, title: str, cap: int) -> tuple[str, int]:
            # Returns (colored cell text, visible width). Strips any leading
            # workflow tag + MANUAL prefix + pN — the category prefix conveys it.
            tag_color = color_map.get(kind, RESET)
            tag = f"{tag_color}[{kind}]{RESET}"
            clean = re.sub(r"^\s*(\[[^\]]+\]|p[0-3]|MANUAL\s*-\s*)\s*", "", title, flags=re.I)
            clean = re.sub(r"^\s*(\[[^\]]+\]|p[0-3])\s*", "", clean, flags=re.I)
            clean = clean[:cap] + ("…" if len(clean) > cap else "")
            return f"{tag} {clean}", len(f"[{kind}] ") + len(clean)

        if len(actions) <= 5:
            # One column — unchanged look, wide titles.
            for kind, title in actions:
                cell, _ = _ceo_cell(kind, title, LEFT_W - 20)
                post.append(f"    {cell}")
        else:
            # Two columns of five (column-major) so >5 items don't overflow
            # the window. Left col = first 5, right col = next 5.
            # "[kind] " prefix is ~12 cols; fill the rest of the column.
            ROWS, CAP, CELL_W = 5, _COL_W - 14, _COL_W
            left, right_cells = actions[:ROWS], actions[ROWS:]
            for i in range(len(left)):
                lcell, lvis = _ceo_cell(left[i][0], left[i][1], CAP)
                if i < len(right_cells):
                    rcell, _ = _ceo_cell(right_cells[i][0], right_cells[i][1], CAP)
                    pad = " " * max(1, CELL_W - lvis)
                    post.append(f"    {lcell}{pad}{rcell}")
                else:
                    post.append(f"    {lcell}")
    post.append("")

    # ===== RIGHT COLUMN — recent tick activity + ships + last log line =====
    # Recent tick dispatches — what the scheduler actually fired for this game,
    # newest first. Idle ticks (dispatched=[]) are filtered out.
    right.append(f"  {BOLD}▸ Recent tick dispatches (last {tick_dispatch_n}){RESET}")
    tdisp = recent_tick_dispatches(slug, tick_dispatch_n)
    if not tdisp:
        right.append(f"    {DIM}(no agent dispatches in recent ticks){RESET}")
    else:
        for t, what, errs in tdisp:
            col = RED if errs else GREEN
            mark = "✗" if errs else "▸"
            what_s = what[:RIGHT_W - 16] + ("…" if len(what) > RIGHT_W - 16 else "")
            right.append(f"    {DIM}{t}{RESET} {col}{mark}{RESET} {what_s}")
    right.append("")

    # Last N things shipped
    right.append(f"  {BOLD}▸ Last {recent_ships_n} shipped{RESET}")
    ships = last_n_ships(game_dir, recent_ships_n)
    if not ships:
        right.append(f"    {DIM}(no ships found in git log){RESET}")
    else:
        for sha, age, subject in ships:
            age_col = f"{age:>4s}"
            subj = subject[:RIGHT_W - 18] + ("…" if len(subject) > RIGHT_W - 18 else "")
            right.append(f"    {DIM}{sha} {age_col}{RESET}  {subj}")
    right.append("")

    # Most recent log line — across all per-worker continuous logs for this game.
    right.append(f"  {BOLD}▸ Last log line{RESET}")
    wid, last = last_log_line(slug)
    last_s = last[:RIGHT_W - 8] + ("…" if len(last) > RIGHT_W - 8 else "")
    right.append(f"    {DIM}{wid:>3s}  {last_s}{RESET}")
    right.append("")

    return lines, post, right


def render(now: datetime, games: list) -> str:
    """Render the dashboard. GLOBAL panels (status, models, tick daemon,
    wrappers, token/$ usage, scheduled agents) are rendered ONCE; per-game
    panels are rendered for each enabled game. With a single enabled game the
    output reads as it always has."""
    # The "primary" game drives the global status-row interactive-dev heartbeat +
    # test-runner decoration (these reflect machine-wide dev activity).
    primary = games[0] if games else {"slug": None, "dir": ""}
    p_slug = primary["slug"]

    title = f"SPRAXEL DASHBOARD — {now:%a %Y-%m-%d %H:%M:%S %Z}"
    bar = "─" * (WIDTH)
    head = [f"{BOLD}{CYAN}{title}{RESET}", f"{DIM}{bar}{RESET}", ""]

    # ── GLOBAL status panel (rendered once) ──
    lines: list = []

    # Whether ANY game has its (per-game) test runner active/pending — drives the
    # global status-row decoration. Single-game: just the primary game's flags.
    def _tr_state(slug):
        if slug is None:
            return None
        if _tr_active(slug).exists():
            return "running"
        if _tr_pending(slug).exists():
            return "pending"
        return None
    tr_any = None
    for g in games:
        st = _tr_state(g["slug"])
        if st == "running":
            tr_any = "running"; break
        if st == "pending":
            tr_any = "pending"

    # System status row
    if _spx_get("continuous.force_interactive_developers").lower() == "true":
        # force_interactive_developers mode: show TWO independent dimensions —
        #  (1) system pause (.paused) still governs the crew agents, and
        #  (2) whether a /spraxel-develop run is currently EXECUTING (a fresh
        #      heartbeat marker, touched each item by the skill).
        base = f"{YELLOW}⏸  PAUSED{RESET}" if PAUSED.exists() else f"{GREEN}▶  RUNNING{RESET}"
        try:
            stale = int(_spx_get("continuous.interactive_dev_heartbeat_stale_secs", "1800"))
        except ValueError:
            stale = 1800
        ida = _interactive_dev_active(p_slug) if p_slug else None
        executing = (
            ida is not None and ida.exists()
            and (time.time() - ida.stat().st_mtime) <= stale
        )
        dev_part = f"{GREEN}executing{RESET}" if executing else f"{GRAY}idle{RESET}"
        status = f"{base} {DIM}(interactive-dev){RESET} · develop: {dev_part}"
        if tr_any == "running":
            status += f" · {BLUE}test runner running{RESET}"
        elif tr_any == "pending":
            status += f" · {BLUE}test runner scheduled{RESET}"
    elif PAUSED.exists():
        status = f"{YELLOW}⏸  PAUSED{RESET}"
    elif tr_any == "running":
        status = f"{BLUE}▶  running — test runner running{RESET}"
    elif tr_any == "pending":
        status = f"{BLUE}▶  running — test runner scheduled{RESET}"
    else:
        status = f"{GREEN}▶  running{RESET}"
    lines.append(f"  Status         {status}")

    # Sonnet-cap auto-fallback (only shown while active)
    cap_status = sh(f'python3 "{REPO_DIR}/scripts/sonnet_cap.py" status')
    if cap_status.startswith("CAPPED"):
        lines.append(f"  Models         {YELLOW}⚠ Sonnet capped → Opus{RESET} {DIM}{cap_status[len('CAPPED → using Opus '):]}{RESET}")

    # Tick daemon
    tick_loaded = bool(sh("launchctl list | grep com.spraxel.tick"))
    tick_line = f"{GREEN}✓ loaded{RESET}" if tick_loaded else f"{RED}✗ NOT LOADED{RESET}"
    lines.append(f"  Tick daemon    {tick_line}")

    # Wrappers (one per parallel-dev worker). The "uptime" is the wrapper
    # process lifetime — NOT how long each worker has been on its current
    # item. The per-worker phase elapsed in "Current items" is more useful
    # for spotting stuck dev sessions.
    wrappers = real_wrappers()
    wrapper_pids = list(wrappers.values())
    if wrapper_pids:
        n = len(wrapper_pids)
        ets = sorted([process_etime(p) or 0 for p in wrapper_pids], reverse=True)
        max_age = fmt_etime(ets[0])
        wrapper_line = f"{GREEN}{n} worker(s){RESET} {DIM}wrapper proc up {max_age}{RESET}"
    else:
        wrapper_line = f"{GRAY}not running{RESET}" if PAUSED.exists() else f"{RED}⚠ not running{RESET}"
    lines.append(f"  Wrappers       {wrapper_line}")

    # Cap counter is PER-PROJECT — rendered inside each project's section below.
    lines.append("")

    # Token usage — GLOBAL (account/machine-wide token-usage.json). Rendered once.
    _token_usage_lines(lines)

    # Scheduled agents — GLOBAL (shared cron schedule). Rendered once under the
    # global panel (each project dispatches the same crons against its own state).
    _next_agents_lines(now, lines)

    # The dashboard is PER-PROJECT: a single GLOBAL header block (system / models /
    # tick / wrappers / token-usage / schedule), then ONE clearly-bannered section
    # per enabled game/project — uniform whether there is 1 project or N.
    blocks = ["\n".join(_compose_columns(lines, [], LEFT_W, GUTTER, RIGHT_W))]
    for g in games:
        gslug = g["slug"]
        gdir = Path(g["dir"]) if g["dir"] else None
        # Friendly project label: "<display name> · <slug>" (slug alone if no name).
        name = (_spx_get("identity.name", slug=gslug).strip() if gslug else "")
        label = f"{name} · {gslug}" if name and name != gslug else (gslug or "?")
        gpre, gpost, gright = _per_game_panels(now, gslug, gdir, wrapper_pids)
        sec: list = ["", f"  {BOLD}{CYAN}━━ {label} ━━{RESET}",
                     (_cap_counter_line(now, gslug) if gslug else "  Cap counter    ?"), ""]
        sec.extend(gpre)
        sec.extend(gpost)
        blocks.append("\n".join(_compose_columns(sec, gright, LEFT_W, GUTTER, RIGHT_W)))
    if not games:
        blocks.append(f"\n  {YELLOW}(no enabled games in the registry){RESET}")
    return "\n".join(head + blocks)


def _sleep_or_quit(interval: float) -> bool:
    """Sleep up to `interval` seconds, but return True early if the user
    presses 'q' (or Q). Requires the terminal in cbreak mode (set in main).
    Falls back to a plain sleep when stdin isn't a tty (piped/redirected)."""
    if not sys.stdin.isatty():
        time.sleep(interval)
        return False
    import select
    deadline = time.time() + interval
    while True:
        remaining = deadline - time.time()
        if remaining <= 0:
            return False
        r, _, _ = select.select([sys.stdin], [], [], remaining)
        if r:
            ch = sys.stdin.read(1)
            if ch in ("q", "Q"):
                return True
            # any other key: ignore, keep waiting out the interval


def main() -> int:
    p = argparse.ArgumentParser(description="Spraxel always-on dashboard")
    p.add_argument("--interval", type=int, default=5,
                   help="refresh interval in seconds (default: 5)")
    p.add_argument("--game", default=None,
                   help="show only this project/game slug (default: all enabled)")
    args = p.parse_args()

    def _games():
        gs = enabled_games()
        if args.game:
            gs = [g for g in gs if g["slug"] == args.game] or gs
        return gs

    # Re-read the game registry each refresh so enabling/adding a game shows up
    # without a restart.
    # Put the terminal in cbreak mode so a single 'q' keypress is readable
    # without Enter (mirrors Ctrl+C as a quit). Restored on exit.
    old_tty = None
    if sys.stdin.isatty():
        try:
            import termios, tty
            old_tty = termios.tcgetattr(sys.stdin)
            tty.setcbreak(sys.stdin.fileno())
        except Exception:
            old_tty = None
    try:
        while True:
            now = datetime.now(TZ)
            sys.stdout.write(CLEAR_SCREEN)
            sys.stdout.write(render(now, _games()))
            sys.stdout.write(f"\n{DIM}  refresh every {args.interval}s · press q or Ctrl+C to exit{RESET}\n")
            sys.stdout.flush()
            if _sleep_or_quit(args.interval):
                break
    except KeyboardInterrupt:
        pass
    finally:
        if old_tty is not None:
            import termios
            termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_tty)
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
