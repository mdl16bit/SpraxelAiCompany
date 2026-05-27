#!/usr/bin/env bash
# continuous_dev.sh — long-running Developer loop.
#
# Contract: there should ALWAYS be N completed items waiting for the CEO to
# review. The system ships items as fast as Claude + tests will allow, until
# N have shipped since the last CEO interaction. Then it sleeps. Any CEO
# interaction (a non-bot commit, a manual checkin, etc.) resets the counter.
#
# This script is started by tick.sh if it's not already running. It self-
# restarts via the same path if it crashes. Survives Mac sleep (continues
# when the Mac wakes).
#
# Behavior:
#   - Picks the top eligible item from WORK.md ## Todo.
#   - Branches, runs Developer, runs tests, runs Reviewer, merges to master.
#   - On success: increments shipped-since-last-signal counter.
#   - When counter >= target_per_batch: sleeps in 60s ticks, looking for a
#     CEO signal (a non-bot commit or .cache/ceo-checkin.ts touch).
#   - On CEO signal: resets counter to 0, immediately starts shipping again.
#
# Pause:  touch ~/SpraxelAiCompany/.paused   → loop sleeps until .paused gone.
# Force-checkin:  bash scripts/checkin.sh    → resets counter immediately.

set -o pipefail

# --- arg parsing ---
WORKER_ID=1
while [ $# -gt 0 ]; do
  case "$1" in
    --worker-id) WORKER_ID="$2"; shift 2 ;;
    --worker-id=*) WORKER_ID="${1#*=}"; shift ;;
    *) echo "continuous_dev: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEDULE="$REPO_DIR/schedule.yaml"
RUN_AGENT="$REPO_DIR/scripts/run_agent.sh"
WORKMD="$REPO_DIR/scripts/workmd.py"
SLUGIFY="$REPO_DIR/scripts/slugify.py"
PAUSED_FLAG="$REPO_DIR/.paused"
LOCKS_DIR="$REPO_DIR/.locks"
CACHE_DIR="$REPO_DIR/.cache"
# Cap counter is SHARED across all parallel-dev workers — one batch of N
# ships drains the counter for everyone. last_signal_* / last_ts likewise.
STATE_FILE="$CACHE_DIR/continuous-state.json"
CHECKIN_FILE="$CACHE_DIR/ceo-checkin.ts"
mkdir -p "$LOCKS_DIR" "$CACHE_DIR"

# Startup trace — overwritten each spawn. If the wrapper dies before
# reaching the main loop (e.g., env issue under launchd), this file shows
# the last step it survived. Diagnostic for the launchd-spawn-died-silently
# class of bugs (see 2026-05-26 12:00 PT incident).
TRACE_FILE="$CACHE_DIR/continuous-startup-trace.log"
trace() { echo "$(date '+%Y-%m-%d %H:%M:%S %Z')  $*" >> "$TRACE_FILE"; }
# Truncate at start so old traces don't accumulate.
{
  echo "=== spawn pid=$$ at $(date '+%Y-%m-%d %H:%M:%S %Z') ==="
  echo "  parent_pid=$PPID"
  echo "  PATH=$PATH"
  echo "  HOME=${HOME:-UNSET}"
  echo "  USER=${USER:-UNSET}"
  echo "  LOGNAME=${LOGNAME:-UNSET}"
  echo "  TERM=${TERM:-UNSET}"
  echo "  SHELL=${SHELL:-UNSET}"
  echo "  TZ=${TZ:-UNSET}"
  echo "  PWD=$(pwd)"
  echo "  argv0=${BASH_SOURCE[0]}"
} > "$TRACE_FILE"
trace "step: starting"

# --- per-worker single-instance lock ---
# Each worker has its own lockdir so 3 workers can coexist. tick.sh sweeps
# stale lockdirs for workers whose pid is no longer running.
LOCK="$LOCKS_DIR/continuous-w$WORKER_ID.lockdir"
if ! mkdir "$LOCK" 2>/dev/null; then
  trace "step: exit 0 (lockdir already held — another instance of worker $WORKER_ID running)"
  exit 0   # another instance of THIS worker is running
fi
## Cleanup on wrapper exit: kill ALL direct children (run_local_tests.sh,
## run_agent.sh, any sleep in the main loop), then release the lockdir.
## Without the child-kill, a wrapper that dies (SIGKILL, crash, normal exit)
## leaves its run_local_tests.sh + their godot grandchildren reparented to
## launchd — orphan zombies eating resources + holding the test lockdir
## (2026-05-27 incident — orphan run_local_tests.sh from a prior wrapper
## generation held the test lock for 30 min, blocking all 3 workers).
##
## pkill -P $$ targets only direct children (the same process group as
## this script). Each child's own EXIT trap then propagates the kill
## deeper (run_local_tests.sh kills its godot via the run_bounded killer
## subshell + EXIT trap; run_agent.sh kills its claude session via
## SIGTERM handler).
trap 'pkill -P $$ 2>/dev/null; sleep 0.2; rmdir "$LOCK" 2>/dev/null' EXIT INT TERM
trace "step: lock acquired for worker $WORKER_ID"

# Resolve game_dir + target.
game_dir=$(python3 - "$SCHEDULE" <<'PY'
import sys, os, re
with open(sys.argv[1]) as f:
    for line in f:
        m = re.match(r"\s*game_dir:\s*(\S+)", line)
        if m:
            print(os.path.expanduser(m.group(1))); break
PY
)
trace "step: game_dir parsed: '$game_dir'"
# Read all continuous.* knobs from schedule.yaml in one pass, with defaults.
# Emits "KEY=VAL" lines we eval'd into shell vars below.
_continuous_yaml_vars=$(python3 - "$SCHEDULE" <<'PY'
import sys, re
defaults = {
    "target_per_batch":       10,
    "retry_per_item":          1,
    "dev_concurrency":         1,
    "max_fail_streak":         3,
    "fail_backoff_seconds":    1800,
    "poll_interval_seconds":   60,
    "idle_threshold":          5,
    "idle_sleep_seconds":      300,
    "max_dev_minutes":         30,
}
try:
    text = open(sys.argv[1]).read()
except Exception:
    text = ""
# Pull the continuous: block — up to the next top-level (non-indented) key.
# Allow blank lines + comment lines inside the block (previous regex
# stopped at the first blank line, silently dropping every knob defined
# after that — including dev_concurrency).
m = re.search(r"^continuous:\s*\n((?:(?:[ \t]+.*)?\n)*?)(?=^\S|\Z)", text, re.M)
block = m.group(1) if m else ""
# Also accept the legacy `overnight.target_items` as a fallback for target_per_batch.
if not re.search(r"^\s+target_per_batch:", block, re.M):
    om = re.search(r"^overnight:\s*\n((?:(?:[ \t]+.*)?\n)*?)(?=^\S|\Z)", text, re.M)
    if om:
        mm = re.search(r"\s*target_items:\s*(\d+)", om.group(1))
        if mm:
            defaults["target_per_batch"] = int(mm.group(1))
for key, default in defaults.items():
    mm = re.search(rf"^\s+{re.escape(key)}:\s*(\d+)", block, re.M)
    val = int(mm.group(1)) if mm else default
    print(f"{key.upper()}={val}")
PY
)
eval "$_continuous_yaml_vars"
unset _continuous_yaml_vars
# Map UPPER_CASE → existing var names + new shell vars used by the main loop.
target_per_batch=$TARGET_PER_BATCH
trace "step: target_per_batch=$target_per_batch dev_concurrency=$DEV_CONCURRENCY max_fail_streak=$MAX_FAIL_STREAK fail_backoff=${FAIL_BACKOFF_SECONDS}s poll=${POLL_INTERVAL_SECONDS}s idle=${IDLE_THRESHOLD}*${IDLE_SLEEP_SECONDS}s"
if [ -z "$game_dir" ] || [ ! -d "$game_dir" ]; then
  trace "step: FATAL — game_dir not resolvable ('$game_dir')"
  echo "continuous: game_dir not resolvable — abort"
  exit 1
