# {{GAME_NAME}} — Claude project notes

Game-specific instructions for the agents (Developer, Reviewer, Playtester, …)
working on this codebase. The Spraxel *framework* lives in `~/SpraxelAiCompany`;
this file is the *game* half — fill it in as the project takes shape. Keep it
accurate: the Developer agent reads it on every run, so stale notes here cause
wrong work.

> This is a scaffold. Replace every `TODO:` with real content (or delete the
> section if it doesn't apply). See `~/GameProjects/infiltrators/CLAUDE.md` for a
> fully-worked example.

## Locked design decisions
<!-- Non-negotiables the agents must never undo. e.g. "permadeath is intended",
     "no controller support yet", "2D only". -->
TODO:

## Engine / project setup
<!-- Engine + version, how to open/run the project, the Godot binary path (must
     match Philosophy.md dev.godot_binary), export presets. -->
TODO:

## Autoloads / globals
<!-- Singletons and what each owns. -->
TODO:

## Class hierarchy
<!-- Core base classes and how scenes/scripts relate. -->
TODO:

## Conventions
<!-- Naming, file layout, signal patterns, commit style, trace-event naming —
     anything a dev must follow to match existing code. -->
TODO:

## Important gotchas
<!-- Footguns specific to THIS codebase. Things that broke before and shouldn't
     again. (Framework/worker gotchas live in
     ~/SpraxelAiCompany/docs/WORKER_OPERATIONS.md.) -->
TODO:

## File map
<!-- Where the important things live: scenes/, scripts/, resources/, assets/. -->
TODO:

## Testing
<!-- Uses the GUT addon (res://addons/gut) — see new_game.sh step "Install GUT".
     Unit tests in test/unit/test_*.gd; acceptance scenarios in
     scripts/scenarios/<slug>.gd; debug boot hooks via --demo-feature=<slug>.
     Devs do NOT run the suite (the batch runner does); the only dev-side test
     runs are the two exceptions in the Developer agent's step 7. -->
TODO:

## Running / debugging
<!-- How to launch a feature in-engine, the --demo-feature flag, headless boot. -->
TODO:

## When working on this codebase
<!-- A short checklist the Developer should follow before finishing an item. -->
TODO:
