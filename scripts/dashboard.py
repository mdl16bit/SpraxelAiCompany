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

# Reuse the existing cron matcher.
sys.path.insert(0, str(Path(__file__).parent))
from cron_match import cron_match

REPO_DIR = Path.home() / "SpraxelAiCompany"
SCHEDULE = REPO_DIR / "schedule.yaml"
STATE_FILE = REPO_DIR / ".cache" / "continuous-state.json"
PAUSED = REPO_DIR / ".paused"
TR_PENDING = REPO_DIR / ".cache" / "test-runner-pending"
TR_ACTIVE = REPO_DIR / ".cache" / "test-runner-active"
TICK_LOG_DIR = REPO_DIR / "logs" / "tick"
CONTINUOUS_LOG_DIR = REPO_DIR / "logs" / "continuous"
TZ = ZoneInfo("America/Los_Angeles")

# Target render width. The two-column sections and title truncation caps derive
# from this so the dashboard fills a wide terminal instead of an ~80-col box.
WIDTH = 160
_INDENT = 4                       # leading "    " on every content row
_COL_W = (WIDTH - _INDENT) // 2   # width of the left column in 2-col sections

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


def worker_commits(worker_id: int) -> tuple[int, int] | None:
    """(commits_ahead_of_origin/master, seconds_since_last_commit) for the worker's
    feat branch, read from its worktree — a live "is it actually making progress?"
    signal now that devs commit incrementally. None if no worktree."""
    wt = Path(__file__).resolve().parent.parent / ".worktrees" / f"worker-{worker_id}"
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


