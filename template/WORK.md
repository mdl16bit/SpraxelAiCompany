# {{GAME_NAME}} — work tracking

Human-friendly view of all work. Three sections separated by exactly 50
dashes. Edit freely — `sync_work_md.py` keeps this in sync with GitHub
Issues:

- New Todo lines without `(#N)` get appended to `.factory/inbox/pending-intake.md`
  for Producer to clean up and turn into GH Issues.
- `(#N)`-annotated lines are cross-checked against live issues.
- Lines move between sections in response to PR merges and release cuts.

Line format: `- [priority] [kind:] title (#issue-number)`

Examples:
- `- p0 stairs teleport on save/load` (no issue yet — sync will queue it)
- `- p1 bug: guard sees through walls (#34)` (already an issue)
- `- new — animated secretary` (priority + kind to be inferred by Producer)

## Shipped (previous releases)

--------------------------------------------------

## Shipped since last release

--------------------------------------------------

## Todo
