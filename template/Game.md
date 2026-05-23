# {{GAME_NAME}} — game catalog

Canonical reference for what features the game has, how to play them,
and how to test them. Agents read this to know what features exist, what
controls trigger them, and what debug hooks the Playtester can use.

Every feature shipped by the Developer must add a block here. Without a
block, Playtester can't test the feature and Demo Creator can't film it.

## Controls

TODO: keybind table

| Action | Keyboard | Gamepad |
|---|---|---|
| ... | ... | ... |

## Features

### Example Feature Name
- **What**: One-line description of the player-facing behavior.
- **Controls**: Input → effect (e.g. "F when within 24px directly behind a guard whose alert level is 0").
- **Debug hook**: `--demo-feature=<slug>` — describes the scene/state the boot path drops the player into.
- **Trace events emitted**: `evt.name.start`, `evt.name.success`, `evt.name.fail`
- **Test scenario**: `scripts/scenarios/<slug>.gd`
- **Acceptance**: Restate the acceptance criteria here so Playtester can assert on them.
