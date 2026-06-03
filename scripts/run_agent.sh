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

# Read the spec's model frontmatter field and map to a full Claude model ID.
# Short names (haiku/sonnet/opus) map to the latest 4.x release. A full ID
# (starts with "claude-") passes through unchanged. Missing field = Sonnet.
model_short=$(awk '/^model:/ { sub(/^model:[[:space:]]*/, ""); gsub(/["'"'"']/, ""); print; exit }' "$spec")
case "${model_short:-sonnet}" in
  haiku)  model_id="claude-haiku-4-5-20251001" ;;
  sonnet) model_id="claude-sonnet-4-6"          ;;
  opus)   model_id="claude-opus-4-7"            ;;
  claude-*) model_id="$model_short"             ;;
  *)      echo "run_agent: unknown model '$model_short' in $spec — defaulting to sonnet" >&2
          model_id="claude-sonnet-4-6"          ;;
esac

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

# --- Per-agent lock (mkdir is atomic on macOS — flock not available by default) ---
# When the wrapper passes SPRAXEL_WORK_DIR (parallel-worker mode), use a
# worker-suffixed lockdir so N workers can each have their own developer +
# reviewer agent running in parallel. Otherwise (standalone / crew agent
# invocation), one-at-a-time is the right semantics.
if [ -n "${SPRAXEL_WORK_DIR:-}" ]; then
  worker_suffix=$(basename "$SPRAXEL_WORK_DIR")   # e.g. "worker-1"
  lock_dir="$LOCKS_DIR/$agent-$worker_suffix.lockdir"
else
  lock_dir="$LOCKS_DIR/$agent.lockdir"
fi
# PID-aware acquire (lockutils.sh): self-heals orphan locks left by a
# SIGKILL'd prior invocation. If the lockdir's holder.pid points to a
# dead process, we sweep and reacquire within the next poll cycle.
# Timeout 1s — if a LIVE process holds the lock, this exits rc=2
# (caller treats as "agent already running" — caller is the wrapper's
# ship_one_item, which will retry on the next iteration).
. "$REPO_DIR/scripts/lockutils.sh"
if ! acquire_lock "$lock_dir" 1 0.2; then
  echo "run_agent: $agent already running (lock: $lock_dir)" >&2
  exit 2
fi

# --- Worktree resolution ---
# Crew agents (everything but `developer`) commit to master-only state files
# (WORK.md, .factory/local/MORNING.md, .factory/escalations.md). But when the
# continuous wrapper is mid-ship, the main game-repo checkout is on a feature
# branch, possibly with uncommitted dev work. Switching the main checkout's
# HEAD would race with the wrapper.
#
# Solution: create a temporary git WORKTREE pointing at origin/master, and
# run the crew agent inside it. The main checkout stays on the feat branch,
# untouched. The agent's commits land on master in the worktree and push to
# origin from there. Wrapper picks them up via clean_slate's
# `reset --hard origin/master` at the start of its next iter.
#
# When the main checkout is ALREADY on master (wrapper idle / cap-sleep),
# skip the worktree dance and just operate in $game_dir directly — faster
# and avoids unnecessary disk churn.
WORK_DIR="$game_dir"
WORKTREE_PATH=""
cd "$game_dir"
# If the wrapper passes SPRAXEL_WORK_DIR (e.g., the worker's worktree path),
# operate in that directory directly. The wrapper is responsible for the
# worktree lifecycle in that case; we just inherit.
if [ -n "${SPRAXEL_WORK_DIR:-}" ] && [ -d "$SPRAXEL_WORK_DIR" ]; then
  WORK_DIR="$SPRAXEL_WORK_DIR"
  echo "run_agent: $agent — inheriting WORK_DIR=$SPRAXEL_WORK_DIR from wrapper" >&2
# Otherwise, for crew agents (everything but developer/reviewer), create a
# transient worktree pinned at origin/master so they don't disturb the
# wrapper's feat-branch state.
# - developer: needs the wrapper's feat branch (that's its workspace)
# - reviewer : runs `git diff master...HEAD` on the dev's feat branch;
#              a fresh master worktree would show an empty diff and the
#              reviewer would always say "looks great" (silent failure)
elif [ "$agent" != "developer" ] && [ "$agent" != "reviewer" ]; then
  current_branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
  if [ "$current_branch" != "master" ] && [ -n "$current_branch" ]; then
    WORKTREE_PATH="$REPO_DIR/.worktrees/${agent}-$$"
    mkdir -p "$REPO_DIR/.worktrees"
    # Pull latest origin/master so the worktree starts from the freshest state.
    git fetch --quiet origin master 2>/dev/null
    if ! git worktree add --quiet --detach "$WORKTREE_PATH" origin/master 2>/dev/null; then
      echo "run_agent: $agent — failed to create worktree at $WORKTREE_PATH; deferring" >&2
      rmdir "$lock_dir" 2>/dev/null || true
      exit 5
    fi
    # Detached HEAD at origin/master. Create a local 'master' ref inside the
    # worktree (separate from the main repo's master ref) so commits can go on
    # a named branch + push to origin master via HEAD:master.
    WORK_DIR="$WORKTREE_PATH"
    echo "run_agent: $agent — using worktree $WORKTREE_PATH (main checkout is on $current_branch)" >&2
  fi
