#!/usr/bin/env bash
# run_agent.sh — invoke one Spraxel agent via `claude -p` headless on the Max plan.
#
# Usage:
#   run_agent.sh <agent-name>            # fire the named agent once
#   run_agent.sh <agent-name> --dry-run  # print prompt, don't call claude
#
# The agent spec at agents/spraxel-<name>.md is read and used as the prompt
# preamble. Current WORK.md and Philosophy.md are appended as context.
# Working directory is the game_dir from schedule.yaml.
#
# Exit codes:
#   0  — agent ran cleanly
#   1  — claude CLI failed
#   2  — locked (another instance running)
#   3  — paused (.paused file exists)
#   4  — agent spec or game_dir missing

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEDULE="$REPO_DIR/schedule.yaml"
AGENTS_DIR="$REPO_DIR/agents"
LOGS_DIR="$REPO_DIR/logs"
LOCKS_DIR="$REPO_DIR/.locks"
PAUSED_FLAG="$REPO_DIR/.paused"

agent="${1:-}"
dry_run="${2:-}"
if [ -z "$agent" ]; then
  echo "usage: $0 <agent-name> [--dry-run]" >&2
  exit 4
fi

if [ -e "$PAUSED_FLAG" ]; then
  echo "run_agent: paused (rm $PAUSED_FLAG to resume)" >&2
  exit 3
fi

# Normalize agent name: underscores in schedule.yaml → hyphens in spec filenames.
agent_slug="${agent//_/-}"
spec="$AGENTS_DIR/spraxel-$agent_slug.md"
if [ ! -f "$spec" ]; then
  echo "run_agent: spec not found: $spec" >&2
  exit 4
fi

# Pull game_dir from schedule.yaml (simple YAML extraction — no PyYAML required).
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
  echo "run_agent: game_dir not resolvable: '$game_dir'" >&2
  exit 4
fi

mkdir -p "$LOGS_DIR/$agent" "$LOCKS_DIR"
ts=$(date +%Y-%m-%d-%H%M)
log="$LOGS_DIR/$agent/$ts.log"

# Compose the prompt. The agent spec is the contract; we append today's state.
{
  cat "$spec"
  echo
  echo "---"
  echo "## Today's runtime context"
  echo
  echo "Working directory: $game_dir"
  echo "Date: $(date '+%Y-%m-%d %H:%M %Z')"
  echo
  echo "### Philosophy.md (run_mode and budgets)"
  if [ -f "$game_dir/Philosophy.md" ]; then
    sed -n '1,80p' "$game_dir/Philosophy.md"
  else
    echo "(no Philosophy.md found at $game_dir/Philosophy.md)"
  fi
  echo
  echo "### WORK.md (current state)"
  if [ -f "$game_dir/WORK.md" ]; then
    cat "$game_dir/WORK.md"
  else
    echo "(no WORK.md found at $game_dir/WORK.md)"
  fi
  echo
  # Per-item brief (set by overnight_dev.sh — used by Developer for "this is your assignment").
  if [ -n "${SPRAXEL_ITEM_BRIEF:-}" ] && [ -f "$SPRAXEL_ITEM_BRIEF" ]; then
    echo "---"
    cat "$SPRAXEL_ITEM_BRIEF"
    echo
  fi
  echo "---"
  echo "Do your role's work now per the spec above. Tools: Bash, Read, Edit, Write, Grep, Glob."
  echo "Write to files under $game_dir as your spec describes. Print one short status line to stdout."
} > "$log.prompt"

if [ "$dry_run" = "--dry-run" ]; then
  echo "Prompt written to: $log.prompt"
  echo "Would run: claude -p (cwd=$game_dir, log=$log)"
  exit 0
fi

# Per-agent lock (mkdir is atomic on macOS — flock is not available by default).
# If the lockdir already exists, another instance of this agent is in flight.
lock_dir="$LOCKS_DIR/$agent.lockdir"
if ! mkdir "$lock_dir" 2>/dev/null; then
  echo "run_agent: $agent already running (lock: $lock_dir)" >&2
  exit 2
fi
trap 'rmdir "$lock_dir" 2>/dev/null || true' EXIT INT TERM

# Run claude headless. --dangerously-skip-permissions enables Bash/Edit/Write without prompts.
# stdin = composed prompt, stdout/stderr → log.
echo "run_agent: $agent → $log" >&2
cd "$game_dir"
if claude --dangerously-skip-permissions -p < "$log.prompt" > "$log" 2>&1; then
  echo "run_agent: $agent ok" >&2
  exit 0
else
  rc=$?
  echo "run_agent: $agent FAILED (rc=$rc) — see $log" >&2
  exit 1
fi
