# Infiltrators — Look & Feel Revamp: Advice & Options

> Context for your planning doc. You're considering: **(a) tile-based**, **(b) bigger characters**, **(c) more cinematic**. Below is what the game looks like *today* (facts), then honest scoping per direction. Engine is paused; nothing here is a change — it's analysis.
>
> **Design north star (from `Philosophy.md` / `INSPIRATIONS.md`):** *Lost Vikings* told in *Gunpoint*'s voice — 8 thieves, side-on, multi-floor heist building, plan-mode choreography. Art intent: dark / grounded / militaristic (Front Mission, MGS1, Otomo silhouettes). Explicitly **"no cute," not procgen.**

---

## What the game looks like *right now* (the honest baseline)

| Aspect | Today |
|---|---|
| **Resolution** | 1920×1080, `canvas_items` stretch, `aspect=expand` (wide monitors see *more world*, not bars). `project.godot:62-67` |
| **Art style** | **100% programmatic vector** — there is **no shipped art**. Characters are hand-coded `Polygon2D` silhouettes (~28×56px). Walls/floors are `ColorRect`/PackedScenes. Lights are gradient-texture blobs. The pile of small procedural-draw props keeps growing (panic button, dropped-pistol pickup, tamper-evidence scuff mark, flammable-spill puddle/flame, ~65 `_draw()`-based interactables/effects total) — same house style, more of it. Only template/README assets exist for characters/guards. |
| **Character on-screen size** | ~56px tall × default zoom 1.2 ≈ **~6% of screen height.** Small. It's a wide, zoomed-out "diorama" of a whole building floor — *not* a character-forward camera. |
| **World structure** | **NO TileMap / TileSet anywhere.** Levels are **hand-placed free-form nodes** at absolute coordinates. Built-in levels are `.tscn`; user levels are free-form JSON. Playable area ≈ 3400×1200px — small, single-screen-ish Gunpoint puzzles. |
| **The only grid** | Fog-of-war logical 64px cells (`fog_of_war.gd:13`) — for vision/minimap, **not geometry rendering.** |
| **Camera** | `Camera2D`, smooth follow, snaps to integer pixels, zoom 0.6–3.0 (default 1.2), a 3× "sniper scope" mode. **No camera bounds set** (relies on small levels). |
| **Lighting** | Additive colored `PointLight2D` blobs, now also toggled dynamically at runtime — e.g. an ignited `FlammableSpill` fire turns on a warm-orange 120px light (and suppresses dark-zone concealment nearby) until extinguished or burned out. **Zero occluders anywhere in the codebase → still no real shadow casting.** Stealth darkness is *logical* (dark zones + fog), not rendered shadow. |
| **Shaders / post** | **One** shader total, still (sniper-scope vignette) — no new shaders shipped. But there is now a first **atmosphere layer**: `StormFront` (outdoor/rooftop missions) spawns a `StormWeatherOverlay` `CanvasLayer` — procedural rain streaks + a tinted, semi-transparent full-screen `ColorRect`, both fading in/out over 2s via `Tween` — plus real gameplay debuffs (guard vision/hearing, sprint skid). It's a genuine mood/weather beat, but it's a per-scene `CanvasLayer`+`ColorRect`, **not** a `WorldEnvironment` or `CanvasModulate`; no bloom/grade/CRT/day-night exist, and **no parallax** (still explicitly out-of-scope, `ASSETS.md:82`). |
| **Pipeline** | Drop-in: name a PNG/MP3/JSON correctly → it overrides the procedural default; delete it → game still runs on polygons. A 3-tier sprite pipeline exists (`character_sprite.gd`) but **no character PNGs are shipped.** The same `AssetPaths.apply_object_sprite_to()` drop-in pattern keeps getting wired into new props as they ship (e.g. the tamper-evidence tell) — the plumbing for "ship real art" gets more ready every week even though no art has landed. |

**The single most important fact for your decision:** the look you're reacting to is *placeholder procedural geometry*, not a finished art style. A huge amount of "the feel" could change just by **shipping actual art into the existing drop-in pipeline** — no architecture change at all. New `[manual][art]`/`[manual][sfx]` gaps keep piling up behind shipped systems (a flame sprite-sheet for `FlammableSpill`, a storm ambient audio loop for `StormFront`, a scuff-mark sprite for the tamper tell) — every one of them is evidence for "ship real art first," not a reason to wait.

---

## Direction (b): Bigger characters / more screen space — 🟢 SMALL–MEDIUM, lowest risk
**Recommendation: do this first. It's cheap, reversible, and the fastest way to feel a difference.**

