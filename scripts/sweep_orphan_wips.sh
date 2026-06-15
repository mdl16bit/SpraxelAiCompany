#!/usr/bin/env bash
# sweep_orphan_wips.sh — release [wip:N] claims that no live worker is working.
#
# The wip analog of lockutils' sweep_dead_locks. A worker killed/restarted
# mid-item can leave its item tagged [wip:N] with no process or worktree
# actually on it; the claim then looks taken, so no worker can grab it —
# silently starving the pool (the recurring "why is a worker idle?" cause).
#
# Detection: a [wip:N] item is "active" iff its slug (slugify of the
# tag-stripped title — the same slug the deterministic feat branch is built
# from) appears in SOME currently-checked-out worker-worktree branch. Any wip
# whose slug is in no checked-out branch is an orphan → released to claimable.
#
# Debounced: an orphan must be seen on TWO consecutive sweeps before release, so
# a worker that just claimed (wip tagged) but hasn't checked out its branch yet
# (a few-second window) is never falsely released.
#
# Release is via `workmd.py unclaim`, committed + pushed under master-push.lockdir
# (a bare WORK.md edit would be wiped by a worker's reset --hard).
#
# Usage: sweep_orphan_wips.sh [--dry-run]   (called every cycle by tick.sh)
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKMD="$REPO_DIR/scripts/workmd.py"
SLUGIFY="$REPO_DIR/scripts/slugify.py"
# shellcheck source=lockutils.sh
. "$REPO_DIR/scripts/lockutils.sh"

# Parse out --game <slug>, leaving the script's own --dry-run flag.
game_arg=""
DRY_RUN="false"
while [ $# -gt 0 ]; do
  case "$1" in
    --game)    game_arg="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    *)         shift ;;
  esac
done

# Resolve game context (game_dir + per-game state paths) via the shared resolver.
if [ -n "$game_arg" ]; then
  . "$REPO_DIR/scripts/gctx.sh" --game "$game_arg"
else
  . "$REPO_DIR/scripts/gctx.sh"
fi
game_dir="$GAME_DIR"
CAND_CACHE="$CACHE_DIR/wip-orphan-candidates.txt"

if [ -z "$game_dir" ] || [ ! -d "$game_dir" ]; then exit 0; fi
WORK="$game_dir/WORK.md"
[ -f "$WORK" ] || exit 0

# Branches checked out across all worktrees (main + workers). A detached
# worktree contributes no branch line, so its stale wip won't match → orphan.
# NB: read-loop, not `mapfile` — macOS ships bash 3.2, which has no mapfile.
BRANCHES=()
while IFS= read -r _b; do
  [ -n "$_b" ] && BRANCHES+=("$_b")
done < <(git -C "$game_dir" worktree list --porcelain 2>/dev/null \
  | awk '/^branch /{sub("refs/heads/","",$2); print $2}')

mkdir -p "$CACHE_DIR"
prev_cands=""; [ -f "$CAND_CACHE" ] && prev_cands=$(cat "$CAND_CACHE")
this_cands=""
to_release=()

while IFS= read -r title; do
  [ -n "$title" ] || continue
  core=$(printf '%s' "$title" | sed -E 's/^\[wip:[0-9]+\][[:space:]]*//')
  slug=$(printf '%s' "$core" | python3 "$SLUGIFY" 2>/dev/null)
  [ -n "$slug" ] || continue
  active=0
  for b in "${BRANCHES[@]:-}"; do
    [ -n "$b" ] || continue
    case "$b" in *"$slug"*) active=1; break;; esac
  done
  if [ "$active" -eq 0 ]; then
    this_cands+="$slug"$'\n'
    # Release only if it was ALSO an orphan last sweep (debounce the claim race).
    if printf '%s\n' "$prev_cands" | grep -qxF "$slug"; then
      to_release+=("$core")
    fi
  fi
done < <(grep -E '^\[wip:[0-9]+\]' "$WORK")

printf '%s' "$this_cands" > "$CAND_CACHE"

[ "${#to_release[@]}" -eq 0 ] && exit 0

if [ "$DRY_RUN" = "true" ]; then
  echo "sweep_orphan_wips: [dry-run] would release ${#to_release[@]} orphan(s):"
  for core in "${to_release[@]}"; do echo "  - ${core:0:80}"; done
  exit 0
fi

# Release under the master-push lock, applied post-sync (one locked session).
LOCK="$LOCKS_DIR/master-push.lockdir"
if ! acquire_lock "$LOCK" 60 0.3; then
  echo "sweep_orphan_wips: master-push lock busy — skip (retry next tick)" >&2
  exit 0
fi
trap 'release_lock "$LOCK"' EXIT
cd "$game_dir" || exit 0
git checkout --quiet master 2>/dev/null
git fetch --quiet origin master 2>/dev/null && git reset --hard origin/master --quiet 2>/dev/null
released=0
for core in "${to_release[@]}"; do
  if python3 "$WORKMD" unclaim "$WORK" "$core" >/dev/null 2>&1; then
    released=$((released + 1))
    echo "sweep_orphan_wips: released orphan [wip] — ${core:0:70}"
  fi
done
if [ "$released" -gt 0 ] && ! git diff --quiet WORK.md 2>/dev/null; then
  git add WORK.md
  git -c user.email=tick-bot@spraxel.ai -c user.name='Spraxel Tick' \
    commit --quiet -m "chore(work): auto-released $released orphaned [wip] claim(s) — no live worker"
  git push --quiet origin master 2>/dev/null || echo "sweep_orphan_wips: push failed (retry next tick)" >&2
fi
release_lock "$LOCK"
exit 0
