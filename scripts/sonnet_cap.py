#!/usr/bin/env python3
"""Sonnet-cap auto-fallback flag — shared across ALL Sonnet-configured agents.

When a `claude --model <sonnet> -p` call hits the weekly Sonnet usage cap it
returns a tiny "usage limit reached" refusal (the ~75-byte logs that used to cause
retry storms — see project_sonnet_cap_stalls_pipeline). This module is the shared
coordination point so the whole system transparently falls back to Opus while the
cap is hit, and returns to Sonnet once it clears:

  - Headless agents (run_agent.sh) and the interactive /spraxel-develop dev
    subagents both call `is-capped` BEFORE running a Sonnet model; if capped they
    use Opus instead.
  - Whoever first hits the cap calls `detect <log>` (or `set`), which writes the
    flag with a reset/re-probe time.
  - `is-capped` auto-clears the flag once that time passes, so the next Sonnet
    call re-probes; if the real cap cleared it succeeds (flag stays gone), if not
    `detect` re-arms it. Net: Opus only while capped, only until cleared.

Flag file: ~/SpraxelAiCompany/.cache/sonnet-capped.json

Subcommands:
  is-capped         exit 0 if currently capped (flag present + not past reset);
                    else exit 1 (auto-removes an expired flag → re-probe Sonnet).
  detect <logfile>  if the log looks like a Sonnet usage-cap refusal, SET the flag
                    + exit 0 (capped); else exit 1. Used by run_agent.sh after a run.
  set [reset_epoch] directly arm the flag (caller already knows it's a cap, e.g. an
                    interactive dev subagent that failed on the limit).
  clear             remove the flag (cap cleared / manual override).
  status            human-readable one-liner (used by the dashboard).
"""
import json, os, re, subprocess, sys, time
from datetime import datetime

REPO = os.path.expanduser("~/SpraxelAiCompany")
FLAG = os.path.join(REPO, ".cache", "sonnet-capped.json")

# Specific cap phrases (NOT bare "limit") so a normal short agent status line that
# merely mentions a limit doesn't false-positive.
CAP_RE = re.compile(
    # The real subscription cap line is: "You've hit your Sonnet limit · resets
    # <date> at 6am (America/Los_Angeles)" — so "hit your … limit" + "Sonnet limit"
    # MUST match. Plus the generic API/usage-limit phrasings.
    r"hit your[^.\n]*limit|reached your[^.\n]*limit|sonnet limit|usage limit|"
    r"limit reached|limit will reset|·\s*resets|resets .*\bat\b|rate.?limit|"
    r"too many requests|out of (?:credit|usage)|weekly limit|"
    r"upgrade to (?:increase|continue)",
    re.I,
)
SIZE_MAX = 1200  # a capped claude -p reply is tiny; real agent output is much larger


def _reprobe_secs() -> int:
    try:
        v = subprocess.run(
            ["python3", os.path.join(REPO, "scripts", "spx_config.py"),
             "get", "policy.sonnet_cap_reprobe_secs"],
            capture_output=True, text=True, timeout=5).stdout.strip()
        return int(v) if v.isdigit() else 7200
    except Exception:
        return 7200


def _load():
    try:
        return json.load(open(FLAG))
    except Exception:
        return None


def is_capped() -> bool:
    d = _load()
    if not d:
        return False
    if time.time() >= float(d.get("reset_ts", 0)):
        try:
            os.remove(FLAG)        # expired → re-probe Sonnet next call
        except OSError:
            pass
        return False
    return True


def _parse_reset(text: str):
    # Best-effort: an explicit ISO datetime in the cap message.
    m = re.search(r"(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2})", text or "")
    if m:
        for fmt in ("%Y-%m-%d %H:%M", "%Y-%m-%dT%H:%M"):
            try:
                return datetime.strptime(m.group(1), fmt).timestamp()
            except Exception:
                pass
    return None


def set_flag(reset_ts=None, data=None):
    now = time.time()
    if reset_ts is None:
        reset_ts = _parse_reset(data) or (now + _reprobe_secs())
    os.makedirs(os.path.dirname(FLAG), exist_ok=True)
    json.dump({
        "capped": True,
        "detected_ts": now,
        "detected_human": datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %Z"),
        "reset_ts": reset_ts,
        "reset_human": datetime.fromtimestamp(reset_ts).astimezone().strftime("%Y-%m-%d %H:%M:%S %Z"),
    }, open(FLAG, "w"), indent=2)


def detect(logfile: str) -> bool:
    try:
        data = open(logfile, errors="replace").read()
    except Exception:
        return False
    if len(data) > SIZE_MAX or not CAP_RE.search(data):
        return False
    set_flag(data=data)
    return True


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "is-capped":
        sys.exit(0 if is_capped() else 1)
    if cmd == "detect":
        sys.exit(0 if (len(sys.argv) > 2 and detect(sys.argv[2])) else 1)
    if cmd == "set":
        set_flag(reset_ts=float(sys.argv[2]) if len(sys.argv) > 2 else None)
        print("sonnet-cap flag ARMED"); sys.exit(0)
    if cmd == "clear":
        try:
            os.remove(FLAG)
        except OSError:
            pass
        print("sonnet-cap flag cleared"); sys.exit(0)
    if cmd == "status":
        d = _load()
        if d and is_capped():
            print(f"CAPPED → using Opus until {d.get('reset_human','?')} (then re-probes Sonnet)")
        else:
            print("not capped — Sonnet normal")
        sys.exit(0)
    print("usage: sonnet_cap.py {is-capped|detect <log>|set [reset_epoch]|clear|status}", file=sys.stderr)
    sys.exit(2)


if __name__ == "__main__":
    main()
