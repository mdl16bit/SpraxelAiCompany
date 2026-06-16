#!/usr/bin/env bash
# gctx.sh — Spraxel game-context resolver. SOURCE this; do not execute.
#
#   source "$(dirname "$0")/gctx.sh"                 # current game ($SPRAXEL_GAME or sole game)
#   source "$(dirname "$0")/gctx.sh" --game infiltrators
#
# Game selection order: --game arg > $SPRAXEL_GAME env > sole enabled game.
# Exports, for the resolved game:
#   GAME_SLUG  GAME_DIR  WORK_MD
#   LOCKS_DIR  CACHE_DIR  GAME_LOGS_DIR  WORKTREES_DIR   (per-game operational state)
#   GLOBAL_CACHE  PAUSED_FLAG                            (framework-global, shared by all games)
#   SPRAXEL_GAME  (re-exported so child processes inherit the resolved slug)
#
# PHASE 1 layout = LEGACY FLAT (nothing moves yet). Phase 3 flips the per-game
# vars to state/<slug>/… , logs/<slug>/… , .worktrees/<slug>/… — callers don't change.

# Resolve framework repo root from this file's location (works when sourced).
_GCTX_SELF="${BASH_SOURCE[0]}"
GCTX_REPO_DIR="$(cd "$(dirname "$_GCTX_SELF")/.." && pwd)"
REPO_DIR="${REPO_DIR:-$GCTX_REPO_DIR}"

# --game arg (only consumes the flag pair; leaves other positional params alone).
_gctx_want=""
if [ "${1:-}" = "--game" ] && [ -n "${2:-}" ]; then
    _gctx_want="$2"
fi
_gctx_want="${_gctx_want:-${SPRAXEL_GAME:-}}"

# Resolve slug + dir via the single source of truth (spx_config.py).
if [ -n "$_gctx_want" ]; then
    GAME_DIR="$(python3 "$GCTX_REPO_DIR/scripts/spx_config.py" game-dir "$_gctx_want" 2>/dev/null || true)"
    GAME_SLUG="$_gctx_want"
else
    # Default game = first line of `games` (sole / first enabled).
    _gctx_line="$(python3 "$GCTX_REPO_DIR/scripts/spx_config.py" games 2>/dev/null | head -n1)"
    GAME_SLUG="${_gctx_line%%	*}"            # text before first TAB
    GAME_DIR="${_gctx_line#*	}"; GAME_DIR="${GAME_DIR%%	*}"  # text between 1st and 2nd TAB
fi

if [ -z "${GAME_SLUG:-}" ] || [ -z "${GAME_DIR:-}" ] || [ ! -d "$GAME_DIR" ]; then
    echo "gctx: could not resolve game (want='${_gctx_want:-<default>}' slug='${GAME_SLUG:-}' dir='${GAME_DIR:-}')" >&2
    return 4 2>/dev/null || exit 4
fi

export SPRAXEL_GAME="$GAME_SLUG"
export GAME_SLUG GAME_DIR
export WORK_MD="$GAME_DIR/WORK.md"

# --- per-game operational state (NAMESPACED by slug) ---
# Each game gets an isolated state tree so multiple games can run concurrently
# without colliding on locks / caches / worktrees / logs.
STATE_DIR="$REPO_DIR/state/$GAME_SLUG"
LOCKS_DIR="$STATE_DIR/locks"
CACHE_DIR="$STATE_DIR/cache"
GAME_LOGS_DIR="$REPO_DIR/logs/$GAME_SLUG"
WORKTREES_DIR="$REPO_DIR/.worktrees/$GAME_SLUG"
export STATE_DIR LOCKS_DIR CACHE_DIR GAME_LOGS_DIR WORKTREES_DIR
# Ensure the two most-written per-game roots exist (cheap, idempotent) so first
# writes never fail; log/worktree dirs are mkdir'd by their writers.
mkdir -p "$LOCKS_DIR" "$CACHE_DIR" 2>/dev/null || true

# --- framework-global state (shared by ALL games, never namespaced) ---
# Account-wide concerns: Sonnet rate-limit flag, token/$ accounting, the wall-clock
# tick stamp, and the master pause switch. These reflect the one Anthropic account
# / one machine, so they intentionally stay shared across games.
export GLOBAL_CACHE="$REPO_DIR/.cache"
export PAUSED_FLAG="$REPO_DIR/.paused"

unset _GCTX_SELF _gctx_want _gctx_line
