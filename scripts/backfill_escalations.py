#!/usr/bin/env python3
"""One-shot: take the 14 historical escalations in .factory/escalations.md
and restore them to WORK.md as [escalated] items, then rewrite
escalations.md with self-contained summaries (parsed from each per-item
log).

Pre-condition: the OLD escalations.md format had entries shaped like:

    ## Escalated 2026-05-25 19:36 PDT — <title>
    log: /Users/.../logs/continuous/2026-05-25/<slug>.log
      <optional indented detail lines>

After this script:

- escalations.md is rewritten in the NEW format (self-contained block
  per entry, with "why it failed" + per-attempt failure list + branch
  note saying "deleted by old wrapper, start fresh when resuming").
- Each title is appended to WORK.md ## Todo as [escalated] with detail
  lines summarizing what failed and a `branch: <gone, start-fresh>` note.

Idempotent: skips entries whose title (with [escalated] prefix) is
already in WORK.md ## Todo so re-running doesn't double-up.

Run from the game repo's parent or via absolute paths. Edits files
in-place. The CEO reviews + commits + pushes.
"""

import re
import sys
from pathlib import Path
from datetime import datetime

REPO = Path("/Users/skinnyluigi/GameProjects/infiltrators")
WORK_MD = REPO / "WORK.md"
ESC_MD = REPO / ".factory" / "escalations.md"

# Re-parse each escalation entry from the old format.
ENTRY_RE = re.compile(
    r"^## Escalated (?P<ts>[^—]+?) — (?P<title>.+?)$",
    re.M,
)


def parse_old_escalations(text: str):
    """Yield (ts, title, log_path, raw_details) tuples."""
    out = []
    # Split on the `## Escalated` heading, keeping the heading + body together.
    chunks = re.split(r"(?=^## Escalated )", text, flags=re.M)
    for chunk in chunks:
        m = ENTRY_RE.match(chunk)
        if not m:
            continue
        ts = m.group("ts").strip()
        title = m.group("title").strip()
        log_match = re.search(r"^log:\s*(.+?)$", chunk, re.M)
        log_path = log_match.group(1).strip() if log_match else ""
        # Collect any indented detail lines from the old entry.
        detail_lines = []
        for line in chunk.splitlines():
            if line.startswith("  ") and not line.lower().startswith("  log:"):
                detail_lines.append(line[2:].rstrip())
        out.append((ts, title, log_path, detail_lines))
    return out


def parse_log_failures(log_path: str):
    """Read a per-item log and extract per-attempt failure info.

    Returns list of dicts:
        {"n": 1, "ts": "...", "baseline": N, "new": ["..."]}
    """
    p = Path(log_path)
    if not p.exists():
        return []
    log = p.read_text()
    parts = re.split(r"^=== attempt (\d+) at (.*?) ===\s*$", log, flags=re.M)
    attempts = []
    i = 1
    while i + 2 < len(parts):
        n = int(parts[i])
        ts = parts[i + 1].strip()
        body = parts[i + 2]
        baseline_match = re.search(r"baseline failures captured \((\d+)\)", body)
        baseline = int(baseline_match.group(1)) if baseline_match else 0
        new_fails = []
        new_fail_block = re.search(
            r"NEW failures on attempt \d+:\s*\n(.*?)(?=\n===|\nescalated:|\Z)",
            body, re.S,
        )
        if new_fail_block:
            for line in new_fail_block.group(1).splitlines():
                line = line.strip()
                if line and not line.startswith("continuous:") and not line.startswith("["):
                    new_fails.append(line)
        if "reviewer BLOCKED" in body:
            new_fails.insert(0, "reviewer rejected the diff")
        if "developer rc=" in body and not new_fails:
            rc_match = re.search(r"developer rc=(\d+)", body)
            new_fails.append(f"dev agent crashed (rc={rc_match.group(1) if rc_match else '?'})")
        if "merge/push FAILED" in body:
            new_fails.append("merge to master failed")
        attempts.append({"n": n, "ts": ts, "baseline": baseline, "new": new_fails})
        i += 3
    return attempts


