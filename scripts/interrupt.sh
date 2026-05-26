#!/usr/bin/env bash
# interrupt.sh — pause the system + preserve any in-flight overnight work
# so the CEO can do an arbitrary manual change safely.
#
# Use when the CEO says "wait, do X first" while overnight is running.
# Paired with `resume.sh` which restores state.
#
# What it does:
#   1. Sets the .paused flag (blocks new agent dispatches from tick.sh)
#   2. Kills any in-flight overnight loop + Developer + Reviewer + claude -p
#   3. If the game repo has uncommitted changes from the in-flight Developer,
#      git stash them on the current branch (preserved, recoverable)
#   4. Checks out master and pulls fresh
#   5. Records pre-interrupt state to .cache/last-interrupt.txt so resume.sh
#      can restore it
#
# Idempotent — running twice does nothing harmful. Safe to run when nothing
# is in flight (just sets .paused + checks out master if needed).

set -o pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEDULE="$REPO_DIR/schedule.yaml"
PAUSED_FLAG="$REPO_DIR/.paused"
CACHE_DIR="$REPO_DIR/.cache"
STATE_FILE="$CACHE_DIR/last-interrupt.txt"
LOCKS_DIR="$REPO_DIR/.locks"

mkdir -p "$CACHE_DIR"

# Resolve game_dir from schedule.yaml
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
  echo "interrupt: ERROR — game_dir not resolvable from $SCHEDULE" >&2
  exit 1
fi

echo "interrupt: starting at $(date '+%Y-%m-%d %H:%M:%S %Z')"

# 1. Block new dispatches.
touch "$PAUSED_FLAG"
echo "  ✓ daemon paused (.paused flag set)"

# 2. Kill in-flight loop + agent processes.
#    IMPORTANT: kill EVERY layer (continuous_dev → run_agent → claude -p).
#    Just killing continuous_dev orphans the run_agent + claude children, and
#    those orphans hold the developer.lockdir, blocking any future Developer.
killed=0
for pat in "continuous_dev.sh" "overnight_dev.sh" "run_agent.sh" "claude --model claude-" "claude --dangerously-skip-permissions -p"; do
  pids=$(pgrep -f "$pat" 2>/dev/null | tr '\n' ' ')
  if [ -n "$pids" ]; then
    # shellcheck disable=SC2086
    kill -TERM $pids 2>/dev/null && killed=$((killed + $(echo $pids | wc -w)))
  fi
done
sleep 2
# SIGKILL any survivors (claude -p in a syscall can ignore SIGTERM briefly).
for pat in "continuous_dev.sh" "overnight_dev.sh" "run_agent.sh" "claude --model claude-" "claude --dangerously-skip-permissions -p"; do
  pgrep -f "$pat" 2>/dev/null | xargs kill -KILL 2>/dev/null || true
done
echo "  ✓ killed $killed agent process(es)"

# Clear stale lockdirs left by killed processes.
for ld in "$LOCKS_DIR"/*.lockdir; do
  [ -e "$ld" ] && rmdir "$ld" 2>/dev/null
done

# 3. Stash in-flight Developer work (if any) on whatever branch we're on.
cd "$game_dir" || exit 1
pre_branch=$(git branch --show-current)
stash_ref=""
if [ -n "$(git status --porcelain)" ]; then
  stash_msg="interrupt-$(date +%Y%m%d-%H%M%S)-on-${pre_branch}"
  if git stash push -u -m "$stash_msg" 2>&1 | tail -1 | grep -q "Saved working directory"; then
    stash_ref=$(git stash list | head -1 | cut -d: -f1)
    echo "  ✓ stashed in-flight work: $stash_ref ($stash_msg)"
  else
    echo "  ✓ working tree was clean — nothing to stash"
  fi
else
  echo "  ✓ working tree clean — nothing to stash"
fi

# 4. Checkout master + pull.
if [ "$pre_branch" != "master" ]; then
  git checkout --quiet master
  echo "  ✓ checked out master (was on: $pre_branch)"
else
  echo "  ✓ already on master"
fi
git fetch --quiet origin master 2>/dev/null
git pull --ff-only --quiet origin master 2>/dev/null || echo "  ⚠ master pull skipped (no remote or non-ff)"

# 5. Record state for resume.sh.
cat > "$STATE_FILE" <<EOF
ts: $(date '+%Y-%m-%d %H:%M:%S %Z')
pre_branch: $pre_branch
stash_ref: $stash_ref
stash_msg: ${stash_msg:-(none)}
EOF

echo
echo "interrupt: done. CEO can now make changes on master."
echo "  Pre-interrupt state recorded: $STATE_FILE"
echo "  When done: bash ~/SpraxelAiCompany/scripts/resume.sh"
exit 0
