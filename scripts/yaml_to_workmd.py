#!/usr/bin/env python3
"""One-shot migration: WORK.yaml → WORK.md (legacy two-divider format).

Run once per game repo during Phase 2 of the offline migration. After this
runs and you've verified the output, WORK.yaml can be deleted (Phase 6).

Usage:
    yaml_to_workmd.py <repo-dir>          Reads <repo-dir>/WORK.yaml,
                                          writes <repo-dir>/WORK.md.
    yaml_to_workmd.py <repo-dir> --check  Dry-run; print to stdout, don't write.
"""
import argparse
import sys
from pathlib import Path

import yaml


HEADER = """# {game} — work tracking

Single source of truth for all work in this game. Three sections separated by
two dividers (10+ dashes/equals). Top-of-Todo is what the overnight Developer
loop ships next. Format details: see ~/SpraxelAiCompany/scripts/workmd.py.

Conventions:
  - Item title = any non-indented line.
  - Indented lines = detail / repro / sub-points for the previous item.
  - Optional tags at line start: pN priority (p0=urgent..p3=nice-to-have),
    [bug] / [feature] / [chore] kind, [game-feature] for player-facing
    mechanics, [idea] for un-promoted Designer drops (overnight skips these),
    [cold] for items the Janitor archived.
"""


def format_item(yaml_item: dict) -> list[str]:
    title = str(yaml_item.get("title", "")).strip()
    if not title:
        return []
    # Prepend tags/priority if structured fields are present and not already in title.
    bits: list[str] = []
    kind = yaml_item.get("kind")
    if kind and f"[{kind}]" not in title.lower():
        bits.append(f"[{kind}]")
    pri = yaml_item.get("priority")
    if pri and not any(t in title.lower() for t in (" p0 ", " p1 ", " p2 ", " p3 ")) \
            and not title.lower().startswith(("p0 ", "p1 ", "p2 ", "p3 ")):
        bits.append(str(pri).lower())
    bits.append(title)
    line = " ".join(bits)
    out = [line]
    notes = yaml_item.get("notes")
    if notes:
        # Notes can be multi-line; indent every line by 2 spaces.
        # IMPORTANT: skip blank lines — they would split the parent item into
        # two items when re-parsed (blank line = item boundary in WORK.md).
        for nl in str(notes).splitlines():
            if nl.strip():
                out.append(f"  {nl.rstrip()}")
    return out


def render(data: dict, game_name: str) -> str:
    shipped = data.get("shipped") or []
    # WORK.yaml in current form stores shipped as flat list. If versioned (per
    # release-cut), it might be a dict — handle both.
    if isinstance(shipped, dict):
        flat = []
        for version, items in shipped.items():
            for it in (items or []):
                if isinstance(it, dict):
                    it = dict(it)
                    it.setdefault("version", version)
                flat.append(it)
        shipped = flat

    current = data.get("current") or []
    todo = data.get("todo") or []

    lines: list[str] = []
    lines.append(HEADER.format(game=game_name).rstrip())
    lines.append("")
    lines.append("## Shipped (previous releases)")
    for it in shipped:
        if isinstance(it, dict):
            v = it.get("version")
            block = format_item(it)
            if v and block:
                block[0] = f"{v} — {block[0]}"
            lines.extend(block)
    lines.append("")
    lines.append("-" * 50)
    lines.append("## Shipped since last release")
    for it in current:
        if isinstance(it, dict):
            lines.extend(format_item(it))
    lines.append("")
    lines.append("=" * 50)
    lines.append("## Todo")
    for it in todo:
        if isinstance(it, dict):
            lines.extend(format_item(it))
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("repo_dir")
    p.add_argument("--check", action="store_true", help="dry-run, print to stdout")
    args = p.parse_args()

    repo = Path(args.repo_dir).expanduser()
    yaml_path = repo / "WORK.yaml"
    md_path = repo / "WORK.md"

    if not yaml_path.exists():
        print(f"missing: {yaml_path}", file=sys.stderr)
        return 1

    data = yaml.safe_load(yaml_path.read_text()) or {}
    out = render(data, game_name=repo.name)

    if args.check:
        sys.stdout.write(out)
        return 0

    # Back up existing WORK.md if present.
    if md_path.exists():
        backup = md_path.with_suffix(".md.pre-migration")
        md_path.rename(backup)
        print(f"backed up existing WORK.md → {backup}", file=sys.stderr)

    md_path.write_text(out)
    print(f"wrote: {md_path}  ({len(out.splitlines())} lines)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
