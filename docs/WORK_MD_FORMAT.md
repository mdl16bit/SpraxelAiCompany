# WORK.md format

WORK.md is the single source of truth for one game's work queue. The format
is intentionally lenient — the CEO writes/edits it directly, agents append
or move items via `scripts/workmd.py`.

## Sections

Three sections separated by exactly two dividers (a line of 10+ dashes `-` or
10+ equals signs `=`):

```
# <game-name> — work tracking
<optional prose, ignored by the parser>

## Shipped (previous releases)
<items, often with v0.N — prefix>
----------
## Shipped since last release
<items, chronological completion order — newest at the bottom>
==========
## Todo
<items, top of the section is what the overnight Developer loop ships next>
```

The overnight loop pulls the top N from `## Todo`. As features merge, they
get appended to `## Shipped since last release`. On a release cut, items
there roll into `## Shipped (previous releases)` with a `v0.N —` prefix.

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
- H2 (`## ...`) marks the three section boundaries.
- H3+ inside a section is ignored.

## Concurrent edits

Any agent writing to WORK.md acquires an atomic mkdir-based lock at
`WORK.md.lockdir` for the duration of read-modify-write. If you edit WORK.md
manually (as CEO) while an agent is mid-write, the agent retries for 30s
then fails — see `.factory/escalations.md`.