fi
trace "step: game_dir validated"

# --- per-worker worktree setup ---
# Each parallel worker operates inside its own dedicated worktree so 3
# workers can be on 3 different feat branches simultaneously without
# fighting over the main checkout's HEAD. The worktree is persistent —
# created on first use, reused across iterations (faster than recreating).
# Worker's HEAD is detached on origin/master between items; per-item the
# worker creates a feat branch in its worktree.
WORK_DIR="$REPO_DIR/.worktrees/worker-$WORKER_ID"
if [ ! -d "$WORK_DIR" ]; then
  trace "step: creating worker worktree at $WORK_DIR"
  mkdir -p "$REPO_DIR/.worktrees"
  cd "$game_dir"
  git fetch --quiet origin master 2>/dev/null
  if ! git worktree add --quiet --detach "$WORK_DIR" origin/master 2>/dev/null; then
    trace "step: FATAL — failed to create worktree at $WORK_DIR"
    echo "continuous: failed to create worktree for worker $WORKER_ID at $WORK_DIR" >&2
    exit 1
  fi
  trace "step: worktree created"
fi
trace "step: worktree ready at $WORK_DIR"

# On startup, release any orphaned [wip:$WORKER_ID] claims from a prior
# crash so the worker doesn't deadlock on its own claim tag.
python3 "$WORKMD" release-wip "$game_dir/WORK.md" --worker-id "$WORKER_ID" \
  >> "$TRACE_FILE" 2>&1 || true

# --- state helpers ---
init_state_if_missing() {
  if [ ! -f "$STATE_FILE" ]; then
    cat > "$STATE_FILE" <<EOF
{
  "shipped_since_last_signal": 0,
  "last_signal_sha": "$(git -C "$game_dir" rev-parse master 2>/dev/null || echo '')",
  "last_signal_ts": "$(date '+%Y-%m-%d %H:%M:%S %Z')",
  "last_ts": "$(date '+%Y-%m-%d %H:%M:%S %Z')"
}
EOF
  fi
}
read_state() {
  python3 -c "import json,sys; print(json.load(open('$STATE_FILE'))['$1'])"
}
write_state() {
  python3 - <<PY
import json
s = json.load(open('$STATE_FILE'))
s['$1'] = '$2' if not '$2'.isdigit() else int('$2')
s['last_ts'] = '$(date '+%Y-%m-%d %H:%M:%S %Z')'
json.dump(s, open('$STATE_FILE','w'), indent=2)
PY
}
# Atomic read-modify-write +1 for parallel-dev: lockdir guards against
# concurrent workers losing increments. Prints the NEW value to stdout.
inc_state() {
  python3 - <<PY
import json, os, time
state_file = '$STATE_FILE'
key = '$1'
lock = state_file + '.lockdir'
deadline = time.time() + 10
while True:
    try:
        os.mkdir(lock)
        break
    except FileExistsError:
        if time.time() > deadline:
            raise SystemExit(2)
        time.sleep(0.05)
try:
    s = json.load(open(state_file))
    s[key] = int(s.get(key, 0)) + 1
    s['last_ts'] = '$(date '+%Y-%m-%d %H:%M:%S %Z')'
    json.dump(s, open(state_file, 'w'), indent=2)
    print(s[key])
finally:
    try: os.rmdir(lock)
    except FileNotFoundError: pass
PY
}

# --- CEO signal detection ---
# Returns 0 if a CEO signal has happened since last_signal_sha:
#   - a master commit by an author whose email doesn't match *-bot@spraxel.ai
#   - OR the manual checkin file has been touched since last_signal_ts
# Returns 1 if no signal.
ceo_signaled() {
  local last_sha last_ts
  last_sha=$(read_state last_signal_sha)
  last_ts=$(read_state last_signal_ts)
  # Manual checkin: any touch newer than last_signal_ts.
  if [ -f "$CHECKIN_FILE" ]; then
    local checkin_epoch state_epoch
    checkin_epoch=$(stat -f '%m' "$CHECKIN_FILE" 2>/dev/null || echo 0)
    state_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S %Z" "$last_ts" +%s 2>/dev/null || echo 0)
    [ "$checkin_epoch" -gt "$state_epoch" ] && return 0
  fi
  # Git commits by non-bot authors since last_sha.
  cd "$game_dir" || return 1
  if [ -n "$last_sha" ] && git rev-parse --verify --quiet "$last_sha" >/dev/null; then
    local non_bot_commits
    non_bot_commits=$(git log --format='%ae' "${last_sha}..master" 2>/dev/null | grep -v -E '\-bot@spraxel\.ai$' | head -1)
    [ -n "$non_bot_commits" ] && return 0
  fi
  return 1
}

# Reset counter, advance the watermark to current master HEAD.
record_ceo_signal() {
  cd "$game_dir" || return
  local now_sha now_ts
  now_sha=$(git rev-parse master 2>/dev/null || echo '')
  now_ts=$(date '+%Y-%m-%d %H:%M:%S %Z')
  python3 - <<PY
import json
s = json.load(open('$STATE_FILE'))
s['shipped_since_last_signal'] = 0
s['last_signal_sha'] = '$now_sha'
s['last_signal_ts'] = '$now_ts'
s['last_ts'] = '$now_ts'
json.dump(s, open('$STATE_FILE','w'), indent=2)
PY
  echo "continuous: ceo signal detected — counter reset"
}

