#!/usr/bin/env python3
"""WORK.yaml <-> GitHub Issues sync. YAML-native successor to sync_work_md.py.

**Bidirectional**: by default does BOTH directions in one run.

Modes:
  (default)            run both directions (WORK.yaml→intake AND Issues→WORK.yaml backfill)
  --apply              execute (default: dry-run)
  --queue-only         only the WORK.yaml→intake direction
  --backfill-only      only the Issues→WORK.yaml direction
  --release-cut v0.N   move all `current:` items to `shipped[v0.N]:`
  --move-closed --issue N   move item with issue: N from todo to current

Schema per WORK.yaml item (see WORK.yaml header for full spec):
  - title: str (required)
    issue: int (optional)
    priority: p0|p1|p2|p3 (optional)
    kind: feature|bug|chore (optional)
    notes: multi-line (optional)
    version: v0.N (only on shipped items)

The intake-queue direction queues items in `todo:` without an `issue:`
annotation into `.factory/inbox/pending-intake.md` (DRAINED-aware dedup).

The backfill direction queries `gh issue list --state all` and:
  - Open issue not in WORK.yaml → append to todo: with issue: N, priority + kind from labels
  - Closed-with-merged-PR not in WORK.yaml → append to current: (release-cut later moves to shipped)
  - Closed-with-merged-PR already in todo: → move to current:
  - Closed manually (no merged PR) → skip (don't track; CEO closed for a reason)
Existing entries with `issue: N` are never reordered or modified.
"""

from __future__ import annotations
import argparse, json, re, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path
import yaml


def load_yaml(p: Path) -> dict:
    if not p.exists():
        return {"shipped": [], "current": [], "todo": []}
    return yaml.safe_load(p.read_text()) or {"shipped": [], "current": [], "todo": []}


def save_yaml(p: Path, data: dict) -> None:
    header_lines = []
    # Preserve the existing YAML's header comments
    if p.exists():
        for line in p.read_text().splitlines():
            if line.startswith("#") or not line.strip():
                header_lines.append(line)
            else:
                break
    header = "\n".join(header_lines).rstrip() + "\n\n" if header_lines else ""
    body = yaml.safe_dump(data, sort_keys=False, default_flow_style=False, width=200, allow_unicode=True)
    p.write_text(header + body)


def existing_intake_titles(intake: Path) -> set[str]:
    if not intake.exists():
        return set()
    titles = set()
    for raw in intake.read_text().splitlines():
        if not raw.startswith("- "):
            continue
        body = raw[2:]
        m = re.match(r"\s*(\[[^\]]+\])?\s*(.*)", body)
        titles.add((m.group(2) if m else body).strip())
    return titles


def cmd_sync(args):
    repo_dir = Path(args.repo_dir).resolve()
    yaml_path = repo_dir / "WORK.yaml"
    intake_path = repo_dir / ".factory" / "inbox" / "pending-intake.md"

    data = load_yaml(yaml_path)
    todo = data.get("todo") or []

    # Find unannotated items (no `issue:` key)
    unannotated = [item for item in todo if not item.get("issue")]
    if not unannotated:
        print("WORK.yaml todo: no unannotated items; nothing to queue")
        return 0

    print(f"WORK.yaml todo: {len(unannotated)} unannotated item(s)")
    already = existing_intake_titles(intake_path)
    fresh = [it for it in unannotated if it.get("title", "").strip() not in already]
    if not fresh:
        print(f"  no new items to queue (all {len(unannotated)} already in intake)")
        return 0

    stamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
    body = [f"\n## {stamp} — queued from WORK.yaml\n"]
    for item in fresh:
        meta = []
        if item.get("priority"): meta.append(item["priority"])
        if item.get("kind") and item["kind"] != "feature": meta.append(item["kind"])
        meta_str = f"[{','.join(meta)}] " if meta else ""
        body.append(f"- {meta_str}{item['title']}")
        notes = item.get("notes", "")
        if notes:
            for ln in notes.splitlines():
                if ln.strip():
                    body.append(f"  {ln}")
    block = "\n".join(body) + "\n"

    if args.apply:
        intake_path.parent.mkdir(parents=True, exist_ok=True)
        if not intake_path.exists():
            intake_path.write_text("# pending intake — raw WORK.yaml entries awaiting Producer triage\n")
        with intake_path.open("a") as f:
            f.write(block)
        print(f"  appended {len(fresh)} new item(s) to {intake_path}")
    else:
        print(f"  would append {len(fresh)} new item(s) (dry-run; pass --apply)")
        for ln in block.splitlines():
            print(f"  {ln}")
    return 0