fi

# Trap: always release the lockdir + remove worktree on exit.
cleanup() {
  if [ -n "$WORKTREE_PATH" ] && [ -d "$WORKTREE_PATH" ]; then
    # If the agent committed in the worktree, push HEAD to origin/master.
    # The agent's own workflow normally pushes, but this is belt-and-suspenders
    # in case the agent committed but failed to push (network blip, etc).
    git -C "$WORKTREE_PATH" push --quiet origin HEAD:master 2>/dev/null || true
    git -C "$game_dir" worktree remove --force "$WORKTREE_PATH" 2>/dev/null || true
    # Best-effort: also remove any stale parent dir if empty.
    rmdir "$REPO_DIR/.worktrees" 2>/dev/null || true
  fi
  release_lock "$lock_dir"
}
trap cleanup EXIT INT TERM

# --- Compose the prompt (with WORK_DIR-aware paths) ---
# The agent spec is the contract; we append today's state. Code/scene
# paths use WORK_DIR (the worker's worktree). WORK.md operations use
# the CANONICAL WORK_MD_PATH = $game_dir/WORK.md — the main checkout's
# copy. Critical for parallel-dev: N workers all share that one file
# via workmd.py's FileLock, so two devs can't produce conflicting
# WORK.md state on their respective feat branches (which used to lead
# to literal git-merge-conflict markers landing on master).
WORK_MD_PATH="$game_dir/WORK.md"
{
  cat "$spec"
  echo
  echo "---"
  echo "## Today's runtime context"
  echo
  echo "Working directory: $WORK_DIR"
  echo "WORK.md path:      $WORK_MD_PATH  ← USE THIS EXACT PATH for every workmd.py call"
  if [ -n "$WORKTREE_PATH" ]; then
    echo "(NOTE: this is a temporary worktree pinned at origin/master; the main"
    echo " game repo is at $game_dir on a feature branch. Do all your git work"
    echo " from $WORK_DIR. Push with: git push origin HEAD:master)"
  fi
  echo "Date: $(date '+%Y-%m-%d %H:%M %Z')"
  echo
  echo "## CRITICAL: WORK.md path discipline"
  echo "ALL workmd.py invocations (clarify, append, retry, ship, etc.) MUST use the"
  echo "canonical path $WORK_MD_PATH — NOT $WORK_DIR/WORK.md. Reason: with parallel"
  echo "developers, each worker's worktree has its own copy of WORK.md. If devs"
  echo "modify the worktree copy, their feat-branch squash-merges produce git"
  echo "conflicts on WORK.md when landing concurrently on master. Always pointing"
  echo "workmd.py at the main-checkout file ($WORK_MD_PATH) means workmd.py's own"
  echo "FileLock serializes across all workers — no possible conflicts."
  echo
  echo "Examples (CORRECT):"
  echo "  python3 ~/SpraxelAiCompany/scripts/workmd.py clarify $WORK_MD_PATH ..."
  echo "  python3 ~/SpraxelAiCompany/scripts/workmd.py append  $WORK_MD_PATH ..."
  echo
  echo "WRONG (will corrupt WORK.md under parallel-dev):"
  echo "  python3 ~/SpraxelAiCompany/scripts/workmd.py clarify ./WORK.md ..."
  echo "  python3 ~/SpraxelAiCompany/scripts/workmd.py clarify $WORK_DIR/WORK.md ..."
  echo
  echo "### Philosophy.md (run_mode and budgets)"
  if [ -f "$WORK_DIR/Philosophy.md" ]; then
    sed -n '1,80p' "$WORK_DIR/Philosophy.md"
  else
    echo "(no Philosophy.md found at $WORK_DIR/Philosophy.md)"
  fi
  echo
  echo "### WORK.md (current state — read from canonical path)"
  if [ -f "$WORK_MD_PATH" ]; then
    cat "$WORK_MD_PATH"
  else
    echo "(no WORK.md found at $WORK_MD_PATH)"
  fi
  echo
  # Per-item brief (set by continuous_dev.sh — used by Developer for "this is your assignment").
  if [ -n "${SPRAXEL_ITEM_BRIEF:-}" ] && [ -f "$SPRAXEL_ITEM_BRIEF" ]; then
    echo "---"
    cat "$SPRAXEL_ITEM_BRIEF"
    echo
  fi
  echo "---"
  echo "Do your role's work now per the spec above. Tools: Bash, Read, Edit, Write, Grep, Glob."
  echo "Write to files under $WORK_DIR as your spec describes. Print one short status line to stdout."
} > "$log.prompt"

