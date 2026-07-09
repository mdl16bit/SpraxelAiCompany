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
AGENTS_DIR="$REPO_DIR/agents"

agent="${1:-}"
shift || true
dry_run=""
game_arg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run="--dry-run"; shift ;;
    --game)    game_arg="${2:-}"; shift 2 ;;
    *)         shift ;;
  esac
done
if [ -z "$agent" ]; then
  echo "usage: $0 <agent-name> [--dry-run] [--game <slug>]" >&2
  exit 4
fi

# Resolve game context (game_dir + per-game state paths) via the shared resolver.
# Honors --game, else $SPRAXEL_GAME, else the sole enabled game. Sets GAME_DIR,
# LOCKS_DIR, CACHE_DIR, GAME_LOGS_DIR, WORKTREES_DIR, GLOBAL_CACHE, PAUSED_FLAG.
if [ -n "$game_arg" ]; then
  . "$REPO_DIR/scripts/gctx.sh" --game "$game_arg"
else
  . "$REPO_DIR/scripts/gctx.sh"
fi
game_dir="$GAME_DIR"
LOGS_DIR="$GAME_LOGS_DIR"

if [ -e "$PAUSED_FLAG" ] && [ "$dry_run" != "--dry-run" ]; then
  # --dry-run is exempt: it only composes the prompt file (no model call, no
  # writes to game state) — useful for verifying prompt size while paused.
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

# Resolve the agent's model from COMPANY_CONFIG.yaml (models.<agent>), which a
# game's GAME_CONFIG.yaml can override. Falls back to the spec's `model:`
# frontmatter (legacy) then Sonnet. Short names (haiku/sonnet/opus) map to the
# latest 4.x release; a full "claude-*" id passes through unchanged.
model_short=$(python3 "$REPO_DIR/scripts/spx_config.py" get "models.$agent" 2>/dev/null)
[ -z "$model_short" ] && model_short=$(awk '/^model:/ { sub(/^model:[[:space:]]*/, ""); gsub(/["'"'"']/, ""); print; exit }' "$spec")
# Map short name → full Claude id via COMPANY_CONFIG models.ids (so a new Claude
# release is a config edit, not a code edit). Built-in defaults are the fallback.
case "$model_short" in
  claude-*) model_id="$model_short" ;;   # already a full id — pass through
  *)
    model_id=$(python3 "$REPO_DIR/scripts/spx_config.py" get "models.ids.${model_short:-sonnet}" 2>/dev/null)
    if [ -z "$model_id" ]; then
      case "${model_short:-sonnet}" in
        haiku)  model_id="claude-haiku-4-5-20251001" ;;
        opus)   model_id="claude-opus-4-8" ;;
        sonnet) model_id="claude-sonnet-4-6" ;;
        *) echo "run_agent: unknown model '$model_short' in $spec — defaulting to sonnet" >&2
           model_id="claude-sonnet-4-6" ;;
      esac
    fi ;;
esac