def resolve_game_dir() -> Path | None:
    if not SCHEDULE.exists(): return None
    for line in SCHEDULE.read_text().splitlines():
        m = re.match(r"\s*game_dir:\s*(\S+)", line)
        if m: return Path(os.path.expanduser(m.group(1)))
    return None


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
        out = sh("git log master --grep='^feat:' --author='continuous-bot' "
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


def last_log_line(game_dir: Path | None) -> tuple[str, str]:
    """Last meaningful `continuous:` line across ALL per-worker logs.

    Returns (worker_label, line). worker_label is "w1" / "w2" / "w3" /
    "—" for legacy single-wrapper logs. Picks the line with the most
    recent file mtime across the per-worker logs so the dashboard shows
    the truly newest event, not the legacy daily-aggregate file.
    """
    today = datetime.now(TZ).strftime("%Y-%m-%d")
    yesterday = (datetime.now(TZ) - timedelta(days=1)).strftime("%Y-%m-%d")
    # Collect candidate log files (today's per-worker + yesterday's + legacy).
    candidates: list[tuple[Path, str]] = []
    for stamp in (today, yesterday):
        for p in CONTINUOUS_LOG_DIR.glob(f"{stamp}-w*.log"):
            m = re.search(r"-w(\d+)\.log$", p.name)
            wid = f"w{m.group(1)}" if m else "—"
            candidates.append((p, wid))
        legacy = CONTINUOUS_LOG_DIR / f"{stamp}.log"
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
        "--author='continuous-bot' | wc -l",
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
            f"--author='continuous-bot' | wc -l",
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
        f"--author='continuous-bot' -n {n}",
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


def read_philosophy_int(game_dir: Path | None, dotted_key: str, default: int) -> int:
    """Read a numeric YAML-ish value from Philosophy.md.

    `dotted_key` is e.g. "dashboard.recent_ships". We grep for the inner
    key (after the dot) under a top-level section line matching the
    outer key (before the dot). The parser is intentionally lenient —
    same shape as the bash readers in continuous_dev.sh / agent specs.
    """
    if game_dir is None:
        return default
    phil = game_dir / "Philosophy.md"
    if not phil.exists():
        return default
    try:
        text = phil.read_text()
    except Exception:
        return default
    outer, inner = dotted_key.split(".", 1)
    m = re.search(rf"^{re.escape(outer)}:\s*\n((?:[ \t]+\S.*\n?)*)", text, re.M)
    if not m:
        return default
    block = m.group(1)
    mm = re.search(rf"^\s+{re.escape(inner)}:\s*(\d+)", block, re.M)
    if mm:
        try:
            return int(mm.group(1))
        except ValueError:
            return default
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


def render(now: datetime, game_dir: Path | None) -> str:
    lines = []
    # Read configurable dashboard counts from Philosophy.md (with defaults).
    recent_ships_n = read_philosophy_int(game_dir, "dashboard.recent_ships", 15)
    ceo_actions_n  = read_philosophy_int(game_dir, "dashboard.ceo_actions", 10)
    title = f"SPRAXEL DASHBOARD — {now:%a %Y-%m-%d %H:%M:%S %Z}"
    bar = "─" * len(title)
    lines.append(f"{BOLD}{CYAN}{title}{RESET}")
    lines.append(f"{DIM}{bar}{RESET}")
    lines.append("")

    # System status row
    if PAUSED.exists():
        status = f"{YELLOW}⏸  PAUSED{RESET}"
    elif TR_ACTIVE.exists():
        status = f"{BLUE}▶  running — test runner running{RESET}"
    elif TR_PENDING.exists():
        status = f"{BLUE}▶  running — test runner scheduled{RESET}"
    else:
        status = f"{GREEN}▶  running{RESET}"
    lines.append(f"  Status         {status}")

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

    # Cap counter
    cap_line = "?"
    if STATE_FILE.exists():
        try:
            s = json.loads(STATE_FILE.read_text())
            shipped = s.get("shipped_since_last_signal", "?")
            last_sig = s.get("last_signal_ts", "?")
            try:
                # Parse last_signal_ts to compute age
                ts = datetime.strptime(last_sig, "%Y-%m-%d %H:%M:%S %Z").replace(tzinfo=TZ)
                age = now - ts
                age_str = fmt_etime(int(age.total_seconds()))
            except Exception:
                age_str = ""
            color = YELLOW if str(shipped) == "10" else GREEN
            cap_line = f"{color}{shipped}/10{RESET} {DIM}since {last_sig} ({age_str} ago){RESET}"
        except Exception:
            pass
    lines.append(f"  Cap counter    {cap_line}")
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
                    clean = clean[:120] + ("…" if len(clean) > 120 else "")
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
            commits = worker_commits(wid)
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
    lines.append(f"    Today:        {GREEN}{tput['today']:>3}{RESET} {DIM}(continuous-bot ships){RESET}")
    lines.append(f"    7-day:        {GREEN}{tput['seven_day']:>3}{RESET} {DIM}avg {tput['avg_per_day']}/day{RESET}")
    lines.append(f"    Lifetime:     {DIM}{tput['lifetime']:>3}{RESET}")
    lines.append(f"    Escalations:  {YELLOW}{escalations_today(game_dir):>3}{RESET} {DIM}(today, CEO-bound){RESET}")
    lines.append("")

    # Next 10 scheduled runs (two columns of 5, column-major — left = first 5)
    lines.append(f"  {BOLD}▸ Next 10 agents to execute{RESET}")
    fires = next_n_fires(now, 10)
    if not fires:
        lines.append(f"    {DIM}(no upcoming runs found){RESET}")
    else:
        def _fire_cell(ts, name, cap: int) -> tuple[str, int]:
            if ts.date() == now.date():
                day = "today"
            elif ts.date() == (now + timedelta(days=1)).date():
                day = "tmr"
            else:
                day = ts.strftime("%a")
            prefix = f"{day:5s} {ts:%H:%M PT}"
            nm = name[:cap] + ("…" if len(name) > cap else "")
            return f"{DIM}{prefix}{RESET}  {nm}", len(prefix) + 2 + len(nm)

        if len(fires) <= 5:
            for ts, name in fires:
                cell, _ = _fire_cell(ts, name, WIDTH - 24)
                lines.append(f"    {cell}")
        else:
            # prefix ("today 14:30 PT  ") is ~16 cols; fill the rest of the column.
            ROWS, CAP, CELL_W = 5, _COL_W - 18, _COL_W
            left, right = fires[:ROWS], fires[ROWS:]
            for i in range(len(left)):
                lcell, lvis = _fire_cell(left[i][0], left[i][1], CAP)
                if i < len(right):
                    rcell, _ = _fire_cell(right[i][0], right[i][1], CAP)
                    pad = " " * max(1, CELL_W - lvis)
                    lines.append(f"    {lcell}{pad}{rcell}")
                else:
                    lines.append(f"    {lcell}")
    lines.append("")

    # Next N CEO action items (things blocking on you)
    lines.append(f"  {BOLD}▸ Next {ceo_actions_n} CEO action items{RESET}")
    actions = pending_ceo_actions(game_dir, ceo_actions_n)
    if not actions:
        lines.append(f"    {DIM}(none — queue is clear){RESET}")
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
                cell, _ = _ceo_cell(kind, title, WIDTH - 20)
                lines.append(f"    {cell}")
        else:
            # Two columns of five (column-major) so >5 items don't overflow
            # the window. Left col = first 5, right col = next 5.
            # "[kind] " prefix is ~12 cols; fill the rest of the column.
            ROWS, CAP, CELL_W = 5, _COL_W - 14, _COL_W
            left, right = actions[:ROWS], actions[ROWS:]
            for i in range(len(left)):
                lcell, lvis = _ceo_cell(left[i][0], left[i][1], CAP)
                if i < len(right):
                    rcell, _ = _ceo_cell(right[i][0], right[i][1], CAP)
                    pad = " " * max(1, CELL_W - lvis)
                    lines.append(f"    {lcell}{pad}{rcell}")
                else:
                    lines.append(f"    {lcell}")
    lines.append("")

    # Last N things shipped
    lines.append(f"  {BOLD}▸ Last {recent_ships_n} shipped{RESET}")
    ships = last_n_ships(game_dir, recent_ships_n)
    if not ships:
        lines.append(f"    {DIM}(no ships found in git log){RESET}")
    else:
        for sha, age, subject in ships:
            # Pad age to 4 chars right-aligned so columns align; truncate subject
            age_col = f"{age:>4s}"
            subj = subject[:WIDTH - 20] + ("…" if len(subject) > WIDTH - 20 else "")
            lines.append(f"    {DIM}{sha} {age_col}{RESET}  {subj}")
    lines.append("")

    # Most recent log line — across all per-worker continuous logs.
    lines.append(f"  {BOLD}▸ Last log line{RESET}")
    wid, last = last_log_line(game_dir)
    lines.append(f"    {DIM}{wid:>3s}  {last}{RESET}")
    lines.append("")

    return "\n".join(lines)


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
    args = p.parse_args()

    game_dir = resolve_game_dir()

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
            sys.stdout.write(render(now, game_dir))
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