def fetch_gh_issues(repo: str | None) -> list[dict]:
    """Fetch open + closed issues with labels + state."""
    args = ["gh", "issue", "list", "--state", "all", "--limit", "500",
            "--json", "number,title,state,labels,closedAt"]
    if repo:
        args += ["--repo", repo]
    return json.loads(subprocess.check_output(args, text=True))


def fetch_merged_prs_for_issue(repo: str | None, issue_num: int) -> bool:
    """Return True if a merged PR exists that closed this issue.

    Searches PR bodies for `closes #N` / `fixes #N` (case-insensitive)."""
    args = ["gh", "pr", "list", "--state", "merged", "--limit", "200",
            "--search", f"closes #{issue_num} OR fixes #{issue_num} OR closed #{issue_num}",
            "--json", "number"]
    if repo:
        args += ["--repo", repo]
    try:
        out = json.loads(subprocess.check_output(args, text=True))
        return len(out) > 0
    except subprocess.CalledProcessError:
        return False


def derive_entry_from_gh(gh_issue: dict) -> dict:
    """Build a WORK.yaml entry dict from a gh issue's JSON."""
    label_names = {lbl["name"] for lbl in gh_issue.get("labels", [])}
    entry: dict = {"title": gh_issue["title"], "issue": gh_issue["number"]}
    for p in ("priority:p0", "priority:p1", "priority:p2", "priority:p3"):
        if p in label_names:
            entry["priority"] = p.split(":")[1]
            break
    for k in ("kind:bug", "kind:chore", "kind:feature"):
        if k in label_names:
            entry["kind"] = k.split(":")[1]
            break
    return entry


def cmd_backfill(args, data: dict) -> tuple[dict, list[str]]:
    """Issues → WORK.yaml direction.

    Returns the updated data dict and a list of human-readable change descriptions.
    Does NOT save; caller decides based on --apply.
    """
    changes: list[str] = []
    try:
        gh_issues = fetch_gh_issues(args.repo)
    except subprocess.CalledProcessError as e:
        print(f"  backfill: gh issue list failed ({e}); skipping", file=sys.stderr)
        return data, changes
    print(f"  backfill: loaded {len(gh_issues)} GH issues (open + closed)")

    # Index all WORK.yaml entries by issue number
    indexed: dict[int, tuple[str, int]] = {}  # issue_num -> (section, index_in_section)
    for section in ("shipped", "current", "todo"):
        items = data.get(section) or []
        for idx, item in enumerate(items):
            if isinstance(item, dict) and item.get("issue"):
                indexed[item["issue"]] = (section, idx)

    todo = data.setdefault("todo", [])
    current = data.setdefault("current", [])

    for gi in gh_issues:
        num = gi["number"]
        state = gi["state"]  # 'OPEN' or 'CLOSED'
        present = indexed.get(num)

        if state == "OPEN":
            if present is None:
                entry = derive_entry_from_gh(gi)
                todo.append(entry)
                changes.append(f"  + todo: #{num} {gi['title'][:70]}")
            # else: open + already in WORK.yaml → leave alone
        else:  # CLOSED
            # Was it merged via PR or closed manually?
            has_merged_pr = fetch_merged_prs_for_issue(args.repo, num)
            if not has_merged_pr:
                # Closed manually (dup / wontfix / etc.) — skip; don't track
                continue
            if present is None:
                entry = derive_entry_from_gh(gi)
                current.append(entry)
                changes.append(f"  + current: #{num} {gi['title'][:70]} (closed via merged PR)")
            elif present[0] == "todo":
                # Move from todo → current
                section_items = data[present[0]]
                moved = section_items.pop(present[1])
                # Refresh indexed after pop
                for k, (sec, ix) in list(indexed.items()):
                    if sec == present[0] and ix > present[1]:
                        indexed[k] = (sec, ix - 1)
                current.append(moved)
                changes.append(f"  ↳ #{num} todo → current (PR merged)")
            # else: already in current or shipped → leave alone
    return data, changes


