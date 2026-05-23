# {{GAME_NAME}} — work tracking

Human-friendly view of all work. **The format is lenient on purpose** — the
CEO writes this by hand (often dictated), so the parser tolerates the
real-world variations described below. `sync_work_md.py` keeps this in sync
with GitHub Issues:

- New Todo items without `(#N)` get queued in `.factory/inbox/pending-intake.md`
  for Producer to clean up and turn into GH Issues.
- `(#N)`-annotated items are cross-checked against live issues.
- Items move between sections as PRs merge and releases cut.

## Format conventions

**Items**: any non-indented, non-empty line is a work item title. Either of
these works:

```
- p0 bug: stairs teleport on save/load (#34)
```

```
Stairs teleport on save/load when you save mid-staircase
```

Bullet prefix (`- `), priority (`p0`–`p3`), and `(#N)` annotation are all
optional. Producer will infer priority and kind during triage if you omit them.

**Details**: indented lines (any leading whitespace) belong to the previous
item as detail / repro / sub-points. Example:

```
Stairs teleport on save/load
  repro: save mid-staircase, load
  character spawns one floor below
  affects all stair types except the warehouse spiral
```

The whole block becomes one issue; the indented lines flow into the body.

**Dividers**: a line of 10+ dashes (`-`) or 10+ equals signs (`=`) separates
sections. The parser is flexible:

- 0 dividers → everything is Todo.
- 1 divider → above is Shipped, below is Todo.
- 2+ dividers → first separates Shipped from Current; last separates
  Current from Todo. Anything between them is "current" / since-last-release.

**Headers**: lines before the first `## ` markdown heading are header /
explanation text and are ignored by the parser. If you don't use any `## `
headings, the file has no header and parsing starts at line 1.

## Shipped (previous releases)

--------------------------------------------------

## Shipped since last release

--------------------------------------------------

## Todo
