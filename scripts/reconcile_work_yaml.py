#!/usr/bin/env python3
"""
reconcile_work_yaml.py — backfill (#N) annotations on WORK.yaml entries
by fuzzy-matching titles against existing GitHub Issues (open + closed).

Why this exists:
- WORK.yaml is the CEO's brain-dump (often 100+ items).
- sync_work_yaml.py only assigns (#N) when it creates an Issue. It does
  NOT reconcile against issues that already exist (e.g., created via the
  Producer skill, by hand, or by Designer accepts).
- Result: WORK.yaml drifts from GH state and looks 3x larger than it is.

What this does:
- For each WORK.yaml entry without `issue:`, search open+closed GH Issues
  for a title match using normalized comparison (lowercase, strip
  punctuation/whitespace, take first 80 chars).
- Confidence levels:
  * EXACT (normalized titles identical) → set issue: N
  * STRONG (one is prefix of the other AND both >= 30 chars normalized) → set issue: N
  * MULTIPLE / WEAK / NONE → leave alone, log to stdout for CEO review

Idempotent. Never destroys existing `issue:` annotations.

Usage:
    python3 reconcile_work_yaml.py --repo-dir <game-repo> [--apply]

Default is dry-run; pass --apply to actually write WORK.yaml.
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("error: pyyaml not installed (pip install pyyaml)", file=sys.stderr)
    sys.exit(2)


def normalize(title: str) -> str:
    """Lowercase, strip punctuation, collapse whitespace, take first 80 chars."""
    t = title.lower()
    t = re.sub(r"[^\w\s]", " ", t)
    t = re.sub(r"\s+", " ", t).strip()
    return t[:80]


def fetch_issues(repo: str | None) -> list[dict]:
    """Return open + closed issues, both states."""
    args = ["gh", "issue", "list", "--state", "all", "--limit", "500",
            "--json", "number,title,state"]
    if repo:
        args += ["--repo", repo]
    out = subprocess.check_output(args, text=True)
    return json.loads(out)


def best_match(title: str, issues: list[dict]) -> tuple[str, int | None]:
    """Return (confidence, issue_number)."""
    norm_t = normalize(title)
    if not norm_t:
        return "NONE", None

    exact = [i for i in issues if normalize(i["title"]) == norm_t]
    if len(exact) == 1:
        return "EXACT", exact[0]["number"]
    if len(exact) > 1:
        return "MULTIPLE", None

    strong = []
    for i in issues:
        norm_i = normalize(i["title"])
        if not norm_i or len(norm_t) < 30 or len(norm_i) < 30:
            continue
        if norm_t.startswith(norm_i) or norm_i.startswith(norm_t):
            strong.append(i)
    if len(strong) == 1:
        return "STRONG", strong[0]["number"]
    if len(strong) > 1:
        return "MULTIPLE", None
    return "NONE", None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo-dir", required=True, help="Target game repo directory")
    ap.add_argument("--repo", help="GitHub repo (owner/name); inferred from cwd if omitted")
    ap.add_argument("--apply", action="store_true", help="Write changes (default: dry-run)")
    args = ap.parse_args()

    repo_dir = Path(args.repo_dir).resolve()
    work_yaml = repo_dir / "WORK.yaml"
    if not work_yaml.exists():
        print(f"error: {work_yaml} not found", file=sys.stderr)
        sys.exit(2)

    issues = fetch_issues(args.repo)
    print(f"Loaded {len(issues)} GH issues (open + closed)")

    data = yaml.safe_load(work_yaml.read_text())
    stats = {"EXACT": 0, "STRONG": 0, "MULTIPLE": 0, "NONE": 0, "ALREADY": 0}
    changes: list[tuple[str, str, int]] = []
    weak_log: list[str] = []

    for section, items in data.items():
        if not isinstance(items, list):
            continue
        for entry in items:
            if not isinstance(entry, dict) or "title" not in entry:
                continue
            if "issue" in entry and entry["issue"]:
                stats["ALREADY"] += 1
                continue
            conf, num = best_match(entry["title"], issues)
            stats[conf] += 1
            if conf in ("EXACT", "STRONG") and num is not None:
                entry["issue"] = num
                changes.append((section, entry["title"][:60], num))
            elif conf == "MULTIPLE":
                weak_log.append(f"  [{section}] MULTIPLE matches: {entry['title'][:70]}")
            # NONE → silent (probably deduped by Producer or just not yet planned)

    print("\n=== Summary ===")
    print(f"  Already annotated (skipped):  {stats['ALREADY']}")
    print(f"  EXACT match (will annotate):  {stats['EXACT']}")
    print(f"  STRONG match (will annotate): {stats['STRONG']}")
    print(f"  MULTIPLE matches (skipped):   {stats['MULTIPLE']}")
    print(f"  NO match (skipped):           {stats['NONE']}")
    print(f"  Total changes:                {len(changes)}")

    if changes:
        print("\n=== Annotations to be applied ===")
        for section, title, num in changes[:30]:
            print(f"  [{section}] #{num}: {title}")
        if len(changes) > 30:
            print(f"  ... and {len(changes) - 30} more")
    if weak_log:
        print("\n=== Multiple-match items (need CEO disambiguation) ===")
        for line in weak_log[:20]:
            print(line)
        if len(weak_log) > 20:
            print(f"  ... and {len(weak_log) - 20} more")

    if args.apply and changes:
        work_yaml.write_text(yaml.safe_dump(data, sort_keys=False, allow_unicode=True))
        print(f"\nApplied {len(changes)} annotations to {work_yaml}")
    elif args.apply:
        print("\nNothing to apply.")
    else:
        print("\n(dry-run; re-run with --apply to write changes)")


if __name__ == "__main__":
    main()
