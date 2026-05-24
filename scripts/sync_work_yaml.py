#!/usr/bin/env python3
"""WORK.yaml <-> GitHub Issues sync. YAML-native successor to sync_work_md.py.

Modes:
  (default)            dry-run; print proposed changes
  --apply              execute (queue + commit)
  --release-cut v0.N   move all `current:` items to `shipped[v0.N]:`
  --move-closed --issue N   move item with issue: N from todo to current

Schema per WORK.yaml item (see WORK.yaml header for full spec):
  - title: str (required)
    issue: int (optional)
    priority: p0|p1|p2|p3 (optional)
    kind: feature|bug|chore (optional)
    notes: multi-line (optional)
    version: v0.N (only on shipped items)

Queues items in `todo:` without an `issue:` annotation into
`.factory/inbox/pending-intake.md` (DRAINED-aware dedup — won't re-queue
titles that already appear under any `## DRAINED ...` header).
"""

from __future__ import annotations
import argparse, re, sys
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
    ap.add_argument("--release-cut", metavar="v0.<N>")
    ap.add_argument("--move-closed", metavar="N")
    args = ap.parse_args()
    if args.release_cut:
        return cmd_release_cut(args)
    if args.move_closed:
        return cmd_move_closed(args)
    return cmd_sync(args)


if __name__ == "__main__":
    sys.exit(main())
