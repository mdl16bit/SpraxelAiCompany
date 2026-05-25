#!/usr/bin/env bash
# resume.sh — restore the state interrupt.sh paused, then resume the daemon.
#
# Usage:
#   bash scripts/resume.sh             # restore + resume (default)
#   bash scripts/resume.sh --drop      # discard the in-flight stash (don't restore)
#   bash scripts/resume.sh --no-resume # restore but leave .paused (won't fire)
#
# What it does (default):
#   1. Reads .cache/last-interrupt.txt for pre-interrupt state.
#   2. Checks out the pre-interrupt branch (if it was something other than master).
#   3. Pops the stash if there was one.
#   4. Removes the .paused flag → tick.sh starts dispatching again.

set -o pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEDULE="$REPO_DIR/schedule.yaml"
PAUSED_FLAG="$REPO_DIR/.paused"
STATE_FILE="$REPO_DIR/.cache/last-interrupt.txt"

mode="restore"
case "${1:-}" in
  --drop) mode="drop" ;;
  --no-resume) mode="no-resume" ;;
  "") ;;
  *) echo "usage: $0 [--drop|--no-resume]" >&2; exit 1 ;;
esac

if [ ! -f "$STATE_FILE" ]; then
  echo "resume: no prior interrupt state at $STATE_FILE — just clearing .paused"
  rm -f "$PAUSED_FLAG"
  echo "  ✓ .paused removed; daemon will resume on next tick"
  exit 0
fi

# Resolve game_dir
game_dir=$(python3 - "$SCHEDULE" <<'PY'
import sys, os, re
with open(sys.argv[1]) as f:
    for line in f:
        m = re.match(r"\s*game_dir:\s*(\S+)", line)
        if m:
            print(os.path.expanduser(m.group(1))); break
PY
)

# Parse state file
pre_branch=$(grep '^pre_branch:' "$STATE_FILE" | cut -d' ' -f2-)
stash_ref=$(grep '^stash_ref:' "$STATE_FILE" | cut -d' ' -f2-)

echo "resume: starting at $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "  pre-interrupt branch: $pre_branch"
echo "  stash:                ${stash_ref:-(none)}"

cd "$game_dir" || { echo "resume: game_dir gone — abort"; exit 1; }

# Make sure working tree is clean before any restore.
if [ -n "$(git status --porcelain)" ]; then
  echo "  ⚠ working tree is DIRTY on $(git branch --show-current) — refusing to restore"
  echo "    commit or stash your changes first, then re-run resume.sh"
  exit 2
fi

case "$mode" in
  drop)
    if [ -n "$stash_ref" ]; then
      git stash drop "$stash_ref" 2>/dev/null && echo "  ✓ dropped stash $stash_ref"
    fi
    echo "  ✓ in-flight Developer work discarded"
    ;;
  restore|no-resume)
    if [ -n "$pre_branch" ] && [ "$pre_branch" != "master" ]; then
      # Restore the overnight branch if it still exists
      if git rev-parse --verify --quiet "$pre_branch" >/dev/null; then
        git checkout --quiet "$pre_branch"
        echo "  ✓ checked out $pre_branch"
      else
        echo "  ⚠ branch $pre_branch is gone — staying on master"
      fi
    fi
    if [ -n "$stash_ref" ]; then
      if git stash pop "$stash_ref" 2>&1 | grep -q "conflict"; then
        echo "  ⚠ stash pop hit conflicts — resolve manually, then rm $PAUSED_FLAG"
        exit 3
      fi
      echo "  ✓ popped stash $stash_ref"
    fi
    ;;
esac

# Resume daemon unless --no-resume.
if [ "$mode" = "no-resume" ]; then
  echo "  ✓ left .paused in place (daemon still paused)"
else
  rm -f "$PAUSED_FLAG"
  echo "  ✓ removed .paused — daemon will dispatch on next tick"
fi

# Archive the state file so a future interrupt starts fresh.
mv "$STATE_FILE" "${STATE_FILE}.prev" 2>/dev/null
echo
echo "resume: done."
exit 0
