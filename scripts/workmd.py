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
    workmd.py escalate <path> <title>          Tag the item [escalated] in
        [--summary-file F] [--detail D...]     place + append the summary
                                               markdown to escalations.md.
                                               Rare — only for items that
                                               truly need CEO judgment.
    workmd.py retry <path> <title>             Tag the item [retry] in
        [--detail D...]                        place. Used by the wrapper
                                               when tests/reviewer/merge
                                               failed — next dev run picks
                                               it up and tries again.
    workmd.py resume <path> <title>            Flip [escalated]/[retry]
                                               → [resume] so the wrapper
                                               picks it up.
    workmd.py sync-escalations <path>          Regenerate escalations.md
        [--escalations P]                      from current [escalated]
                                               items in WORK.md. Idempotent.
                                               Wrapper calls this every iter,
                                               so CEO clearing escalations.md
                                               without retagging just makes
                                               it reappear next tick.
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
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterator


DIVIDER_RE = re.compile(r"^[-=]{10,}\s*$")
SECTION_HEADING_RE = re.compile(r"^##\s+")   # H2 only — section boundaries
ANY_HEADING_RE = re.compile(r"^#{1,6}\s+")    # any-depth — skip when scanning for items
PRIORITY_RE = re.compile(r"\bp[0-3]\b", re.I)
KIND_TAG_RE = re.compile(r"\[(bug|feature|chore|idea|game-feature|cold|manual|needs-ceo|future|escalated|resume|retry|concern|untriaged-proposal-active|untriaged|epic|test_failure|wip:\d+)\]", re.I)
WIP_TAG_RE = re.compile(r"\[wip:(\d+)\]", re.I)
# A new work item's first state: shaping not yet done. Devs + Designer skip it.
# `[untriaged]` = raw, awaiting Architect intake (fast-pass or first questionnaire);
# `[untriaged-proposal-active]` = a questionnaire is in flight in .factory/local/TRIAGE.md.
TRIAGE_ID_RE = re.compile(r"^\s*triage-id:\s*(\S+)\s*$", re.I)
# Subtasks / epics. The Architect can decompose a complex feature into a parent
# `[epic]` item (devs skip it; it auto-ships when its last child ships) + N child
# items that share `epic-id: E-xxxx` and are ordered by `seq: N`. A child is only
# eligible once every lower-seq sibling has shipped (left ## Todo) — strictly
# sequential, so each child builds on the prior one's merged code.
EPIC_ID_RE = re.compile(r"^\s*epic-id:\s*(\S+)\s*$", re.I)
SEQ_RE = re.compile(r"^\s*seq:\s*(\d+)\s*$", re.I)
# A `[test_failure]` item (filed by the batch test runner) carries a
# `test-ref: <kind>:<id>` detail naming the single test that failed, e.g.
# `test-ref: unit:test/unit/test_foo.gd` or `test-ref: scenario:add-dogs`.
# The fixing developer re-runs ONLY this ref as its merge gate, and the runner
# dedupes against open [test_failure] items by this ref.
TEST_REF_RE = re.compile(r"^\s*test-ref:\s*(\S+)\s*$", re.I)
# Manual-item prefix: "MANUAL - foo", "MANUAL: foo", "MANUAL foo" — overnight skips these.
MANUAL_PREFIX_RE = re.compile(r"^\s*MANUAL\b\s*[-:–—]?\s*", re.I)
# Future-item prefix: "FUTURE - foo", "FUTURE: foo", "FUTURE foo" — overnight
# skips these too. Signals to the CEO that this is on the roadmap but not yet
# ready (needs scoping / blocked on something / deliberately deferred).
FUTURE_PREFIX_RE = re.compile(r"^\s*FUTURE\b\s*[-:–—]?\s*", re.I)


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
    def is_future(self) -> bool:
        """True if item is parked for later — either tagged [future] or starts
        with a FUTURE prefix (e.g. 'FUTURE - multiplayer co-op'). Overnight
        skips these. Use for things on the roadmap that aren't ready: needs
        scoping, blocked on a dependency, or deliberately deferred until a
        later milestone. The CEO removes the tag when ready to schedule it."""
        return "future" in self.tags or bool(FUTURE_PREFIX_RE.match(self.title))

    @property
    def is_needs_ceo(self) -> bool:
        """True if Developer asked clarifying questions — needs CEO answers
        before overnight will re-attempt it."""
        return "needs-ceo" in self.tags

    @property
    def is_escalated(self) -> bool:
        """True if this item needs CEO judgment (rare, manually-set state
        for genuine design/PM concerns or items the dev truly cannot
        action). NOT set automatically by test failures, reviewer blocks,
        or merge conflicts — those use [retry] instead. The feature
        branch (if any) has been preserved on origin (see the `branch:`
        detail line). Wrapper skips [escalated] — CEO triages by either
        deleting the item, editing it and retagging as [resume], or just
        leaving it (does nothing)."""
        return "escalated" in self.tags

    @property
    def is_resume(self) -> bool:
        """True if CEO has triaged an escalated item and wants the dev to
        resume from the saved branch. Wrapper picks up [resume] items,
        checks out the branch listed in details, rebases on master, and
        hands off to the dev with full failure context."""
        return "resume" in self.tags

    @property
    def is_wip(self) -> bool:
        """True if a parallel-dev worker has claimed this item (tagged
        `[wip:N]` where N is the worker id). Other workers' top_n calls
        skip [wip:*] items so two workers never grab the same item.
        Released on ship (item moves to Shipped) or retry (re-tagged as
        [retry]). Workers also strip their own [wip:<my-id>] on startup
        in case a prior crash left one behind."""
        return bool(WIP_TAG_RE.search(self.title))

    @property
    def wip_worker_id(self) -> int | None:
        """If is_wip, returns the integer worker id; else None."""
        m = WIP_TAG_RE.search(self.title)
        return int(m.group(1)) if m else None

    @property
    def is_retry(self) -> bool:
        """True if the wrapper bounced this item back into the queue
        because tests failed / reviewer blocked / merge conflicted on
        the dev's branch. These are all things the next developer run
        can fix — no CEO involvement needed. The feature branch is
        preserved on origin (see `branch:` detail line); details capture
        the specific failure (reviewer findings, test names, conflict
        files). Wrapper picks up [retry] items just like [resume],
        rebases the saved branch on master, and hands off to the dev
        with the prior attempt's commits + failure context."""
        return "retry" in self.tags

    @property
    def is_concern(self) -> bool:
        """True if this item is advisory commentary rather than work to
        do — Designer or Producer flagged a potential issue (cliché /
        complexity / balance / drift). The wrapper skips [concern]
        items. CEO triages: delete (dismiss), remove the tag (turn into
        real work), or leave alone (defer)."""
        return "concern" in self.tags

    @property
    def is_untriaged(self) -> bool:
        """True if this is a freshly-added item awaiting the Architect's first
        pass (fast-pass or questionnaire). Devs + Designer skip it. Set at the
        intake sources (producer/designer-promote/manual feature items)."""
        return "untriaged" in self.tags

    @property
    def is_untriaged_proposal_active(self) -> bool:
        """True while a shaping questionnaire is in flight for this item (its
        Q&A lives in .factory/local/TRIAGE.md, keyed by the item's triage-id
        detail line). Devs + Designer skip it until the Architect finalizes
        the spec and removes the tag."""
        return "untriaged-proposal-active" in self.tags

    @property
    def triage_id(self) -> str | None:
        """The stable id linking this item to its TRIAGE.md section, stored as
        a `triage-id: T-xxxx` detail line (added by shape-start)."""
        for d in self.details:
            m = TRIAGE_ID_RE.match(d)
            if m:
                return m.group(1)
        return None

    @property
    def is_epic(self) -> bool:
        """True if this is a parent `[epic]` item — a display + completion
        tracker for a decomposed feature. Devs NEVER build it directly; it
        auto-ships once all its children (same epic-id) have shipped."""
        return "epic" in self.tags

    @property
    def epic_id(self) -> str | None:
        """For a parent `[epic]` or a child subtask: the shared `epic-id: E-xxxx`
        detail that groups a decomposed feature's items together."""
        for d in self.details:
            m = EPIC_ID_RE.match(d)
            if m:
                return m.group(1)
        return None

    @property
    def seq(self) -> int | None:
        """A child subtask's 1-based order within its epic (`seq: N` detail).
        Children are claimable strictly in seq order."""
        for d in self.details:
            m = SEQ_RE.match(d)
            if m:
                return int(m.group(1))
        return None

    @property
    def is_test_failure(self) -> bool:
        """True if this is a regression filed by the batch test runner. It IS
        claimable (NOT skipped), but only ONE [test_failure] is worked at a time
        across all workers (see _test_failure_blocked) — other workers take
        normal items. The fixing dev MAY run the single named test (test_ref) to
        verify the fix, the only place tests run in the dev path."""
        return "test_failure" in self.tags

    @property
    def test_ref(self) -> str | None:
        """For a `[test_failure]` item: the `test-ref: <kind>:<id>` detail naming
        the one failing test (e.g. `unit:test/unit/test_foo.gd`,
        `scenario:add-dogs`). Used as the dedup key + the targeted fix gate."""
        for d in self.details:
            m = TEST_REF_RE.match(d)
            if m:
                return m.group(1)
        return None

    def to_dict(self) -> dict:
        return {
            "title": self.title,
            "details": self.details,
            "priority": self.priority,
            "tags": self.tags,
            "triage_id": self.triage_id,
            "epic_id": self.epic_id,
            "seq": self.seq,
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
    completion order. Strips any [wip:N] tag (a shipping item is by definition
    no longer claimed) and any [untriaged]/[untriaged-proposal-active] tag (a
    shipped item is by definition no longer awaiting shaping — e.g. the
    Architect ships an item it recognizes as already-done). Raises ValueError
    if not found.
    """
    with FileLock(path):
        wm = parse(path)
        idx = find_item(wm.todo, title)
        if idx < 0:
            raise ValueError(f"item not found in todo: {title!r}")
        item = wm.todo.pop(idx)
        item.title = WIP_TAG_RE.sub("", item.title)
        item.title = re.sub(r"\[(untriaged-proposal-active|untriaged)\]\s*", "",
                            item.title, flags=re.I).strip()
        item.raw_lines = [item.title] + [f"  {d}" for d in item.details]
        wm.current.append(item)
        path.write_text(serialize(wm))
        return item


def sync_escalations(work_path: Path, esc_path: Path) -> int:
    """Regenerate esc_path from the current [escalated] items in WORK.md.

    Idempotent: if WORK.md is unchanged, esc_path is rewritten byte-for-byte.
    If the CEO clears esc_path manually without retagging items in WORK.md
    (e.g., to acknowledge they've read it but haven't decided yet), the
    next call rebuilds it. The only way to remove an item from
    escalations.md is to retag it in WORK.md ([escalated] → [resume]) —
    or, in the rare "I'm abandoning this entirely" case, delete the item
    line from WORK.md by hand.

    Returns the count of escalated items.
    """
    wm = parse(work_path)
    escalated = [it for it in wm.todo if it.is_escalated]
    esc_path.parent.mkdir(parents=True, exist_ok=True)

    header = [
        "# Escalations",
        "",
        f"Generated {time.strftime('%Y-%m-%d %H:%M %Z')} by continuous_dev.sh.",
        "",
        "This file is **derived state**, recomputed from WORK.md every wrapper",
        "iteration. To resolve an item:",
        "",
        "- **Resume** (retry from saved branch with new guidance): retag",
        "  `[escalated]` → `[resume]` in WORK.md and edit the item's detail",
        "  lines with your decision/clarification.",
        "- **Acknowledge but defer** (you've read this; doing it later):",
        "  no action — the item will keep showing up here until retagged.",
        "  Clearing this file alone does nothing; the next tick regenerates.",
        "",
    ]

    if not escalated:
        esc_path.write_text("\n".join(header + ["No items currently escalated.", ""]))
        return 0

    body: list[str] = []
    for it in escalated:
        title = re.sub(r"^\[escalated\]\s*", "", it.title, flags=re.I)
        body.append(f"## {title}")
        body.append("")
        if it.details:
            for d in it.details:
                body.append(f"- {d}")
        else:
            body.append("- (no details captured — see git log of WORK.md for history)")
        body.append("")
        body.append("---")
        body.append("")

    esc_path.write_text("\n".join(header + body))
    return len(escalated)


## After this many consecutive retries, the item auto-escalates to
## [escalated] instead of getting yet another [retry] tag. CEO action
## becomes required at that point — five attempts is enough signal that
## the dev can't land this autonomously.
RETRY_ESCALATE_THRESHOLD = 5


def retry(
    path: Path,
    title: str,
    new_details: list[str] | None = None,
) -> WorkItem:
    """Tag a Todo item as [retry] in-place — used by the wrapper when a
    dev's branch failed tests / reviewer / merge. The next dev run picks
    up [retry] items and tries again with the failure feedback in
    details.

    - Adds `[retry]` to the title (strips [resume]/[escalated] if present —
      these are mutually exclusive states).
    - Appends `new_details` (failure summary, branch name, attempt info)
      under the item.
    - Item stays in Todo. top_n() includes [retry] as eligible — they
      retry next iter.
    - No CEO escalation. The dev fixes their own mess on the next run.

    AUTO-ESCALATION: when the item already has >= RETRY_ESCALATE_THRESHOLD
    `retry:` detail lines from prior attempts, this call promotes it to
    [escalated] instead. The CEO sees the item in escalations.md +
    MORNING.md and decides whether to retag [resume] (with new
    guidance), [drop] (delete the item), or leave it stuck.
    """
    with FileLock(path):
        wm = parse(path)
        idx = find_item(wm.todo, title)
        if idx < 0:
            raise ValueError(f"item not found in todo: {title!r}")
        item = wm.todo[idx]
        # Count prior `retry:` lines — each retry call appends one, so the
        # count = number of times this item has been retried before.
        prior_retries = sum(
            1 for d in item.details
            if d.strip().lower().startswith("retry:")
        )
        # Strip mutually exclusive tags + any [wip:N] claim.
        new_title = re.sub(r"\[(resume|escalated|retry)\]\s*", "", item.title, flags=re.I)
        new_title = WIP_TAG_RE.sub("", new_title).strip()
        # If this would be the Nth retry where N >= threshold, auto-escalate.
        # (prior_retries counts ATTEMPTS that already produced a retry: line;
        # this call would be the (prior_retries+1)th, so we trigger when that
        # value reaches the threshold.)
        attempt_about_to_make = prior_retries + 1
        if attempt_about_to_make >= RETRY_ESCALATE_THRESHOLD:
            new_title = "[escalated] " + new_title
            item.details.append(
                f"auto-escalated: failed {attempt_about_to_make} times — "
                f"CEO judgment required to unstick this item"
            )
        else:
            new_title = "[retry] " + new_title
        item.title = new_title
        if new_details:
            for d in new_details:
                if d not in item.details:
                    item.details.append(d)
        item.raw_lines = [item.title] + [f"  {d}" for d in item.details]
        path.write_text(serialize(wm))
    return item


def escalate(
    path: Path,
    title: str,
    escalations_path: Path,
    summary_md: str = "",
    new_details: list[str] | None = None,
) -> WorkItem:
    """Tag a Todo item as [escalated] in-place and append a rich summary
    to escalations.md.

    Replaces the previous behavior (which removed the item from Todo);
    that lost the dev's branch and made it hard for the CEO to see all
    pending work in one place.

    NEW behavior:
    - Adds `[escalated]` to the item's title (if not already).
    - Appends `new_details` (failure summary, branch name, last commit,
      etc.) under the item so the CEO can triage from WORK.md alone.
    - Appends `summary_md` (a markdown block, no log path link) to
      escalations.md — that file becomes a self-contained history.
    - The item stays in Todo. The wrapper's top_n filter skips
      [escalated], so it won't auto-retry until the CEO retags as
      [resume].
    """
    with FileLock(path):
        wm = parse(path)
        idx = find_item(wm.todo, title)
        if idx < 0:
            raise ValueError(f"item not found in todo: {title!r}")
        item = wm.todo[idx]
        # Tag the title with [escalated] if not already present. Also strip
        # any prior [resume] tag — those are mutually exclusive states.
        new_title = re.sub(r"\[resume\]\s*", "", item.title, flags=re.I)
        if "escalated" not in [t.lower() for t in KIND_TAG_RE.findall(new_title)]:
            new_title = "[escalated] " + new_title
        item.title = new_title
        # Append new detail lines (caller passes failure summary).
        if new_details:
            for d in new_details:
                if d not in item.details:
                    item.details.append(d)
        # Rebuild raw_lines so serialize() emits the updated title + details.
        item.raw_lines = [item.title] + [f"  {d}" for d in item.details]
        path.write_text(serialize(wm))

    if summary_md:
        escalations_path.parent.mkdir(parents=True, exist_ok=True)
        with escalations_path.open("a") as f:
            f.write(summary_md.rstrip() + "\n")
    return item


def append(path: Path, section: str, line: str, details: list[str] | None = None,
           top: bool = False) -> None:
    """Add a new item to the named section ('todo', 'current', 'shipped').

    Appends to the END by default; `top=True` inserts at index 0 (the test
    runner queues [test_failure] items at the top of ## Todo)."""
    section_attr = {"todo": "todo", "current": "current", "shipped": "shipped"}.get(section)
    if section_attr is None:
        raise ValueError(f"unknown section: {section!r}")
    with FileLock(path):
        wm = parse(path)
        item = WorkItem(title=line.strip(), details=list(details or []))
        if top:
            getattr(wm, section_attr).insert(0, item)
        else:
            getattr(wm, section_attr).append(item)
        path.write_text(serialize(wm))


def file_test_failure(path: Path, test_ref: str, title: str,
                      details: list[str] | None = None) -> bool:
    """File a [test_failure] regression for `test_ref` at the TOP of ## Todo.

    Deduped: if any OPEN (## Todo) item already carries `test-ref: <test_ref>`,
    do nothing and return False — re-running the suite never piles duplicate
    items for the same still-broken test. Otherwise prepend a new item whose
    first detail is `test-ref: <test_ref>` and return True.

    The title should already include the `[test_failure]` tag + a priority,
    e.g. `[test_failure] p1 unit:test/unit/test_foo.gd failing`.
    """
    with FileLock(path):
        wm = parse(path)
        ref = test_ref.strip()
        for it in wm.todo:
            if it.test_ref == ref:
                return False
        merged = [f"test-ref: {ref}"] + list(details or [])
        wm.todo.insert(0, WorkItem(title=title.strip(), details=merged))
        path.write_text(serialize(wm))
        return True


def _find_in_all(wm: WorkMd, title: str) -> tuple[str, int]:
    """Find item across all sections. Returns (section_name, index) or ('', -1)."""
    for section in ("todo", "current", "shipped"):
        idx = find_item(getattr(wm, section), title)
        if idx >= 0:
            return section, idx
    return "", -1


def promote(path: Path, title: str, details: list[str] | None = None,
            retitle: str | None = None) -> WorkItem:
    """'Accept' a Designer idea or 'resurrect' a cold-archived item — optionally
    WITH edits (accept-with-edits).

    - `[idea]` → `[untriaged]`: accepting a designer idea sends it INTO the
      shaping pipeline (the Architect will fast-pass it or write a
      questionnaire), NOT straight to the build queue. This is the gate that
      keeps the CEO from greenlighting vague ideas.
    - `[cold]` → removed: a janitor-archived item was already real, shaped
      work; resurrecting it makes it directly eligible again.

    Edits applied at accept time (so the CEO doesn't need a drop+re-append
    dance just to tweak an idea before it enters shaping):
    - `details`: extra spec/constraint lines appended under the item (e.g.
      "Only trigger ~1/3 of patrol reversals"). The Architect reads these.
    - `retitle`: replace the idea's descriptive text while PRESERVING its
      leading tags + priority (the `[idea]`→`[untriaged]` swap still happens).
      Pass just the new description, not the tags.
    """
    with FileLock(path):
        wm = parse(path)
        section, idx = _find_in_all(wm, title)
        if idx < 0:
            raise ValueError(f"item not found: {title!r}")
        item = getattr(wm, section)[idx]
        if item.is_idea:
            new_title = re.sub(r"\[idea\]\s*", "[untriaged] ", item.title, count=1, flags=re.I)
        elif item.is_future:
            # CEO pulled a deferred [future] item into the shaping pipeline.
            new_title = re.sub(r"\[future\]\s*", "[untriaged] ", item.title, count=1, flags=re.I)
        else:
            new_title = re.sub(r"\[cold\]\s*", "", item.title, flags=re.I)
        new_title = re.sub(r"\s{2,}", " ", new_title).strip()
        if new_title == item.title and not details and not retitle:
            raise ValueError(f"item has no [idea]/[cold]/[future] tag: {title!r}")
        # Optional retitle: swap the descriptive text, keep leading tags + pN.
        if retitle is not None:
            m = re.match(r"^\s*((?:(?:\[[^\]]+\]|p[0-3])\s*)+)", new_title, flags=re.I)
            prefix = m.group(1).strip() + " " if m else ""
            new_title = f"{prefix}{retitle.strip()}"
        item.title = new_title
        if details:
            item.details.extend(details)
        # Rebuild raw_lines from scratch so appended details + the new title all
        # persist through serialize() (which prefers raw_lines when present).
        _rewrite_item_lines(item)
        path.write_text(serialize(wm))
        return item


def approve(path: Path, title: str) -> WorkItem:
    """Clear the [needs-ceo] tag from an item — the CEO validating a candidate so
    it becomes a live, dev-claimable item.

    [needs-ceo] is the gate the Triager/Playtester (candidate [bug]) and the
    Developer (a question for the CEO) put on an item; workers skip it until the
    CEO acts. Approving strips ONLY the [needs-ceo] tag, leaving the rest of the
    title intact (e.g. `[needs-ceo] [bug] p1 Foo` -> `[bug] p1 Foo`), so the
    overnight loop picks it up by priority like any other item.

    Returns the item with [needs-ceo] stripped, or raises if not found / the item
    isn't tagged [needs-ceo].
    """
    with FileLock(path):
        wm = parse(path)
        section, idx = _find_in_all(wm, title)
        if idx < 0:
            raise ValueError(f"item not found: {title!r}")
        item = getattr(wm, section)[idx]
        if not re.search(r"\[needs-ceo\]", item.title, flags=re.I):
            raise ValueError(f"item has no [needs-ceo] tag: {title!r}")
        item.title = re.sub(r"\[needs-ceo\]\s*", "", item.title, count=1, flags=re.I)
        item.title = re.sub(r"\s{2,}", " ", item.title).strip()
        _rewrite_item_lines(item)
        path.write_text(serialize(wm))
        return item


def find_item_by_triage_id(wm: WorkMd, triage_id: str) -> tuple[str, int]:
    """Find an item across all sections by its `triage-id` detail line.
    Returns (section_name, index) or ('', -1). Used by the Architect to map a
    TRIAGE.md questionnaire back to its WORK.md item without title matching."""
    tid = triage_id.strip().lower()
    for section in ("todo", "current", "shipped"):
        for idx, it in enumerate(getattr(wm, section)):
            cur = it.triage_id
            if cur and cur.lower() == tid:
                return section, idx
    return "", -1


def _rewrite_item_lines(item: WorkItem) -> None:
    item.raw_lines = [item.title] + [f"  {d}" for d in item.details]


def shape_list(path: Path) -> dict:
    """JSON-able view of the shaping pipeline: Todo items tagged `[untriaged]`
    (need intake), `[untriaged-proposal-active]` (questionnaire in flight), and
    `[concern]` (Designer design-issue advisories the Architect shapes into a
    resolution questionnaire, same as untriaged)."""
    wm = parse(path)
    untriaged = [it.to_dict() for it in wm.todo if it.is_untriaged]
    in_flight = [it.to_dict() for it in wm.todo if it.is_untriaged_proposal_active]
    concerns = [it.to_dict() for it in wm.todo if it.is_concern]
    return {"untriaged": untriaged, "proposal_active": in_flight, "concerns": concerns}


def shape_start(path: Path, title: str, triage_id: str | None = None) -> tuple[WorkItem, str]:
    """Intake: swap `[untriaged]` (or `[concern]`)→`[untriaged-proposal-active]`
    and attach a stable `triage-id` detail line (auto `T-xxxx` if not supplied).
    Returns (item, triage_id). The Architect calls this once it has written the
    item's Round-1 questionnaire to TRIAGE.md. `[concern]` items are accepted so
    Designer design-issue advisories flow through the same shaping pipeline."""
    with FileLock(path):
        wm = parse(path)
        section, idx = _find_in_all(wm, title)
        if idx < 0:
            raise ValueError(f"item not found: {title!r}")
        item = getattr(wm, section)[idx]
        if not (item.is_untriaged or item.is_concern):
            raise ValueError(f"item is not [untriaged]/[concern]: {item.title!r}")
        tid = (triage_id or f"T-{uuid.uuid4().hex[:4]}").strip()
        new_title = re.sub(r"\[(?:untriaged|concern)\]\s*", "[untriaged-proposal-active] ",
                           item.title, count=1, flags=re.I)
        item.title = re.sub(r"\s{2,}", " ", new_title).strip()
        if item.triage_id is None:
            item.details.append(f"triage-id: {tid}")
        else:
            tid = item.triage_id
        _rewrite_item_lines(item)
        path.write_text(serialize(wm))
        return item, tid


def shape_detail(path: Path, triage_id: str, details: list[str]) -> WorkItem:
    """Append spec detail lines to the proposal-active item with this triage-id
    WITHOUT finalizing it (records 'spec so far' between follow-up rounds)."""
    with FileLock(path):
        wm = parse(path)
        section, idx = find_item_by_triage_id(wm, triage_id)
        if idx < 0:
            raise ValueError(f"no item with triage-id: {triage_id!r}")
        item = getattr(wm, section)[idx]
        item.details.extend(details)
        _rewrite_item_lines(item)
        path.write_text(serialize(wm))
        return item


def shape_finalize(path: Path, triage_id: str, details: list[str] | None = None) -> WorkItem:
    """Finalize: append any final spec detail lines, then strip
    `[untriaged-proposal-active]` so the item becomes eligible for developers.
    Matched by triage-id."""
    with FileLock(path):
        wm = parse(path)
        section, idx = find_item_by_triage_id(wm, triage_id)
        if idx < 0:
            raise ValueError(f"no item with triage-id: {triage_id!r}")
        item = getattr(wm, section)[idx]
        if details:
            item.details.extend(details)
        new_title = re.sub(r"\[untriaged-proposal-active\]\s*", "", item.title,
                           count=1, flags=re.I)
        item.title = re.sub(r"\s{2,}", " ", new_title).strip()
        _rewrite_item_lines(item)
        path.write_text(serialize(wm))
        return item


def shape_pass(path: Path, title: str, details: list[str] | None = None) -> WorkItem:
    """Fast-pass: strip `[untriaged]` (and, defensively,
    `[untriaged-proposal-active]`) directly — the Architect judged the item
    already concrete enough to build, so no questionnaire is needed. Optionally
    append a clarifying detail. Matched by title substring."""
    with FileLock(path):
        wm = parse(path)
        section, idx = _find_in_all(wm, title)
        if idx < 0:
            raise ValueError(f"item not found: {title!r}")
        item = getattr(wm, section)[idx]
        new_title = re.sub(r"\[(untriaged-proposal-active|untriaged)\]\s*", "",
                           item.title, flags=re.I)
        new_title = re.sub(r"\s{2,}", " ", new_title).strip()
        if new_title == item.title:
            raise ValueError(f"item has no [untriaged] tag: {title!r}")
        item.title = new_title
        if details:
            item.details.extend(details)
        _rewrite_item_lines(item)
        path.write_text(serialize(wm))
        return item


def shape_epic(path: Path, triage_id: str, children: list[str]) -> tuple[WorkItem, list[WorkItem]]:
    """Decompose a shaped feature into a parent `[epic]` + sequential children.

    Finds the proposal-active item by `triage_id`, converts it into the parent
    `[epic] <feature>` (devs skip it; it auto-ships via reconcile_epics once all
    children ship), and inserts N child subtask items right after it in ## Todo.
    Each child reuses the parent's kind + priority and carries `epic-id: <id>`
    (== triage_id) + `seq: N`. epic-id reuses the triage-id value.

    `children` is a list of "<title> | <spec line> | <spec line>..." strings —
    the first `|`-segment is the child title, the rest become spec detail lines.
    Returns (parent, [children])."""
    if not children:
        raise ValueError("shape-epic needs at least one --child")
    with FileLock(path):
        wm = parse(path)
        sec, idx = find_item_by_triage_id(wm, triage_id)
        if idx < 0 or sec != "todo":
            raise ValueError(f"no in-Todo item with triage-id: {triage_id!r}")
        parent = wm.todo[idx]
        # Inherit kind + priority from the parent's current title for the children.
        kind_m = re.search(r"\[(bug|feature|chore|game-feature)\]", parent.title, re.I)
        kind = kind_m.group(1).lower() if kind_m else "feature"
        prio = parent.priority or ""
        # Parent becomes a clean "[epic] <feature name>" line (all other leading
        # tags + priority stripped — the parent is never built).
        feature = re.sub(r"^\s*((\[[^\]]+\]|p[0-3])\s*)+", "", parent.title, flags=re.I).strip()
        parent.title = f"[epic] {feature}"
        if parent.epic_id is None:
            parent.details.append(f"epic-id: {triage_id}")
        _rewrite_item_lines(parent)
        # Build child items.
        kids: list[WorkItem] = []
        for n, spec in enumerate(children, start=1):
            parts = [p.strip() for p in spec.split("|")]
            ctitle = parts[0]
            cdetails = [p for p in parts[1:] if p]
            prefix = f"[{kind}] {prio} " if prio else f"[{kind}] "
            kid = WorkItem(
                title=f"{prefix}{feature} — {ctitle}",
                details=[f"epic-id: {triage_id}", f"seq: {n}"] + cdetails,
            )
            _rewrite_item_lines(kid)
            kids.append(kid)
        # Insert children right after the parent (raw-file cohesion).
        wm.todo[idx + 1:idx + 1] = kids
        path.write_text(serialize(wm))
        return parent, kids


def reconcile_epics(path: Path) -> int:
    """Auto-ship any `[epic]` parent whose children have all shipped. A parent
    is complete when it has ≥1 child total and ZERO children remaining in
    ## Todo (shipped children have moved to Shipped-since). Idempotent; the
    wrapper calls this after each ship. Returns the count of epics shipped."""
    shipped = 0
    with FileLock(path):
        wm = parse(path)
        for parent in list(wm.todo):
            if not parent.is_epic:
                continue
            eid = parent.epic_id
            if not eid:
                continue
            in_todo = [c for c in wm.todo if not c.is_epic and c.epic_id == eid]
            elsewhere = [c for c in (wm.current + wm.shipped)
                         if not c.is_epic and c.epic_id == eid]
            if (len(in_todo) + len(elsewhere)) >= 1 and not in_todo:
                wm.todo.remove(parent)
                parent.title = WIP_TAG_RE.sub("", parent.title).strip()
                _rewrite_item_lines(parent)
                wm.current.append(parent)
                shipped += 1
        if shipped:
            path.write_text(serialize(wm))
    return shipped


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


def reorder_future(path: Path, order: list[str]) -> int:
    """Re-sort `[future]` items to the BOTTOM of ## Todo in the given order.

    Each `order` entry is a case-insensitive substring of a `[future]` item's
    title; matched items are placed (in that order) below all non-`[future]`
    items. Any `[future]` item NOT matched by an entry is kept after the ordered
    ones, in its original relative order. Items are MOVED VERBATIM — titles and
    every detail line are preserved exactly (these are the same WorkItem objects,
    just reordered), so nothing is reworded. Returns the count of `[future]`
    items repositioned (0 if there are none). Non-`[future]` items keep their
    current order untouched.
    """
    with FileLock(path):
        wm = parse(path)
        future = [it for it in wm.todo if it.is_future]
        if not future:
            return 0
        non_future = [it for it in wm.todo if not it.is_future]
        ordered: list[WorkItem] = []
        used: set[int] = set()
        for q in order:
            ql = q.strip().lower()
            if not ql:
                continue
            for it in future:
                if id(it) not in used and ql in it.title.lower():
                    ordered.append(it); used.add(id(it)); break
        for it in future:  # unmatched [future] items keep their relative order
            if id(it) not in used:
                ordered.append(it)
        wm.todo = non_future + ordered
        path.write_text(serialize(wm))
        return len(ordered)


def top_n(path: Path, n: int = 10, skip_attempted: list[str] | None = None) -> list[WorkItem]:
    """Return the first N eligible Todo items.

    Eligible = not [idea], not [cold], not [manual]/MANUAL, not [needs-ceo],
    not [future]/FUTURE, not [escalated], not [concern], not in
    skip_attempted.

    [resume] and [retry] items ARE eligible:
      - [resume]: CEO triaged an escalation and wants a retry from the
        saved branch.
      - [retry]: wrapper bounced the item after a test/reviewer/merge
        failure — next dev run picks it up and tries again from the
        saved branch with failure feedback in details.

    Preserves file order.
    """
def _is_skipped(it: WorkItem) -> bool:
    return (it.is_idea or it.is_cold or it.is_manual or it.is_needs_ceo
            or it.is_future or it.is_escalated or it.is_concern or it.is_wip
            or it.is_untriaged or it.is_untriaged_proposal_active
            or it.is_epic)


def _subtask_blocked(wm: "WorkMd", it: WorkItem) -> bool:
    """True if `it` is an epic child whose predecessor hasn't shipped yet.

    A child (has epic_id + seq) is blocked while ANY lower-seq sibling is still
    in `## Todo` — pending, [wip], [retry], or [escalated]. A shipped child has
    left Todo (moved to Shipped-since), so this naturally lets exactly the next
    incomplete subtask through and gates the rest. Non-subtask items (no epic_id
    / no seq) are never blocked."""
    eid = it.epic_id
    seq = it.seq
    if not eid or seq is None:
        return False
    for sib in wm.todo:
        if sib is it or sib.is_epic:
            continue
        if sib.epic_id == eid and sib.seq is not None and sib.seq < seq:
            return True
    return False


def _test_failure_blocked(wm: "WorkMd", it: WorkItem) -> bool:
    """True if `it` is a [test_failure] item while ANOTHER [test_failure] is
    already claimed ([wip:*]). Only ONE test_failure is worked at a time across
    all workers — so a second worker scanning the queue skips every test_failure
    and takes the next normal item instead. When the in-flight fix ships (leaves
    ## Todo) or retries, the next test_failure unblocks. Non-test_failure items
    are never blocked by this."""
    if not it.is_test_failure:
        return False
    for o in wm.todo:
        if o is it:
            continue
        if o.is_test_failure and o.is_wip:
            return True
    return False


def _is_resumable(it: WorkItem) -> bool:
    """[retry] / [resume] items have a saved branch + failure feedback
    in details; the next dev gets a head start. Prefer these over fresh
    items so we don't leave near-done work languishing at the bottom
    of the queue."""
    return it.is_retry or it.is_resume


def top_n(path: Path, n: int = 10, skip_attempted: list[str] | None = None) -> list[WorkItem]:
    """Return the first N eligible Todo items.

    Eligible = not [idea]/[cold]/[manual]/[needs-ceo]/[future]/[escalated]/
    [concern]/[wip:*], not in skip_attempted.

    Ordering: **[retry] and [resume] items come first** (in file order
    among themselves), then everything else (in file order). Rationale:
    [retry]/[resume] items have ~90% of the work already done on a
    saved branch — the next dev just addresses failure feedback. Always
    prefer those over fresh items so near-done work doesn't languish
    while N+1 fresh items pile up on top of it.
    """
    wm = parse(path)
    skip = {s.strip().lower() for s in (skip_attempted or [])}
    resumable: list[WorkItem] = []
    fresh: list[WorkItem] = []
    for it in wm.todo:
        if _is_skipped(it) or _subtask_blocked(wm, it) or _test_failure_blocked(wm, it):
            continue
        if it.title.strip().lower() in skip:
            continue
        if _is_resumable(it):
            resumable.append(it)
        else:
            fresh.append(it)
    return (resumable + fresh)[:n]


def claim(path: Path, worker_id: int) -> WorkItem | None:
    """Atomically pick the top eligible item AND tag it [wip:<worker_id>].

    Two parallel dev workers calling claim() never grab the same item —
    the FileLock around the read-modify-write serialises the operation,
    and the [wip:N] tag makes the item invisible to other workers'
    top_n / claim calls until released.

    Selection order matches top_n(): [retry]/[resume] items first (saved
    branch ready), then fresh items. With 3 workers in parallel, this
    drains the retry queue before fresh work, which is what the CEO wants.

    Returns the claimed WorkItem (with the new [wip:N] tag in its title),
    or None if no eligible items exist.
    """
    with FileLock(path):
        wm = parse(path)
        chosen_idx = -1
        # Two-pass: first scan for [retry]/[resume], then any eligible.
        for i, it in enumerate(wm.todo):
            if _is_skipped(it) or _subtask_blocked(wm, it) or _test_failure_blocked(wm, it):
                continue
            if _is_resumable(it):
                chosen_idx = i
                break
        if chosen_idx < 0:
            for i, it in enumerate(wm.todo):
                if _is_skipped(it) or _subtask_blocked(wm, it) or _test_failure_blocked(wm, it):
                    continue
                chosen_idx = i
                break
        if chosen_idx < 0:
            return None
        item = wm.todo[chosen_idx]
        item.title = f"[wip:{worker_id}] " + item.title
        item.raw_lines = [item.title] + [f"  {d}" for d in item.details]
        path.write_text(serialize(wm))
        return item


def unclaim(path: Path, title: str) -> WorkItem | None:
    """Strip the [wip:N] tag from an item (called by the worker when its
    work concludes — either ship or retry, both already handle the title
    transition themselves, but unclaim is the safe fallback for crash
    recovery).

    Returns the item with the [wip:N] tag stripped, or None if not found.
    """
    with FileLock(path):
        wm = parse(path)
        for section in ("todo", "current", "shipped"):
            sec_items: list[WorkItem] = getattr(wm, section)
            for it in sec_items:
                if WIP_TAG_RE.search(it.title):
                    # Match the un-wipped title against the requested title
                    stripped = WIP_TAG_RE.sub("", it.title).strip()
                    requested = WIP_TAG_RE.sub("", title).strip()
                    if stripped.lower().startswith(requested.lower()[:60]) \
                       or requested.lower().startswith(stripped.lower()[:60]):
                        it.title = WIP_TAG_RE.sub("", it.title).strip()
                        it.raw_lines = [it.title] + [f"  {d}" for d in it.details]
                        path.write_text(serialize(wm))
                        return it
        return None


def release_wip(path: Path, worker_id: int) -> int:
    """Strip all [wip:<worker_id>] tags. Workers call this on startup so
    a prior crash (lockfile orphan, SIGKILL, etc.) doesn't leave items
    stuck in wip state. Returns the count of items released.
    """
    pattern = re.compile(rf"\[wip:{worker_id}\]\s*", re.I)
    released = 0
    with FileLock(path):
        wm = parse(path)
        for section in ("todo", "current", "shipped"):
            sec_items: list[WorkItem] = getattr(wm, section)
            for it in sec_items:
                if pattern.search(it.title):
                    it.title = pattern.sub("", it.title).strip()
                    it.raw_lines = [it.title] + [f"  {d}" for d in it.details]
                    released += 1
        if released:
            path.write_text(serialize(wm))
    return released


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

    pe = sub.add_parser("escalate",
        help="tag a Todo item [escalated] in-place + append self-contained summary to escalations.md")
    pe.add_argument("path")
    pe.add_argument("title")
    pe.add_argument("--summary-file", default=None,
                    help="path to a markdown file whose contents are appended to escalations.md as the summary block (no log path link).")
    pe.add_argument("--detail", action="append", default=[],
                    help="indented detail line to append under the item (repeatable). Use for branch:, last-commit:, attempt summaries, etc.")
    pe.add_argument("--escalations", default=None,
                    help="path to escalations.md (default: <path-parent>/.factory/escalations.md)")

    pre = sub.add_parser("resume",
        help="flip an [escalated] item to [resume] — CEO has triaged and wants the dev to pick it back up next overnight")
    pre.add_argument("path")
    pre.add_argument("title")

    prt = sub.add_parser("retry",
        help="tag a Todo item [retry] — wrapper bounces failed branches here instead of escalating to CEO")
    prt.add_argument("path")
    prt.add_argument("title")
    prt.add_argument("--detail", action="append", default=[],
                     help="indented detail line (repeatable). Use for branch:, attempt-N feedback, reviewer findings, test names, etc.")

    pse = sub.add_parser("sync-escalations",
        help="regenerate escalations.md from current [escalated] items in WORK.md (idempotent; called every wrapper tick).")
    pse.add_argument("path", help="path to WORK.md")
    pse.add_argument("--escalations", default=None,
                     help="path to escalations.md (default: <path-parent>/.factory/escalations.md)")

    pcl = sub.add_parser("claim",
        help="atomically claim the next eligible Todo item — tag [wip:<worker-id>] + return its title. Used by parallel-dev workers.")
    pcl.add_argument("path")
    pcl.add_argument("--worker-id", type=int, required=True)

    puc = sub.add_parser("unclaim",
        help="strip [wip:N] from an item (release without ship/retry — used by crash recovery).")
    puc.add_argument("path")
    puc.add_argument("title")

    prw = sub.add_parser("release-wip",
        help="strip ALL [wip:<worker-id>] tags. Workers call this on startup so a prior crash doesn't leave items stuck claimed.")
    prw.add_argument("path")
    prw.add_argument("--worker-id", type=int, required=True)

    pa = sub.add_parser("append", help="append a new item to a section")
    pa.add_argument("path")
    pa.add_argument("--section", required=True, choices=("todo", "current", "shipped"))
    pa.add_argument("title")
    pa.add_argument("--detail", action="append", default=[], help="indented detail line (repeatable)")
    pa.add_argument("--top", action="store_true", help="insert at the TOP of the section instead of the end")

    ptf = sub.add_parser("file-test-failure",
        help="file a [test_failure] regression at the top of ## Todo, deduped by --test-ref (used by the batch test runner)")
    ptf.add_argument("path")
    ptf.add_argument("--test-ref", required=True, help="canonical ref of the failing test, e.g. unit:test/unit/test_foo.gd or scenario:add-dogs")
    ptf.add_argument("title", help="full item title incl. tag, e.g. '[test_failure] p1 unit:test/unit/test_foo.gd failing'")
    ptf.add_argument("--detail", action="append", default=[], help="indented detail line (repeatable) — e.g. a failure excerpt")

    pr = sub.add_parser("promote",
        help="accept an idea / pull a [future] in ([idea]/[future]→[untriaged]) / resurrect a [cold] item — optionally with edits (--detail / --retitle)")
    pr.add_argument("path")
    pr.add_argument("title")
    pr.add_argument("--detail", action="append", default=[],
        help="spec/constraint line to append under the item at accept time (repeatable)")
    pr.add_argument("--retitle", default=None,
        help="replace the item's descriptive text (tags + priority are preserved); pass just the new description")

    pap = sub.add_parser("approve",
        help="clear [needs-ceo] from an item — CEO validates a candidate ([bug]/question) → live, dev-claimable")
    pap.add_argument("path")
    pap.add_argument("title")

    pd = sub.add_parser("drop", help="delete an item entirely from any section (reject idea / dedupe bug)")
    pd.add_argument("path")
    pd.add_argument("title")

    pb = sub.add_parser("bump", help="change priority tag (p0..p3) on an item")
    pb.add_argument("path")
    pb.add_argument("title")
    pb.add_argument("priority")

    prf = sub.add_parser("reorder-future",
        help="re-sort [future] items to the bottom of ## Todo in the given order (verbatim move — no reword)")
    prf.add_argument("path")
    prf.add_argument("order", nargs="*",
        help="[future] title substrings in desired priority order; unmatched [future] items go after, in original order")

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

    psl = sub.add_parser("shape-list",
        help="JSON of [untriaged] (need intake) + [untriaged-proposal-active] (in-flight) Todo items")
    psl.add_argument("path")

    pss = sub.add_parser("shape-start",
        help="Architect intake: swap [untriaged]→[untriaged-proposal-active], attach + print a triage-id")
    pss.add_argument("path")
    pss.add_argument("title")
    pss.add_argument("--id", default=None, help="triage id to use (default: auto T-xxxx)")

    psd = sub.add_parser("shape-detail",
        help="append spec detail lines to the item with this triage-id (interim spec / follow-up rounds)")
    psd.add_argument("path")
    psd.add_argument("--id", required=True)
    psd.add_argument("--detail", action="append", required=True,
        help="indented detail line (repeatable)")

    psf = sub.add_parser("shape-finalize",
        help="append final spec detail lines + remove [untriaged-proposal-active] → item becomes eligible")
    psf.add_argument("path")
    psf.add_argument("--id", required=True)
    psf.add_argument("--detail", action="append", default=[],
        help="indented spec detail line (repeatable)")

    psp = sub.add_parser("shape-pass",
        help="fast-pass: strip [untriaged] directly (already-concrete item, no questionnaire) → eligible")
    psp.add_argument("path")
    psp.add_argument("title")
    psp.add_argument("--detail", action="append", default=[],
        help="optional clarifying detail line (repeatable)")

    pep = sub.add_parser("shape-epic",
        help="decompose a shaped feature into a parent [epic] + sequential child subtasks")
    pep.add_argument("path")
    pep.add_argument("--id", required=True, help="triage-id of the proposal-active item to decompose")
    pep.add_argument("--child", action="append", required=True, dest="child",
        help="'<child title> | <spec line> | <spec line>' (repeatable, in order)")

    prx = sub.add_parser("reconcile-epics",
        help="auto-ship any [epic] parent whose children have all shipped (wrapper calls after each ship)")
    prx.add_argument("path")

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
        summary_md = ""
        if args.summary_file:
            sf = Path(os.path.expanduser(args.summary_file))
            if sf.exists():
                summary_md = sf.read_text()
        item = escalate(path, args.title, esc, summary_md=summary_md, new_details=args.detail)
        print(f"escalated (tagged in-place): {item.title}")
        return 0

    if args.cmd == "retry":
        item = retry(path, args.title, new_details=args.detail)
        print(f"retry (tagged in-place): {item.title}")
        return 0

    if args.cmd == "sync-escalations":
        esc = Path(os.path.expanduser(args.escalations)) if args.escalations \
              else path.parent / ".factory" / "escalations.md"
        n = sync_escalations(path, esc)
        print(f"sync-escalations: regenerated {esc} ({n} escalated item(s))")
        return 0

    if args.cmd == "claim":
        item = claim(path, args.worker_id)
        if item is None:
            # stderr, NOT stdout: the continuous_dev wrapper captures stdout as
            # the claim JSON and treats empty stdout as "nothing to claim" (a
            # clean idle, exit 3). Printing here on stdout slipped past that
            # check and got mislabeled "claim returned malformed json".
            print("claim: no eligible items", file=sys.stderr)
            return 1
        print(json.dumps(item.to_dict(), indent=2))
        return 0

    if args.cmd == "unclaim":
        item = unclaim(path, args.title)
        if item is None:
            print(f"unclaim: no item found matching {args.title!r}", file=sys.stderr)
            return 1
        print(f"unclaimed: {item.title}")
        return 0

    if args.cmd == "release-wip":
        n = release_wip(path, args.worker_id)
        print(f"release-wip: released {n} item(s) tagged [wip:{args.worker_id}]")
        return 0

    if args.cmd == "resume":
        with FileLock(path):
            wm = parse(path)
            section, idx = _find_in_all(wm, args.title)
            if idx < 0:
                print(f"item not found: {args.title!r}", file=sys.stderr)
                return 1
            item = getattr(wm, section)[idx]
            new_title = re.sub(r"\[(escalated|retry)\]\s*", "", item.title, flags=re.I)
            if new_title == item.title:
                print(f"item is not [escalated] or [retry]: {item.title!r}", file=sys.stderr)
                return 1
            new_title = "[resume] " + new_title
            item.title = new_title
            if item.raw_lines:
                item.raw_lines[0] = new_title
            path.write_text(serialize(wm))
        print(f"resumed: {item.title}")
        return 0

    if args.cmd == "append":
        append(path, args.section, args.title, args.detail, top=args.top)
        where = "top of" if args.top else "to"
        print(f"appended {where} {args.section}: {args.title}")
        return 0

    if args.cmd == "file-test-failure":
        filed = file_test_failure(path, args.test_ref, args.title, args.detail)
        if filed:
            print(f"filed [test_failure] for {args.test_ref}")
            return 0
        print(f"file-test-failure: already open for {args.test_ref} — skipped (dedup)")
        return 0

    if args.cmd == "promote":
        item = promote(path, args.title, details=args.detail, retitle=args.retitle)
        print(f"promoted: {item.title}")
        return 0

    if args.cmd == "approve":
        item = approve(path, args.title)
        print(f"approved: {item.title}")
        return 0

    if args.cmd == "drop":
        item = drop(path, args.title)
        print(f"dropped: {item.title}")
        return 0

    if args.cmd == "bump":
        item = bump(path, args.title, args.priority)
        print(f"bumped to {args.priority}: {item.title}")
        return 0

    if args.cmd == "reorder-future":
        n = reorder_future(path, args.order)
        print(f"reorder-future: repositioned {n} [future] item(s) at the bottom of ## Todo")
        return 0

    if args.cmd == "release-cut":
        n = release_cut(path, args.version)
        print(f"release-cut {args.version}: rolled {n} item(s) from current → shipped")
        return 0

    if args.cmd == "clarify":
        item = clarify(path, args.title, args.question)
        print(f"clarified ({len(args.question)} questions): {item.title}")
        return 0

    if args.cmd == "shape-list":
        print(json.dumps(shape_list(path), indent=2))
        return 0

    if args.cmd == "shape-start":
        item, tid = shape_start(path, args.title, args.id)
        print(tid)
        return 0

    if args.cmd == "shape-detail":
        item = shape_detail(path, args.id, args.detail)
        print(f"shape-detail: +{len(args.detail)} line(s) → {item.title}")
        return 0

    if args.cmd == "shape-finalize":
        item = shape_finalize(path, args.id, args.detail)
        print(f"shape-finalize: {item.title}")
        return 0

    if args.cmd == "shape-pass":
        item = shape_pass(path, args.title, args.detail)
        print(f"shape-pass: {item.title}")
        return 0

    if args.cmd == "shape-epic":
        parent, kids = shape_epic(path, args.id, args.child)
        print(f"shape-epic: {parent.title} → {len(kids)} subtask(s)")
        for k in kids:
            print(f"  {k.title}")
        return 0

    if args.cmd == "reconcile-epics":
        n = reconcile_epics(path)
        print(f"reconcile-epics: shipped {n} completed epic parent(s)")
        return 0

    return 1


if __name__ == "__main__":
    sys.exit(main())
