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
- **What it does**: One player-facing sentence — no implementation detail.
- **Controls**: Input → effect (e.g. "F when within 24px directly behind a guard whose alert level is 0").
- **First encounter**: When the player first sees this in normal play (e.g. "any locked door in warehouse_01") — feeds the future tutorial system.
- **Tutorial prompt** (one line, ≤80 chars): the exact hint text shown on first encounter, e.g. `"Press H to drill locked doors (3s — loud)"`.
- **Debug hook**: `--demo-feature=<slug>` — describes the scene/state the boot path drops the player into.
- **Trace events**: `evt.name.start`, `evt.name.success`, `evt.name.fail`
- **Test scenario**: `scripts/scenarios/<slug>.gd`
- **Unit test**: `test/unit/test_<slug>.gd`
- **Acceptance**: 2-4 bullets the Playtester can verify.

<!-- This block shape is the REVIEWER'S BLOCKING CHECKLIST (spraxel-reviewer.md
     check #5) — a dev following this template must never get blocked for a
     missing field. Keep the field list in sync with spraxel-developer.md step 4. -->
