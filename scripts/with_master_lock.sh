#!/usr/bin/env bash
# with_master_lock.sh — the ONE safe way to mutate the canonical WORK.md.
#
# Performs a single workmd.py mutation atomically: under the master-push lock,
# on a freshly-synced master, then commits + pushes WORK.md. A bare
# `workmd.py <mutate>` is UNSAFE — it leaves the edit uncommitted in game_dir,
# where the next continuous_dev worker's `reset --hard origin/master` (run before
# every claim/merge) silently eats it. This wrapper closes that race for good.
#
# The canonical WORK.md path is injected automatically as the subcommand's first
# positional, so you pass only the subcommand + its remaining args.
#
# Usage:
#   with_master_lock.sh [-m "<commit subject>"] <workmd-subcmd> [args...]
#
# Examples:
#   with_master_lock.sh promote "Patrol turn telegraph" --detail "fire ~1/3 of reversals"
#   with_master_lock.sh drop    "Some half-baked idea"
#   with_master_lock.sh resume  "Escalated thing the dev should retry"
#   with_master_lock.sh -m "accept: schedule corruption" promote "Patrol schedule corruption"
#
# Exit: 0 on success (or no-op if WORK.md was unchanged); 1 on lock timeout /
# mutation failure / push race; 2 on usage error.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEDULE="$REPO_DIR/schedule.yaml"
WORKMD="$REPO_DIR/scripts/workmd.py"
LOCKS_DIR="$REPO_DIR/.locks"
# shellcheck source=lockutils.sh
. "$REPO_DIR/scripts/lockutils.sh"

msg=""
if [ "${1:-}" = "-m" ]; then
  msg="${2:-}"; shift 2
fi
if [ $# -lt 1 ]; then
  echo "usage: $0 [-m \"<commit subject>\"] <workmd-subcmd> [args...]" >&2
  exit 2
fi
subcmd="$1"; shift   # remaining "$@" are the subcmd's args AFTER the WORK.md path

# Default commit subject if -m not given: "chore(work): <subcmd> '<first-arg>'".
if [ -z "$msg" ]; then
  first="${1:-}"
  short="${first:0:50}"
  [ "${#first}" -gt 50 ] && short="${short}..."
  msg="chore(work): ${subcmd} '${short}'"
fi

# Resolve game_dir from schedule.yaml.
game_dir=$(python3 - "$SCHEDULE" <<'PY'
import sys, os, re
with open(sys.argv[1]) as f:
    for line in f:
        m = re.match(r"\s*game_dir:\s*(\S+)", line)
        if m:
            print(os.path.expanduser(m.group(1))); break
PY
)
if [ -z "$game_dir" ] || [ ! -d "$game_dir" ]; then
  echo "with_master_lock: game_dir not resolvable from $SCHEDULE" >&2
  exit 1
fi

# Acquire the SAME lock the workers serialize their merges on. Holding it in
# THIS (single, long-lived) process is what makes the whole edit→commit→push
# atomic — see docs/WORKER_OPERATIONS.md §4.
mkdir -p "$LOCKS_DIR"
LOCK="$LOCKS_DIR/master-push.lockdir"
if ! acquire_lock "$LOCK" 120 0.3; then
  echo "with_master_lock: couldn't get master-push lock in 120s (a worker merge may be running) — try again." >&2
  exit 1
fi
trap 'release_lock "$LOCK"' EXIT   # release on ANY exit (success, error, signal)

cd "$game_dir" || { echo "with_master_lock: cannot cd $game_dir" >&2; exit 1; }
git checkout --quiet master 2>/dev/null || { echo "with_master_lock: cannot checkout master in $game_dir" >&2; exit 1; }
git fetch --quiet origin master 2>/dev/null
git reset --hard origin/master --quiet 2>/dev/null   # mutate against the latest pushed WORK.md

# Run the mutation, injecting the canonical WORK.md path as the first positional.
if ! python3 "$WORKMD" "$subcmd" "$game_dir/WORK.md" "$@"; then
  echo "with_master_lock: 'workmd.py $subcmd' failed — nothing committed." >&2
  exit 1
fi

git add WORK.md
if git diff --cached --quiet; then
  echo "with_master_lock: WORK.md unchanged (no match / no-op) — nothing to commit."
  exit 0
fi
git -c user.email=ceo@spraxel.ai -c user.name='Spraxel CEO' commit --quiet -m "$msg" \
  || { echo "with_master_lock: commit failed" >&2; exit 1; }
if ! git push --quiet origin master 2>/dev/null; then
  echo "with_master_lock: push failed (lost a race?) — commit is local; re-run or 'git -C $game_dir push origin master'." >&2
  exit 1
fi
echo "with_master_lock: ✓ $msg"