if [ "$dry_run" = "--dry-run" ]; then
  echo "Prompt written to: $log.prompt"
  echo "Would run: claude --model $model_id -p (cwd=$WORK_DIR, log=$log)"
  exit 0
fi

# --- Run claude headless ---
# --dangerously-skip-permissions enables Bash/Edit/Write without prompts.
# stdin = composed prompt, stdout/stderr → log. Model is per-agent (see frontmatter).
# SPRAXEL_AGENT_RUN=1 tells the global SessionStart hook to skip checkin.sh —
# without it, every agent's claude session would touch ceo-checkin.ts and the
# continuous loop would interpret that as a fresh CEO signal after every ship.
cd "$WORK_DIR"

# Retry policy. Crew agents (briefer, pm, triager, designer, …) are
# idempotent + short, and their #1 failure mode is a claude session that
# dies with EMPTY output under concurrency — the 2026-05-28 incident where
# morning_briefer emitted 0 bytes at 05:00 (3 dev claudes + playtester +
# triager all live) and MORNING.md silently went stale for the day, with no
# retry. So crew agents retry a few times with a backoff, AND we treat empty
# output as failure (claude produced nothing = it didn't do the job).
# developer/reviewer are NOT retried here — the continuous wrapper owns their
# retry + stall-detection; double-retrying would fight it.
case "$agent" in
  developer|reviewer) max_attempts=1 ;;
  *)                  max_attempts=3 ;;
esac

# Report safety-net. Every reporting agent SHOULD leave a dated report (see
# _shared.md) so the Morning Briefer's News digest sees its work — but LLM
# compliance is imperfect (2026-05-29 audit: triager/designer/pm/demo_creator
# all ran yet left no report). If a successful run leaves none, we write a
# minimal stub from the agent's log so the run is never invisible. Exempt:
# developer/reviewer (the continuous loop reports per-shipped-item for them)
# and morning_briefer (it's the consumer of reports).
REPORTS_DIR="$game_dir/.factory/local/reports"
case "$agent" in
  developer|reviewer|morning_briefer) self_reports=0 ;;
  *)                                  self_reports=1 ;;
esac
count_reports() { ( ls "$REPORTS_DIR"/*-"$agent".md 2>/dev/null || true ) | wc -l | tr -d ' '; }
reports_before=$(count_reports)

attempt=1
while :; do
  echo "run_agent: $agent ($model_id) attempt $attempt/$max_attempts → $log" >&2
  SPRAXEL_AGENT_RUN=1 WORK_MD_PATH="$WORK_MD_PATH" \
    claude --model "$model_id" --dangerously-skip-permissions -p < "$log.prompt" > "$log" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ] && [ -s "$log" ]; then
    echo "run_agent: $agent ok (attempt $attempt)" >&2
    # Reliable "ran ok" stamp (per agent, NORMALIZED slug so it matches whether
    # the caller used the schedule key "morning_briefer" or the slug
    # "morning-briefer"). catch_up.sh reads this to know an agent already produced
    # today's output — far more robust than grepping the session log (the "ok
    # (attempt" line only goes to the wrapper's stderr).
    mkdir -p "$REPO_DIR/.cache/agent-last-ok"
    : > "$REPO_DIR/.cache/agent-last-ok/$agent_slug.ts"
    if [ "$self_reports" -eq 1 ] && [ "$(count_reports)" = "$reports_before" ]; then
      tailmsg=$( { grep -vE '^[[:space:]]*$' "$log" 2>/dev/null || true; } | tail -1 | cut -c1-160)
      printf '%s\n' \
        "- $agent ran but left no self-report (stub written by the wrapper)." \
        "  Last log line: ${tailmsg:-(no output captured)}" \
        | bash "$REPO_DIR/scripts/report.sh" "$agent" >/dev/null 2>&1 || true
      echo "run_agent: $agent left no report — wrote a stub" >&2
    fi
    # Architect seen-stamp safety-net. The architect is told to `touch` this
    # LAST so tick.sh's reactive TRIAGE-answer trigger doesn't re-wake it on its
    # OWN writes — but LLM agents routinely skip end-of-run housekeeping, leaving
    # the stamp stale and causing redundant reactive re-dispatches. Enforce it
    # here on every successful run so the stamp can never go stale.
    if [ "$agent" = "architect" ]; then
      mkdir -p "$REPO_DIR/.cache"
      touch "$REPO_DIR/.cache/architect-triage-seen.ts"
    fi
    exit 0
  fi
  reason="rc=$rc"
  [ -s "$log" ] || reason="$reason, EMPTY output (claude produced nothing)"
  echo "run_agent: $agent attempt $attempt FAILED ($reason) — see $log" >&2
  if [ "$attempt" -ge "$max_attempts" ]; then
    echo "run_agent: $agent gave up after $attempt attempt(s)" >&2
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep 30   # let transient concurrency / rate pressure ease before retrying
done
