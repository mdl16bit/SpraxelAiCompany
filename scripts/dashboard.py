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
TICK_LOG_DIR = REPO_DIR / "logs" / "tick"
CONTINUOUS_LOG_DIR = REPO_DIR / "logs" / "continuous"
TZ = ZoneInfo("America/Los_Angeles")

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


def next_n_fires(now: datetime, n: int = 3) -> list[tuple[datetime, str]]:
    schedule = parse_schedule_yaml()
    if not schedule: return []
    events = []
    for name, cron in schedule:
        scan = now.replace(second=0, microsecond=0) + timedelta(minutes=1)
        end = now + timedelta(days=35)
        found = 0
        while scan < end and found < 2:
            try:
                if cron_match(cron, scan):
                    events.append((scan, name))
                    found += 1
            except Exception:
                break
            scan += timedelta(minutes=1)
    events.sort(key=lambda e: e[0])
    return events[:n]


def last_log_line(game_dir: Path | None) -> str:
    """Last meaningful line from the continuous log."""
    today = datetime.now(TZ).strftime("%Y-%m-%d")
    log = CONTINUOUS_LOG_DIR / f"{today}.log"
    if not log.exists():
        # Try yesterday in case midnight just passed
        yesterday = (datetime.now(TZ) - timedelta(days=1)).strftime("%Y-%m-%d")
        log = CONTINUOUS_LOG_DIR / f"{yesterday}.log"
    if not log.exists(): return "(no log)"
    try:
        lines = log.read_text().splitlines()
        for ln in reversed(lines):
            ln = ln.strip()
            if ln.startswith("continuous:"):
                return ln[:80]
    except Exception:
        pass
    return "(empty)"


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


def render(now: datetime, game_dir: Path | None) -> str:
    lines = []
    title = f"SPRAXEL DASHBOARD — {now:%a %Y-%m-%d %H:%M:%S %Z}"
    bar = "─" * len(title)
    lines.append(f"{BOLD}{CYAN}{title}{RESET}")
    lines.append(f"{DIM}{bar}{RESET}")
    lines.append("")

    # System status row
    if PAUSED.exists():
        status = f"{YELLOW}⏸  PAUSED{RESET}"
    else:
        status = f"{GREEN}▶  running{RESET}"
    lines.append(f"  Status         {status}")

    # Tick daemon
    tick_loaded = bool(sh("launchctl list | grep com.spraxel.tick"))
    tick_line = f"{GREEN}✓ loaded{RESET}" if tick_loaded else f"{RED}✗ NOT LOADED{RESET}"
    lines.append(f"  Tick daemon    {tick_line}")

    # Wrapper
    wrapper_pids = pgrep("continuous_dev.sh")
    if wrapper_pids:
        et = process_etime(wrapper_pids[0]) or 0
        wrapper_line = f"{GREEN}alive{RESET} {DIM}PID {wrapper_pids[0]}, up {fmt_etime(et)}{RESET}"
    else:
        wrapper_line = f"{GRAY}not running{RESET}" if PAUSED.exists() else f"{RED}⚠ not running{RESET}"
    lines.append(f"  Wrapper        {wrapper_line}")

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

    # Current item
    dev_pids = pgrep("run_agent.sh developer")
    claude_pids = pgrep("claude --model claude-sonnet-4-6 --dangerously-skip-permissions")
    lines.append(f"  {BOLD}▸ Current item{RESET}")
    if dev_pids and claude_pids:
        et = process_etime(claude_pids[0]) or 0
        # Try to extract the title from the last "→ '...' on" log entry
        cur_item = "(working)"
        log = CONTINUOUS_LOG_DIR / f"{now:%Y-%m-%d}.log"
        if log.exists():
            try:
                lines_in = log.read_text().splitlines()
                for ln in reversed(lines_in):
                    m = re.search(r"continuous: → '([^']+)'", ln)
                    if m:
                        cur_item = m.group(1)[:55]
                        break
            except Exception:
                pass
        lines.append(f"    {CYAN}\"{cur_item}\"{RESET}")
        lines.append(f"    {DIM}dev session at PID {claude_pids[0]}, {fmt_etime(et)} in{RESET}")
    elif wrapper_pids and not PAUSED.exists():
        lines.append(f"    {DIM}(idle — wrapper sleeping or between items){RESET}")
    else:
        lines.append(f"    {DIM}(nothing — system paused or stopped){RESET}")
    lines.append("")

    # Today's totals
    lines.append(f"  {BOLD}▸ Today{RESET}")
    lines.append(f"    Ships:        {GREEN}{ships_today(game_dir)}{RESET}")
    lines.append(f"    Escalations:  {YELLOW}{escalations_today(game_dir)}{RESET}")
    lines.append("")

    # Next 3 scheduled fires
    lines.append(f"  {BOLD}▸ Next 3 fires{RESET}")
    fires = next_n_fires(now, 3)
    if not fires:
        lines.append(f"    {DIM}(no upcoming fires found){RESET}")
    else:
        for ts, name in fires:
            if ts.date() == now.date():
                day = "today"
            elif ts.date() == (now + timedelta(days=1)).date():
                day = "tom."
            else:
                day = ts.strftime("%a")
            lines.append(f"    {DIM}{day} {ts:%H:%M PT}{RESET}  {name}")
    lines.append("")

    # Most recent log line
    lines.append(f"  {BOLD}▸ Last log line{RESET}")
    last = last_log_line(game_dir)
    lines.append(f"    {DIM}{last}{RESET}")
    lines.append("")

    return "\n".join(lines)


def main() -> int:
    p = argparse.ArgumentParser(description="Spraxel always-on dashboard")
    p.add_argument("--interval", type=int, default=5,
                   help="refresh interval in seconds (default: 5)")
    args = p.parse_args()

    game_dir = resolve_game_dir()
    try:
        while True:
            now = datetime.now(TZ)
            sys.stdout.write(CLEAR_SCREEN)
            sys.stdout.write(render(now, game_dir))
            sys.stdout.write(f"\n{DIM}  refresh every {args.interval}s · Ctrl+C to exit{RESET}\n")
            sys.stdout.flush()
            time.sleep(args.interval)
    except KeyboardInterrupt:
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
