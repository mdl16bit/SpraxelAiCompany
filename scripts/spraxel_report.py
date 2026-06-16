#!/usr/bin/env python3
"""Spraxel status report — print a self-contained snapshot of the system.

Sections:
  1. Right now — paused?, wrapper alive?, in-flight item, counter
  2. Last 24 hours — ships, escalations, CEO commits, crew agents fired
  3. Last week — ships, escalations, top features, releases
  4. Next 20 scheduled events — crew agent firings with PT date+time

Pure read-only / pure local — no Claude tokens. Run via /spraxel-report
skill or directly: python3 ~/SpraxelAiCompany/scripts/spraxel_report.py
"""

import os
import re
import sys
import json
import subprocess
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

# Reuse the existing cron matcher + the multi-game config/layout helpers.
sys.path.insert(0, str(Path(__file__).parent))
from cron_match import cron_match
import spx_config

# REPO_DIR is the framework root (one dir above scripts/). spx_config.REPO is the
# same value; we re-derive it here so the path constants below read clearly.
REPO_DIR = Path(spx_config.REPO)
SCHEDULE = REPO_DIR / "schedule.yaml"
# GLOBAL (account/machine-wide, NOT namespaced): the pause flag lives at repo root.
PAUSED = REPO_DIR / ".paused"
TZ = ZoneInfo("America/Los_Angeles")


def _state_file(slug: str) -> Path:
    """Per-game continuous-state.json (cap counter, signal timestamps)."""
    return Path(spx_config.cache_dir(slug)) / "continuous-state.json"


def _tick_log_dir(slug: str) -> Path:
    """Per-game tick log dir: logs/<slug>/tick/."""
    return Path(spx_config.game_logs_dir(slug)) / "tick"


def _continuous_log_dir(slug: str) -> Path:
    """Per-game continuous log dir: logs/<slug>/continuous/."""
    return Path(spx_config.game_logs_dir(slug)) / "continuous"


def enabled_games() -> list:
    """Enabled games from the registry (falls back to all if none flagged)."""
    reg = spx_config.games()
    return [g for g in reg if g.get("enabled")] or reg


def sh(cmd: str, cwd: Path | None = None) -> str:
    """Run a shell command and return stdout (stripped). Empty string on
    nonzero exit (we silently swallow — this is a status report, not a
    failure-critical operation)."""
    try:
        r = subprocess.run(
            cmd, shell=True, capture_output=True, text=True,
            cwd=str(cwd) if cwd else None,
        )
        return r.stdout.strip()
    except Exception:
        return ""


def fmt_etime(seconds: int) -> str:
    """Format an elapsed-seconds value as 'Xh Ym' or 'Ym Ns'."""
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m {seconds % 60}s"
    h, r = divmod(seconds, 3600)
    return f"{h}h {r // 60}m"


def process_etime(pid: int) -> int | None:
    """Return elapsed seconds for a PID, or None if dead."""
    out = sh(f"ps -p {pid} -o etime= 2>/dev/null")
    if not out:
        return None
    parts = out.split("-")
    if len(parts) == 2:
        days = int(parts[0])
        rest = parts[1]
    else:
        days = 0
        rest = parts[0]
    hms = rest.split(":")
    if len(hms) == 3:
        h, m, s = (int(x) for x in hms)
    elif len(hms) == 2:
        h, m, s = 0, int(hms[0]), int(hms[1])
    else:
        h, m, s = 0, 0, int(hms[0])
    return days * 86400 + h * 3600 + m * 60 + s


def pgrep(pattern: str) -> list[int]:
    """Return PIDs matching `pgrep -f <pattern>`. Empty list on no match."""
    out = sh(f"pgrep -f {pattern!r} 2>/dev/null")
    if not out:
        return []
    return [int(x) for x in out.splitlines() if x.strip().isdigit()]