# --- Sonnet-cap auto-fallback to Opus ---
# If this agent resolves to Sonnet AND the shared sonnet-cap flag is active (a
# prior Sonnet call hit the weekly limit and it hasn't re-probed yet), run on Opus
# instead. The flag self-clears once its reset window passes, so this reverts to
# Sonnet automatically. (Applies to crew + the headless developer in both modes.)
SONNET_ID=$(python3 "$REPO_DIR/scripts/spx_config.py" get models.ids.sonnet 2>/dev/null); SONNET_ID=${SONNET_ID:-claude-sonnet-4-6}
OPUS_ID=$(python3 "$REPO_DIR/scripts/spx_config.py" get models.ids.opus 2>/dev/null); OPUS_ID=${OPUS_ID:-claude-opus-4-8}
if [ "$model_id" = "$SONNET_ID" ] && python3 "$REPO_DIR/scripts/sonnet_cap.py" is-capped; then
  echo "run_agent: Sonnet capped — $agent running on Opus ($OPUS_ID)" >&2
  model_id="$OPUS_ID"
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
    WORKTREE_PATH="$WORKTREES_DIR/${agent}-$$"
    mkdir -p "$WORKTREES_DIR"
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
    rmdir "$WORKTREES_DIR" 2>/dev/null || true
  fi
  release_lock "$lock_dir"
}
# DIAGNOSTIC (2026-06-07): devs complete + commit but run_agent exits rc=143
# (external SIGTERM) and the wrapper bounces them pre-merge — source untraced.
# Log the full process ancestry + timing when a signal arrives, so the killer's
# lineage can be correlated with tick/reaper/wrapper logs. Passive: only fires on
# a signal; cleanup still runs via the EXIT trap; exit code unchanged (143/130).
on_signal() {
  local signum="$1"
  {
    echo "=== $(date '+%F %T') run_agent[$agent] pid=$$ got SIG=$signum attempt=${attempt:-?} claude_pid=${claude_pid:-?} ==="
    local p=$$
    for _ in 1 2 3 4 5 6 7; do
      [ -z "$p" ] || [ "$p" -le 1 ] && break
      ps -o pid=,ppid=,etime=,command= -p "$p" 2>/dev/null | cut -c1-160 | sed 's/^/    /'
      p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    done
  } >> "$REPO_DIR/logs/signal-debug.log" 2>&1
  exit $((128 + signum))   # triggers the EXIT trap → cleanup
}
trap 'on_signal 15' TERM
trap 'on_signal 2' INT
trap cleanup EXIT

# --- Compose the prompt (with WORK_DIR-aware paths) ---
# The agent spec is the contract; we append today's state. Code/scene
# paths use WORK_DIR (the worker's worktree). WORK.md operations use
# the CANONICAL WORK_MD_PATH = $game_dir/WORK.md — the main checkout's
# copy. Critical for parallel-dev: N workers all share that one file
# via workmd.py's FileLock, so two devs can't produce conflicting
# WORK.md state on their respective feat branches (which used to lead
# to literal git-merge-conflict markers landing on master).
WORK_MD_PATH="$game_dir/WORK.md"

