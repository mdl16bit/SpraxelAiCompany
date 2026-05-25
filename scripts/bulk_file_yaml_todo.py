#!/usr/bin/env python3
"""
bulk_file_yaml_todo.py — file a GH issue for EVERY unannotated todo entry
in WORK.yaml, then update WORK.yaml with the (#N) annotations.

The "no silent drops" enforcement script. Previously Producer would
file some items and drop others as "vague" / "duplicate" / "already
shipped"; this script removes that judgment call and just files
everything, labeling them `needs-triage` so CEO can re-categorize in
batch later via the GH UI.

Defaults applied to every filed issue:
  - kind:feature (override later via re-labeling)
  - priority:p3 (assume backlog; CEO/PM promote when ready)
  - needs-triage (so they're easy to filter)
  - status:from-yaml (provenance marker)

Skip rules (the ONLY items that don't get filed):
  - Title appears in deferred.md's "Already-shipped per Game.md" list

Idempotent: skips entries that already have an `issue:` annotation.

Usage:
    python3 bulk_file_yaml_todo.py --repo-dir <game-repo> [--apply] [--limit N]

Default is dry-run; pass --apply to actually create issues.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("error: pyyaml not installed (pip install pyyaml)", file=sys.stderr)
    sys.exit(2)


def load_already_shipped(deferred_path: Path) -> set[str]:
    """Pull title fragments from deferred.md's 'Already-shipped' section."""
    if not deferred_path.exists():
        return set()
    text = deferred_path.read_text()
    m = re.search(r"## Already-shipped per Game\.md.*?(?=^##|\Z)", text, re.M | re.S)
    if not m:
        return set()
    shipped = set()
    for line in m.group(0).splitlines():
        if line.strip().startswith("- "):
            t = line.strip()[2:].split(" → ")[0]
            shipped.add(t.lower().strip())
    return shipped


def truncate_title(title: str, max_len: int = 80) -> str:
    if len(title) <= max_len:
        return title
    return title[: max_len - 3].rstrip() + "..."


def file_issue(repo: str | None, title: str, body: str, labels: list[str]) -> int | None:
    args = ["gh", "issue", "create", "--title", title, "--body", body,
            "--label", ",".join(labels)]
    if repo:
        args += ["--repo", repo]
    try:
        out = subprocess.check_output(args, text=True).strip()
    except subprocess.CalledProcessError as e:
        print(f"  ERROR filing '{title[:50]}': {e}", file=sys.stderr)
        return None
    m = re.search(r"/issues/(\d+)$", out)
    return int(m.group(1)) if m else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo-dir", required=True)
    ap.add_argument("--repo", help="owner/name (inferred from cwd if omitted)")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--limit", type=int, default=None, help="cap how many to file (test runs)")
    args = ap.parse_args()

    repo_dir = Path(args.repo_dir).resolve()
    yaml_path = repo_dir / "WORK.yaml"
    deferred_path = repo_dir / ".factory" / "inbox" / "deferred.md"

    data = yaml.safe_load(yaml_path.read_text())
    todo = data.get("todo") or []
    already_shipped = load_already_shipped(deferred_path)

    candidates = []
    skipped_shipped = []
    skipped_annotated = 0
    for entry in todo:
        if not isinstance(entry, dict) or "title" not in entry:
            continue
        if entry.get("issue"):
            skipped_annotated += 1
            continue
        title = entry["title"]
        title_lc = title.lower()
        if any(s in title_lc for s in already_shipped):
            skipped_shipped.append(title[:80])
            continue
        candidates.append(entry)

    print(f"Found {len(todo)} todo items.")
    print(f"  already annotated (skipped):  {skipped_annotated}")
    print(f"  already-shipped (skipped):    {len(skipped_shipped)}")
    print(f"  to file:                      {len(candidates)}")

    if args.limit:
        candidates = candidates[: args.limit]
        print(f"  --limit applied: capping at {len(candidates)}")

    if not candidates:
        print("\nNothing to file.")
        return 0

    if not args.apply:
        print("\nFirst 10 that would be filed:")
        for c in candidates[:10]:
            print(f"  - {truncate_title(c['title'])}")
        print(f"\n(dry-run; re-run with --apply to file all {len(candidates)})")
        return 0

    filed = 0
    failed = 0
    for entry in candidates:
        full_title = entry["title"]
        short_title = truncate_title(full_title)
        body = (
            "## Why\n\n"
            "Bulk-filed from `WORK.yaml` todo entry (2026-05-25 cleanup). "
            "Producer previously dropped this item silently during the original drain; "
            "the no-silent-drops policy means every WORK.yaml entry must end as either a "
            "filed issue or an explicit deferral.\n\n"
            "## Source\n\n"
            f"```\n{full_title}\n```\n\n"
            "## CEO action\n\n"
            "Re-categorize (kind/priority/area labels), refine acceptance criteria, OR "
            "close as `wontfix` if no longer wanted. The `needs-triage` label tags this "
            "for batch review.\n"
        )
        labels = ["kind:feature", "priority:p3", "needs-triage", "status:from-yaml"]
        num = file_issue(args.repo, short_title, body, labels)
        if num is None:
            failed += 1
            continue
        entry["issue"] = num
        filed += 1
        if filed % 10 == 0:
            print(f"  filed {filed}/{len(candidates)}...")

    # Save WORK.yaml with the new annotations
    yaml_path.write_text(yaml.safe_dump(data, sort_keys=False, allow_unicode=True, width=200))
    print(f"\nFiled {filed} issues; {failed} failed.")
    print(f"WORK.yaml updated with {filed} new (#N) annotations.")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
