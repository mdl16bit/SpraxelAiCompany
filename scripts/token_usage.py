#!/usr/bin/env python3
"""token_usage.py — split token spend into the subscription pool vs API-credit pool.

ZERO Claude tokens — this is pure local file parsing, not a `claude -p` agent. It
reads the JSONL session transcripts Claude Code writes under ~/.claude/projects/
(the same ledger ccusage reads) and classifies each session by its `entrypoint`:

  entrypoint "cli"      → interactive Claude Code (the CEO's sessions)  → SUBSCRIPTION pool
  entrypoint "sdk-cli"  → headless `claude -p` (run_agent.sh / dev workers) → API-CREDIT pool

Headless dev workers run in git worktrees, so the ledger spans several project
dirs (main + worktrees/worker-N). We glob every dir whose path mentions the repo.

Windows (each pool by its own real cadence — see COMPANY_CONFIG / README):
  subscription → since the most recent Mon 06:00 PT (the weekly Sonnet cap reset)
  api_credit   → since the 1st of the current month 00:00 PT (the $250 monthly cap)

Writes .cache/token-usage.json (read by scripts/dashboard.py). Run standalone to
test:  python3 scripts/token_usage.py   (prints the JSON and writes the cache).

Stdlib only. Streams each transcript line-by-line — worktree files are ~400 MB.
"""
import os
import sys
import json
import glob
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).parent))
from spx_config import get as cfg_get  # pricing + monthly cap (honors GAME_CONFIG)

TZ = ZoneInfo("America/Los_Angeles")
REPO_DIR = Path.home() / "SpraxelAiCompany"
CACHE = REPO_DIR / ".cache" / "token-usage.json"
PROJECTS = Path.home() / ".claude" / "projects"
TS_FMT = "%Y-%m-%d %H:%M:%S %Z"          # the format dashboard.py already parses

# entrypoint → pool. Anything else (unknown/missing) is ignored.
POOL_BY_ENTRYPOINT = {"cli": "subscription", "sdk-cli": "api_credit"}


def transcript_dirs():
    """Every ~/.claude/projects dir for this repo (main checkout + worktrees)."""
    return [Path(p) for p in glob.glob(str(PROJECTS / "*SpraxelAiCompany*"))]


def file_entrypoint(path):
    """Read a transcript's entrypoint once (it's fixed per session). Cheap scan of
    the first lines that carry it; returns None if absent."""
    try:
        with open(path, "r", errors="replace") as f:
            for _ in range(50):                      # entrypoint appears on early records
                line = f.readline()
                if not line:
                    break
                i = line.find('"entrypoint"')
                if i == -1:
                    continue
                # crude but robust: pull the quoted value after the colon
                j = line.find('"', line.find(":", i) + 1)
                k = line.find('"', j + 1)
                if j != -1 and k != -1:
                    return line[j + 1:k]
    except OSError:
        pass
    return None


def parse_ts(s):
    """Transcript timestamps are ISO-8601 UTC (e.g. 2026-06-14T20:58:00.123Z)."""
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(TZ)
    except ValueError:
        return None


def week_start(now):
    """Most recent Monday 06:00 PT — the weekly Sonnet-cap reset boundary."""
    d = now.replace(hour=6, minute=0, second=0, microsecond=0)
    # Step back a day at a time until we land on a Monday 06:00 that is <= now.
    while d.weekday() != 0 or d > now:
        d -= timedelta(days=1)
    return d


def month_start(now):
    return now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)


def pricing_for(model):
    """Longest-prefix match against COMPANY_CONFIG.policy.pricing."""
    table = cfg_get("policy.pricing", {}) or {}
    best = None
    for key, rates in table.items():
        if model.startswith(key) and (best is None or len(key) > len(best[0])):
            best = (key, rates)
    return best[1] if best else None


def usd(by_model):
    """Estimated USD for a {model: {input,output,cache_write,cache_read}} bundle."""
    total = 0.0
    for model, u in by_model.items():
        r = pricing_for(model)
        if not r:
            continue
        total += (
            u["input"] * r["input"]
            + u["output"] * r["output"]
            + u["cache_write"] * r["cache_write"]
            + u["cache_read"] * r["cache_read"]
        ) / 1_000_000
    return round(total, 2)


def blank():
    return {"input": 0, "output": 0, "cache_write": 0, "cache_read": 0}


def compute(now=None):
    now = now or datetime.now(TZ)
    bounds = {"subscription": week_start(now), "api_credit": month_start(now)}
    # pools[pool][model] -> token bundle; de-dup assistant msgs by requestId
    pools = {"subscription": {}, "api_credit": {}}
    seen = set()

    for d in transcript_dirs():
        for fpath in glob.glob(str(d / "*.jsonl")):
            pool = POOL_BY_ENTRYPOINT.get(file_entrypoint(fpath))
            if not pool:
                continue
            since = bounds[pool]
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
                        if ts is None or ts < since:
                            continue
                        model = msg.get("model") or "unknown"
                        b = pools[pool].setdefault(model, blank())
                        b["input"] += u.get("input_tokens", 0) or 0
                        b["output"] += u.get("output_tokens", 0) or 0
                        b["cache_write"] += u.get("cache_creation_input_tokens", 0) or 0
                        b["cache_read"] += u.get("cache_read_input_tokens", 0) or 0
            except OSError:
                continue

    def pool_summary(pool, window):
        by_model = pools[pool]
        total = sum(sum(b.values()) for b in by_model.values())
        out = {
            "window": window,
            "since": bounds[pool].strftime(TS_FMT),
            "total_tokens": total,
            "by_model": {
                m: sum(b.values())
                for m, b in sorted(by_model.items())
                if sum(b.values()) > 0
            },
        }
        return out, by_model

    sub, _ = pool_summary("subscription", "week")
    api, api_models = pool_summary("api_credit", "month")
    api["est_usd"] = usd(api_models)
    try:
        api["cap_usd"] = float(cfg_get("policy.budgets.monthly_usd_hard_cap", 0) or 0)
    except (TypeError, ValueError):
        api["cap_usd"] = 0

    return {
        "calculated_ts": now.strftime(TS_FMT),
        "subscription": sub,
        "api_credit": api,
    }


def main():
    result = compute()
    CACHE.parent.mkdir(parents=True, exist_ok=True)
    CACHE.write_text(json.dumps(result, indent=2))
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
