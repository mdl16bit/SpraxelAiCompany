#!/usr/bin/env python3
"""WORK.md <-> GitHub Issues sync for the Spraxel gamedev factory.

Modes:
  (default)  dry-run. Print proposed changes, write nothing.
  --apply    execute the proposed changes.
  --seed     bootstrap-only: create GH Issues directly from unannotated WORK.md
             lines, bypassing the pending-intake queue. Use ONCE per repo.

Without --seed, unannotated Todo lines are queued in
.factory/inbox/pending-intake.md for the Producer agent to clean up + create
later. This indirection keeps messy dictated lines from becoming garbage
issues that the Developer wastes tokens on.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

DASH_LINE = "-" * 50
SECTIONS = ("shipped", "current", "todo")

ISSUE_RE = re.compile(r"\s*\(#(\d+)\)\s*$")
PRIORITY_RE = re.compile(r"^(p[0-3])\s+", re.IGNORECASE)
KIND_PREFIX_RE = re.compile(r"^(bug|fix|chore|feat|feature|new)\s*[:\-—]\s*", re.IGNORECASE)
LIST_BULLET_RE = re.compile(r"^\s*-\s+")


@dataclass
class WorkLine:
    raw: str
    line_no: int
    section: str
    bullet: str = ""
    body: str = ""
    issue_no: int | None = None
    priority: str = ""
    kind: str = "feature"

    @property
    def title(self) -> str:
        return self.body.strip()


@dataclass
class WorkDoc:
    header: list[str] = field(default_factory=list)
    sections: dict[str, list[WorkLine]] = field(default_factory=lambda: {s: [] for s in SECTIONS})
    raw_lines: list[str] = field(default_factory=list)


def parse_work_md(text: str) -> WorkDoc:
    doc = WorkDoc()
    doc.raw_lines = text.splitlines()

    HEADER, SHIPPED, CURRENT, TODO = -1, 0, 1, 2
    section_names = {SHIPPED: "shipped", CURRENT: "current", TODO: "todo"}

    section = HEADER
    dash_count = 0
    for i, raw in enumerate(doc.raw_lines):
        if raw.strip() == DASH_LINE:
            dash_count += 1
            if dash_count > 2:
                raise ValueError(
                    f"WORK.md has more than 2 dashed-line dividers (line {i + 1})"
                )
            section = SHIPPED if section == HEADER else section + 1
            continue

        if section == HEADER:
            if LIST_BULLET_RE.match(raw):
                section = SHIPPED
            else:
                doc.header.append(raw)
                continue

        if not LIST_BULLET_RE.match(raw):
            continue

        wl = _parse_line(raw, i + 1, section_names[section])
        doc.sections[section_names[section]].append(wl)

    if dash_count < 2:
        raise ValueError(
            f"WORK.md must contain two dashed-line dividers (found {dash_count})"
        )
    return doc


def _parse_line(raw: str, line_no: int, section: str) -> WorkLine:
    body = LIST_BULLET_RE.sub("", raw).rstrip()
    issue_no: int | None = None
    m = ISSUE_RE.search(body)
    if m:
        issue_no = int(m.group(1))
        body = body[: m.start()].rstrip()

    priority = ""
    p = PRIORITY_RE.match(body)
    if p:
        priority = p.group(1).lower()
        body = body[p.end():]

    kind = "feature"
    k = KIND_PREFIX_RE.match(body)
    if k:
        prefix = k.group(1).lower()
        if prefix in ("bug", "fix"):
            kind = "bug"
        elif prefix == "chore":
            kind = "chore"
        body = body[k.end():]

    return WorkLine(
        raw=raw,
        line_no=line_no,
        section=section,
        bullet="- ",
        body=body.strip(),
        issue_no=issue_no,
        priority=priority,
        kind=kind,
    )


def detect_repo_nwo(repo_dir: Path) -> str:
    out = _run(
        ["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
        cwd=repo_dir,
    )
    return out.strip()


def list_existing_issue_titles(repo_nwo: str) -> dict[int, dict]:
    out = _run(
        [
            "gh", "issue", "list",
            "--repo", repo_nwo,
            "--state", "all",
            "--limit", "500",
            "--json", "number,title,state,labels",
        ]
    )
    items = json.loads(out)
    return {it["number"]: it for it in items}


def gh_issue_create(repo_nwo: str, title: str, body: str, labels: list[str]) -> int:
    cmd = ["gh", "issue", "create", "--repo", repo_nwo, "--title", title, "--body", body]
    for lbl in labels:
        cmd += ["--label", lbl]
    out = _run(cmd)
    last = out.strip().splitlines()[-1]
    m = re.search(r"/issues/(\d+)", last)
    if not m:
        raise RuntimeError(f"could not parse issue URL from gh output: {out!r}")
    return int(m.group(1))


def ensure_labels_exist(repo_nwo: str, labels: set[str]) -> None:
    out = _run(
        ["gh", "label", "list", "--repo", repo_nwo, "--limit", "200", "--json", "name", "-q", ".[].name"]
    )
    existing = set(out.split())
    for lbl in sorted(labels - existing):
        try:
            _run(["gh", "label", "create", lbl, "--repo", repo_nwo, "--color", _label_color(lbl)])
            print(f"  created label: {lbl}")
        except subprocess.CalledProcessError as e:
            print(f"  WARN could not create label {lbl}: {e}", file=sys.stderr)


def _label_color(name: str) -> str:
    if name.startswith("priority:p0"):
        return "b60205"
    if name.startswith("priority:p1"):
        return "d93f0b"
    if name.startswith("priority:p2"):
        return "fbca04"
    if name.startswith("priority:p3"):
        return "0e8a16"
    if name == "kind:bug":
        return "ee0701"
    if name == "kind:chore":
        return "c2e0c6"
    if name == "kind:feature":
        return "1d76db"
    return "bfdadc"


def labels_for(wl: WorkLine) -> list[str]:
    out: list[str] = [f"kind:{wl.kind}"]
    if wl.priority:
        out.append(f"priority:{wl.priority}")
    return out


def _run(cmd: list[str], cwd: Path | None = None) -> str:
    res = subprocess.run(
        cmd, cwd=str(cwd) if cwd else None, capture_output=True, text=True, check=False
    )
    if res.returncode != 0:
        raise subprocess.CalledProcessError(
            res.returncode, cmd, output=res.stdout, stderr=res.stderr
        )
    return res.stdout


def _existing_intake_titles(intake_path: Path) -> set[str]:
    if not intake_path.exists():
        return set()
    titles: set[str] = set()
    for raw in intake_path.read_text().splitlines():
        if not raw.startswith("- "):
            continue
        body = raw[2:]
        m = re.match(r"\(line \d+\)\s*(\[[^\]]+\])?\s*(.*)", body)
        if m:
            titles.add(m.group(2).strip())
        else:
            titles.add(body.strip())
    return titles


def append_to_intake(intake_path: Path, lines: list[WorkLine], apply: bool) -> None:
    if not lines:
        return
    already = _existing_intake_titles(intake_path)
    fresh = [wl for wl in lines if wl.title not in already]
    if not fresh:
        print(f"  no new items to queue (all {len(lines)} already in intake)")
        return

    stamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
    body = [f"\n## {stamp} — queued from WORK.md\n"]
    for wl in fresh:
        meta = []
        if wl.priority:
            meta.append(wl.priority)
        if wl.kind != "feature":
            meta.append(wl.kind)
        meta_str = f" [{','.join(meta)}]" if meta else ""
        body.append(f"- (line {wl.line_no}){meta_str} {wl.title}")
    block = "\n".join(body) + "\n"

    if apply:
        intake_path.parent.mkdir(parents=True, exist_ok=True)
        if not intake_path.exists():
            intake_path.write_text(
                "# pending intake — raw WORK.md lines awaiting Producer triage\n"
            )
        with intake_path.open("a") as f:
            f.write(block)
        print(f"  appended {len(fresh)} new item(s) to {intake_path} ({len(lines) - len(fresh)} skipped as duplicates)")
    else:
        print(f"  would append {len(fresh)} new item(s) to {intake_path}:")
        for line in block.splitlines():
            if line:
                print(f"    {line}")


def annotate_work_md(doc: WorkDoc, work_md: Path, updates: dict[int, int]) -> None:
    if not updates:
        return
    lines = doc.raw_lines[:]
    for line_no_1based, issue_no in updates.items():
        idx = line_no_1based - 1
        if not lines[idx].rstrip().endswith(f"(#{issue_no})"):
            lines[idx] = lines[idx].rstrip() + f" (#{issue_no})"
    work_md.write_text("\n".join(lines) + ("\n" if not lines[-1].endswith("\n") else ""))


def cmd_sync(args: argparse.Namespace) -> int:
    repo_dir = Path(args.repo_dir).resolve()
    work_md = repo_dir / "WORK.md"
    if not work_md.exists():
        print(f"ERROR: {work_md} does not exist", file=sys.stderr)
        return 1

    text = work_md.read_text()
    try:
        doc = parse_work_md(text)
    except ValueError as e:
        print(f"ERROR parsing WORK.md: {e}", file=sys.stderr)
        return 2

    print(f"WORK.md: shipped={len(doc.sections['shipped'])} "
          f"current={len(doc.sections['current'])} todo={len(doc.sections['todo'])}")

    unannotated_todos = [w for w in doc.sections["todo"] if w.issue_no is None]
    annotated = [w for w in doc.sections["todo"] + doc.sections["current"] + doc.sections["shipped"] if w.issue_no is not None]

    if args.parse_only:
        print(f"unannotated todo lines: {len(unannotated_todos)}")
        for w in unannotated_todos:
            extras = []
            if w.priority:
                extras.append(w.priority)
            if w.kind != "feature":
                extras.append(w.kind)
            tag = f" [{','.join(extras)}]" if extras else ""
            print(f"  line {w.line_no}{tag}  {w.title}")
        print(f"annotated lines: {len(annotated)}")
        for w in annotated:
            print(f"  line {w.line_no}  #{w.issue_no}  {w.title}  ({w.section})")
        return 0

    if args.seed:
        repo_nwo = detect_repo_nwo(repo_dir)
        print(f"repo: {repo_nwo}")
        existing = list_existing_issue_titles(repo_nwo)
        existing_titles = {it["title"] for it in existing.values()}
        to_create = [w for w in unannotated_todos if w.title not in existing_titles]
        skipped = len(unannotated_todos) - len(to_create)
        print(f"seed: {len(to_create)} new issue(s) to create, {skipped} already exist by title")
        if not to_create:
            return 0

        all_labels = set()
        for wl in to_create:
            all_labels.update(labels_for(wl))
        if args.apply:
            ensure_labels_exist(repo_nwo, all_labels)

        updates: dict[int, int] = {}
        for wl in to_create:
            labels = labels_for(wl)
            body = f"_Seeded from WORK.md line {wl.line_no}._\n\n## Acceptance criteria\n\n- [ ] (define before implementation)\n"
            if args.apply:
                num = gh_issue_create(repo_nwo, wl.title, body, labels)
                updates[wl.line_no] = num
                print(f"  #{num}  {wl.title}  [{','.join(labels)}]")
            else:
                print(f"  would create: {wl.title}  [{','.join(labels)}]")
        if args.apply:
            annotate_work_md(doc, work_md, updates)
            print(f"annotated {len(updates)} line(s) in WORK.md with issue numbers")
        return 0

    if unannotated_todos:
        print(f"unannotated todo lines: {len(unannotated_todos)} (queuing for Producer triage)")
        intake = repo_dir / ".factory" / "inbox" / "pending-intake.md"
        append_to_intake(intake, unannotated_todos, apply=args.apply)
    else:
        print("no unannotated todo lines to triage")

    if annotated and not args.skip_gh:
        try:
            repo_nwo = detect_repo_nwo(repo_dir)
        except subprocess.CalledProcessError:
            print(f"skipping issue existence check (no gh remote in {repo_dir})")
            return 0
        existing = list_existing_issue_titles(repo_nwo)
        missing = [w for w in annotated if w.issue_no not in existing]
        if missing:
            print(f"WARN: {len(missing)} WORK.md line(s) reference non-existent issues:")
            for w in missing:
                print(f"  line {w.line_no}  #{w.issue_no}  {w.title!r}")
        else:
            print(f"all {len(annotated)} annotated line(s) on {repo_nwo} reference live issues")

    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--repo-dir", default=".", help="Target game repo (default: cwd)")
    ap.add_argument("--apply", action="store_true", help="Execute changes (default: dry-run)")
    ap.add_argument("--seed", action="store_true", help="Bootstrap: create issues directly, skip intake queue")
    ap.add_argument("--parse-only", action="store_true", help="Parse WORK.md and print structure, no gh calls")
    ap.add_argument("--skip-gh", action="store_true", help="Skip GitHub issue-existence reconciliation")
    args = ap.parse_args()
    return cmd_sync(args)


if __name__ == "__main__":
    sys.exit(main())
