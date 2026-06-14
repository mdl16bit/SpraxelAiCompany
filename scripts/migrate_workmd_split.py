#!/usr/bin/env python3
"""One-time migration: externalize WORK.md's `## Shipped (previous releases)`
archive into per-release WORK_<version>.md files, emptying that section in
WORK.md. Items are grouped by their `vX.Y — ` title prefix (written by past
release_cut runs); items with no version prefix go to WORK_archive.md.

Usage: migrate_workmd_split.py <path/to/WORK.md>
Idempotent-ish: re-running on an already-empty shipped section is a no-op.
"""
import re
import sys
from collections import OrderedDict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import workmd  # noqa: E402

VRE = re.compile(r"^(v\d+(?:\.\d+)*)\s*[—-]")


def main(argv):
    if not argv:
        print("usage: migrate_workmd_split.py <WORK.md>", file=sys.stderr)
        return 2
    wp = Path(argv[0])
    wm = workmd.parse(wp)
    if not wm.shipped:
        print("nothing to migrate (## Shipped previous-releases already empty)")
        return 0

    groups = OrderedDict()
    for it in wm.shipped:
        m = VRE.match(it.title.strip())
        groups.setdefault(m.group(1) if m else "archive", []).append(it)

    for key, items in groups.items():
        fname = "WORK_archive.md" if key == "archive" else f"WORK_{key}.md"
        arch = wp.parent / fname
        title = (f"# Shipped — pre-versioned archive ({len(items)} items)"
                 if key == "archive" else f"# {key} — shipped ({len(items)} items)")
        block = [title, ""]
        for it in items:
            block.extend(workmd._emit_item(it))
        block.append("")
        prefix = ""
        if arch.exists():
            old = arch.read_text()
            prefix = old + ("" if old.endswith("\n") else "\n") + "\n"
        arch.write_text(prefix + "\n".join(block) + "\n")
        print(f"  wrote {fname}: {len(items)} items")

    wm.shipped = []
    wm.shipped_heading = ("## Shipped (previous releases) — archived to WORK_v*.md "
                          "(read on demand via release notes / git log)")
    wp.write_text(workmd.serialize(wm))
    print(f"WORK.md: shipped section emptied → {wp.stat().st_size} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
