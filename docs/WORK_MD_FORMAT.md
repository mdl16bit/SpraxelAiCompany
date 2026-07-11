# WORK.md format

WORK.md is the single source of truth for one game's work queue. The format
is intentionally lenient — the CEO writes/edits it directly, agents append
or move items via `scripts/workmd.py`.

## Sections

Four sections (the 2026-07 reformat), separated by dividers (a line of 10+
dashes `-` or 10+ equals signs `=`):

```
# <game-name> — work tracking
<optional prose, ignored by the parser>

## Up-and-coming work
<active/near-term Todo — the top of this section is what the ship loop builds next>
==========
## Finished since last release
<items, chronological completion order — newest at the bottom>
==========
## Next work
<deferred backlog — [future]/[cold]/[manual] parked items>
==========
## Shipped (previous releases)
<historical archive footer; release cuts move bulk history to WORK_v0.N.md>
```

The ship loop pulls the top of `## Up-and-coming work`. As features merge,
they get appended to `## Finished since last release`. On a release cut
(`workmd.py release-cut`), that section's items are archived to a
`WORK_v0.N.md` sidecar file (keeping the live file small — the 2026-07
432KB prompt-bloat outage is why), leaving a one-line pointer in
`## Shipped (previous releases)`.

The parser (`workmd.py`) also recognizes the legacy 3-section headings
(`## Shipped since last release` → finished, `## Todo` → up-and-coming), so
older game repos keep working — but new files use the 4-section layout above
(see `template/WORK.md`).

## Items

- **Title** — any non-indented, non-empty line. The whole line is the title.
- **Details** — every indented line (any leading whitespace) that follows
  belongs to that item.
- **Blank line** — separates items. An item ends at the first blank line OR
  the next non-indented line.

## Tags

Inline tags at the start of a title line are extracted automatically:

- **Priority**: `p0` .. `p3` (p0=urgent, p3=nice-to-have). Default: none.
- **Kind**: `[bug]` / `[feature]` / `[chore]`. Default: none.
- **`[game-feature]`** — explicit player-facing mechanic. Use this for things
  that move the game forward (run button, jumping, swimming) vs. tooling.
- **`[idea]`** — Designer drop, un-promoted. **Overnight loop skips these.**
  CEO removes the `[idea]` tag to promote (item becomes shippable), or
  deletes the line to reject.
- **`[cold]`** — Janitor moved a stale item out of active rotation.
- **`[manual]`** or **`MANUAL - ` line prefix** — CEO-only work (controller
  testing, sourcing music, hand-tuning art, anything the Developer agent
  can't do). **Overnight skips these.** Remove the tag/prefix to make it
  shippable, or just delete the line when done.

Example:

```
[bug] p0 Stairs teleport on save/load
  repro: save mid-staircase, load
  character spawns one floor below
  affects all stair types except the warehouse spiral

[game-feature] p1 Add duck mechanic
  Everyone can duck. Helps hide behind tables and stuff.

[idea] [feature] p2 Sleeping-gas grenade item
  Designer drop — CEO triage to promote.
```

## Headings

- H1 (`# Game-Name — ...`) is the file's main heading; it and the prose
  beneath it stay in the file header and are not parsed as items.
- H2 (`## ...`) marks the section boundaries.
- H3+ inside a section is ignored.

## Concurrent edits

Any agent writing to WORK.md acquires an atomic mkdir-based lock at
`WORK.md.lockdir` for the duration of read-modify-write. If you edit WORK.md
manually (as CEO) while an agent is mid-write, the agent retries for 30s
then fails — see `.factory/escalations.md`.
