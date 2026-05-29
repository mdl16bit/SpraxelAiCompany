#!/usr/bin/env python3
"""Decide whether a cron-scheduled agent is DUE to fire — drift-proof.

tick.sh fires on a ~60s launchd timer that DRIFTS, so a single-minute cron
(e.g. `0 3 * * *`) can be skipped entirely if no tick lands during that minute
(observed 2026-05-29: ticks at 02:59:59 then 03:01:00 → the 03:00 playtester
slot was never evaluated). A plain "does the cron match THIS minute" check
silently drops such slots.

This catches the miss: for an agent it scans the last `--grace-min` minutes for
the MOST RECENT minute the cron matched; if that slot is newer than the slot we
last fired this agent for, it's due (fire now, up to a minute or two late). A
per-agent stamp file records the last fired slot, so a slot fires AT MOST ONCE
no matter how many ticks land in/after its minute (no double-fire).

Slots older than `--grace-min` are abandoned (don't fire a flood of stale daily
slots after the Mac sleeps / the system is paused for a while — the next day's
run covers it). tick bails on `.paused` before calling this, so paused time
never accrues missed slots.

Usage:
    cron_due.py <agent> "<cron>" --stamp <path> [--tz TZ] [--grace-min N] [--now ISO]
Exit 0 = DUE (and the stamp is updated to the matched slot), 1 = not due,
2 = error. Concurrency: tick processes agents sequentially, one tick at a time,
so the read-modify-write of the stamp file is not racy.
"""
import argparse
import json
import os
import sys
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cron_match import cron_match  # reuse the exact matching semantics


def _load(stamp: str) -> dict:
    try:
        with open(stamp) as f:
            return json.load(f)
    except Exception:
        return {}


def _save(stamp: str, data: dict) -> None:
    tmp = f"{stamp}.tmp.{os.getpid()}"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, stamp)


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("agent")
    p.add_argument("expr")
    p.add_argument("--stamp", required=True, help="JSON file of {agent: last-fired-slot ISO-minute}")
    p.add_argument("--tz", default="America/Los_Angeles")
    p.add_argument("--grace-min", type=int, default=15, help="how far back to catch a missed slot")
    p.add_argument("--now", default=None, help="ISO-8601 override (testing)")
    args = p.parse_args()

    try:
        tz = ZoneInfo(args.tz)
        now = (datetime.fromisoformat(args.now).replace(tzinfo=tz)
               if args.now else datetime.now(tz)).replace(second=0, microsecond=0)
        # Most recent minute in [now-grace, now] where the cron matches.
        match_slot = None
        for back in range(0, args.grace_min + 1):
            m = now - timedelta(minutes=back)
            if cron_match(args.expr, m):
                match_slot = m.strftime("%Y-%m-%dT%H:%M")
                break
        if match_slot is None:
            return 1  # cron doesn't match anywhere in the window — not due

        data = _load(args.stamp)
        if data.get(args.agent) == match_slot:
            return 1  # already fired for this exact slot — no double-fire
        # New (or caught-up) slot → fire and record it.
        data[args.agent] = match_slot
        _save(args.stamp, data)
        return 0
    except ValueError as e:
        print(f"cron_due: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
