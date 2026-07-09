#!/usr/bin/env python3
"""playtest_metrics.py — fun-telemetry aggregation over Tracer JSONL files.

The game's Tracer autoload writes one JSON object per line:
    {"t": <seconds since boot>, "evt": "<name>", ...extra}
The Playtester runs each feature with --trace-file=/tmp/playtest-<slug>.jsonl;
this tool turns those raw traces into a durable per-run aggregate and
cross-build trends. ZERO Claude tokens — pure local parsing.

Subcommands:
  collect <glob...> --out-dir <game>/.factory/telemetry
      Aggregate today's trace files → <out-dir>/<YYYY-MM-DD>.json
      (slug inferred from filename playtest-<slug>.jsonl; repeat runs merge).
  trend --dir <game>/.factory/telemetry [--last 5]
      Compare the newest aggregate against the previous N: per-slug event
      deltas, duration changes, new/vanished event keys. Markdown to stdout —
      paste-ready for the findings file's ## Trends section.

Signal buckets (pattern-matched over evt names, plus raw counts always kept):
  detection: detect|spot|alert|suspicious|search     combat: ko|takedown|damage|shot
  failure:   fail|caught|game_over|death             success: success|complete|extract|win
"""
import argparse
import glob as globmod
import json
import re
import sys
from datetime import date
from pathlib import Path

BUCKETS = {
    "detection": re.compile(r"detect|spot|alert|suspicious|search", re.I),
    "combat": re.compile(r"\bko\b|takedown|damage|shot", re.I),
    "failure": re.compile(r"fail|caught|game_over|death", re.I),
    "success": re.compile(r"success|complete|extract|win", re.I),
}
SLUG_RE = re.compile(r"playtest-(.+?)\.jsonl$")


def parse_trace(path):
    events, duration = {}, 0.0
    firsts = {}
    try:
        with open(path, errors="replace") as f:
            for line in f:
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                evt = rec.get("evt")
                if not isinstance(evt, str):
                    continue
                t = rec.get("t") or 0.0
                events[evt] = events.get(evt, 0) + 1
                duration = max(duration, float(t))
                for bucket, rx in BUCKETS.items():
                    if rx.search(evt) and bucket not in firsts:
                        firsts[f"first_{bucket}_s"] = round(float(t), 2)
                        break
    except OSError:
        return None
    if not events:
        return None
    buckets = {b: sum(n for e, n in events.items() if rx.search(e))
               for b, rx in BUCKETS.items()}
    return {"events": events, "buckets": buckets, "duration_s": round(duration, 2),
            **firsts}


def cmd_collect(args):
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    runs = {}
    for pattern in args.globs:
        for path in sorted(globmod.glob(pattern)):
            m = SLUG_RE.search(path)
            slug = m.group(1) if m else Path(path).stem
            agg = parse_trace(path)
            if agg:
                runs[slug] = agg   # later run of the same slug wins
    if not runs:
        print("playtest_metrics: no parseable traces matched", file=sys.stderr)
        return 1
    out = out_dir / f"{date.today().isoformat()}.json"
    doc = {"date": date.today().isoformat(), "runs": runs,
           "totals": {b: sum(r["buckets"].get(b, 0) for r in runs.values())
                      for b in BUCKETS}}
    out.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n")
    print(f"playtest_metrics: wrote {out} ({len(runs)} slug(s))")
    return 0


def cmd_trend(args):
    files = sorted(Path(args.dir).glob("*.json"))
    if len(files) < 2:
        print("(no trend yet — fewer than 2 telemetry snapshots)")
        return 0
    docs = [json.loads(f.read_text()) for f in files[-(args.last + 1):]]
    cur, prevs = docs[-1], docs[:-1]
    print(f"## Trends — {cur['date']} vs previous {len(prevs)} snapshot(s)\n")
    # totals trend
    print("| bucket | now | prev avg | delta |")
    print("|---|---|---|---|")
    for b in BUCKETS:
        now = cur["totals"].get(b, 0)
        avg = sum(d["totals"].get(b, 0) for d in prevs) / len(prevs)
        d = now - avg
        flag = " ⚠" if avg and abs(d) / max(avg, 1) > 0.5 else ""
        print(f"| {b} | {now} | {avg:.1f} | {d:+.1f}{flag} |")
    # per-slug notes: new slugs, vanished events, duration swings
    prev_runs = docs[-2]["runs"]
    notes = []
    for slug, r in cur["runs"].items():
        p = prev_runs.get(slug)
        if not p:
            notes.append(f"- `{slug}`: first snapshot ({r['duration_s']}s, "
                         f"{sum(r['events'].values())} events)")
            continue
        dd = r["duration_s"] - p["duration_s"]
        if p["duration_s"] and abs(dd) / p["duration_s"] > 0.3:
            notes.append(f"- `{slug}`: duration {p['duration_s']}s → {r['duration_s']}s")
        gone = set(p["events"]) - set(r["events"])
        if gone:
            notes.append(f"- `{slug}`: events VANISHED vs last run: "
                         f"{', '.join(sorted(gone)[:5])} (regression or removed?)")
    zero = [s for s, r in cur["runs"].items() if sum(r["events"].values()) <= 1]
    if zero:
        notes.append(f"- ⚠ trace-silent slugs (≤1 event — hook broken or feature "
                     f"un-instrumented): {', '.join(zero)}")
    print()
    print("\n".join(notes) if notes else "(no per-slug anomalies)")
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    pc = sub.add_parser("collect")
    pc.add_argument("globs", nargs="+")
    pc.add_argument("--out-dir", required=True)
    pt = sub.add_parser("trend")
    pt.add_argument("--dir", required=True)
    pt.add_argument("--last", type=int, default=5)
    args = ap.parse_args()
    return cmd_collect(args) if args.cmd == "collect" else cmd_trend(args)


if __name__ == "__main__":
    sys.exit(main())
