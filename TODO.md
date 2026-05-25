# Spraxel framework — open TODOs

What's still unfinished after the offline migration. Items get removed when they ship.

## Active

(empty — offline migration shipped 2026-05-25)

## Next up

### Video taker / demo-creator agent

`spraxel-demo-creator.md` is a stub. Goal: nightly screen recording of one
shipped feature using `screencapture -V <s>` or `ffmpeg` against a Godot
window driven by `--demo-feature=<slug>` boot mode. Outputs to
`assets/demos/<feature>.mov`. Then either uploaded by hand or embedded into
the weekly Blogger draft.

Complexity: M. Blockers: needs a stable headless Godot window pattern that
captures cleanly (Godot 4's `--headless` skips rendering — likely need a
non-headless invocation with `--audio-driver Dummy --video-driver opengl3`
on an off-screen window).

### Multi-game bootstrap

`scripts/new_game.sh` works, but the offline workflow needs:
- Copy `schedule.yaml` into each game's repo (one schedule per game).
- Update the daemon plist to target the chosen game's WORK.md.

For a second game, also: the daemon ticks the wrong WORK.md unless we
either (a) shard one daemon per game or (b) extend `tick.sh` to iterate
over multiple game-dir entries in `schedule.yaml`.

Defer until you actually start a second game.

### Token usage backpressure

If `claude -p` starts returning 429 (Max weekly cap hit), the agents all
silently fail. Add a daily health check in `tick.sh`:

```bash
# pseudo
recent_errors=$(grep -l "rate limit\|429" logs/*/$(date +%Y-%m-%d)*.log | wc -l)
if [ $recent_errors -gt 3 ]; then
  echo "$(date)  RATE LIMIT detected — pausing 24h" >> logs/tick/$(date +%Y-%m-%d).log
  touch .paused
  # And: schedule rm of .paused for tomorrow.
fi
```

Defer until you've actually hit the cap.

### Email / push notifications

Currently no external notification — you have to open MORNING.md yourself.
If you want a "morning ping" on your phone: macOS Notification Center via
`osascript -e 'display notification ...'` at 06:05 PT, or a simple iOS
Shortcut watching `MORNING.md` via iCloud Drive.

Defer until the routine feels under-attended.

## Decided / closed

### Why no PR workflow?

Decided 2026-05-25: in a one-person studio, PRs add ceremony without value.
Overnight loop does Developer → tests → Reviewer → merge in one shot. If a
feature lands broken, `git revert` is cheap and you find out in the next
play-test.

### Why no GitHub Issues?

Decided 2026-05-25: WORK.md is simpler, faster, fully offline, and
unifies the queue + ship log in one file. Editing WORK.md in any text
editor is more pleasant than navigating GitHub UI.

### Why no GitHub Actions?

Decided 2026-05-25: marginal Actions cost (free-tier minutes) constrained
us. All workflows are now local shell scripts. Loss: no auto-CI on PRs,
but there are no PRs now.

### Why no `/schedule` Anthropic routines?

Decided 2026-05-25: `/schedule` bills per-token, separate from Max plan.
`claude -p` headless on Max is flat-fee. Same agent, no marginal cost.

### Why no Concierge agent?

Decided 2026-05-25: renamed to morning-briefer, writes MORNING.md
instead of a GH issue body. Concierge as a concept presupposed GH
issues; morning-briefer presupposes a local file.

### Why no Conflict-resolver / Auto-merge / Keepalive?

Decided 2026-05-25: these existed to keep the GH-Actions cascade running.
With no PRs and no event-driven chains, they vanished.