- **Already supports it:** Character size flows from two vars (`_sil_w`/`_sil_h`) that scale polygon + collision together (`character_sprite.gd:124-130`); camera zoom is one tunable (`level.gd:12`). You can make characters bigger *today* by raising zoom or `_sil_*`.
- **Must change:** HUD bars are pinned at fixed pixel offsets above the head (`base_character.tscn:55-118`) — they'd need to scale with character size. Camera has **no bounds**, so a tighter zoom may reveal level edges → add `limit_*` to the camera. Bigger characters = fewer on screen at once → re-check plan-mode legibility.
- **Biggest risk:** *design, not tech.* The whole game depends on seeing the building floor and choreographing multiple characters at once. Zoom in too far and you lose the Lost-Vikings/Frozen-Synapse readability. **Suggest: prototype a zoom change first (one number), playtest the plan-mode feel, before committing to larger sprites.**

---

## Direction (c): More cinematic — 🟡 MEDIUM (incremental) → LARGE (full), medium risk
**Recommendation: there's a high-value *cheap* win here; take it. The rest is a long tail — though it's now a slightly shorter tail than it was.**

- **Update since this doc was first drafted:** `StormFront` (weather sweeps on outdoor/rooftop/dock missions) shipped a real atmosphere layer — a `CanvasLayer` overlay with procedural rain streaks and a tinted, fading `ColorRect`, plus a gameplay-linked mood beat (guard vision/hearing debuffs, sprint skid, an on-screen "STORM ACTIVE" banner). It's a genuine, if partial, down payment on "cinematic": it proves the team can ship a scene-wide mood effect with Tween fades without a rewrite. But be precise about what it *isn't* — it's a per-scene `CanvasLayer`+`ColorRect`, not a `WorldEnvironment` or `CanvasModulate`, it's gated to outdoor missions with `has_outdoor_zones`, and it doesn't touch lighting at all. It moves the needle, it doesn't close the gap.
- **The cheap, high-impact win — real shadows — is still unclaimed:** confirmed zero `LightOccluder2D` usage anywhere in the codebase; lights (including the newer `FlammableSpill` fire light) are still flat additive blobs. Adding occluders to the existing wall segments (auto-generatable from wall geometry) + enabling shadows on the `PointLight2D`s would still transform the mood instantly, and it's still **additive, not a rewrite** — it fits the MGS/Otomo shadow-silhouette intent perfectly. This remains the single best next move in this direction.
- **Other hooks already present:** camera smoothing + shake + scope-zoom, light flicker, dynamic lights that now toggle on/off with gameplay events (fire ignite/extinguish), a working cutscene runner (`CutsceneRunner`), tension/adaptive audio (`tension_audio.gd`, `music_manager.gd`), and now a proven fade-overlay pattern (`storm_weather_overlay.gd`) that a future day-night or tone-grade pass could reuse. The cinematic *intent* is already documented and now has one more working example behind it.
- **The big absences (the expensive long tail):** still no global post-processing / true `WorldEnvironment` / color grade, still no `CanvasModulate`-driven day-night, still no parallax, and — the real ceiling — **still no actual art**, with the art/sfx gap list growing (flame sprite-sheet, storm ambient audio track both filed as `[manual]` off recent ships). "Cinematic" on polygon silhouettes tops out fast.
- **Biggest risk:** perf + the **aggressive pixel-snapping** (`project.godot:538-539`, `main_camera.gd:68`) that was added to kill 1px jitter may fight soft shadows / smooth camera moves. `StormFront`'s screen-space rain/tint sidesteps this (it draws in a `CanvasLayer` above the world, not into world-space), so it's not proof the snap-vs-smooth tension is resolved — occluder shadows will still need to reconcile with it. Budget time for that.

---

## Direction (a): Tile-based world — 🔴 LARGE, highest risk
**Recommendation: don't start here, and first answer one question (below). This is the expensive one and it partly fights the design.**

