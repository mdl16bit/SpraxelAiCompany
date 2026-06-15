#!/usr/bin/env bash
# reap_hung_agents.sh — safety-net monitor for HUNG (alive-but-stuck) agents.
#
# Why this exists: run_agent.sh and tick.sh both honour a LIVE lock holder, so a
# process that is alive but wedged (e.g. a `claude -p` whose API socket stalled)
# holds its agent lockdir forever and blocks the pipeline — observed 2026-06-07
# when the architect wedged 22 min at ~0% CPU. run_agent.sh now self-caps each
# attempt with a watchdog; THIS is the belt-and-suspenders layer that catches
# anything the per-call watchdog misses (a watchdog subshell that itself died, a
# lock left by a SIGKILL'd run, or a non-run_agent process).
#
# Heuristic: a lockdir whose age exceeds the agent's plausible max runtime is
# almost certainly hung. We kill the holder.pid tree and clear the lock so the
# next tick can re-dispatch cleanly. Conservative thresholds — well above a
# healthy run — so we never reap a legitimately-working agent.
#
# Idempotent, read-mostly, exits 0. Safe to call every tick.
#   bash ~/SpraxelAiCompany/scripts/reap_hung_agents.sh
set -uo pipefail

_reap_default_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="${REPO_DIR:-$_reap_default_repo}"

# Resolve game context (the LOCKS_DIR this sweeps) via the shared resolver.
# Honors --game, else $SPRAXEL_GAME, else the sole enabled game. PHASE 1: gctx's
# flat LOCKS_DIR == $REPO_DIR/.locks, so the swept set is unchanged.
game_arg=""
[ "${1:-}" = "--game" ] && { game_arg="${2:-}"; shift 2; }
if [ -n "$game_arg" ]; then
  . "$REPO_DIR/scripts/gctx.sh" --game "$game_arg"
else
  . "$REPO_DIR/scripts/gctx.sh"
fi
. "$REPO_DIR/scripts/lockutils.sh" 2>/dev/null || true

# Per-lock max age (minutes) before we consider the holder hung. Generous:
# crew agents finish in ~5-8 min; test-runner ~60 min; master-push is a quick
# edit so a long hold means a wedged push.
#
# NEVER reap continuous-w* — those lockdirs are LONG-LIVED BY DESIGN (the worker
# holds one for its entire multi-day lifetime; the continuous_dev wrapper has its
# OWN per-item MAX_DEV_MINUTES stall watchdog). Age says nothing about their
# health, so we skip them entirely (returning 0 = "never reap").
max_age_min() {
  # Map the agent/lock name → a reaper class, then read its max-age from
  # COMPANY_CONFIG reaper.max_age_minutes.<class> (fallback = built-in default).
  local cls dflt
  case "$1" in
    continuous-w*)        cls=continuous_worker; dflt=0  ;;   # long-lived by design; wrapper self-manages
    architect|designer|pm|triager|playtester|demo_creator|janitor|blogger|asset_librarian|morning-briefer|morning_briefer)
                          cls=crew;        dflt=20 ;;
    test-runner)          cls=test_runner; dflt=75 ;;
    master-push)          cls=master_push; dflt=5  ;;
    catch_up|*)           cls=catch_up;    dflt=30 ;;
  esac
  local v; v=$(python3 "$REPO_DIR/scripts/spx_config.py" get "reaper.max_age_minutes.$cls" 2>/dev/null)
  echo "${v:-$dflt}"
}

now=$(date +%s)
reaped=()
for d in "$LOCKS_DIR"/*.lockdir; do
  [ -d "$d" ] || continue
  base=$(basename "$d" .lockdir)
  am=$(max_age_min "$base")
  [ "$am" -eq 0 ] && continue            # 0 = never reap (e.g. long-lived continuous-w*)
  thresh=$(( am * 60 ))
  # lockdir mtime = when the lock was acquired.
  mtime=$(stat -f %m "$d" 2>/dev/null || stat -c %Y "$d" 2>/dev/null) || continue
  age=$(( now - mtime ))
  [ "$age" -lt "$thresh" ] && continue   # young enough — leave it

  pid=""
  [ -f "$d/holder.pid" ] && pid=$(cat "$d/holder.pid" 2>/dev/null | tr -dc '0-9')
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    echo "$(date '+%F %T') reap: $base held ${age}s (>${thresh}s) by live pid $pid — killing hung tree" >&2
    # kill children first, then the holder
    for k in $(pgrep -P "$pid" 2>/dev/null); do
      pkill -TERM -P "$k" 2>/dev/null; kill -TERM "$k" 2>/dev/null
    done
    pkill -TERM -P "$pid" 2>/dev/null; kill -TERM "$pid" 2>/dev/null
    sleep 3
    pkill -KILL -P "$pid" 2>/dev/null; kill -KILL "$pid" 2>/dev/null
  else
    echo "$(date '+%F %T') reap: $base held ${age}s (>${thresh}s), holder dead/unknown — clearing stale lock" >&2
  fi
  # Clear the lock (release_lock removes holder.pid first; fall back to rm -rf).
  release_lock "$d" 2>/dev/null || rm -rf "$d"
  reaped+=("$base(${age}s)")
done

[ "${#reaped[@]}" -gt 0 ] && echo "$(date '+%F %T') reap: cleared ${reaped[*]}" >&2
exit 0