# Byte-capped WORK.md section renderer. NEVER embed an unbounded section:
# 2026-06-13→07-08 the un-cut "Finished since last release" section grew to
# 373KB, every crew prompt blew the model input limit ("Prompt is too long"),
# and the whole scheduled crew was dead for 2+ weeks. Sections are rendered
# via workmd.py (fallback: raw file) and hard-truncated at a byte cap with a
# pointer so the agent can pull the rest on demand.
emit_workmd_capped() {
  local sections="$1" cap="$2" tmp
  tmp=$(mktemp)
  if [ -f "$WORK_MD_PATH" ]; then
    python3 "$REPO_DIR/scripts/workmd.py" render "$WORK_MD_PATH" --sections "$sections" >"$tmp" 2>/dev/null \
      || cat "$WORK_MD_PATH" >"$tmp"
  else
    echo "(no WORK.md found at $WORK_MD_PATH)" >"$tmp"
  fi
  if [ "$(wc -c <"$tmp")" -gt "$cap" ]; then
    head -c "$cap" "$tmp"
    echo
    echo "[... TRUNCATED — WORK.md section(s) '$sections' exceed the $((cap/1024))KB prompt budget."
    echo "Pull more ONLY if your task needs it: python3 ~/SpraxelAiCompany/scripts/workmd.py top $WORK_MD_PATH -n 30"
    echo "or: python3 ~/SpraxelAiCompany/scripts/workmd.py render $WORK_MD_PATH --sections $sections ]"
  else
    cat "$tmp"
  fi
  rm -f "$tmp"
}

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
  # ── Delegate-all banner ─────────────────────────────────────────────────
  # When policy.delegate_all is true, make the full-autonomy mandate impossible
  # to miss — agents also read it from _shared.md, but injecting it here keeps it
  # in the live context even if the spec section is skimmed.
  _delegate_all=$(python3 "$REPO_DIR/scripts/spx_config.py" get policy.delegate_all 2>/dev/null)
  case "$_delegate_all" in
    true|True|TRUE|1|yes|on)
      echo "## ⚙️  DELEGATE-ALL MODE ACTIVE — full autonomy, NO CEO"
      echo "There is no CEO to ask, wait on, or escalate to. You finalize every"
      echo "decision yourself. Specifically:"
      echo "- NEVER tag [needs-ceo], [idea], [concern], [escalated], or write a"
      echo "  TRIAGE.md questionnaire and wait. Make the call you'd recommend and proceed."
      echo "- NEVER file [manual] items. Generate PLACEHOLDER assets (rects, tones,"
      echo "  lorem copy, simple layouts) so the feature ships fully working."
      echo "- Treat designer concerns as legitimate; auto-shape/fix rather than defer."
      echo "- Do NOT escalate blocked items — leave them to the wrapper's retry/[cold] path."
      echo "- Work is UNCAPPED and runs forever; the only stops are the spend ceiling"
      echo "  (daily_run_cap) and the CEO's manual .paused. See _shared.md → DELEGATE-ALL MODE."
      echo
      ;;
  esac
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
  echo "### Philosophy.md (design philosophy)"
  # Philosophy.md is now prose-only (config moved to COMPANY_CONFIG.yaml /
  # GAME_CONFIG.yaml). run_mode + budgets come from scripts/spx_config.py.
  if [ -f "$WORK_DIR/Philosophy.md" ]; then
    head -c 32768 "$WORK_DIR/Philosophy.md"   # prose-only; cap defends against regrowth
  else
    echo "(no Philosophy.md found at $WORK_DIR/Philosophy.md)"
  fi
  echo
  # ── Context diet (cost + prompt-size safety) ─────────────────────────
  # Every tier is BYTE-CAPPED via emit_workmd_capped — no section is ever
  # embedded unbounded (see the 2026-07-08 incident note on the helper).
  # Three tiers:
  #   developer/reviewer            → ## Todo only (don't need shipped history;
  #                                    dev gets its item via SPRAXEL_ITEM_BRIEF,
  #                                    reviewer reads the git diff). ~80% of runs.
  #   architect/designer/triager/   → current + Todo (recent "Shipped since last
  #     morning_briefer               release" for dedup/context).
  #   everyone else (pm/janitor/…)  → current + Todo as well. The old "Shipped
  #                                    (previous releases)" history lives in
  #                                    per-release WORK_v*.md archives + release
  #                                    notes — PM/janitor read those on demand.
  case "$agent" in
    developer|reviewer)
      echo "### WORK.md — ## Todo only (Shipped archive omitted to save tokens)"
      echo "# Need shipped history? Run: python3 ~/SpraxelAiCompany/scripts/workmd.py render $WORK_MD_PATH --sections current,todo   (or: git log)"
      emit_workmd_capped todo 40960
      ;;
    architect|designer|triager|morning_briefer)
      echo "### WORK.md — ## Shipped-since-last-release + ## Todo (older releases archive omitted to save tokens)"
      echo "# Need the full archive? Run: python3 ~/SpraxelAiCompany/scripts/workmd.py render $WORK_MD_PATH --sections shipped,current,todo   (or: git log)"
      emit_workmd_capped current,todo 81920
      ;;
    *)
      echo "### WORK.md — current release + Todo (previous-release history lives in WORK_v*.md archives + .factory/releases/*.md — read on demand)"
      emit_workmd_capped current,todo 81920
      ;;
  esac
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