def parse_schedule_yaml() -> list[tuple[str, str, str]]:
    """Yield (agent_name, cron_expr, description) for each crew agent in
    schedule.yaml's `agents:` block."""
    if not SCHEDULE.exists():
        return []
    text = SCHEDULE.read_text()
    m = re.search(r"^agents:\s*\n((?:[ \t]+\S.*\n?)*)", text, re.M)
    if not m:
        return []
    out = []
    for line in m.group(1).splitlines():
        mm = re.match(
            r"\s*(\w+):\s*\{[^}]*cron:\s*\"([^\"]+)\"[^}]*description:\s*\"([^\"]+)\"",
            line,
        )
        if mm:
            out.append((mm.group(1), mm.group(2), mm.group(3)))
    return out


# ─── Section 1: Right Now ─────────────────────────────────────────────────

def section_right_now(now: datetime, games: list) -> None:
    print("## Right now\n")
    print(f"- **Time**: {now:%Y-%m-%d %H:%M:%S %Z}")

    # Paused? — GLOBAL flag at repo root (governs every game).
    if PAUSED.exists():
        print(f"- **System: ⏸️  PAUSED** — `.paused` flag set. No agents will fire, "
              f"no items will ship until you `rm {PAUSED}`.")
    else:
        print("- **System: ▶️  running**")

    # Tick daemon
    tick_status = sh("launchctl list | grep com.spraxel.tick")
    if tick_status:
        print(f"- **Tick daemon**: loaded (`{tick_status.split()[2] if len(tick_status.split())>=3 else 'com.spraxel.tick'}`)")
    else:
        print("- **Tick daemon**: ⚠️  NOT loaded — run `bash scripts/install_daemon.sh`")

    # Continuous wrapper
    wrapper_pids = pgrep("continuous_dev.sh")
    if wrapper_pids:
        pid = wrapper_pids[0]
        et = process_etime(pid)
        print(f"- **Continuous wrapper**: alive (PID {pid}, up {fmt_etime(et or 0)})")
    else:
        if PAUSED.exists():
            print("- **Continuous wrapper**: not running (system paused)")
        else:
            print("- **Continuous wrapper**: ⚠️  not running — next tick (≤60 s) should respawn")

    # Active dev / claude session
    dev_pids = pgrep("run_agent.sh developer")
    claude_pids = pgrep("claude --model claude-sonnet-4-6 --dangerously-skip-permissions")
    if dev_pids and claude_pids:
        et = process_etime(claude_pids[0])
        print(f"- **In flight**: dev agent (PID {claude_pids[0]}, {fmt_etime(et or 0)} in)")
    elif dev_pids:
        print(f"- **In flight**: dev wrapper starting (PID {dev_pids[0]})")
    else:
        print("- **In flight**: nothing")

    # Per-game state: cap counter + most-recent item attempted. When a single
    # game is enabled the lines read exactly as before (no game prefix); with
    # multiple games each line is prefixed with the game slug.
    multi = len(games) > 1
    for g in games:
        slug, gd = g["slug"], (Path(g["dir"]) if g["dir"] else None)
        pfx = f" [{slug}]" if multi else ""

        # Cap counter — PER-GAME continuous-state.json.
        sf = _state_file(slug)
        if sf.exists():
            try:
                s = json.loads(sf.read_text())
                shipped = s.get("shipped_since_last_signal", "?")
                last_sig = s.get("last_signal_ts", "?")
                print(f"- **Cap counter{pfx}**: {shipped}/10 shipped since last CEO signal at {last_sig}")
            except Exception:
                pass

        # Most-recent item attempted — from the PER-GAME continuous log dir.
        if gd is not None:
            clog_dir = _continuous_log_dir(slug)
            try:
                recent_logs = sorted(clog_dir.glob("*.log"))[-3:]
            except Exception:
                recent_logs = []
            last_item = ""
            for lp in reversed(recent_logs):
                try:
                    lines = lp.read_text().splitlines()
                except Exception:
                    continue
                for ln in reversed(lines):
                    m = re.search(r"continuous: → '([^']+)' on ", ln)
                    if m:
                        last_item = m.group(1)
                        break
                if last_item:
                    break
            if last_item:
                print(f"- **Most recent item attempted{pfx}**: \"{last_item[:80]}{'…' if len(last_item) > 80 else ''}\"")

    print()


