#!/usr/bin/env python3
"""Match a 5-field cron expression against the current time in a given timezone.

Usage:
    cron_match.py "0 7 * * *" [--tz America/Los_Angeles] [--now YYYY-MM-DDTHH:MM]
    Exit 0 = match, 1 = no match, 2 = parse error.

Fields: minute hour day-of-month month day-of-week
Each field supports: *, N, N-M, N,M,P, */N, N-M/S
Day-of-week: 0=Sun..6=Sat (also accepts 7=Sun for compatibility).

No external deps — stdlib only. Designed to be called from tick.sh.
"""
import argparse
import sys
from datetime import datetime
from zoneinfo import ZoneInfo


FIELD_RANGES = [
    (0, 59),   # minute
    (0, 23),   # hour
    (1, 31),   # day of month
    (1, 12),   # month
    (0, 6),    # day of week (0=Sun)
]


def expand_field(field: str, lo: int, hi: int) -> set[int]:
    """Expand one cron field into the explicit set of matching integers."""
    out: set[int] = set()
    for token in field.split(","):
        step = 1
        if "/" in token:
            token, step_s = token.split("/", 1)
            step = int(step_s)
            if step <= 0:
                raise ValueError(f"step must be >= 1: {field}")
        if token == "*":
            start, end = lo, hi
        elif "-" in token:
            start_s, end_s = token.split("-", 1)
            start, end = int(start_s), int(end_s)
        else:
            start = end = int(token)
        for v in range(start, end + 1, step):
            if v < lo or v > hi:
                # Allow dow=7 → 0 (some cron dialects)
                if (lo, hi) == (0, 6) and v == 7:
                    out.add(0)
                else:
                    raise ValueError(f"value {v} out of range [{lo},{hi}]: {field}")
            else:
                out.add(v)
    return out


def cron_match(expr: str, dt: datetime) -> bool:
    fields = expr.strip().split()
    if len(fields) != 5:
        raise ValueError(f"expected 5 fields, got {len(fields)}: {expr!r}")
    minute, hour, dom, month, dow = (
        expand_field(f, lo, hi) for f, (lo, hi) in zip(fields, FIELD_RANGES)
    )
    # cron semantics: if dom and dow are both restricted (not *), match if EITHER hits.
    # Detect "restricted" by comparing expanded set to full range.
    dom_full = set(range(1, 32))
    dow_full = set(range(0, 7))
    dom_restricted = dom != dom_full
    dow_restricted = dow != dow_full

    # Python: Monday=0..Sunday=6. cron: Sunday=0..Saturday=6.
    py_dow = dt.weekday()
    cron_dow = (py_dow + 1) % 7

    base = (
        dt.minute in minute
        and dt.hour in hour
        and dt.month in month
    )
    if not base:
        return False
    if dom_restricted and dow_restricted:
        return dt.day in dom or cron_dow in dow
    if dom_restricted:
        return dt.day in dom
    if dow_restricted:
        return cron_dow in dow
    return True


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("expr")
    p.add_argument("--tz", default="America/Los_Angeles")
    p.add_argument("--now", default=None, help="ISO-8601 override (default: now)")
    args = p.parse_args()

    try:
        tz = ZoneInfo(args.tz)
        if args.now:
            # Truncate to minute precision.
            dt = datetime.fromisoformat(args.now).replace(tzinfo=tz, second=0, microsecond=0)
        else:
            dt = datetime.now(tz).replace(second=0, microsecond=0)
        return 0 if cron_match(args.expr, dt) else 1
    except ValueError as e:
        print(f"cron_match: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