# Force the game repo back to a clean master synced with origin. Called at
# the start of every iteration AND before recording an escalation, so a
# single bad item can't silently corrupt the next item or block its own
# escalation from being recorded. Returns 0 if HEAD ends up on clean
# master, 1 otherwise (the only way that fails is a genuinely broken repo
# — disk full, lock held by another process, etc.).
clean_slate() {
  cd "$WORK_DIR" || return 1
  # Abort any in-progress merge/rebase/cherry-pick.
  git merge --abort 2>/dev/null
  git rebase --abort 2>/dev/null
  git cherry-pick --abort 2>/dev/null
  # Drop leftover baseline-test-stash entries from prior failed runs.
  while git stash list 2>/dev/null | grep -q "baseline-test-stash"; do
    git stash drop 2>/dev/null || break
  done
  # Discard any staged / unstaged changes from a wrecked iteration.
  git reset --hard HEAD --quiet 2>/dev/null
  # Worker worktree uses DETACHED HEAD on origin/master between items — never
  # `git checkout master`, because the main checkout (or another worker)
  # may hold master. Detached HEAD avoids the worktree-branch-conflict.
  git fetch --quiet origin master 2>/dev/null
  if ! git checkout --detach origin/master --quiet 2>/dev/null; then
    return 1
  fi
  git reset --hard origin/master --quiet 2>/dev/null
  # Delete any stale local feat/cont-* branches in this worktree (left over
  # from successful ships — the squash-commit lives on origin/master now).
  for b in $(git branch --list 'feat/cont-*' --format='%(refname:short)' 2>/dev/null); do
    git branch -D "$b" --quiet 2>/dev/null || true
  done
  return 0
}

