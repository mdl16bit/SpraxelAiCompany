---
name: spraxel-demo-creator
description: Demo Creator for the Spraxel gamedev factory. Captures short clips / screenshots demonstrating recently-shipped features for the Blogger and CEO. Implementation deferred — design documented; needs Godot windowed-mode in CI or a self-hosted runner.
model: sonnet
---

# Demo Creator v1 — design notes (implementation deferred)

The original plan called for video clips per shipped feature, twice weekly, via Godot MovieMaker. **MovieMaker is editor-only** (the probe earlier this session confirmed bare `godot --headless` doesn't run it) so the realistic implementation path is one of:

1. **Self-hosted runner on the CEO's Mac.** Godot windowed runs the
   scenario, MovieMaker writes AVI, ffmpeg transcodes to MP4. The Mac
   has to be awake. The ONLY "Mac-awake" hard dependency in the system.
2. **xvfb + Linux runner.** Spin a virtual display in CI, run Godot
   windowed against it, screen-capture via ffmpeg. No Mac dependency
   but complex to make reliable. Frame rate may be poor.
3. **Screenshot-only (cheapest).** Add a `--screenshot` CLI flag to
   `DebugBoot` that captures the framebuffer to PNG at scripted
   moments during a scenario run, dump them to a workflow artifact.
   Blogger embeds. Works in plain headless. Doesn't move, but
   "filmed-still" is 80% of the value for early-stage devlog posts.

Tonight's recommendation: **start with #3 (screenshots-only)** when this lands. Video upgrade later when #1 or #2 is justified.

## Triggers (when implemented)

- Per-PR step in `developer.yml`: capture 1-3 screenshots from the new feature's `--demo-feature=<slug>` scenario, attach as workflow artifacts.
- Weekly batch (`demo-creator.yml`, Saturday morning before Blogger): re-run all scenarios with screenshot mode, upload to a dedicated artifacts branch or GH Pages bucket.

## Output target (when implemented)

For a Blogger-embeddable URL:
- Option A: dedicated `gh-pages` orphan branch holding only artifacts. Blogger embeds `https://mdl16bit.github.io/infiltrators/demos/<slug>.png`.
- Option B: GH Issue attachments. Demo Creator posts the screenshot as a comment-with-image on issue #5; Blogger downloads + re-embeds.
- Option C: GH Pages directly.

## CRITICAL: never commit to master (when implemented)

All artifact pushes go to non-master branches or GH issue attachments. Same rule as every other Phase 2/3 agent.

## What's already in place

The DebugBoot + Tracer pipeline already supports `--demo-feature=<slug>` to land in scripted scenes. Adding `--screenshot=path.png[,t=2.5]` to DebugBoot would let Tracer / scenarios trigger captures. That's a small Godot-side change a future Developer agent can make once we file an issue for it.

## Triggers (today)

None — agent definition exists for documentation. No scheduled routine. CEO files an issue when ready to build screenshot-mode (start with #3).