- **Already supports it:** almost nothing. Pixel-snap + nearest-filter are tile-friendly defaults; fog-of-war already thinks in 64px cells. That's it — **no TileMap/TileSet exists.**
- **Must change (ground-up):** author a TileSet; convert all built-in levels; **rewrite the JSON level format and migrate every saved user level**; rebuild the Level Editor as a tile-painter (today it's free-form placement); reconcile collision (per-segment bodies + one infinite floor) with tile collision.
- **Biggest risk — it fights the DNA:** levels are deliberately small, hand-crafted, "readable single-screen" puzzles where **each wall carries gameplay params** (`breachable`, `wall_mat`, breach points). A uniform tile grid throws away per-wall semantics and the bespoke-puzzle feel, *plus* forces a hard data migration of everything authored so far.

### ⚠️ The one question to answer before scoping tiles
**Do you want tiles for *art* or for *level structure*?**
- **Tiles-for-art** (paint a tiled visual skin over the existing free-form geometry) — **far cheaper**, no level-format rewrite, keeps per-wall gameplay semantics. Likely a *medium* job.
- **Tiles-as-geometry** (grid-snapped level structure, tile-painter editor, new JSON format) — the **very large** rewrite above.

These are wildly different in cost. Pin this down first; it's the difference between medium and very-large.

---

## Suggested sequencing (my recommendation)
1. **Ship real art** into the existing drop-in pipeline first — biggest feel-change for zero architecture risk. The whole "placeholder" impression may largely resolve here. The `[manual][art]`/`[manual][sfx]` backlog keeps growing behind shipped systems (flame sprite-sheet for `FlammableSpill`, storm ambient audio for `StormFront`, a scuff-mark sprite for the tamper tell, on top of the pre-existing character/guard sheet gaps) — every new one is more evidence this is where the leverage is, not a reason to defer it further.
2. **Bigger characters / zoom** (b) — one-number prototype, playtest plan-mode legibility, then commit + fix HUD-scaling and add camera bounds.
3. **Shadow occluders** (c, cheap win) — instant mood, fits the art intent, still completely unclaimed (zero `LightOccluder2D` in the codebase as of this update).
4. **Decide the tile question** (a, art-skin vs. geometry) — only after 1–3, and only if the look still isn't where you want it.
5. Long-tail cinematic polish (post/grade/day-night) last — note `StormFront`'s fade-overlay `CanvasLayer` is a small, real down payment already banked here, not a reason to skip it.

**Key files if you want to dig in:** `project.godot` (display/snap) · `scenes/characters/base_character.tscn` · `scripts/characters/character_sprite.gd` · `scripts/characters/character_draw.gd` · `scripts/game/main_camera.gd` · `scripts/missions/level.gd` · `scripts/missions/level_io.gd` · `scenes/levels/sample/warehouse_01.tscn` · `scripts/systems/fog_of_war.gd` · `assets/shaders/sniper_scope.gdshader` · `scripts/systems/storm_front.gd` · `scripts/effects/storm_weather_overlay.gd` · `scripts/interactables/flammable_spill.gd` · `ASSETS.md` · `SPRITE_SHEET_GUIDE.md` · `INSPIRATIONS.md` · `Philosophy.md`.

---

## Addendum 2026-07-08 — what today's batch changes about this analysis (nothing structural; the "ship art first" case got stronger)

Four features shipped today (Paid Informant Tip, Decoy Extraction Signal, Rescue Objective + "Silent Extraction" mission, Veteran Run). None change the engine/rendering baseline above — every visual added is more of the same house-style procedural draw (a cyan diamond+ring HUD marker, an amber beacon with a fading pulse). But two of them materially sharpen the argument in "Suggested sequencing" step 1:

- **The game now has NAMED CHARACTERS standing on placeholder polygons.** The Rescue Objective introduces **Informant Kade** — a story-relevant escort NPC the camera and the player's attention follow for a whole mission — rendered as a tinted humanoid `Polygon2D` (same template as a guard). Veteran Run introduces the hero **"The Fox"** — a boss-shaped recurring enemy with a codec introduction — rendered as the guard polygon fallback, whose codec popup shows the *generic coordinator portrait* because he has no art of his own. These are the highest-visibility art gaps the game has ever had: not "a prop lacks a sprite" but "the characters the design asks you to CARE about have no faces." Both are filed as `[manual][art]` (Kade sprite + idle/walk anim; The Fox sprite + portrait + line pools).
- **Replayability meta now multiplies the value of every art asset.** Veteran Run has players re-touring ALL authored levels with escalated stakes — any art shipped into the drop-in pipeline is now seen twice per player (campaign + veteran), and hero/named-NPC art specifically anchors the mode's fantasy ("Reyes is already patrolling mission 1"). Same leverage math as before, bigger multiplier.
- Minor: today's batch also fixed a real render-adjacent bug (a `.gd.uid` collision that could make `warehouse_01.tscn` fail to instantiate after a cache rebuild) — worth knowing if you saw "Scene instance is missing" during earlier look-and-feel poking; it wasn't the art pipeline's fault and it's gone now.

**Net effect on the recommendation:** unchanged order, higher urgency on step 1 — and if art budget is tight, the two named characters (Kade, The Fox) plus the 8 core thief archetypes are now the clear priority list, ahead of props/effects.
