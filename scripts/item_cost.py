#!/usr/bin/env python3
"""item_cost.py — estimate the token cost of ONE piece of work by time window.

ZERO Claude tokens — pure local parsing of the same ~/.claude/projects JSONL
ledger token_usage.py reads. Sums assistant-message usage whose timestamp falls
inside [--since, --until], priced via COMPANY_CONFIG policy.pricing.

Attribution model:
  headless dev worker  → its transcripts live under its own worktree project
                         dir; pass --dir-filter worker-<id> for clean per-item
                         attribution even with parallel workers.
  interactive dev item → the /spraxel-develop subagents bill inside the CEO's
                         session transcript; items run serially, so a bare time
                         window is a good estimate (other simultaneous CEO chat
                         in the window will be included — treat as approximate).

Usage:
  item_cost.py --since <epoch|ISO> [--until <epoch|ISO>] [--dir-filter SUBSTR]
               [--pool api_credit|subscription|all] [--json]
Prints e.g.:  $0.84  (in=112k out=9k cache_w=48k cache_r=1.2m)  [pool=all]
Exit 0 with $0.00 when nothing matched (missing ledger is never fatal).

Used by ship_lib.sh's ship_report to stamp a cost on every shipped item and
append it to state/<slug>/cache/item-costs.tsv.
"""
import argparse
import glob
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from token_usage import (  # noqa: E402
    POOL_BY_ENTRYPOINT, blank, file_entrypoint, parse_ts, pricing_for,
    transcript_dirs, usd,
)


def _to_dt(s):
    if s is None:
        return None
    try:
        return datetime.fromtimestamp(float(s), tz=timezone.utc)
    except (TypeError, ValueError):
        pass
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        sys.exit(f"item_cost: bad timestamp {s!r}")


def compute(since, until, dir_filter="", pool_want="all"):
    by_model = {}
    tot = blank()
    seen = set()
    for d in transcript_dirs():
        if dir_filter and dir_filter not in str(d):
            continue
        for fpath in glob.glob(str(d / "*.jsonl")):
            try:
                # cheap skip: untouched since the window opened → no entries in it
                if datetime.fromtimestamp(Path(fpath).stat().st_mtime,
                                          tz=timezone.utc) < since:
                    continue
            except OSError:
                continue
            pool = POOL_BY_ENTRYPOINT.get(file_entrypoint(fpath))
            if pool is None or (pool_want != "all" and pool != pool_want):
                continue
            try:
                with open(fpath, "r", errors="replace") as f:
                    for line in f:
                        if '"assistant"' not in line or '"usage"' not in line:
                            continue
                        try:
                            rec = json.loads(line)
                        except json.JSONDecodeError:
                            continue
                        if rec.get("type") != "assistant":
                            continue
                        msg = rec.get("message") or {}
                        u = msg.get("usage") or {}
                        if not u:
                            continue
                        rid = rec.get("requestId")
                        if rid:
                            if rid in seen:
                                continue
                            seen.add(rid)
                        ts = parse_ts(rec.get("timestamp"))
                        if ts is None or ts < since or ts > until:
                            continue
                        b = by_model.setdefault(msg.get("model") or "unknown", blank())
                        for k, src in (("input", "input_tokens"),
                                       ("output", "output_tokens"),
                                       ("cache_write", "cache_creation_input_tokens"),
                                       ("cache_read", "cache_read_input_tokens")):
                            v = u.get(src, 0) or 0
                            b[k] += v
                            tot[k] += v
            except OSError:
                continue
    return usd(by_model), tot, by_model


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--since", required=True)
    ap.add_argument("--until", default=None)
    ap.add_argument("--dir-filter", default="")
    ap.add_argument("--pool", default="all",
                    choices=["all", "api_credit", "subscription"])
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    since = _to_dt(a.since)
    until = _to_dt(a.until) or datetime.now(timezone.utc)
    cost, tot, by_model = compute(since, until, a.dir_filter, a.pool)

    def k(n):
        return f"{n/1_000_000:.1f}m" if n >= 1_000_000 else f"{n/1000:.0f}k" if n >= 1000 else str(n)

    unpriced = sorted(m for m in by_model if pricing_for(m) is None)
    if a.json:
        print(json.dumps({"usd": cost, "tokens": tot, "by_model": by_model,
                          "unpriced_models": unpriced}))
    else:
        note = f"  ⚠ unpriced: {','.join(unpriced)}" if unpriced else ""
        print(f"${cost:.2f}  (in={k(tot['input'])} out={k(tot['output'])} "
              f"cache_w={k(tot['cache_write'])} cache_r={k(tot['cache_read'])})  "
              f"[pool={a.pool}]{note}")


if __name__ == "__main__":
    main()