# ── Prompt-size guard ────────────────────────────────────────────────
# Last line of defense: the caps above should keep prompts far below this,
# but if the assembled prompt still exceeds PROMPT_MAX_BYTES (spec bloat,
# giant Philosophy, oversized item brief), rebuild a MINIMAL prompt instead
# of sending a doomed "Prompt is too long" request.
PROMPT_MAX_BYTES=153600   # 150KB ≈ ~40K tokens
_psize=$(wc -c < "$log.prompt")
if [ "$_psize" -gt "$PROMPT_MAX_BYTES" ]; then
  echo "run_agent: $agent prompt ${_psize}B > ${PROMPT_MAX_BYTES}B — degrading to minimal context" >&2
  {
    cat "$spec"
    echo
    echo "---"
    echo "## Today's runtime context (MINIMAL — normal embedded context exceeded the prompt budget: ${_psize} bytes)"
    echo
    echo "Working directory: $WORK_DIR"
    echo "WORK.md path:      $WORK_MD_PATH  ← USE THIS EXACT PATH for every workmd.py call"
    echo "Date: $(date '+%Y-%m-%d %H:%M %Z')"
    case "$_delegate_all" in true|True|TRUE|1|yes|on)
      echo "DELEGATE-ALL MODE ACTIVE — no CEO; decide yourself, never tag [needs-ceo]/[escalated] (see _shared.md)." ;;
    esac
    echo
    echo "⚠ Philosophy.md + WORK.md sections were OMITTED (size). Read on demand:"
    echo "  python3 ~/SpraxelAiCompany/scripts/workmd.py top $WORK_MD_PATH -n 30"
    echo "  cat $WORK_DIR/Philosophy.md"
    if [ -n "${SPRAXEL_ITEM_BRIEF:-}" ] && [ -f "$SPRAXEL_ITEM_BRIEF" ]; then
      echo
      echo "---"
      cat "$SPRAXEL_ITEM_BRIEF"
    fi
    echo
    echo "---"
    echo "Do your role's work now per the spec above. Tools: Bash, Read, Edit, Write, Grep, Glob."
    echo "Write to files under $WORK_DIR as your spec describes. Print one short status line to stdout."
  } > "$log.prompt"
fi

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
  developer|reviewer) max_attempts=$(python3 "$REPO_DIR/scripts/spx_config.py" get agent_retry.lone_attempt 2>/dev/null);  max_attempts=${max_attempts:-1} ;;
  *)                  max_attempts=$(python3 "$REPO_DIR/scripts/spx_config.py" get agent_retry.crew_attempts 2>/dev/null); max_attempts=${max_attempts:-3} ;;
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

