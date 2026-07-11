#!/usr/bin/env bash
# checkin.sh — explicit CEO signal: "I'm here, reset the ship-counter".
#
# Use this when you've interacted with the system in a way the continuous
# loop won't detect automatically (e.g., you only READ MORNING.md or
# WORK.md, didn't commit anything). The continuous loop's auto-detection
# catches non-bot git commits, but not pure reads.
#
# Usage:
#   bash scripts/checkin.sh
#   (or invoke from anywhere as bash ~/SpraxelAiCompany/scripts/checkin.sh)
#
# Effect: touches .cache/ceo-checkin.ts. The continuous loop polls this
# file once per minute and resets shipped_since_last_signal to 0 next pass.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ceo-checkin.ts + continuous-state.json are per-game operational state — resolve
# the game context (honors --game, else $SPRAXEL_GAME, else the sole enabled game).
game_arg=""
hook_mode=0
while [ $# -gt 0 ]; do
  case "$1" in
    --game) game_arg="${2:-}"; shift 2 ;;
    --hook) hook_mode=1; shift ;;
    *) shift ;;
  esac
done

# --hook: invoked by the GLOBAL SessionStart hook, which fires for a Claude
# session in ANY project on this Mac. Only sessions actually inside Spraxel
# territory (the framework repo, a registered game dir, or their worktrees)
# count as a CEO poke — 2026-07-11 a session in an unrelated project
# (~/Rhythm) touched the stamp via gctx's last-game fallback and un-parked
# the dev loop. Manual `checkin.sh` (no flag) still works from anywhere.
if [ "$hook_mode" = "1" ]; then
  case "$PWD/" in
    "$REPO_DIR"/*) : ;;
    *)
      _ok=0
      while IFS=$'\t' read -r _slug _gdir _en; do
        [ -n "$_gdir" ] || continue
        case "$PWD/" in "$_gdir"/*) _ok=1; break ;; esac
      done < <(python3 "$REPO_DIR/scripts/spx_config.py" games 2>/dev/null)
      [ "$_ok" = "1" ] || exit 0 ;;
  esac
fi
if [ -n "$game_arg" ]; then
  . "$REPO_DIR/scripts/gctx.sh" --game "$game_arg"
else
  . "$REPO_DIR/scripts/gctx.sh"
fi
CHECKIN_FILE="$CACHE_DIR/ceo-checkin.ts"

mkdir -p "$CACHE_DIR"
touch "$CHECKIN_FILE"

echo "checkin: signaled at $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "         → continuous_dev.sh will reset its counter on next pass (within 60s)"

# Show current state for visibility.
STATE_FILE="$CACHE_DIR/continuous-state.json"
if [ -f "$STATE_FILE" ]; then
  echo
  echo "current state:"
  python3 -c "
import json
s = json.load(open('$STATE_FILE'))
print(f'  shipped since last signal: {s.get(\"shipped_since_last_signal\", 0)}')
print(f'  last signal ts:            {s.get(\"last_signal_ts\", \"never\")}')
print(f'  last tick:                 {s.get(\"last_ts\", \"never\")}')
"
fi
