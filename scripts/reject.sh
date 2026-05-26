#!/usr/bin/env bash
# reject.sh — CEO rejects a shipped feature.
#
# Reverts the feat: + work: shipped commits for a given feature on master,
# pushes, and re-queues the item to WORK.md ## Todo as [needs-ceo] [reject]
# so the Developer takes another swing with the CEO's feedback as context.
#
# Usage:
#   bash scripts/reject.sh <slug-or-sha> [reason ...]
#
# Examples:
#   bash scripts/reject.sh cutscene-engine "subtitles cut off the bottom"
#   bash scripts/reject.sh 6d2d92c "drill bar invisible on dark floors"
#
# Resolves the target by:
#   1. If it's a valid git ref, use it directly.
#   2. Otherwise look for the most recent `feat: <slug...>` commit on master
#      whose subject matches the slug case-insensitively.
#
# Then finds the paired `work: shipped '<title>'` commit (if any) and
# reverts both in one push. If revert hits conflicts, the CEO resolves
# manually — script exits 1 with a clear message.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEDULE="$REPO_DIR/schedule.yaml"
WORKMD="$REPO_DIR/scripts/workmd.py"

if [ $# -eq 0 ]; then
  echo "usage: $0 <slug-or-sha> [reason ...]" >&2
  exit 1
fi

target="$1"
shift
reason="${*:-no reason given}"

# Pull game_dir from schedule.yaml.
game_dir=$(python3 - "$SCHEDULE" <<'PY'
import sys, os, re
with open(sys.argv[1]) as f:
    for line in f:
        m = re.match(r"\s*game_dir:\s*(\S+)", line)
        if m:
            print(os.path.expanduser(m.group(1)))
            break
PY
)
if [ -z "$game_dir" ] || [ ! -d "$game_dir" ]; then
  echo "reject: game_dir not resolvable" >&2
  exit 1
fi
cd "$game_dir"

# Confirm we're on master with a clean tree — revert needs both.
current_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
if [ "$current_branch" != "master" ]; then
  echo "reject: HEAD is '$current_branch', need master. Aborting." >&2
  exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "reject: working tree dirty, refusing to revert. Stash or commit first." >&2
  git status --short >&2
  exit 1
fi

# Resolve target → feat sha + work-shipped sha (if paired).
feat_sha=""
if git rev-parse --verify --quiet "$target^{commit}" >/dev/null; then
  feat_sha=$(git rev-parse --short "$target")
else
  # Slug lookup: latest feat: commit whose subject matches the slug.
  feat_sha=$(git log master --format='%h %s' | \
             grep -iE "^[a-f0-9]+ feat: .*$target" | \
             head -1 | awk '{print $1}')
fi
if [ -z "$feat_sha" ]; then
  echo "reject: no feat: commit found for '$target'" >&2
  exit 1
fi

feat_subject=$(git log -1 --format='%s' "$feat_sha")
feat_title="${feat_subject#feat: }"
echo "reject: matched feat $feat_sha — '$feat_title'"

# Find the paired `work: shipped '<title>'` commit, if any.
shipped_sha=$(git log master --format='%h %s' | \
              grep -F "work: shipped '$feat_title'" | \
              head -1 | awk '{print $1}')

# Build the list of commits to revert (newest first — git revert applies
# them in order, undoing forward in time).
to_revert=()
if [ -n "$shipped_sha" ]; then
  to_revert+=("$shipped_sha")
  echo "reject: matched work-shipped $shipped_sha — will revert both"
fi
to_revert+=("$feat_sha")

# Revert. --no-edit uses default message; we add a follow-up empty commit
# only if there's something to amend. Actually let git revert make its own
# commits with default messages — keeps history readable.
if ! git revert --no-edit "${to_revert[@]}" 2>&1; then
  echo "" >&2
  echo "reject: revert hit conflicts. Resolve files listed above, then:" >&2
  echo "  git revert --continue" >&2
  echo "  git push origin master" >&2
  echo "  python3 $WORKMD append WORK.md \"[needs-ceo] [reject] Re-implement: $feat_title\" --section todo --detail \"Rejected $feat_sha — $reason\"" >&2
  exit 1
fi

# Push the revert commits.
if ! git push origin master 2>&1; then
  echo "reject: push failed — revert is local-only. Push manually:" >&2
  echo "  git push origin master" >&2
  exit 1
fi

# Re-queue the item in WORK.md as [needs-ceo] [reject] so the Developer
# takes another swing with the CEO's feedback as context.
python3 "$WORKMD" append "$game_dir/WORK.md" \
  "[needs-ceo] [reject] Re-implement: $feat_title" \
  --section todo \
  --detail "Rejected $feat_sha at $(date '+%Y-%m-%d %H:%M %Z')" \
  --detail "Reason: $reason" \
  --detail "Original work: see reflog for $feat_sha / cherry-pick if you want to start from the old code"

git add WORK.md
git -c user.email=ceo-reject@spraxel.ai -c user.name='CEO Reject' \
    commit --quiet -m "reject: '$feat_title' re-queued for rework"
git push --quiet origin master 2>&1 | tail -1

echo ""
echo "✓ rejected $feat_sha"
[ -n "$shipped_sha" ] && echo "  + reverted work-shipped $shipped_sha"
echo "  re-queued in WORK.md ## Todo with [needs-ceo] [reject]"
echo "  CEO note: edit the item details with specifics so the Developer can fix it"