# ─── Section 2 + 3: Last 24h / Last week ───────────────────────────────────

def commit_counts(game_dir: Path, since: str) -> dict:
    """Return {ships, escalations, ceo_commits} for the given git --since."""
    ships = sh(
        f"git log master --since='{since}' --pretty='%h' --grep='^feat:' "
        f"--author='continuous-bot' --author='Interactive Dev' | wc -l",
        cwd=game_dir,
    )
    escs = sh(
        f"git log master --since='{since}' --pretty='%h' --grep='^escalate:' "
        f"--author='continuous-bot' --author='Interactive Dev' | wc -l",
        cwd=game_dir,
    )
    ceo = sh(
        f"git log master --since='{since}' --pretty='%h' --author='skinnyluigi' | wc -l",
        cwd=game_dir,
    )
    return {
        "ships": int(ships) if ships.isdigit() else 0,
        "escalations": int(escs) if escs.isdigit() else 0,
        "ceo_commits": int(ceo) if ceo.isdigit() else 0,
    }


def _section_last_24h_one(now: datetime, slug: str, game_dir: Path | None) -> None:
    if not game_dir or not game_dir.exists():
        print("- (game_dir not resolvable)\n")
        return
    c = commit_counts(game_dir, "24 hours ago")
    print(f"- **Ships**: {c['ships']} feature(s) (`feat:` commits by continuous-bot)")
    print(f"- **Escalations**: {c['escalations']}")
    print(f"- **CEO commits**: {c['ceo_commits']}")

    # Crew agents fired (from the PER-GAME tick log)
    tick_log_dir = _tick_log_dir(slug)
    today = now.strftime("%Y-%m-%d")
    yesterday = (now - timedelta(days=1)).strftime("%Y-%m-%d")
    dispatches = []
    for d in (yesterday, today):
        log = tick_log_dir / f"{d}.log"
        if not log.exists():
            continue
        for line in log.read_text().splitlines():
            mm = re.search(r"(\d{2}:\d{2}:\d{2}) PDT.+dispatched=\[([^\]]+)\]", line)
            if mm and mm.group(2):
                dispatches.append((d, mm.group(1), mm.group(2)))
    if dispatches:
        print(f"- **Crew agents fired** ({len(dispatches)}):")
        for d, t, names in dispatches[-15:]:  # last 15 to keep it readable
            print(f"    - {d} {t} — {names}")
    else:
        print("- **Crew agents fired**: none (likely paused)")

    # Recent feat: titles
    feats = sh(
        f"git log master --since='24 hours ago' --pretty='%h %s' "
        f"--grep='^feat:' --author='continuous-bot' --author='Interactive Dev' | head -10",
        cwd=game_dir,
    )
    if feats:
        print("- **Top recent ships** (newest first):")
        for line in feats.splitlines()[:5]:
            print(f"    - `{line[:7]}` {line[8:][:90]}{'…' if len(line[8:]) > 90 else ''}")
    print()


def _section_last_week_one(now: datetime, slug: str, game_dir: Path | None) -> None:
    if not game_dir or not game_dir.exists():
        print("- (game_dir not resolvable)\n")
        return
    c = commit_counts(game_dir, "7 days ago")
    print(f"- **Ships**: {c['ships']}")
    print(f"- **Escalations**: {c['escalations']}")
    print(f"- **CEO commits**: {c['ceo_commits']}")

    # Releases this week
    releases = sh(
        "git log master --since='7 days ago' --pretty='%h %s' "
        "--grep='^chore: release\\|^release:' | head -5",
        cwd=game_dir,
    )
    if releases:
        print("- **Releases**:")
        for line in releases.splitlines():
            print(f"    - {line}")
    else:
        print("- **Releases**: none")

    # Top 10 features by date
    feats = sh(
        "git log master --since='7 days ago' --pretty='%h %ar %s' "
        "--grep='^feat:' --author='continuous-bot' --author='Interactive Dev' | head -20",
        cwd=game_dir,
    )
    if feats:
        print("- **Features shipped this week** (top 10, newest first):")
        for line in feats.splitlines()[:10]:
            # line format: "abc1234 5 hours ago feat: title"
            parts = line.split(maxsplit=3)
            if len(parts) >= 4:
                sha, t1, t2, rest = parts[0], parts[1], parts[2], parts[3]
                # rest = "X ago feat: title" — kebab everything after "feat:"
                title = re.sub(r"^.*?feat:\s*", "", rest)
                print(f"    - `{sha}` {title[:90]}{'…' if len(title) > 90 else ''}")
    print()