def build_summary_block(ts, title, attempts):
    """Build the self-contained markdown block for the new escalations.md."""
    out = []
    out.append("")
    out.append(f"## Escalated {ts} — {title}")
    out.append("")
    out.append("**Outcome**: not merged. Master unchanged. **Branch was deleted by the "
               "old wrapper (pre-2026-05-26 fix) — start fresh if you resume.**")
    out.append("")
    if not attempts:
        out.append("**Why it failed**: log unavailable (file missing / unparseable).")
    else:
        cats = sorted({f for a in attempts for f in a["new"]})
        if cats:
            out.append(f"**Why it failed**: " + "; ".join(cats) + ".")
        else:
            out.append("**Why it failed**: see attempt details below.")
    out.append("")
    for a in attempts:
        out.append(f"**Attempt {a['n']}** ({a['ts']}):")
        if a["baseline"]:
            out.append(f"  - {a['baseline']} pre-existing baseline failure(s) ignored")
        if a["new"]:
            for f in a["new"]:
                out.append(f"  - NEW: {f}")
        else:
            out.append("  - no NEW failures captured (see log for details)")
        out.append("")
    return "\n".join(out)


def main():
    work_text = WORK_MD.read_text()
    old_esc_text = ESC_MD.read_text() if ESC_MD.exists() else ""
    entries = parse_old_escalations(old_esc_text)
    if not entries:
        print("no entries to backfill — escalations.md is empty or already new format")
        return 0

    print(f"backfilling {len(entries)} historical escalations...")

    # 1. Append [escalated] items to WORK.md ## Todo (idempotent).
    todo_marker = "\n## Todo\n"
    if todo_marker not in work_text:
        print(f"WARN: could not find ## Todo section in WORK.md, skipping WORK.md restore", file=sys.stderr)
    else:
        todo_idx = work_text.find(todo_marker) + len(todo_marker)
        addition_lines = []
        for ts, title, log_path, raw_details in entries:
            already_in_work = (f"[escalated] " in work_text and title in work_text)
            if already_in_work:
                continue
            addition_lines.append(f"[escalated] {title}")
            addition_lines.append(f"  outcome: not merged; master unchanged")
            addition_lines.append(f"  why: see escalations.md entry dated {ts}")
            addition_lines.append(f"  branch: <gone — deleted by old wrapper, start fresh on resume>")
            addition_lines.append(f"  to retry: change [escalated] → [resume] (will spawn a fresh branch)")
            for d in raw_details:
                if d.strip():
                    addition_lines.append(f"  original-detail: {d}")
        if addition_lines:
            work_text = work_text[:todo_idx] + "\n".join(addition_lines) + "\n" + work_text[todo_idx:]
            WORK_MD.write_text(work_text)
            print(f"  ✓ appended {sum(1 for l in addition_lines if l.startswith('[escalated]'))} items to WORK.md ## Todo")
        else:
            print(f"  – all entries already present in WORK.md, skipping append")

    # 2. Rewrite escalations.md with rich entries.
    new_blocks = []
    new_blocks.append("# Escalations log\n")
    new_blocks.append(
        "When the wrapper can't ship a feature after 2 attempts, it escalates: the "
        "item stays in WORK.md tagged [escalated], its branch is pushed to origin, "
        "and a self-contained summary is appended below. Master is NEVER modified "
        "by failed attempts.\n"
    )
    new_blocks.append(
        "This file is append-only history — the bot writes to it, you don't edit. "
        "Triage happens in WORK.md, not here.\n"
    )
    new_blocks.append("---\n")
    for ts, title, log_path, _details in entries:
        attempts = parse_log_failures(log_path)
        new_blocks.append(build_summary_block(ts, title, attempts))
    ESC_MD.write_text("\n".join(new_blocks) + "\n")
    print(f"  ✓ rewrote escalations.md with {len(entries)} rich entries")

    print("done. review the changes; commit + push when satisfied.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