# --- the per-item ship logic ---
# Returns 0 on successful ship, 1 on failure, 2 on clarify-only (don't count).
ship_one_item() {
  local LOG_DIR="$REPO_DIR/logs/continuous/$(date +%Y-%m-%d)"
  mkdir -p "$LOG_DIR"
  cd "$WORK_DIR" || return 1
  # Pass our worktree path to any child run_agent.sh calls — the dev +
  # reviewer agents inherit this WORK_DIR instead of doing their own
  # worktree creation.
  export SPRAXEL_WORK_DIR="$WORK_DIR"

  # Self-heal: previous iteration may have left a conflicted index, an
  # in-progress merge, a stale stash, or HEAD on a feature branch. Without
  # this, the next item silently runs on the wrong branch / poisoned tree.
  if ! clean_slate; then
    echo "continuous: clean_slate FAILED at iter start — abort"
    return 1
  fi

  # Regenerate escalations.md from current [escalated] items in WORK.md.
  # Idempotent: if the CEO cleared escalations.md without retagging items,
  # the file reappears here on every iter — there's no way to make an
  # [escalated] item silently vanish except by editing WORK.md.
  python3 "$WORKMD" sync-escalations "$game_dir/WORK.md" \
    --escalations "$game_dir/.factory/escalations.md" \
    >> "$LOG_DIR/sync.log" 2>&1 || true

  # Atomically claim the next eligible item — tags it [wip:$WORKER_ID] so
  # other parallel workers don't grab the same one. Returns full JSON
  # (the title here INCLUDES the [wip:N] prefix workmd.py added).
  #
  # CRITICAL: must run UNDER the master-push lock + commit+push the [wip:N]
  # tag immediately. Otherwise the claim sits uncommitted on disk and a
  # CONCURRENT merge subshell's `git reset --hard origin/master` wipes the
  # tag (2026-05-27 incident — two workers claimed the same item because
  # one's claim got wiped by another's reset).
  local next_json next_title slug branch item_log
  local claim_lock="$LOCKS_DIR/master-push.lockdir"
  local claim_wait=0
  while ! mkdir "$claim_lock" 2>/dev/null; do
    sleep 0.3
    claim_wait=$((claim_wait + 1))
    if [ $claim_wait -gt 200 ]; then
      echo "continuous: worker $WORKER_ID — claim-lock held >60s, aborting" >&2
      return 3
    fi
  done
  # Subshell with EXIT trap releases the lock no matter what.
  next_json=$(
    trap 'rmdir "'"$claim_lock"'" 2>/dev/null' EXIT
    cd "$game_dir" || exit 1
    git fetch --quiet origin master 2>/dev/null
    git checkout --quiet master 2>/dev/null || exit 1
    git reset --hard origin/master --quiet 2>/dev/null
    # Now in sync with origin/master. Claim atomically + commit immediately.
    json=$(python3 "$WORKMD" claim "$game_dir/WORK.md" --worker-id "$WORKER_ID" 2>/dev/null)
    if [ -z "$json" ]; then
      exit 3  # no eligible items
    fi
    # Commit + push the [wip:N] tag so other workers see it persisted.
    # Git noise to /dev/null so $json (printed below) is the only stdout.
    git add WORK.md 2>/dev/null
    if ! git diff --cached --quiet; then
      if ! git -c user.email=continuous-bot@spraxel.ai -c user.name='Spraxel Continuous' \
              commit --quiet -m "chore(claim): w$WORKER_ID" 2>/dev/null >/dev/null \
         || ! git push --quiet origin master 2>/dev/null >/dev/null; then
        # Push race lost. Revert the local write (workmd.py applied [wip:N]
        # to a stale state). Re-loop will retry.
        git reset --hard origin/master --quiet 2>/dev/null >/dev/null
        exit 4
      fi
    fi
    printf '%s' "$json"
  )
  local claim_rc=$?
  # The subshell removes the lockdir via its trap, but in case of weird exit
  # paths (e.g., kill during the subshell), best-effort cleanup. Race-safe
  # because the trap inside also tries rmdir.
  rmdir "$claim_lock" 2>/dev/null || true
  if [ "$claim_rc" -eq 3 ] || [ -z "$next_json" ]; then
    echo "continuous: worker $WORKER_ID — no eligible items in WORK.md ## Todo"
    return 3
  fi
  if [ "$claim_rc" -eq 4 ]; then
    echo "continuous: worker $WORKER_ID — claim lost push race, will retry next iter"
    return 3
  fi
  next_title=$(echo "$next_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['title'])" 2>/dev/null)
  if [ -z "$next_title" ]; then
    echo "continuous: worker $WORKER_ID — claim returned malformed json"
    return 3
  fi
  # Strip the [wip:N] claim tag from $next_title immediately. The actual
  # WORK.md item still carries [wip:N] (so other workers see it as
  # claimed); ship()/retry()/unclaim() strip it on their own when they
  # mutate the item. Everywhere downstream — commit subjects, log lines,
  # branch names, find_item substring matches — should use the clean
  # form. [wip:N] is an internal locking detail, never user-facing.
  next_title=$(echo "$next_title" | sed -E 's/^\[wip:[0-9]+\]\s*//')

  slug=$(echo "$next_title" | python3 "$SLUGIFY")
  item_log="$LOG_DIR/w${WORKER_ID}-${slug}.log"

  # ── Resume / Retry path ───────────────────────────────────────────────────
  # If the item is tagged [resume] OR [retry], the dev's prior attempt left
  # a saved branch on origin. Extract the branch name from the item's details
  # (looking for a "branch: <name>" line), check it out, and rebase onto
  # current master so the dev picks up where it left off on an up-to-date base.
  #   - [resume]: CEO triaged a manually-set [escalated] item.
  #   - [retry] : wrapper auto-bounced the item after a tests/reviewer/merge
  #               failure on the prior attempt; the dev sees the feedback in
  #               the item details and tries again.
  local is_resume="false"
  local resume_kind=""   # "resume" or "retry" — drives the prompt suffix
  local saved_branch=""
  if echo "$next_title" | grep -qiE '^\[resume\]'; then
    is_resume="true"
    resume_kind="resume"
  elif echo "$next_title" | grep -qiE '^\[retry\]'; then
    is_resume="true"
    resume_kind="retry"
  fi
  if [ "$is_resume" = "true" ]; then
    saved_branch=$(echo "$next_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
# claim returns a single item dict; defend against legacy list shape too.
it = d[0] if isinstance(d, list) and d else d
if it:
    for det in it.get('details', []):
        det = det.strip()
        if det.lower().startswith('branch:'):
            print(det.split(':', 1)[1].strip())
            break
")
  fi

  if [ "$is_resume" = "true" ] && [ -n "$saved_branch" ]; then
    branch="$saved_branch"
    echo "continuous: ↻ resuming '$next_title' on $branch"
    # Fetch the saved branch from origin and check it out locally.
    if ! git fetch --quiet origin "$branch" 2>/dev/null; then
      echo "continuous: resume FAILED — branch '$branch' missing on origin. Falling back to fresh start." >&2
      branch="feat/cont-$(date +%Y%m%d-%H%M)-$slug"
      git checkout --quiet -B "$branch" origin/master
      is_resume="false"
    else
      if ! git checkout --quiet -B "$branch" "origin/$branch" 2>/dev/null; then
        echo "continuous: resume FAILED — could not checkout origin/$branch. Falling back." >&2
        branch="feat/cont-$(date +%Y%m%d-%H%M)-$slug"
        git checkout --quiet -B "$branch" origin/master
        is_resume="false"
      else
        # Rebase the saved branch onto current master. If rebase conflicts,
        # abort + bounce the item back as [retry] with a "rebase conflict"
        # note. The next dev run resolves the conflict on the saved branch.
        if ! git rebase --quiet origin/master 2>/dev/null; then
          git rebase --abort 2>/dev/null || true
          echo "continuous: $resume_kind FAILED — rebase conflicts. Bouncing back to [retry]." >&2
          clean_slate
          local stripped_title
          stripped_title=$(echo "$next_title" | sed -E 's/^\[(resume|retry)\] //')
          # Push the [retry] retag + conflict-note via the merge lock.
          local rclock="$LOCKS_DIR/master-push.lockdir"
          local rcwait=0
          while ! mkdir "$rclock" 2>/dev/null; do
            sleep 0.3
            rcwait=$((rcwait + 1))
            if [ $rcwait -gt 200 ]; then break; fi
          done
          (
            trap 'rmdir "'"$rclock"'" 2>/dev/null' EXIT
            cd "$game_dir" || exit 1
            git fetch --quiet origin master 2>/dev/null
            git checkout --quiet master 2>/dev/null || exit 1
            git reset --hard origin/master --quiet 2>/dev/null
            python3 "$WORKMD" retry "$game_dir/WORK.md" "$stripped_title" \
              --detail "retry $(date '+%Y-%m-%d %H:%M %Z'): rebase of '$branch' onto master conflicted — next dev run resolves the conflict on the saved branch" \
              >> /dev/null 2>&1 || exit 1
            git add WORK.md 2>/dev/null
            git diff --cached --quiet && exit 0
            git -c user.email=continuous-bot@spraxel.ai -c user.name='Spraxel Continuous' \
                commit --quiet -m "chore(retry): rebase conflict — '$(echo "$stripped_title" | cut -c1-50)...'" 2>/dev/null || exit 1
            git push --quiet origin master 2>/dev/null
          )
          # Lock release via subshell EXIT trap; no outside-safety rmdir (would race).
          return 1
        fi
      fi
    fi
  else
    # Include worker id in branch name so 3 workers picking different
    # items at the same minute don't collide on naming if slugs match.
    branch="feat/cont-$(date +%Y%m%d-%H%M)-w${WORKER_ID}-$slug"
    echo "continuous: worker $WORKER_ID → '$next_title' on $branch"
    git checkout --quiet -B "$branch" origin/master
  fi

  local outcome=fail
  local baseline_failures=""
  for attempt in 1 2; do
    echo "=== attempt $attempt at $(date) ===" >> "$item_log"

    local item_brief
    item_brief=$(echo "$next_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
# claim returns a single dict; defend against legacy list shape too.
it = d[0] if isinstance(d, list) and d else d
if not it: sys.exit()
print('## Today\\'s item')
print()
print(it['title'])
for det in it.get('details', []):
    print(f'  {det}')
")
    # Resume / Retry mode prompt suffix: tell the dev they're picking up
    # prior work on an existing branch (already checked out + rebased on
    # master). The mode determines whose feedback to act on:
    #   - resume: CEO has reviewed + edited the item details
    #   - retry : wrapper bounced the item after tests/reviewer/merge
    #             failed; the failure feedback is in the item details
    if [ "$is_resume" = "true" ]; then
      local mode_blurb=""
      if [ "$resume_kind" = "resume" ]; then
        mode_blurb="The CEO has reviewed the prior failure and edited the
item details above (their feedback is what you should act on)."
      else
        mode_blurb="The wrapper bounced this item back into the queue after the
prior attempt failed tests / reviewer / merge. The failure feedback is
in the item details above — read it carefully and address each point.
This is the SAME work item from a previous run; the goal is to land it,
not to escalate to CEO. Reviewer feedback, test failures, merge conflicts
are all things YOU resolve here."
      fi
      item_brief="$item_brief

## $(echo "$resume_kind" | tr '[:lower:]' '[:upper:]') MODE

You are picking up a previously-attempted work item. The branch \`$branch\`
is already checked out and rebased on current master — the prior dev's
commits are visible in \`git log\`.

$mode_blurb

Read what was tried (\`git log --oneline -10\` + \`git show <sha>\`) and either:
  - Build on the existing code with new commits
  - Or revert / amend specific bad pieces and replace them

Do NOT delete the branch or reset to master. Commit your changes; the wrapper
folds everything into one squash-merge to master at the end."
    fi
    echo "$item_brief" > "$item_log.brief"

    # Fire developer with a HARD time limit (max_dev_minutes). A stuck
    # claude session (idle API, internal loop, etc.) would otherwise block
    # this worker forever — 2026-05-27 incident: w2's claude sat idle 29
    # min before I killed it manually. The watchdog subshell SIGKILLs the
    # dev's process group after $MAX_DEV_MINUTES; the wrapper sees the
    # non-zero exit and treats it as a normal dev failure (→ retry).
    SPRAXEL_ITEM_BRIEF="$item_log.brief" bash "$RUN_AGENT" developer >> "$item_log" 2>&1 &
    dev_pid=$!
    dev_timeout_secs=$((MAX_DEV_MINUTES * 60))
    (
      sleep "$dev_timeout_secs"
      if kill -0 "$dev_pid" 2>/dev/null; then
        echo "continuous: dev session exceeded ${MAX_DEV_MINUTES}m — killing PID $dev_pid" >> "$item_log"
        # Kill the dev process tree (run_agent.sh + claude child). pkill
        # -P targets direct children; loop twice for grandchildren too.
        pkill -KILL -P "$dev_pid" 2>/dev/null
        kill -KILL "$dev_pid" 2>/dev/null
      fi
    ) &
    dev_watchdog_pid=$!
    wait "$dev_pid" 2>/dev/null
    dev_rc=$?
    # Cancel watchdog if dev finished within the budget.
    kill -TERM "$dev_watchdog_pid" 2>/dev/null
    wait "$dev_watchdog_pid" 2>/dev/null
    if [ "$dev_rc" -eq 2 ]; then
      # rc=2 = developer.lockdir held (orphan or concurrent fire). NOT a real
      # failure — wait for the lock to clear, then retry the SAME item.
      echo "continuous: developer LOCKED — waiting (will retry same item, not escalate)" >> "$item_log"
      git checkout --detach origin/master --quiet 2>/dev/null
      git branch -D "$branch" --quiet 2>/dev/null || true
      for waited in 30 60 120 240 480 600; do
        sleep "$waited"
        [ ! -d "$REPO_DIR/.locks/developer.lockdir" ] && break
      done
      if [ -d "$REPO_DIR/.locks/developer.lockdir" ]; then
        echo "continuous: lock still held after 25 min — giving up this iteration" >> "$item_log"
        return 2   # treat as "nothing shipped" — outer loop sleeps + retries
      fi
      attempt=0   # next loop iteration becomes attempt 1
      continue
    elif [ "$dev_rc" -ne 0 ]; then
      echo "continuous: developer rc=$dev_rc on attempt $attempt" >> "$item_log"
      [ "$attempt" -lt 2 ] && continue
      outcome=fail
      break
    fi

    # Mid-run pause check.
    if [ -e "$PAUSED_FLAG" ]; then
      echo "continuous: paused mid-run after developer" >> "$item_log"
      git checkout --detach origin/master --quiet 2>/dev/null
      git branch -D "$branch" --quiet 2>/dev/null || true
      return 2
    fi

    # Clarify detection — Developer asked questions, didn't implement.
    if python3 -c "
import sys
sys.path.insert(0, '$REPO_DIR/scripts')
from workmd import parse, find_item
wm = parse('$game_dir/WORK.md')
for sec in (wm.todo, wm.current, wm.shipped):
    idx = find_item(sec, '$next_title'.replace('[needs-ceo] ', ''))
    if idx >= 0 and sec[idx].is_needs_ceo:
        sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
      echo "continuous: ↪ clarified '$next_title'" >> "$item_log"
      echo "continuous: ↪ clarified '$next_title'"
      # Push the dev's clarify-modified WORK.md to origin master via the
      # serialized merge lock. The dev wrote directly to $WORK_MD_PATH
      # (= $game_dir/WORK.md) per the $WORK_MD_PATH discipline — so by
      # the time we get here, game_dir/WORK.md ALREADY has the [needs-ceo]
      # tag + Q-detail lines. We just need to commit + push it.
      #
      # CRITICAL: do NOT `git reset --hard origin/master` here — that
      # would wipe the dev's uncommitted clarify change. Just fetch +
      # checkout master (the worker's WORK_DIR has its own master state;
      # game_dir's WORK.md should already be the dev's clarified version).
      local clarify_lock="$LOCKS_DIR/master-push.lockdir"
      local clarify_wait=0
      while ! mkdir "$clarify_lock" 2>/dev/null; do
        sleep 0.3
        clarify_wait=$((clarify_wait + 1))
        if [ $clarify_wait -gt 200 ]; then break; fi
      done
      (
        trap 'rmdir "'"$clarify_lock"'" 2>/dev/null' EXIT
        cd "$game_dir" || exit 1
        git fetch --quiet origin master 2>/dev/null
        # Checkout master (no reset — preserves the dev's clarify write).
        git checkout --quiet master 2>/dev/null || exit 1
        git add WORK.md 2>/dev/null
        git diff --cached --quiet && exit 0   # nothing to commit
        if ! git -c user.email=continuous-bot@spraxel.ai -c user.name='Spraxel Continuous' \
                commit --quiet -m "needs-ceo: clarifications on '$next_title'" 2>/dev/null \
           || ! git push --quiet origin master 2>/dev/null; then
          # Push race lost; reset for cleanliness, next iter will re-detect [needs-ceo].
          git reset --hard origin/master --quiet 2>/dev/null
          exit 1
        fi
      )
      # Lock release via subshell EXIT trap; no outside-safety rmdir (would race).
      # Worker cleanup
      cd "$WORK_DIR"
      git fetch --quiet origin master 2>/dev/null
      git checkout --detach origin/master --quiet 2>/dev/null
      git branch -D "$branch" --quiet 2>/dev/null || true
      return 2   # don't count toward batch
    fi

    # Baseline-aware test gate: capture pre-Developer test state once per item,
    # then re-run after Developer's changes. Only count NEW failures (tests
    # that passed before this change but fail after). Pre-existing failures
    # in unrelated modules are noted but don't trigger escalation.
    #
    # Baseline is SHARED across all parallel-dev workers via a per-master-SHA
    # cache file. The first worker to hit a given master SHA runs the test
    # suite + writes the cache; subsequent workers (same SHA) read from
    # cache, skipping the ~5-10 min baseline run. Cache key = origin/master
    # short SHA, so the cache invalidates naturally when master advances.
    if [ -z "${baseline_failures:-}" ]; then
      master_sha=$(git -C "$WORK_DIR" rev-parse --short origin/master 2>/dev/null)
      baseline_cache="$CACHE_DIR/baseline-tests-${master_sha}.txt"
      if [ -n "$master_sha" ] && [ -f "$baseline_cache" ]; then
        baseline_failures=$(cat "$baseline_cache")
        echo "continuous: baseline failures restored from cache ($master_sha; $(echo "$baseline_failures" | grep -c .) entries)" >> "$item_log"
      else
        # No cache for this master SHA — run the suite, capture, write cache.
        git stash push --quiet -m "baseline-test-stash" 2>/dev/null
        git checkout --detach origin/master --quiet 2>/dev/null
        SPRAXEL_GAME_DIR="$game_dir" SPRAXEL_WORKER_ID="$WORKER_ID" \
        bash "$WORK_DIR/scripts/run_local_tests.sh" --quiet >> "$item_log" 2>&1 || true
        baseline_failures=$(python3 -c "
import json
try:
    d = json.load(open('$game_dir/.factory/local-tests-status-w$WORKER_ID.json'))
    print('\\n'.join(d.get('failures', [])))
except Exception:
    pass
")
        git checkout --quiet "$branch" 2>/dev/null
        git stash pop --quiet 2>/dev/null
        # Atomic write so concurrent workers don't see a half-written cache.
        if [ -n "$master_sha" ]; then
          printf '%s' "$baseline_failures" > "$baseline_cache.tmp.$$"
          mv "$baseline_cache.tmp.$$" "$baseline_cache" 2>/dev/null
        fi
        echo "continuous: baseline failures captured ($(echo "$baseline_failures" | grep -c .) entries; cached under $master_sha)" >> "$item_log"
      fi
    fi

    # Run tests on Developer's branch IN THE WORKER'S WORKTREE — not in
    # game_dir. Critical fix from 2026-05-27 audit: previously this invoked
    # `bash $game_dir/scripts/run_local_tests.sh`, whose REPO_DIR resolved
    # to game_dir → tests ran against game_dir's tree (usually master), NOT
    # the worker's feat branch. Result: broken changes could pass the test
    # gate because tests never actually exercised the dev's code.
    SPRAXEL_GAME_DIR="$game_dir" SPRAXEL_WORKER_ID="$WORKER_ID" \
      bash "$WORK_DIR/scripts/run_local_tests.sh" --quiet >> "$item_log" 2>&1
    rc=$?
    if [ $rc -ne 0 ]; then
      current_failures=$(python3 -c "
import json
try:
    d = json.load(open('$game_dir/.factory/local-tests-status-w$WORKER_ID.json'))
    print('\\n'.join(d.get('failures', [])))
except Exception:
    pass
")
      # Compare: anything in current_failures NOT in baseline_failures = new.
      new_failures=$(comm -23 <(echo "$current_failures" | sort -u) <(echo "$baseline_failures" | sort -u))
      if [ -n "$new_failures" ]; then
        echo "continuous: tests FAILED — NEW failures on attempt $attempt:" >> "$item_log"
        echo "$new_failures" >> "$item_log"
        [ "$attempt" -lt 2 ] && { git checkout --quiet "$branch"; continue; }
        outcome=fail
        break
      fi
      echo "continuous: tests had failures but all were pre-existing (baseline match) — accepting" >> "$item_log"
    fi

    if ! bash "$RUN_AGENT" reviewer >> "$item_log" 2>&1; then
      echo "continuous: reviewer BLOCKED" >> "$item_log"
      outcome=fail
      break
    fi

    # Build the full squash-merge commit message: subject line + blank
    # line + body paragraph(s). The developer is supposed to print BOTH
    # markers near the end of its run (per spraxel-developer.md step 9):
    #   COMMIT_SUBJECT: <conv-commit subject>
    #   COMMIT_BODY:
    #   <one or more paragraphs describing the change in detail>
    #   END_COMMIT_BODY
    #
    # If COMMIT_SUBJECT is missing, fall back to the cleaned WORK.md title.
    # If COMMIT_BODY is missing, fall back to extracting the body from the
    # last commit on the feat branch (`git log -1 --format=%b`). Last
    # resort: leave the body empty and just ship a subject-only commit
    # (preserves current behavior).
    commit_subject=$(grep -E '^COMMIT_SUBJECT:[[:space:]]*' "$item_log" 2>/dev/null \
                     | tail -1 \
                     | sed -E 's/^COMMIT_SUBJECT:[[:space:]]*//')
    if [ -z "$commit_subject" ]; then
      commit_subject=$(python3 -c "
import sys
t = sys.argv[1].strip().rstrip(' ?.,;:!')
# Capitalize first letter if lowercase
if t and t[0].islower():
    t = t[0].upper() + t[1:]
# If too long + has a parenthetical, drop the parenthetical
if len(t) > 80 and '(' in t:
    t = t.split('(')[0].strip().rstrip(' -—:,')
# Cap at 100 chars hard
print('feat: ' + t[:100])
" "$next_title")
    fi
    # Ensure it starts with a conv-commit type. If the dev forgot, prepend feat:.
    case "$commit_subject" in
      feat:*|fix:*|refactor:*|perf:*|docs:*|chore:*|test:*|style:*|build:*|ci:*) ;;
      feat\(*|fix\(*|refactor\(*|perf\(*|docs\(*|chore\(*|test\(*) ;;
      *) commit_subject="feat: $commit_subject" ;;
    esac

    # Extract COMMIT_BODY block between markers (if any).
    commit_body=$(python3 - "$item_log" <<'PY'
import sys, re
try:
    log = open(sys.argv[1]).read()
except FileNotFoundError:
    sys.exit(0)
# Find the LAST occurrence (in case there are nested matches across attempts).
m = re.findall(r"COMMIT_BODY:\s*\n(.*?)(?:\nEND_COMMIT_BODY|\Z)", log, re.S)
if m:
    body = m[-1].strip()
    # Drop any trailing status line from the dev's stdout (e.g.,
    # "developer: ok" / "developer: blocked — ...").
    body = re.sub(r"\ndeveloper:.*$", "", body, flags=re.M).strip()
    print(body)
PY
)
    # Fallback: pull the body of the most recent commit on the feat branch
    # (dev should have written it there via `git commit -m "subject" -m
    # "body"`). Strips the subject line out.
    if [ -z "$commit_body" ]; then
      commit_body=$(git -C "$WORK_DIR" log -1 --format='%b' 2>/dev/null | sed -e '/^$/d' | head -50)
    fi
    # Build the combined message. If body is empty, just use subject.
    if [ -n "$commit_body" ]; then
      commit_message="$(printf '%s\n\n%s' "$commit_subject" "$commit_body")"
    else
      commit_message="$commit_subject"
    fi

    # Same cleanup for the `work: shipped` follow-up — truncate very long
    # titles so the bookkeeping commit subject doesn't blow out git log.
    short_title=$(python3 -c "
import sys
t = sys.argv[1].strip()
if len(t) > 60:
    t = t[:57] + '...'
print(t)
" "$next_title")

    # ── Merge: serialize via shared lock, run from game_dir ──────────────
    # Workers each have a worktree on a feat branch. To merge, we briefly
    # cd into game_dir (the main checkout) — only one worker can be in this
    # critical section at a time. The merge itself is < 1 s so this is a
    # negligible bottleneck. game_dir's master is "free" because no
    # worktree ever checks out master (workers use detached HEAD between
    # items — see clean_slate).
    local merge_lock="$LOCKS_DIR/master-push.lockdir"
    local waited=0
    while ! mkdir "$merge_lock" 2>/dev/null; do
      sleep 0.3
      waited=$((waited + 1))
      if [ $waited -gt 200 ]; then
        echo "continuous: merge lock held >60s — aborting" >> "$item_log"
        outcome=fail
        break 2
      fi
    done
    # Subshell so cd doesn't leak; trap to release lock no matter what.
    (
      trap 'rmdir "$merge_lock" 2>/dev/null' EXIT
      cd "$game_dir" || exit 1
      git fetch --quiet origin master 2>/dev/null
      git checkout --quiet master 2>/dev/null || exit 1
      git reset --hard origin/master --quiet 2>/dev/null
      if git merge --squash --quiet "$branch"; then
        # DEFENSE IN DEPTH: discard any WORK.md change that came from the
        # feat branch. Devs are instructed (via run_agent.sh prompt) to
        # ONLY modify game_dir/WORK.md via workmd.py — never the worktree
        # copy. If a dev disobeyed (manual edit, sloppy workmd.py path),
        # the squash would carry that into master and could collide with
        # another worker's concurrent WORK.md change → literal git
        # merge-conflict markers in master's WORK.md (the 2026-05-27
        # incident). Resetting WORK.md to master here makes that
        # impossible: the canonical WORK.md (game_dir, owned by the
        # wrapper via workmd.py + FileLock) is the only source of truth.
        git checkout HEAD -- WORK.md 2>/dev/null || true
        if git -c user.email=continuous-bot@spraxel.ai -c user.name='Spraxel Continuous' \
                commit --quiet -m "$commit_message" \
           && git push --quiet origin master; then
          python3 "$WORKMD" ship "$game_dir/WORK.md" "$next_title" >> "$item_log" 2>&1 || true
          git add WORK.md 2>/dev/null
          git -c user.email=continuous-bot@spraxel.ai -c user.name='Spraxel Continuous' \
              commit --quiet -m "chore(work): mark '$short_title' as shipped" 2>/dev/null
          git push --quiet origin master 2>/dev/null
          exit 0
        else
          exit 1
        fi
      else
        # Squash failed — likely a CODE merge conflict (not WORK.md), which
        # is a real dev-fixable failure. Bail to the retry path.
        git merge --abort 2>/dev/null || true
        exit 1
      fi
    )
    local merge_rc=$?
    # Lock release is handled by the subshell's EXIT trap above. Do NOT
    # rmdir here as a "safety net" — if another worker has already
    # mkdir'd the lock again (raced into the critical section), this
    # rmdir would clobber THEIR lock and let a third worker enter,
    # corrupting WORK.md bookkeeping.
    if [ $merge_rc -eq 0 ]; then
      # Local cleanup in the worker's worktree.
      cd "$WORK_DIR"
      git fetch --quiet origin master 2>/dev/null
      git checkout --detach origin/master --quiet 2>/dev/null
      git branch -d "$branch" --quiet 2>/dev/null || true
      # Delete the remote ref too. Squash-merge creates a NEW commit on
      # master rather than fast-forwarding, so `git branch -r --merged`
      # doesn't catch the feat branch as merged — janitor would never
      # sweep it, and the GitHub UI would show dead-but-not-merged
      # branches indefinitely. Best to clean up at ship time so origin
      # stays tidy.
      git push --quiet origin --delete "$branch" 2>/dev/null || true
      outcome=ok
      break
    else
      echo "continuous: merge/push FAILED (lock-protected merge in game_dir returned rc=$merge_rc)" >> "$item_log"
      outcome=fail
      break
    fi
  done

  if [ "$outcome" != "ok" ]; then
    # ── Retry path (NOT CEO escalation) ─────────────────────────────────────
    # Tests failed / reviewer blocked / merge conflicted — all things the
    # next dev run can fix. Bounce the item back into the queue tagged
    # [retry], with the failure feedback in details. CEO is not involved.
    # CEO escalation ([escalated]) is reserved for items needing real
    # CEO judgment (manually set; rare).
    local last_commit_sha=""
    last_commit_sha=$(git rev-parse --short "$branch" 2>/dev/null || echo "")

    # Preserve the failed branch on origin so the next [retry] run can
    # pick it up.
    if [ -n "$last_commit_sha" ]; then
      git push --quiet --force-with-lease origin "$branch":"$branch" 2>/dev/null || \
        echo "continuous: WARNING — could not push failed branch '$branch' to origin" >> "$item_log"
    fi

    # Self-heal before the bookkeeping commit on master.
    if ! clean_slate; then
      echo "continuous: RETRY self-heal FAILED — cannot reach master to record '$next_title'" >> "$item_log"
      echo "continuous: ⚠️  could not record retry for '$next_title' — fail_streak will brake the loop"
      return 1
    fi

    # Parse the item log to extract a concise list of "what failed this
    # attempt" lines. These go into the WORK.md item details so the next
    # dev sees exactly what to fix. $slug is the item's kebab-slug —
    # also what the reviewer uses as the filename for its findings.
    local feedback_file="$item_log.retry-feedback.txt"
    python3 - "$item_log" "$slug" > "$feedback_file" <<'PY'
import sys, re
log_path, slug = sys.argv[1], sys.argv[2]
try:
    log = open(log_path).read()
except FileNotFoundError:
    log = ""
feedback: list[str] = []
# Reviewer blocking findings — the reviewer writes them to
# .factory/reviews/<slug>.md (gitignored, survives clean_slate). The
# wrapper log only has the "reviewer BLOCKED" header but we can point
# the next dev at the exact findings file.
if "reviewer BLOCKED" in log:
    feedback.append(f"reviewer blocked the diff — read .factory/reviews/{slug}.md for findings + address each [block] item")
# NEW test failures (per attempt)
for m in re.finditer(r"NEW failures on attempt \d+:\s*\n((?:.*\n)*?)(?=\n===|\Z)", log):
    for line in m.group(1).splitlines():
        line = line.strip()
        if line and not line.startswith("continuous:") and not line.startswith("["):
            feedback.append(f"test failed: {line}")
# Merge/push failure
if "merge/push FAILED" in log:
    feedback.append("merge to master failed (likely conflict against current master) — rebase the branch and resolve")
# Dev agent crashed
m = re.search(r"developer rc=(\d+)", log)
if m and not feedback:
    feedback.append(f"dev agent exited rc={m.group(1)} without committing — re-attempt from scratch (working tree was clean-slated)")
# Dedup while preserving order
seen = set()
uniq = []
for f in feedback:
    if f not in seen:
        seen.add(f)
        uniq.append(f)
for f in uniq[:12]:  # cap so WORK.md item doesn't bloat
    print(f)
PY

    # Build detail args: branch ref + each parsed feedback line.
    local detail_args=()
    detail_args+=(--detail "branch: $branch")
    [ -n "$last_commit_sha" ] && detail_args+=(--detail "last-commit: $last_commit_sha")
    detail_args+=(--detail "retry $(date '+%Y-%m-%d %H:%M %Z'): prior attempt did not land — next dev run picks this up from the saved branch")
    if [ -s "$feedback_file" ]; then
      while IFS= read -r fb_line; do
        [ -n "$fb_line" ] && detail_args+=(--detail "$fb_line")
      done < "$feedback_file"
    fi
    rm -f "$feedback_file"

    # Strip any existing [retry]/[resume]/[escalated] tag from the title
    # before passing to workmd.py (retry() will re-add [retry] cleanly).
    local stripped_title
    stripped_title=$(echo "$next_title" | sed -E 's/^\[(resume|retry|escalated)\]\s*//')

    # Commit subject — keep it short + sortable in git log.
    local retry_short
    retry_short=$(python3 -c "
import sys
t = sys.argv[1].strip().rstrip(' ?.,;:!')
if t and t[0].islower():
    t = t[0].upper() + t[1:]
print(t[:55] + ('...' if len(t) > 55 else ''))
" "$stripped_title")
    # Push the [retry] retag + details to origin/master via the
    # serialized merge lock. workmd.py runs INSIDE the lock so any
    # concurrent ship by another worker doesn't get wiped by our reset.
    local retry_lock="$LOCKS_DIR/master-push.lockdir"
    local retry_wait=0
    while ! mkdir "$retry_lock" 2>/dev/null; do
      sleep 0.3
      retry_wait=$((retry_wait + 1))
      if [ $retry_wait -gt 200 ]; then break; fi
    done
    (
      trap 'rmdir "'"$retry_lock"'" 2>/dev/null' EXIT
      cd "$game_dir" || exit 1
      git fetch --quiet origin master 2>/dev/null
      git checkout --quiet master 2>/dev/null || exit 1
      git reset --hard origin/master --quiet 2>/dev/null
      python3 "$WORKMD" retry "$game_dir/WORK.md" "$stripped_title" \
        "${detail_args[@]}" \
        >> "$item_log" 2>&1 || exit 1
      git add WORK.md 2>/dev/null
      git diff --cached --quiet && exit 0
      git -c user.email=continuous-bot@spraxel.ai -c user.name='Spraxel Continuous' \
          commit --quiet -m "chore(retry): $retry_short — bounced back to queue" 2>/dev/null || exit 1
      git push --quiet origin master 2>/dev/null
    )
    # Lock release via subshell EXIT trap; no outside-safety rmdir (would race).
    echo "continuous: ↻ worker $WORKER_ID — retry '$stripped_title' — branch '$branch' preserved, will retry next dev fire"
    return 1
  fi

  echo "continuous: ✓ shipped '$next_title'"
  return 0
}

# --- main loop ---
init_state_if_missing
trace "step: state initialized"
echo "continuous: started — target_per_batch=$target_per_batch, game_dir=$game_dir"
trace "step: entering main loop (startup complete)"

idle_streak=0
fail_streak=0

while true; do
  # Pause check.
  if [ -e "$PAUSED_FLAG" ]; then
    sleep "$POLL_INTERVAL_SECONDS"
    continue
  fi
  # Rate-limit / cascade brake.
  if [ "$fail_streak" -ge "$MAX_FAIL_STREAK" ]; then
    echo "continuous: $MAX_FAIL_STREAK consecutive failures — backing off $((FAIL_BACKOFF_SECONDS / 60)) min"
    fail_streak=0
    sleep "$FAIL_BACKOFF_SECONDS"
    continue
  fi
  # CEO signal check.
  if ceo_signaled; then
    record_ceo_signal
  fi
  # Cap check.
  shipped=$(read_state shipped_since_last_signal)
  if [ "$shipped" -ge "$target_per_batch" ]; then
    # At cap — wait for CEO. Re-check every poll_interval_seconds.
    sleep "$POLL_INTERVAL_SECONDS"
    continue
  fi
  # Ship one item.
  ship_one_item
  rc=$?
  case $rc in
    0) # success
      fail_streak=0
      idle_streak=0
      # Atomic +1 across parallel workers — never lose an increment.
      inc_state shipped_since_last_signal >/dev/null
      ;;
    1) # genuine failure
      fail_streak=$((fail_streak + 1))
      idle_streak=0
      ;;
    2) # clarify / paused mid-flight — don't count
      idle_streak=0
      ;;
    3) # nothing to do (Todo empty of eligible items)
      idle_streak=$((idle_streak + 1))
      if [ "$idle_streak" -ge "$IDLE_THRESHOLD" ]; then
        sleep "$IDLE_SLEEP_SECONDS"
        idle_streak=0
      else
        sleep $((POLL_INTERVAL_SECONDS / 2))
      fi
      ;;
  esac
done