def cmd_release_cut(args):
    repo_dir = Path(args.repo_dir).resolve()
    yaml_path = repo_dir / "WORK.yaml"
    data = load_yaml(yaml_path)
    version = args.release_cut
    current = data.get("current") or []
    if not current:
        print(f"release-cut {version}: nothing in current section; no-op")
        return 0
    shipped = data.get("shipped") or []
    # Tag each current item with the version + prepend to shipped (newest-first)
    for item in current:
        item["version"] = version
    data["shipped"] = current + shipped
    data["current"] = []
    if args.apply:
        save_yaml(yaml_path, data)
        print(f"release-cut {version}: moved {len(current)} item(s) to shipped (newest first)")
    else:
        print(f"release-cut {version}: would move {len(current)} item(s) to shipped (dry-run)")
        for item in current:
            print(f"  + {item.get('title')}  (issue #{item.get('issue', '?')})")
    return 0


def cmd_move_closed(args):
    repo_dir = Path(args.repo_dir).resolve()
    yaml_path = repo_dir / "WORK.yaml"
    data = load_yaml(yaml_path)
    issue_num = int(args.move_closed)
    todo = data.get("todo") or []
    current = data.get("current") or []

    # Find in todo
    found_idx = None
    for i, item in enumerate(todo):
        if item.get("issue") == issue_num:
            found_idx = i
            break
    if found_idx is None:
        # Already in current or shipped? Check.
        if any(it.get("issue") == issue_num for it in current):
            print(f"move-closed #{issue_num}: already in current; no-op")
            return 0
        for sh in data.get("shipped") or []:
            if sh.get("issue") == issue_num:
                print(f"move-closed #{issue_num}: already in shipped; no-op")
                return 0
        print(f"move-closed #{issue_num}: not found in WORK.yaml; no-op (issue may have come from a Designer batch / direct gh create, not a WORK.yaml line)")
        return 0

    moved = todo.pop(found_idx)
    current.append(moved)
    data["todo"] = todo
    data["current"] = current

    if args.apply:
        save_yaml(yaml_path, data)
        print(f"move-closed #{issue_num}: moved '{moved.get('title')}' from todo → current")
    else:
        print(f"move-closed #{issue_num}: would move '{moved.get('title')}' from todo → current (dry-run)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--repo-dir", default=".", help="Target game repo (default: cwd)")
    ap.add_argument("--apply", action="store_true", help="Execute changes (default: dry-run)")
    ap.add_argument("--repo", help="GitHub repo (owner/name); inferred from cwd if omitted")
    ap.add_argument("--release-cut", metavar="v0.<N>")
    ap.add_argument("--move-closed", metavar="N")
    ap.add_argument("--queue-only", action="store_true", help="Only WORK.yaml→intake direction")
    ap.add_argument("--backfill-only", action="store_true", help="Only Issues→WORK.yaml direction")
    args = ap.parse_args()
    if args.release_cut:
        return cmd_release_cut(args)
    if args.move_closed:
        return cmd_move_closed(args)

    # Default: BIDIRECTIONAL — both queue and backfill
    repo_dir = Path(args.repo_dir).resolve()
    yaml_path = repo_dir / "WORK.yaml"
    data = load_yaml(yaml_path)

    if not args.backfill_only:
        # WORK.yaml → intake direction
        cmd_sync(args)
        # Re-load if anything changed (cmd_sync writes only intake, not WORK.yaml, so skip reload)

    if not args.queue_only:
        # Issues → WORK.yaml backfill direction
        print("Issues → WORK.yaml backfill:")
        data, changes = cmd_backfill(args, data)
        if not changes:
            print("  no backfill changes")
        else:
            print(f"  {len(changes)} change(s):")
            for c in changes[:30]:
                print(c)
            if len(changes) > 30:
                print(f"  ... and {len(changes) - 30} more")
            if args.apply:
                save_yaml(yaml_path, data)
                print(f"  written to {yaml_path}")
            else:
                print("  (dry-run; pass --apply to write)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
