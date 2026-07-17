# Infiltrators — Editors Test Guide

> Hands-on guide to every built-in editor. All four are launched from the **title screen**.
> Engine is paused (`.paused` set) — run the game from the Godot editor (open `~/GameProjects/infiltrators` in Godot 4.6) or your normal launch.
>
> **Title-screen wiring:** `scripts/game/title_screen.gd:7-10,75-84`; buttons in `scenes/game/title.tscn`.

| Editor | Launch | Status |
|---|---|---|
| **Level Editor** | Title → LEVEL EDITOR | ✅ Works. |
| **Cutscene Editor** | Title → CUTSCENE EDITOR | ✅ Works. (Note: `OPERATIONS.md §2` wrongly says it doesn't exist — ignore that.) |
| **Story Map Editor** | Title → STORY MAP | ✅ Works. |
| "AI editor" / "UI editor" | (inside Level Editor) | Not standalone — they're features *inside* the Level Editor. |

> **Status check:** All three editors have been stable for weeks. The Level Editor's one-time regression (un-bootable parse error, introduced 2026-06-16 in `6de4181ab`) was fixed and committed as `a569c617` (2026-06-19) and hasn't recurred since — dozens of feature commits have landed on `level_editor.gd` and its `level_editor/` helpers since then with no repeat breakage. One lingering caveat: `.factory/local-tests-status.json` is still stamped 2026-06-14, well before that fix and everything shipped after — it's not evidence the editors still work, so the hands-on checklists below still matter.

---

## 1. Level Editor — full mission builder
**Purpose:** Place walls, floors, guards, items, triggers, paint zones — build a whole playable mission.
**Scene:** `scenes/game/level_editor.tscn` · **Script:** `scripts/game/level_editor.gd` (1435 lines)
**Helpers:** `scripts/game/level_editor/{entity_placer,entity_renderer,inspector_builder,palette}.gd`

### Launch
Title → **LEVEL EDITOR**.

### Camera & global keys
- **Pan:** middle-mouse drag, or Arrow keys
- **Zoom:** mouse wheel (min 0.1×)
- **Ctrl+S** save · **Ctrl+N** new · **Ctrl+T** test-play current level · **Ctrl+Z** undo · **Ctrl+Shift+Z** / **Ctrl+Y** redo (50-step undo history)
- **G** toggle 16px grid snap
- **F1** or **?** — full-screen keyboard reference overlay (use this in-app; it's the source of truth)
- **Esc** — deselect → exit waypoint mode → back to title (press repeatedly)
- Live X/Y world-coord readout shown in the top bar; selected tool gets a yellow border.

### Tools (~80, grouped toolbar: SELECT / GEOMETRY / LAYOUT / OBJECTIVES / ENEMIES / TRIGGERS / ITEMS / ENVIRON)
Each tool = a colored toolbar button + a letter/number hotkey. Highlights of the hotkey→tool map (full map in-app via **F1**, also `OPERATIONS.md:37-97`):

| Key | Tool | Key | Tool |
|---|---|---|---|
| `Tab` | Select | `8` | Guard |
| `1` | Wall | `9` | Camera |
| `2` | Floor | `0` | Vent |
| `3` | Door | `E` | Wall Segment |
| `4` | Ladder | `T` / `Shift+T` | Table / Trap Button |
| `5` | Loot | `D` | Desk |
| `6` | Extraction | `H` | Terminal |
| `7` | Spawn | `N` | Drone · `Z` Dog |

…plus `U` Duct, `J` Fusebox, `S` Dark Zone, `Y` Inv Pickup, `R` Closet, `Q` Crate, `O` Getaway Vehicle, `F`/`Shift+F` Water Leak / Floor Panel, `L`/`Shift+L` Ladder Kit / Spotlight, `B`/`Shift+B` Bitmap Floor / Generator Room, `D`/`Shift+D` Desk / Dispatch Node, and **F2–F12** for Light Switch, Alarm, Breakable Light, Keypad Door, Hatch, etc. Several use shifted-symbol keys (`@ & # * ! ^ ( ) + $ % < >`).

**New since 2026-06-20** (verified against `TOOL_NAMES` in `level_editor.gd`):

| Key | Tool | Key | Tool |
|---|---|---|---|
| `<` | Fire Panel | `Shift+S` | Skylight |
| `>` | Collapse Point | `Shift+D` | Dispatch Node |
| `:` | Security Room | `Shift+B` | Generator Room |
| `~` | Security Shutter | `Shift+H` | Panic Button |
| | | `Shift+G` | Flammable Spill |

**New since 2026-07-08:**

| Key | Tool | Notes |
|---|---|---|
| `Shift+C` | **Captive NPC** | Rescue-objective escort target (place at most one). Only ACTIVE in missions whose `MissionData` sets `has_captive=true` + a `"rescue"` objective — in any other mission the placed captive self-removes at load. |
| `Y` (existing Inv Pickup tool) | — | The item_type dropdown gains **`decoy_signal`** (amber) — the placeable fake-extraction beacon (30 s heavy-wave redirect). |

**New since 2026-07-11:**

| Key | Tool | Notes |
|---|---|---|
| palette **`SC`** button (Structure category, orange) | **Supply Closet** | Marker for the Guard Counter-trap feature: a SUSPICIOUS Patroller/Responder (level 2+) within 200 px can jog here, arm a visible tripwire at the chokepoint (3 s telegraph), then resume patrol. Place near patrol lanes/corridor mouths. Guards also gain a **`can_arm_trap`** toggle in the guard inspector (default ON for Patroller/Responder). Round-trip check: place one + a guard, save, load, confirm both survive. |

**New since 2026-07-17:**

| Key | Tool | Notes |
|---|---|---|
| palette **World Note** button | **World Note** | Readable lore prop (E → one-line subtitle, single-use per mission). Inspector fields: **`note_text`** (multiline — the line shown unless a JSON pool overrides), **`note_id`** (key into `assets/dialogue/world_notes_<level>.json`), and the E-prompt label. Round-trip check: place one with custom text, save, load, read it in test-play, confirm the debrief "NOTES: 1 read" row. |

### Mouse actions
- **Left-click** — place a point. For rectangle tools (Wall / Floor / Surface / Water / Table / Desk / Duct / Dark Zone / Wall Segment / etc.) **left-drag** to draw a rectangle.
- **Select tool active:** click to select an entity, drag to move it.
- **Right-click** — delete the entity under the cursor.

### Waypoint editing (guards / drones / dogs)
1. Select a guard/drone/dog with the Select tool.
2. Press **W** to enter waypoint mode (cyan ring).
3. **Left-click** adds a waypoint, **right-click** removes the last one.
4. **A** — alternate patrol route (orange ring), only meaningful if the guard's `schedule_swap_seconds` is set.

### Guard AI inspector (this *is* the "AI editor")
Select a guard → the inspector exposes spin-box/checkbox fields: `guard_type` (0–7: Patroller/Responder/Civilian/Heavy/K9/Riot/Detective/Checkpoint), `guard_level` (1–5), `detection_speed`, `hearing_radius_multiplier`, `wakeup_time`, `alert_hold_seconds`, `search_duration`, `search_radius`, `has_nvg`, **`has_panic_button`** (NEW 2026-07-02 — pair with a placed Panic Button entity within 32px; guard silently trips it on PATROL→SUSPICIOUS, no HUD tell), `is_trap_operator`, `waypoint_pause`, `schedule_swap_seconds`, `pair_partner_index`, plus Hero (`is_hero`/`disguise_immune`/`hero_id`/…) and Small-talk (`chat_mode`/`chat_script_id`/…) sub-sections. `OPERATIONS.md:104-120` is stale on the field list — treat `scripts/game/level_editor/inspector_builder.gd:72-132` as the source of truth. **Test by:** placing a guard, tuning detection_speed low vs high, then test-playing to feel the difference; separately, place a Panic Button near a guard, enable `has_panic_button`, get spotted, and confirm two HEAVY guards converge after the countdown.

> **Not editor-exposed:** two recent (07-02) guard-adjacent systems aren't wired into this inspector yet — `has_leverage`/`leverage_label` (Personal Leverage) is authored only via `.tscn` node metadata (`scripts/ai/guard_leverage.gd`), and Storm Front's `has_outdoor_zones`/`storm_interval_seconds` live on `MissionData` with no Level Editor UI (set directly on campaign mission resources like Rooftop Hit / Harbor Freight). Neither is testable from a Level Editor–built level today.
>
> **Also not editor-exposed (added 2026-07-08):** `MissionData.has_captive` + the `"rescue"` objective kind (needed to activate a placed Captive NPC) have no Level Editor UI — a Shift+C captive in a user level stays inert unless the mission resource is authored by hand (see `resources/missions/sample/silent_extraction.tres` as the reference). Hero shield charges (Veteran Run's shield-absorb, e.g. The Fox) are likewise authored only via `.tscn` node metadata (`metadata/hero_shield_charges`), not the guard inspector's Hero sub-section.

### Save / load / test-play
- **Save** → `user://levels/<name_lowercased_underscored>.json` (`LevelIO.save`, `scripts/missions/level_io.gd`).
- **Load** → in-editor panel lists files from `user://levels/`.
- **Test-play (Ctrl+T)** → saves to `user://levels/__test__.json`, builds an ad-hoc mission with a 4-slot loadout, jumps into `main.tscn`.
- **Play it for real:** saved user levels auto-appear in **Mission Select** marked with a ★.
- **macOS save path:** `~/Library/Application Support/Godot/app_userdata/Infiltrators/levels/`
- **JSON schema:** docstring atop `scripts/missions/level_io.gd`; summary in `OPERATIONS.md:129-161`.

### Test checklist
- [ ] Editor opens · [ ] Place walls by drag · [ ] Place + give a guard a patrol path (W) · [ ] Tune guard AI fields incl. `has_panic_button` · [ ] Place a Panic Button (Shift+H) and a Flammable Spill (Shift+G) · [ ] `)` key still selects Floor Segment · [ ] Ctrl+S saves · [ ] Load it back and confirm the new entities round-tripped · [ ] Ctrl+T test-play · [ ] Level shows ★ in Mission Select.
- [ ] *(added 2026-07-08)* Place a Captive NPC (Shift+C) and an Inv Pickup set to `decoy_signal` (Y) · [ ] Save + reload and confirm both round-trip · [ ] Ctrl+T test-play: confirm the captive **self-removes** (expected — user missions can't set `has_captive`) and the decoy pickup is collectible/usable with **0**.

---

## 2. Cutscene Editor — visual cutscene builder
**Purpose:** Build/edit JSON cutscene step-lists with a live embedded preview.
**Scene:** `scenes/game/cutscene_editor.tscn` · **Script:** `scripts/game/cutscene_editor.gd` (947 lines)

### Launch
Title → **CUTSCENE EDITOR**.

### Layout & controls
- **Top bar:** File dropdown + **LOAD / NEW / SAVE** + status.
- **Left "STEPS" panel:** ordered step list (`## [type] preview`), click to select.
- **Bottom-left toolbar:** "Add:" dropdown (10 step types) + **+** add, **✗** remove, **↑ / ↓** reorder.
- **Right "STEP INSPECTOR":** per-type fields + a Type-change dropdown (re-defaults the step). Field types: text / multiline / float spinbox / bool checkbox / option dropdowns (portrait IDs, music slots, positions, fade dir) / pan X-Y spinners.
- **Bottom-right "PREVIEW":** live 640×360 SubViewport running the real `CutscenePlayer`.
- **Hotkeys:** **Ctrl+S** save · **Del / Backspace** remove step · **↑ / ↓** move step · **F5** play preview · **Esc** stop preview / back to title.

### Step types
`subtitle · actor · title · shake · pan · sfx · clear · music · fade · wait` — each ships with sensible defaults. Schema: `OPERATIONS.md:205-318`.

### Save / load — ⚠️ caveat
- Saves to **`res://assets/cutscenes/<filename>.json`**. `res://` is **read-only in an exported build** — saving only works running from source / Godot editor. Still a known limitation for shipped builds; hasn't changed since this doc was created.
- Files prefixed `_` are hidden from the list.
- **Auto-trigger convention:** `<mission-slug>_pre.json` / `<mission-slug>_post.json` fire automatically before/after that mission (e.g. `warehouse_job_post.json` already exists in `assets/cutscenes/`).

### Test checklist
- [ ] Open · [ ] NEW → add a subtitle + actor + fade step · [ ] F5 preview plays · [ ] Reorder with ↑/↓ · [ ] Ctrl+S saves to `assets/cutscenes/` · [ ] Name one `<slug>_pre.json` and confirm it fires before that mission.

---

## 3. Story Map Editor — mission dependency graph
**Purpose:** Node-graph defining which missions unlock which (campaign gating).
**Scene:** `scenes/game/mission_graph_editor.tscn` · **Script:** `scripts/game/mission_graph_editor.gd` (538 lines)

### Launch
Title → **STORY MAP**.

### Controls
- **Left-click a card** — select (inspector updates).
- **Left-drag a card** — reposition (position persists).
- **▸ Add Dependency…** — enter connect mode, then click a second card → "selected mission depends on that card." Drawn as bezier arrows.
- **✕** next to a dep in the inspector — remove that dependency.
- **S** or **💾 SAVE** — save · **RESET TO DEFAULT** — delete user graph, reload built-in · **Esc / B / ◂ BACK** — title.

### Inspector
Mission name + slug (read-only) · **Story mission (must-do)** checkbox (gold border) vs optional (teal border) · **DEPENDS ON** list.

### Save / load + in-game effect
- Writes **`user://mission_graph.json`** (`MissionDependencyGraph.save_graph()`); absent → falls back to `res://resources/missions/default_graph.json`.
- **In Mission Select:** unmet prerequisites show 🔒 with a "Complete first: …" tooltip. **Circular dependencies are rejected** (cycle detection in the `MissionDependencyGraph` autoload). Reference: `OPERATIONS.md:348-437`.

### Test checklist
- [ ] Open · [ ] Drag a card · [ ] Add a dependency between two missions · [ ] Mark one as story (gold) · [ ] Save · [ ] Confirm 🔒 appears on the gated mission in Mission Select · [ ] Try to create a cycle → confirm it's rejected · [ ] RESET TO DEFAULT restores.

---

## Notes
- **"AI editor" and "UI editor"** from the dev logs are **not** separate editors — they were production-value passes folded into the Level Editor (the guard-AI inspector and the toolbar/UX polish respectively). `scripts/scenarios/{ai_editor,ui_editor}.gd` are headless acceptance tests, not launchable scenes.
- **Headless demo hooks** exist if you want to script captures: `--demo-feature=level-editor` / `ui-editor` / `ai-editor` / `cutscene-editor-tool` (see `scripts/systems/demos/demo_*.gd`).
