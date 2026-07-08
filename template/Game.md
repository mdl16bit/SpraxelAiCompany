# {{GAME_NAME}} — game catalog

Canonical reference for what features the game has, how to play them, and how
to test them. **This file is an INDEX** — every feature's full block lives in
its own file at `docs/features/<slug>.md`. Agents read the index to know what
exists, then read only the feature files their task touches.

## Controls

TODO: keybind table

| Action | Keyboard | Gamepad |
|---|---|---|
| ... | ... | ... |

## Adding a new feature — the per-feature file contract

Every feature shipped by the Developer must create **one file**
`docs/features/<kebab-slug>.md` (slug = the `--demo-feature` slug) with the
full block, AND add **one index line** under `## Features` below:
`- [<Feature Name>](docs/features/<slug>.md) — <the What-it-does sentence>`

Do NOT write feature blocks into this document — an earlier game's Game.md
grew to 498KB that way and had to be sharded. The Reviewer blocks a merge
that appends a block here or omits the file/index line.

```
# <Feature Name>
- **What it does**: One player-facing sentence — no implementation detail.
- **Controls**: <input> → <effect> (e.g. "F when within 24px directly behind a guard whose alert level is 0").
- **First encounter**: When the player first sees this in normal play — feeds the future tutorial system.
- **Tutorial prompt** (one line, ≤80 chars): the exact hint text shown on first encounter.
- **Debug hook**: `--demo-feature=<slug>` — describes the scene/state the boot path drops the player into.
- **Trace events**: `evt.name.start`, `evt.name.success`, `evt.name.fail`
- **Test scenario**: `scripts/scenarios/<slug>.gd`
- **Unit test**: `test/unit/test_<slug>.gd`
- **Acceptance**: 2-4 bullets the Playtester can verify.
```

<!-- This block shape is the REVIEWER'S BLOCKING CHECKLIST (spraxel-reviewer.md
     check #5) — a dev following this template must never get blocked for a
     missing field. Keep the field list in sync with spraxel-developer.md step 4. -->

## Features (per-feature blocks)

(no features yet — index lines land here as features ship)