# NOTE (2026-06-07): a per-attempt background watchdog was tried here but
# REVERTED — backgrounding the `claude` call correlated with 0-byte dev logs +
# rc=143 kills (every dev build dying ~2-5 min with no output). Restored the
# original FOREGROUND invocation. Hang protection now comes from the lock reaper
# (reap_hung_agents.sh, run each tick) instead of an in-run_agent watchdog.
RUN_START_EPOCH=$(date +%s)   # freshness bar for the post-run compliance check
attempt=1
while :; do
  echo "run_agent: $agent ($model_id) attempt $attempt/$max_attempts → $log" >&2
  SPRAXEL_AGENT_RUN=1 WORK_MD_PATH="$WORK_MD_PATH" \
    claude --model "$model_id" --dangerously-skip-permissions -p < "$log.prompt" > "$log" 2>&1
  rc=$?
  # Sonnet-cap auto-fallback: if we ran Sonnet and the reply is a usage-cap refusal,
  # arm the shared flag (every agent now falls back) and retry THIS run on Opus —
  # WITHOUT burning a real attempt. Automates the old manual "flip dev/architect to
  # opus to unblock" workaround; ends the retry-storm-on-75-byte-logs failure mode.
  if [ "$model_id" = "$SONNET_ID" ] && python3 "$REPO_DIR/scripts/sonnet_cap.py" detect "$log"; then
    echo "run_agent: Sonnet cap detected — switching $agent to Opus ($OPUS_ID) and retrying" >&2
    model_id="$OPUS_ID"
    continue
  fi
  # ── Fatal-response gate ────────────────────────────────────────────
  # Some responses are deterministic failures dressed as success (rc=0 +
  # non-empty output): "Prompt is too long" is the canonical one — it counted
  # as a SUCCESSFUL run for 2 weeks (2026-06-24→07-08), stamping agent-last-ok
  # and silencing catch_up while the whole crew did nothing. Retrying the
  # identical prompt can't help; escalate loudly and stop.
  if [ -s "$log" ] && [ "$(wc -c < "$log")" -lt 2048 ] \
     && grep -qiE '^(Prompt is too long|Invalid API key|Credit balance is too low|OAuth token (has expired|revoked))' "$log"; then
    fatal_msg=$(head -c 160 "$log" | tr '\n' ' ')
    echo "run_agent: $agent FATAL response ('$fatal_msg') — not retrying" >&2
    esc="$game_dir/.factory/escalations.md"
    {
      echo "- ⚠ $(date '+%Y-%m-%d %H:%M %Z') run_agent: **$agent run is FATALLY broken** — model replied: \"$fatal_msg\"."
      echo "  Deterministic failure (retries won't help). Log: $log  Prompt: $log.prompt ($(wc -c < "$log.prompt") bytes)."
    } >> "$esc" 2>/dev/null || true
    printf '%s\n' \
      "- ⚠ $agent run FAILED fatally: \"$fatal_msg\" — needs CEO/operator attention (see $log)." \
      | bash "$REPO_DIR/scripts/report.sh" "$agent" >/dev/null 2>&1 || true
    exit 1
  fi
  if [ "$rc" -eq 0 ] && [ -s "$log" ]; then
    echo "run_agent: $agent ok (attempt $attempt)" >&2
    # Reliable "ran ok" stamp (per agent, NORMALIZED slug so it matches whether
    # the caller used the schedule key "morning_briefer" or the slug
    # "morning-briefer"). catch_up.sh reads this to know an agent already produced
    # today's output — far more robust than grepping the session log (the "ok
    # (attempt" line only goes to the wrapper's stderr).
    mkdir -p "$CACHE_DIR/agent-last-ok"
    : > "$CACHE_DIR/agent-last-ok/$agent_slug.ts"
    # ── Post-run compliance verification ──────────────────────────────
    # 2026-07 incident: the blogger's logs claimed "memory updated at
    # .factory/memory/blogger.md" for weeks while that file never existed.
    # Verify the spec's required artifact was actually TOUCHED this run
    # (mtime >= run start, checked in $WORK_DIR — the agent's real cwd).
    # A miss stays exit-0 (re-running LLM non-compliance doesn't help) but
    # writes a loud ⚠ report the Briefer surfaces in 📰 News.
    if ! grep -qiE 'not scheduled today|run_mode=dryrun' "$log"; then
      _expected=""
      case "$agent" in
        blogger)          _expected=".factory/memory/blogger.md" ;;
        playtester)       _expected=".factory/memory/playtester.md" ;;
        demo_creator)     _expected=".factory/memory/demo-creator.md" ;;
        pm)               _expected=".factory/memory/pm.md" ;;
        designer)         _expected=".factory/memory/designer.md" ;;
        triager)          _expected=".factory/memory/triager.md" ;;
        morning_briefer)  _expected=".factory/local/MORNING.md" ;;
      esac
      _missed=""
      for _e in $_expected; do
        _f="$WORK_DIR/$_e"
        if [ ! -f "$_f" ] || [ "$(stat -f %m "$_f" 2>/dev/null || echo 0)" -lt "$RUN_START_EPOCH" ]; then
          _missed="$_missed $_e"
        fi
      done
      if [ -n "$_missed" ]; then
        echo "run_agent: ⚠ compliance — $agent succeeded but did not touch:$_missed" >&2
        printf '%s\n' \
          "- ⚠ compliance: $agent claimed success but its required artifact(s) went untouched this run:$_missed — treat the run's claims skeptically (log: $log)." \
          | bash "$REPO_DIR/scripts/report.sh" "$agent" >/dev/null 2>&1 || true
      fi
    fi
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
      mkdir -p "$CACHE_DIR"
      touch "$CACHE_DIR/architect-triage-seen.ts"
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
  _bk=$(python3 "$REPO_DIR/scripts/spx_config.py" get agent_retry.backoff_secs 2>/dev/null)
  sleep "${_bk:-30}"   # backoff between attempts (agent_retry.backoff_secs)
done