def section_last_24h(now: datetime, games: list) -> None:
    print("## Last 24 hours\n")
    multi = len(games) > 1
    for g in games:
        gd = Path(g["dir"]) if g["dir"] else None
        if multi:
            print(f"### {g['slug']}\n")
        _section_last_24h_one(now, g["slug"], gd)


def section_last_week(now: datetime, games: list) -> None:
    print("## Last 7 days\n")
    multi = len(games) > 1
    for g in games:
        gd = Path(g["dir"]) if g["dir"] else None
        if multi:
            print(f"### {g['slug']}\n")
        _section_last_week_one(now, g["slug"], gd)


# ─── Section 4: Next 20 scheduled events ───────────────────────────────────

def section_next_20(now: datetime) -> None:
    print("## Next 20 scheduled events\n")

    schedule = parse_schedule_yaml()
    if not schedule:
        print("- (schedule.yaml has no agents block)\n")
        return

    # Compute next firing time per agent by scanning 14 days minute by minute.
    # Cap at 14 days × 1440 = ~20k iterations — fast.
    events = []
    for name, cron, desc in schedule:
        cur = now.replace(second=0, microsecond=0) + timedelta(minutes=1)
        # Find next 5 firings per agent so we have enough to cover 20 events total.
        found = 0
        scan = cur
        end = now + timedelta(days=14)
        while scan < end and found < 5:
            try:
                if cron_match(cron, scan):
                    events.append((scan, name, desc))
                    found += 1
            except Exception:
                break
            scan += timedelta(minutes=1)
        if found == 0:
            # Agent's cron may not fire within 14 days (e.g. monthly on day 1).
            # Skip — but for monthly we should extend the scan; let's at least try 35 days.
            scan = now.replace(second=0, microsecond=0) + timedelta(minutes=1)
            end = now + timedelta(days=35)
            while scan < end and found < 2:
                try:
                    if cron_match(cron, scan):
                        events.append((scan, name, desc))
                        found += 1
                except Exception:
                    break
                scan += timedelta(minutes=1)

    # Add a synthetic "next continuous-loop activity" entry. We approximate
    # by: if not paused and wrapper alive, the loop is always active —
    # there's no "scheduled" tick. So we add a single informational entry.
    if not PAUSED.exists() and pgrep("continuous_dev.sh"):
        events.append((now, "continuous_dev", "shipping items continuously (cap=10/CEO signal)"))

    # Sort + cap at 20.
    events.sort(key=lambda e: e[0])
    events = events[:20]

    # Group by date for readability.
    last_date = None
    for ts, name, desc in events:
        date_str = ts.strftime("%a %Y-%m-%d")
        if date_str != last_date:
            print(f"\n### {date_str}")
            last_date = date_str
        if ts <= now:
            print(f"- **NOW** — `{name}` — {desc}")
        else:
            print(f"- {ts:%H:%M PT} — `{name}` — {desc}")
    print()


def main() -> int:
    now = datetime.now(TZ)
    games = enabled_games()
    print(f"# Spraxel status — {now:%a %Y-%m-%d %H:%M:%S %Z}\n")
    if len(games) == 1:
        g = games[0]
        print(f"Game: `{g['dir']}`\n")
    elif games:
        print("Games: " + ", ".join(f"`{g['slug']}`" for g in games) + "\n")
    section_right_now(now, games)
    section_last_24h(now, games)
    section_last_week(now, games)
    section_next_20(now)   # GLOBAL: schedule.yaml is account/machine-wide
    return 0


if __name__ == "__main__":
    sys.exit(main())
