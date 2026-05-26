#!/usr/bin/env python3
"""WORK.md parser/writer for the Spraxel offline workflow.

Single source of truth for "the work". Three sections separated by dividers:

    [optional header / prose, ignored by mutation tools]
    ## Shipped (previous releases)
    <items>
    ---------- (divider: 10+ dashes or equals)
    ## Shipped since last release
    <items, in chronological completion order>
    ========== (divider)
    ## Todo
    <items, top of the list is what the overnight loop ships next>

Item conventions:
    - Item title = any non-indented, non-empty, non-divider, non-heading line.
    - Detail lines = indented lines belonging to the previous item.
    - Optional tags at line start: priority pN, kind [bug|feature|chore], plus
      special tags [idea] (Designer drops; skipped by overnight) and
      [game-feature] (player-facing mechanic).

CLI:
    workmd.py parse  <path>                    JSON dump of all sections.
    workmd.py top    <path> [-n N]             Print top N todo items as JSON
                                               (skips [idea] and [cold]).
    workmd.py ship   <path> <title>            Move item from Todo → Shipped-since.
    workmd.py escalate <path> <title> <log>    Remove from Todo; append to
                                               .factory/escalations.md.
    workmd.py append <path> --section S <line> Append a raw item line (with
                                               optional indented details on
                                               subsequent --line args).

All mutations hold an atomic lockdir on `<path>.lockdir` for the duration of
the read-modify-write to prevent concurrent agents from corrupting the file.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterator


DIVIDER_RE = re.compile(r"^[-=]{10,}\s*$")
SECTION_HEADING_RE = re.compile(r"^##\s+")   # H2 only — section boundaries
ANY_HEADING_RE = re.compile(r"^#{1,6}\s+")    # any-depth — skip when scanning for items
PRIORITY_RE = re.compile(r"\bp[0-3]\b", re.I)
KIND_TAG_RE = re.compile(r"\[(bug|feature|chore|idea|game-feature|cold|manual|needs-ceo)\]", re.I)
# Manual-item prefix: "MANUAL - foo", "MANUAL: foo", "MANUAL foo" — overnight skips these.
MANUAL_PREFIX_RE = re.compile(r"^\s*MANUAL\b\s*[-:–—]?\s*", re.I)


@dataclass
class WorkItem:
    title: str
    details: list[str] = field(default_factory=list)
    raw_lines: list[str] = field(default_factory=list)  # full original text incl. details
    lineno: int = 0  # 1-based in the source file

    @property
    def priority(self) -> str | None:
        m = PRIORITY_RE.search(self.title)
        return m.group(0).lower() if m else None

    @property
    def tags(self) -> list[str]:
        return [m.group(1).lower() for m in KIND_TAG_RE.finditer(self.title)]

    @property
    def is_idea(self) -> bool:
        return "idea" in self.tags

    @property
    def is_cold(self) -> bool:
        return "cold" in self.tags

    @property
    def is_manual(self) -> bool:
        """True if item is CEO-only — either tagged [manual] or starts with
        a MANUAL prefix (e.g. 'MANUAL - test the game with controller')."""
        return "manual" in self.tags or bool(MANUAL_PREFIX_RE.match(self.title))

    @property
    def is_needs_ceo(self) -> bool:
        """True if Developer asked clarifying questions — needs CEO answers
        before overnight will re-attempt it."""
        return "needs-ceo" in self.tags

    def to_dict(self) -> dict:
        return {
            "title": self.title,
            "details": self.details,
            "priority": self.priority,
            "tags": self.tags,
            "lineno": self.lineno,
        }


@dataclass
class WorkMd:
    path: Path
    header: list[str]
    shipped: list[WorkItem]
    current: list[WorkItem]
    todo: list[WorkItem]
    # Heading lines for each section (preserved verbatim so we can rewrite them).
    shipped_heading: str
    current_heading: str
    todo_heading: str
    # Divider literals (preserve user-chosen separator length).
    divider_a: str
    divider_b: str

    def to_dict(self) -> dict:
        return {
            "path": str(self.path),
            "shipped": [i.to_dict() for i in self.shipped],
            "current": [i.to_dict() for i in self.current],
            "todo": [i.to_dict() for i in self.todo],
            "counts": {
                "shipped": len(self.shipped),
                "current": len(self.current),
                "todo": len(self.todo),
            },
        }


def _iter_items(section_lines: list[str], start_lineno: int) -> Iterator[WorkItem]:
    """Yield WorkItems from a section's raw lines.

    Rules:
      - blank line ends the previous item (and is dropped — we re-emit on save).
      - heading line (## Foo) starts no new item; treated as part of header text already.
      - non-indented non-empty line = new item title.
      - indented line = detail for previous item.
    """
    cur: WorkItem | None = None
    for offset, line in enumerate(section_lines):
        raw = line.rstrip("\n")
        if not raw.strip():
            # blank — flush
            if cur is not None:
                yield cur
                cur = None
            continue
        if ANY_HEADING_RE.match(raw):
            # heading inside a section — skip; never treat as an item.
            if cur is not None:
                yield cur
                cur = None
            continue
        if raw.startswith((" ", "\t")):
            # detail line
            if cur is None:
                # orphan detail — promote to item
                cur = WorkItem(title=raw.strip(), raw_lines=[raw], lineno=start_lineno + offset)
            else:
                cur.details.append(raw.strip())
                cur.raw_lines.append(raw)
            continue
        # New item title
        if cur is not None:
            yield cur
        cur = WorkItem(title=raw.strip(), raw_lines=[raw], lineno=start_lineno + offset)
    if cur is not None:
        yield cur


def parse(path: str | Path) -> WorkMd:
    path = Path(path)
    text = path.read_text()
    lines = text.splitlines()

    # Locate dividers.
    divider_idx = [i for i, ln in enumerate(lines) if DIVIDER_RE.match(ln)]
    if len(divider_idx) < 2:
        # Lenient: synthesize empty sections if dividers missing.
        # Treat everything as Todo.
        return WorkMd(
            path=path,
            header=lines,
            shipped=[],
            current=[],
            todo=[],
            shipped_heading="## Shipped (previous releases)",
            current_heading="## Shipped since last release",
            todo_heading="## Todo",
            divider_a="-" * 50,
            divider_b="=" * 50,
        )

    # Use first two dividers (extras inside sections are tolerated as item details by ignoring).
    div_a, div_b = divider_idx[0], divider_idx[1]

    # Header: everything before the first H2 (## ...) — the section heading.
    # H1 (# Title) and prose stay in the header.
    header_end = 0
    for i, ln in enumerate(lines):
        if SECTION_HEADING_RE.match(ln):
            header_end = i
            break

    # Find the H2 heading inside each section range.
    def section_heading(start: int, end: int, default: str) -> tuple[str, int]:
        for i in range(start, end):
            if SECTION_HEADING_RE.match(lines[i]):
                return lines[i], i + 1  # content starts after heading
        return default, start

    shipped_heading, shipped_body_start = section_heading(header_end, div_a, "## Shipped (previous releases)")
    current_heading, current_body_start = section_heading(div_a + 1, div_b, "## Shipped since last release")
    todo_heading, todo_body_start = section_heading(div_b + 1, len(lines), "## Todo")

    shipped_lines = lines[shipped_body_start:div_a]
    current_lines = lines[current_body_start:div_b]
    todo_lines = lines[todo_body_start:]

    return WorkMd(
        path=path,
        header=lines[:header_end],
        shipped=list(_iter_items(shipped_lines, shipped_body_start + 1)),
        current=list(_iter_items(current_lines, current_body_start + 1)),
        todo=list(_iter_items(todo_lines, todo_body_start + 1)),
        shipped_heading=shipped_heading,
        current_heading=current_heading,
        todo_heading=todo_heading,
        divider_a=lines[div_a],
        divider_b=lines[div_b],
    )


def _emit_item(it: WorkItem) -> list[str]:
    if it.raw_lines:
        return list(it.raw_lines)
    out = [it.title]
    out.extend(f"  {d}" for d in it.details)
    return out


def serialize(wm: WorkMd) -> str:
    lines: list[str] = []
    lines.extend(wm.header)
    if wm.header and wm.header[-1].strip():
        lines.append("")
    lines.append(wm.shipped_heading)
    for it in wm.shipped:
        lines.extend(_emit_item(it))
    lines.append("")
    lines.append(wm.divider_a)
    lines.append(wm.current_heading)
    for it in wm.current:
        lines.extend(_emit_item(it))
    lines.append("")
    lines.append(wm.divider_b)
    lines.append(wm.todo_heading)
    for it in wm.todo:
        lines.extend(_emit_item(it))
    if not lines[-1].endswith("\n"):
        lines.append("")  # trailing newline
    return "\n".join(lines) + "\n"


# ---- locking ----

class FileLock:
    """mkdir-based atomic lock — portable on macOS (no flock dep).

    Times out after `wait_s` seconds and raises TimeoutError.
    """
    def __init__(self, target: Path, wait_s: float = 30.0):
        self.lockdir = Path(str(target) + ".lockdir")
        self.wait_s = wait_s

    def __enter__(self):
        deadline = time.time() + self.wait_s
        while True:
            try:
                self.lockdir.mkdir()
                return self
            except FileExistsError:
                if time.time() >= deadline:
                    raise TimeoutError(f"Could not acquire lock {self.lockdir} within {self.wait_s}s")
                time.sleep(0.2)

    def __exit__(self, *exc):
        try:
            self.lockdir.rmdir()
        except OSError:
            pass


# ---- mutations ----

def find_item(items: list[WorkItem], title: str) -> int:
    """Return index of item matching title (case-insensitive substring match).

    Exact match preferred; otherwise return first substring hit.
    """
    needle = title.strip().lower()
    for i, it in enumerate(items):
        if it.title.strip().lower() == needle:
            return i
    for i, it in enumerate(items):
        if needle in it.title.lower():
            return i
    return -1


def ship(path: Path, title: str) -> WorkItem:
    """Move an item from Todo → Shipped-since-last-release.

    Appends to the end of `current` so the section stays in chronological
    completion order. Raises ValueError if not found.
    """
    with FileLock(path):
        wm = parse(path)
        idx = find_item(wm.todo, title)
        if idx < 0:
            raise ValueError(f"item not found in todo: {title!r}")
        item = wm.todo.pop(idx)
        wm.current.append(item)
        path.write_text(serialize(wm))
        return item


def escalate(path: Path, title: str, log_ref: str, escalations_path: Path) -> WorkItem:
    """Drop an item from Todo and record it in escalations.md.

    The item stays out of WORK.md until the CEO re-adds it. Escalation log
    is append-only so historic context is preserved.
    """
    with FileLock(path):
        wm = parse(path)
        idx = find_item(wm.todo, title)
        if idx < 0:
            raise ValueError(f"item not found in todo: {title!r}")
        item = wm.todo.pop(idx)
        path.write_text(serialize(wm))

    escalations_path.parent.mkdir(parents=True, exist_ok=True)
    block = [
        "",
        f"## Escalated {time.strftime('%Y-%m-%d %H:%M %Z')} — {item.title}",
        f"log: {log_ref}",
    ]
    for d in item.details:
        block.append(f"  {d}")
    with escalations_path.open("a") as f:
        f.write("\n".join(block) + "\n")
    return item


def append(path: Path, section: str, line: str, details: list[str] | None = None) -> None:
    """Append a new item to the named section ('todo', 'current', 'shipped')."""
    section_attr = {"todo": "todo", "current": "current", "shipped": "shipped"}.get(section)
    if section_attr is None:
        raise ValueError(f"unknown section: {section!r}")
    with FileLock(path):
        wm = parse(path)
        item = WorkItem(title=line.strip(), details=list(details or []))
        getattr(wm, section_attr).append(item)
        path.write_text(serialize(wm))


def _find_in_all(wm: WorkMd, title: str) -> tuple[str, int]:
    """Find item across all sections. Returns (section_name, index) or ('', -1)."""
    for section in ("todo", "current", "shipped"):
        idx = find_item(getattr(wm, section), title)
        if idx >= 0:
            return section, idx
    return "", -1


def promote(path: Path, title: str) -> WorkItem:
    """Remove [idea] and [cold] tags from the named item — 'accept' an idea
    or 'resurrect' a cold-archived item. Item becomes eligible for the
    overnight loop again.
    """
    with FileLock(path):
        wm = parse(path)
        section, idx = _find_in_all(wm, title)
        if idx < 0:
            raise ValueError(f"item not found: {title!r}")
        item = getattr(wm, section)[idx]
        new_title = re.sub(r"\[(idea|cold)\]\s*", "", item.title, flags=re.I).strip()
        if new_title == item.title:
            raise ValueError(f"item has no [idea]/[cold] tag: {title!r}")
        item.title = new_title
        # If the item carried its raw_lines from parse, rewrite the title line too.
        if item.raw_lines:
            item.raw_lines[0] = new_title
        path.write_text(serialize(wm))
        return item


def drop(path: Path, title: str) -> WorkItem:
    """Remove an item entirely from any section. Use to reject a Designer
    idea, delete a duplicate bug, or clear a stale item without archiving.
    """
    with FileLock(path):
        wm = parse(path)
        section, idx = _find_in_all(wm, title)
        if idx < 0:
            raise ValueError(f"item not found: {title!r}")
        item = getattr(wm, section).pop(idx)
        path.write_text(serialize(wm))
        return item


def release_cut(path: Path, version: str) -> int:
    """Roll WORK.md sections on a release cut.

    1. Take every item currently in `## Shipped since last release`.
    2. Prepend `<version> — ` to each title.
    3. Append them to `## Shipped (previous releases)` in order.
    4. Leave `## Shipped since last release` empty.

    Returns the count of items moved. Used by the PM agent on release day.
    """
    if not re.fullmatch(r"v\d+(\.\d+)*", version):
        raise ValueError(f"version must look like v0.4 or v1.2.3, got: {version!r}")
    with FileLock(path):
        wm = parse(path)
        moved = list(wm.current)
        if not moved:
            return 0
        for item in moved:
            new_title = f"{version} — {item.title}"
            item.title = new_title
            if item.raw_lines:
                item.raw_lines[0] = new_title
        wm.shipped.extend(moved)
        wm.current = []
        path.write_text(serialize(wm))
        return len(moved)


def bump(path: Path, title: str, new_priority: str) -> WorkItem:
    """Change the priority tag (p0..p3) on an item. Use for triage to bump
    a [bug] from p1 to p0, or to demote a stale [feature].
    """
    new_priority = new_priority.lower().strip()
    if not re.fullmatch(r"p[0-3]", new_priority):
        raise ValueError(f"priority must be p0..p3, got: {new_priority!r}")
    with FileLock(path):
        wm = parse(path)
        section, idx = _find_in_all(wm, title)
        if idx < 0:
            raise ValueError(f"item not found: {title!r}")
        item = getattr(wm, section)[idx]
        if PRIORITY_RE.search(item.title):
            new_title = PRIORITY_RE.sub(new_priority, item.title, count=1)
        else:
            # No existing priority — inject after kind tags or at the start.
            m = re.match(r"^((?:\[[\w-]+\]\s*)+)(.*)", item.title)
            if m:
                new_title = f"{m.group(1)}{new_priority} {m.group(2)}"
            else:
                new_title = f"{new_priority} {item.title}"
        item.title = new_title
        if item.raw_lines:
            item.raw_lines[0] = new_title
        path.write_text(serialize(wm))
        return item


def top_n(path: Path, n: int = 10, skip_attempted: list[str] | None = None) -> list[WorkItem]:
    """Return the first N eligible Todo items.

    Eligible = not [idea], not [cold], not [manual]/MANUAL, not [needs-ceo],
    not in skip_attempted. Preserves file order.
    """
    wm = parse(path)
    skip = {s.strip().lower() for s in (skip_attempted or [])}
    out: list[WorkItem] = []
    for it in wm.todo:
        if it.is_idea or it.is_cold or it.is_manual or it.is_needs_ceo:
            continue
        if it.title.strip().lower() in skip:
            continue
        out.append(it)
        if len(out) >= n:
            break
    return out


def clarify(path: Path, title: str, questions: list[str]) -> WorkItem:
    """Tag an item with [needs-ceo] and append the Developer's clarifying
    questions as indented detail lines under the item.

    Overnight skips [needs-ceo] items. CEO answers the questions (edits the
    item to add specifics), removes the [needs-ceo] tag, and overnight picks
    it up again on the next run.
    """
    if not questions:
        raise ValueError("clarify requires at least one --question")
    with FileLock(path):
        wm = parse(path)
        section, idx = _find_in_all(wm, title)
        if idx < 0:
            raise ValueError(f"item not found: {title!r}")
        item = getattr(wm, section)[idx]
        # Prepend [needs-ceo] tag if not already present.
        if not item.is_needs_ceo:
            new_title = f"[needs-ceo] {item.title}"
            item.title = new_title
            if item.raw_lines:
                item.raw_lines[0] = new_title
        # Append each question as an indented detail line, prefixed with "Q:".
        ts = time.strftime("%Y-%m-%d")
        for q in questions:
            q_line = f"Q ({ts}): {q.strip()}"
            item.details.append(q_line)
            if item.raw_lines:
                item.raw_lines.append(f"  {q_line}")
        path.write_text(serialize(wm))
        return item


# ---- CLI ----

def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)

    pp = sub.add_parser("parse", help="dump structure as JSON")
    pp.add_argument("path")

    pt = sub.add_parser("top", help="print top N eligible Todo items as JSON")
    pt.add_argument("path")
    pt.add_argument("-n", type=int, default=10)
    pt.add_argument("--skip", action="append", default=[], help="title to skip (repeatable)")

    ps = sub.add_parser("ship", help="move Todo item → Shipped-since-last-release")
    ps.add_argument("path")
    ps.add_argument("title")

    pe = sub.add_parser("escalate", help="drop Todo item and record in escalations.md")
    pe.add_argument("path")
    pe.add_argument("title")
    pe.add_argument("--log", default="(no log)")
    pe.add_argument("--escalations", default=None,
                    help="path to escalations.md (default: <repo>/.factory/escalations.md)")

    pa = sub.add_parser("append", help="append a new item to a section")
    pa.add_argument("path")
    pa.add_argument("--section", required=True, choices=("todo", "current", "shipped"))
    pa.add_argument("title")
    pa.add_argument("--detail", action="append", default=[], help="indented detail line (repeatable)")

    pr = sub.add_parser("promote", help="remove [idea]/[cold] tag from an item (accept idea / resurrect cold)")
    pr.add_argument("path")
    pr.add_argument("title")

    pd = sub.add_parser("drop", help="delete an item entirely from any section (reject idea / dedupe bug)")
    pd.add_argument("path")
    pd.add_argument("title")

    pb = sub.add_parser("bump", help="change priority tag (p0..p3) on an item")
    pb.add_argument("path")
    pb.add_argument("title")
    pb.add_argument("priority")

    prc = sub.add_parser("release-cut",
        help="move ## Shipped since last release → ## Shipped (previous releases) under <version>")
    prc.add_argument("path")
    prc.add_argument("version", help="e.g., v0.4")

    pc = sub.add_parser("clarify",
        help="Developer tags an item [needs-ceo] and appends questions as indented details")
    pc.add_argument("path")
    pc.add_argument("title")
    pc.add_argument("--question", action="append", required=True,
        help="clarifying question (repeatable)")

    args = p.parse_args(argv)
    path = Path(os.path.expanduser(args.path))

    if args.cmd == "parse":
        wm = parse(path)
        print(json.dumps(wm.to_dict(), indent=2))
        return 0

    if args.cmd == "top":
        items = top_n(path, n=args.n, skip_attempted=args.skip)
        print(json.dumps([it.to_dict() for it in items], indent=2))
        return 0

    if args.cmd == "ship":
        item = ship(path, args.title)
        print(f"shipped: {item.title}")
        return 0

    if args.cmd == "escalate":
        esc = Path(os.path.expanduser(args.escalations)) if args.escalations \
              else path.parent / ".factory" / "escalations.md"
        item = escalate(path, args.title, args.log, esc)
        print(f"escalated: {item.title} → {esc}")
        return 0

    if args.cmd == "append":
        append(path, args.section, args.title, args.detail)
        print(f"appended to {args.section}: {args.title}")
        return 0

    if args.cmd == "promote":
        item = promote(path, args.title)
        print(f"promoted: {item.title}")
        return 0

    if args.cmd == "drop":
        item = drop(path, args.title)
        print(f"dropped: {item.title}")
        return 0

    if args.cmd == "bump":
        item = bump(path, args.title, args.priority)
        print(f"bumped to {args.priority}: {item.title}")
        return 0

    if args.cmd == "release-cut":
        n = release_cut(path, args.version)
        print(f"release-cut {args.version}: rolled {n} item(s) from current → shipped")
        return 0

    if args.cmd == "clarify":
        item = clarify(path, args.title, args.question)
        print(f"clarified ({len(args.question)} questions): {item.title}")
        return 0

    return 1


if __name__ == "__main__":
    sys.exit(main())
