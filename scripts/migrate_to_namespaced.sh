#!/usr/bin/env bash
# migrate_to_namespaced.sh — one-time, reversible cutover of a game's FLAT state
# into the per-game NAMESPACED layout (state/<slug>/…, logs/<slug>/…, .worktrees/<slug>/…).
#
# Run this DURING a quiesced window as part of the multi-game cutover:
#     1. bash scripts/migrate_to_namespaced.sh --game <slug>     (this script)
#     2. merge the namespaced code (gctx flip + tick.sh + games config) to master
#     3. rm .paused                                              (resume)
#
# It is SAFE: per-game .cache files are COPIED (not moved) into the namespace, so
# the flat originals remain as a backup — a `git revert` of the code alone fully
# rolls back. In-flight feature BRANCHES are never touched (only the worktree
# checkouts are recreated, and the [wip:N] claim tags are released so the items
# return to the buildable queue).
#
# Usage:
#   migrate_to_namespaced.sh [--game <slug>] [--dry-run] [--rollback]
#     --game      game to migrate (default: sole enabled game)
#     --dry-run   print what would happen; change nothing
#     --rollback  remove the namespaced dirs for the game (flat .cache backup is
#                 already intact); pair with `git revert`/reset of the code
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPX="$REPO_DIR/scripts/spx_config.py"
WORKMD="$REPO_DIR/scripts/workmd.py"
PAUSED_FLAG="$REPO_DIR/.paused"
FLAT_LOCKS="$REPO_DIR/.locks"
FLAT_CACHE="$REPO_DIR/.cache"
FLAT_WORKTREES="$REPO_DIR/.worktrees"

game_arg=""; dry_run=0; rollback=0
while [ $# -gt 0 ]; do
  case "$1" in
    --game)     game_arg="${2:-}"; shift 2 ;;
    --dry-run)  dry_run=1; shift ;;
    --rollback) rollback=1; shift ;;
    *) echo "migrate: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

slug="${game_arg:-$(python3 "$SPX" games 2>/dev/null | awk -F'\t' '$3=="1"{print $1; exit}')}"
[ -n "$slug" ] || { echo "migrate: could not resolve a game slug" >&2; exit 1; }
game_dir="$(python3 "$SPX" game-dir "$slug" 2>/dev/null)"
[ -n "$game_dir" ] && [ -d "$game_dir" ] || { echo "migrate: game_dir not found for '$slug'" >&2; exit 1; }

# Resolve the target namespaced paths from the single source of truth (tab-delimited).
while IFS=$'\t' read -r _k _v; do
  [ -n "$_k" ] && eval "NS_$_k=\"\$_v\""
done < <(python3 "$SPX" paths "$slug")
# → NS_GAME_DIR NS_STATE_DIR NS_LOCKS_DIR NS_CACHE_DIR NS_GAME_LOGS_DIR NS_WORKTREES_DIR NS_GLOBAL_CACHE

say() { echo "migrate[$slug]: $*"; }
do_or_echo() { if [ "$dry_run" -eq 1 ]; then echo "  would: $*"; else eval "$*"; fi; }

# Per-game .cache files to bring into the namespace. GLOBAL files (token-usage.json,
# sonnet-capped.json, last-tick-wall.ts) are intentionally EXCLUDED — they stay flat.
PERGAME_CACHE=(
  continuous-state.json
  architect-triage-seen.ts
  designer-dry-ran.date
  engine-uptime-since-test.json
  ceo-checkin.ts
  last-overnight.txt
  heal-sections.min
  agent-last-fire.json
  test-runner-pending
  test-runner-active
  test-runner-ran-sha
  test-runner-progress.json
)

# ── Rollback ────────────────────────────────────────────────────────────────
if [ "$rollback" -eq 1 ]; then
  say "ROLLBACK — removing namespaced dirs (flat .cache backup is intact)."
  do_or_echo "rm -rf '$NS_STATE_DIR'"
  do_or_echo "rm -rf '$NS_GAME_LOGS_DIR'"
  do_or_echo "rm -rf '$NS_WORKTREES_DIR'"
  say "done. Now revert the code (gctx/tick/config) to the flat layout (git)."
  exit 0
