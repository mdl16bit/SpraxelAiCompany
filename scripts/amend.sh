#!/usr/bin/env bash
# amend.sh — CEO keeps a shipped feature but wants changes.
#
# Unlike reject.sh, this does NOT revert. The current implementation stays
# on master; the Developer iterates on top of it next overnight run, using
# the CEO's feedback as scope.
#
# Usage:
#   bash scripts/amend.sh <slug-or-sha> <feedback>
#
# Examples:
#   bash scripts/amend.sh cutscene-engine "title fade is too slow — 0.3s feels better than 1.0s"
#   bash scripts/amend.sh 6d2d92c "drill bar should pulse red below 1s remaining"
#
# Effect: appends `[needs-ceo] [amend] Refine: <title>` to WORK.md ## Todo
# with the original sha, the CEO's feedback, and a pointer to inspect the
# existing implementation. Developer picks it up overnight, reads the
# feedback, and modifies the feature.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKMD="$REPO_DIR/scripts/workmd.py"
# shellcheck source=lockutils.sh
. "$REPO_DIR/scripts/lockutils.sh"

# Parse out --game <slug> from anywhere in the args, leaving the script's own
# positional args (slug-or-sha + feedback words) intact and in order.
game_arg=""
_args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --game) game_arg="${2:-}"; shift 2 ;;
    *)      _args+=("$1"); shift ;;
  esac
done
set -- ${_args[@]+"${_args[@]}"}

if [ $# -lt 2 ]; then
  echo "usage: $0 <slug-or-sha> <feedback> [--game <slug>]" >&2
  echo "" >&2
  echo "Keeps the feature on master, but queues a refinement pass with" >&2
  echo "your feedback as scope. Use reject.sh if you want it gone instead." >&2
  exit 1
fi

target="$1"
shift
feedback="$*"

# Resolve game context (game_dir + per-game state paths) via the shared resolver.
if [ -n "$game_arg" ]; then
  . "$REPO_DIR/scripts/gctx.sh" --game "$game_arg"
else
  . "$REPO_DIR/scripts/gctx.sh"
fi
game_dir="$GAME_DIR"
cd "$game_dir"

# Need master + clean tree to safely commit the WORK.md update.
current_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
if [ "$current_branch" != "master" ]; then
  echo "amend: HEAD is '$current_branch', need master. Aborting." >&2
  exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "amend: working tree dirty, refusing to commit. Stash or commit first." >&2
  git status --short >&2
  exit 1
fi

# Hold the master-push lock for the whole mutate+commit+push, and sync to the
# latest origin/master under it, so a concurrent worker's `reset --hard
# origin/master` can't clobber the WORK.md append before it's pushed. See
# docs/WORKER_OPERATIONS.md §4.
mkdir -p "$LOCKS_DIR"
LOCK="$LOCKS_DIR/master-push.lockdir"
if ! acquire_lock "$LOCK" 120 0.3; then
  echo "amend: couldn't get master-push lock in 120s (worker merge running?) — try again." >&2
  exit 1
fi
trap 'release_lock "$LOCK"' EXIT
git fetch --quiet origin master 2>/dev/null && git reset --hard origin/master --quiet 2>/dev/null

# Resolve target → feat sha.
feat_sha=""
if git rev-parse --verify --quiet "$target^{commit}" >/dev/null; then
  feat_sha=$(git rev-parse --short "$target")
else
  feat_sha=$(git log master --format='%h %s' | \
             grep -iE "^[a-f0-9]+ feat: .*$target" | \
             head -1 | awk '{print $1}')
fi
if [ -z "$feat_sha" ]; then
  echo "amend: no feat: commit found for '$target'" >&2
  exit 1
fi

feat_subject=$(git log -1 --format='%s' "$feat_sha")
feat_title="${feat_subject#feat: }"

# Optional but useful: also note the slug from the branch name if we can
# guess it (helps the dev re-run --demo-feature=<slug>).
slug_hint=""
branch_match=$(git log -1 --format='%D' "$feat_sha" | grep -oE 'feat/cont-[0-9-]+-[a-z0-9-]+' | head -1)
if [ -n "$branch_match" ]; then
  slug_hint="${branch_match#*-*-*-}"   # strip "feat/cont-DATE-TIME-"
fi

echo "amend: matched feat $feat_sha — '$feat_title'"
echo "amend: feedback — '$feedback'"
[ -n "$slug_hint" ] && echo "amend: slug hint — $slug_hint"

# Re-queue as [amend]. NO [needs-ceo] tag — the CEO's feedback IS the spec;
# the dev should pick it up automatically overnight.
python3 "$WORKMD" append "$game_dir/WORK.md" \
  "[amend] Refine: $feat_title" \
  --section todo \
  --detail "Amend $feat_sha at $(date '+%Y-%m-%d %H:%M %Z')" \
  --detail "Feedback: $feedback" \
  --detail "Original implementation is on master at $feat_sha — read it (\`git show $feat_sha\`), then modify in place. Do NOT re-implement from scratch unless the feedback explicitly says to."

git add WORK.md
git -c user.email=ceo-amend@spraxel.ai -c user.name='CEO Amend' \
    commit --quiet -m "chore(amend): queue refinement for $(python3 -c "
import sys
t = sys.argv[1].strip().rstrip(' ?.,;:!')
if t and t[0].islower(): t = t[0].upper() + t[1:]
print(t[:50] + ('...' if len(t) > 50 else ''))
" "$feat_title")"
git push --quiet origin master 2>&1 | tail -1

echo ""
echo "✓ amended $feat_sha (kept on master)"
echo "  queued in WORK.md ## Todo as [amend] — Developer picks it up next overnight"
echo "  Developer will read $feat_sha, refine per your feedback, ship the diff"