fi

# ── Forward migration ───────────────────────────────────────────────────────
say "game_dir       = $game_dir"
say "→ state dir    = $NS_STATE_DIR"
say "→ logs dir     = $NS_GAME_LOGS_DIR"
say "→ worktrees    = $NS_WORKTREES_DIR"
[ "$dry_run" -eq 1 ] && say "(DRY-RUN — no changes will be made)"

# 1. Pause (idempotent). We do NOT unpause — the operator does that after merging.
if [ ! -e "$PAUSED_FLAG" ]; then
  do_or_echo "printf 'migrating %s to namespaced layout (\$(date))\n' '$slug' > '$PAUSED_FLAG'"
  say "paused the system (.paused created)."
else
  say ".paused already present — good."
fi

# 2. Drain: wait briefly for any live flat agent locks to clear (in-flight agents).
if [ "$dry_run" -eq 0 ] && [ -d "$FLAT_LOCKS" ]; then
  . "$REPO_DIR/scripts/lockutils.sh" 2>/dev/null || true
  for _try in 1 2 3 4 5 6 7 8 9 10; do
    live=0
    for l in "$FLAT_LOCKS"/*.lockdir; do
      [ -d "$l" ] || continue
      if command -v lock_holder_alive >/dev/null 2>&1 && lock_holder_alive "$l"; then live=$((live+1)); fi
    done
    [ "$live" -eq 0 ] && break
    say "waiting for $live live agent lock(s) to drain… ($_try/10)"
    sleep 6
  done
fi

# 3. Release [wip:N] claims so in-flight items return to the buildable queue.
#    (Feature branches persist; only the claim tags are dropped.) Covers the
#    interactive worker (0) + headless workers (1..dev_concurrency, padded).
if [ -f "$game_dir/WORK.md" ]; then
  for wid in 0 1 2 3 4 5 6; do
    do_or_echo "python3 '$WORKMD' release-wip '$game_dir/WORK.md' --worker-id $wid >/dev/null 2>&1 || true"
  done
  say "released stale [wip:N] claims (in-flight items return to Todo)."
fi

# 4. Remove the FLAT git worktrees (worker-*, interactive). Checkouts are
#    disposable; the daemon recreates them under .worktrees/<slug>/ on next tick.
if [ -d "$FLAT_WORKTREES" ]; then
  for wt in "$FLAT_WORKTREES"/worker-* "$FLAT_WORKTREES"/interactive; do
    [ -e "$wt" ] || continue
    do_or_echo "git -C '$game_dir' worktree remove --force '$wt' 2>/dev/null || rm -rf '$wt'"
    say "removed flat worktree $(basename "$wt")"
  done
  do_or_echo "git -C '$game_dir' worktree prune 2>/dev/null || true"
fi

# 5. Create the namespaced dirs.
do_or_echo "mkdir -p '$NS_LOCKS_DIR' '$NS_CACHE_DIR' '$NS_GAME_LOGS_DIR' '$NS_WORKTREES_DIR'"

# 6. COPY per-game .cache state into the namespace (flat originals kept as backup).
for f in "${PERGAME_CACHE[@]}"; do
  if [ -e "$FLAT_CACHE/$f" ]; then
    do_or_echo "cp -p '$FLAT_CACHE/$f' '$NS_CACHE_DIR/$f'"
  fi
done
if [ -d "$FLAT_CACHE/agent-last-ok" ]; then
  do_or_echo "cp -Rp '$FLAT_CACHE/agent-last-ok' '$NS_CACHE_DIR/agent-last-ok'"
fi
say "copied per-game .cache state into the namespace (originals left as backup)."

say "DONE. Next: (1) merge the namespaced code to master, (2) rm '$PAUSED_FLAG' to resume."
[ "$dry_run" -eq 1 ] && say "(that was a DRY-RUN — nothing changed)"
exit 0
