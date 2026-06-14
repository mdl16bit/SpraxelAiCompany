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
# PID-aware lockdir helpers: acquire_lock writes the holder PID into
# the lockdir so tick.sh can sweep orphan locks (SIGKILL'd holders)
# without ripping live locks out from under active git operations.
. "$REPO_DIR/scripts/lockutils.sh"
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
# Try to acquire. If the existing lockdir is held by a dead PID (prior
# wrapper SIGKILLed), acquire_lock will sweep and reacquire within one
# poll cycle. If held by a LIVE process, this returns 1 (timeout=1s) and
# we exit cleanly — another instance is genuinely running.
if ! acquire_lock "$LOCK" 1 0.2; then
  trace "step: exit 0 (lockdir held by live worker $WORKER_ID instance)"
  exit 0
fi
## Cleanup on wrapper exit: kill ALL direct children (run_local_tests.sh,
## run_agent.sh, any sleep in the main loop), then release the lockdir.
## Without the child-kill, a wrapper that dies (SIGKILL, crash, normal exit)
## leaves its run_local_tests.sh + their godot grandchildren reparented to
## launchd — orphan zombies eating resources. The test lockdir holds its
## own holder.pid; the next test waiter sweeps it via lock_holder_alive,
## so orphan godot trees aren't catastrophic anymore — but still wasteful.
##
## pkill -P $$ targets only direct children (the same process group as
## this script). Each child's own EXIT trap then propagates the kill
## deeper (run_local_tests.sh kills its godot via the run_bounded killer
## subshell + EXIT trap; run_agent.sh kills its claude session via
## SIGTERM handler).
trap 'for _c in $(pgrep -P $$ 2>/dev/null); do kill_tree "$_c" KILL; done; sleep 0.2; release_lock "$LOCK"' EXIT
# INT/TERM must EXIT (not just run cleanup): a bare signal trap that doesn't
# exit returns control to the interrupted `wait`/`sleep` and the loop keeps
# running — but the EXIT-trap above already released $LOCK, so the worker
# soldiers on WITHOUT its lockdir. tick.sh then sees the lockdir absent and
# spawns a DUPLICATE worker (observed 2026-05-28: a TERM'd worker survived
# lockless, tick respawned over it). `exit` here triggers the EXIT trap once,
# cleanly. 143 = 128+SIGTERM.
trap 'exit 143' INT TERM
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
    "max_dev_minutes":         90,   # absolute backstop for the progress watchdog
    "dev_stall_minutes":       15,   # kill only after this long with NO file writes
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
# Boolean knob (the int loop above only reads digits): cap_excludes_test_fixes
# accepts true/false/1/0/yes/on; default false. Emitted as 1/0 for the shell.
_bm = re.search(r"^\s+cap_excludes_test_fixes:\s*([A-Za-z0-9]+)", block, re.M)
_bval = _bm.group(1).strip().lower() if _bm else ""
print("CAP_EXCLUDES_TEST_FIXES=" + ("1" if _bval in ("true", "1", "yes", "on") else "0"))
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
#
# CRITICAL: must commit + push under the master-push lock, same as claim()
# does. workmd.py release-wip writes to disk but doesn't commit. If we left
# it uncommitted, a concurrent worker's merge `git reset --hard origin/master`
# would RESTORE the [wip:$WORKER_ID] tag (since master still has it from the
# prior committed claim) — undoing our release. Then THIS worker's next
# claim() call would skip the item it owns (it's tagged [wip:N], looks
# claimed by N, BUT N is us, and we just tried to release it...). Either
# way, infinite "release / restore" cycle.
#
# Same merge-lock pattern as claim() — acquire lock, sync master, run
# release-wip, commit + push, release lock.
(
  startup_release_lock="$LOCKS_DIR/master-push.lockdir"
  if ! acquire_lock "$startup_release_lock" 60 0.3; then
    echo "continuous: worker $WORKER_ID — couldn't acquire merge lock for startup release-wip" >> "$TRACE_FILE"
    exit 0
  fi
  trap 'release_lock "'"$startup_release_lock"'"' EXIT
  cd "$game_dir" || exit 0
  git fetch --quiet origin master 2>/dev/null
  git checkout --quiet master 2>/dev/null || exit 0
  git reset --hard origin/master --quiet 2>/dev/null
  released=$(python3 "$WORKMD" release-wip "$game_dir/WORK.md" --worker-id "$WORKER_ID" 2>&1)
  echo "$released" >> "$TRACE_FILE"
  git add WORK.md 2>/dev/null
  if ! git diff --cached --quiet; then
    git -c user.email=continuous-bot@spraxel.ai -c user.name='Spraxel Continuous' \
        commit --quiet -m "chore(work): release stale [wip:$WORKER_ID] claims at worker startup" 2>/dev/null >/dev/null
    git push --quiet origin master 2>/dev/null >/dev/null || \
      git reset --hard origin/master --quiet 2>/dev/null
  fi
)

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

# --- Sampled-scenario bug filing ---
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
# Nuke + recreate this worker's worktree, detached at origin/master. The
# bulletproof recovery when an in-place checkout/reset is wedged — e.g. an
# LFS/filter-dirty entry (addons/gut/*.ttf) that git perpetually reports
# "not uptodate" and refuses to update on a tree switch. NEITHER
# `checkout --force` NOR `reset --hard <other-commit>` can move past such an
# entry, but a from-scratch checkout into a clean dir cannot be blocked by a
# dirty file — so a wedged worktree can never death-loop a worker again.
_rebuild_worktree() {
  echo "continuous: clean_slate — rebuilding wedged worktree $WORK_DIR from origin/master" >&2
  cd "$game_dir" 2>/dev/null || cd / 2>/dev/null || return 1
  git -C "$game_dir" fetch --quiet origin master 2>/dev/null
  git -C "$game_dir" worktree remove --force "$WORK_DIR" 2>/dev/null
  git -C "$game_dir" worktree prune 2>/dev/null
  rm -rf "$WORK_DIR" 2>/dev/null
  git -C "$game_dir" worktree add --detach "$WORK_DIR" origin/master --quiet 2>/dev/null || return 1
  cd "$WORK_DIR" || return 1
  return 0
}

clean_slate() {
  cd "$WORK_DIR" 2>/dev/null || { _rebuild_worktree; return $?; }
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
  # Get onto a clean origin/master. Detach HEAD at the CURRENT commit first (no
  # file changes → can't trip a dirty-entry refusal), then move to origin/master.
  # Both `checkout <other-tree>` AND `reset --hard <other-commit>` REFUSE on a
  # stat/filter-dirty entry ("Entry X not uptodate. Cannot merge") — the repeat
  # offender is LFS-tracked vendored fonts (addons/gut/*.ttf) that git's clean
  # filter leaves perpetually "modified"; --force cannot beat it. So if the
  # in-place reset can't land, fall back to a from-scratch worktree rebuild,
  # which a wedged file cannot block (2026-05-28/29 w2 clean_slate death-loop).
  git checkout --detach --quiet 2>/dev/null || true
  if ! git reset --hard origin/master --quiet 2>/dev/null \
     && ! git reset --hard FETCH_HEAD --quiet 2>/dev/null; then
    _rebuild_worktree || return 1
    return 0
  fi
  # Remove leftover untracked files from a wrecked iteration (respects
  # .gitignore — won't touch .godot/.factory/local caches).
  git clean -fdq 2>/dev/null
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
  if ! acquire_lock "$claim_lock" 60 0.3; then
    echo "continuous: worker $WORKER_ID — claim-lock held >60s, aborting" >&2
    return 3
  fi
  # Subshell with EXIT trap releases the lock no matter what.
  next_json=$(
    trap 'release_lock "'"$claim_lock"'"' EXIT
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

  # A [test_failure] item (filed by the batch test runner) carries a
  # `test-ref: <kind>:<id>` detail naming the one failing test. This is the only
  # kind of item whose named test the wrapper re-runs as the MERGE GATE. Devs run
  # no tests on most items, with two narrow self-validation exceptions (see
  # spraxel-developer.md step 7): a [test_failure] fix, and validating the single
  # regression test a dev writes for a [bug] (fail-without-fix / pass-with-fix).
  # Neither exception changes the gate logic below — only [test_failure] gates.
  local is_test_failure="false" test_ref=""
  CURRENT_ITEM_IS_TEST_FAILURE="false"   # global mirror — read by the main-loop cap gate
  if echo "$next_title" | grep -qiE '^\[test_failure\]'; then
    is_test_failure="true"
    CURRENT_ITEM_IS_TEST_FAILURE="true"
    test_ref=$(echo "$next_json" | python3 -c "
import sys, json, re
d = json.load(sys.stdin); it = d[0] if isinstance(d, list) and d else d
for det in (it or {}).get('details', []):
    m = re.match(r'test-ref:\s*(\S+)', det.strip(), re.I)
    if m:
        print(m.group(1)); break
" 2>/dev/null)
  fi

  slug=$(echo "$next_title" | python3 "$SLUGIFY")
  item_log="$LOG_DIR/w${WORKER_ID}-${slug}.log"

  # Deterministic branch name — a pure function of the item, NOT the clock
  # or the worker id. This is what makes retries reuse the same branch:
  # the name is recomputed identically every attempt, so even if the
  # WORK.md `branch:` detail is lost (a CEO edit, a git reset, workmd
  # dropping it), the fresh-start path lands on the exact same branch that
  # the prior attempt pushed — and reuses it instead of minting a new one.
  #
  # Old scheme `feat/cont-<date>-<time>-wN-<slug>` changed every attempt,
  # so a lost detail orphaned the old branch and created a duplicate. That
  # produced the 18-branch pileup (same item, multiple branches).
  #
  # slug is already tag-stripped + truncated to 50 chars; append a short
  # hash of the full tag-stripped title so two long titles that truncate
  # to the same slug still get distinct branches. Two workers never share
  # an item (the [wip:N] claim lock), so per-item names never collide
  # across workers — the worker id is not needed in the name.
  local _title_core _title_hash
  _title_core=$(printf '%s' "$next_title" | sed -E 's/^[[:space:]]*(\[[a-z-]+\][[:space:]]*)+//I')
  _title_hash=$(printf '%s' "$_title_core" | shasum 2>/dev/null | cut -c1-6)
  local det_branch="feat/cont-${slug}-${_title_hash}"

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
  local resolve_conflict=0   # set when a reusable branch conflicts on rebase →
  local conflict_files=""    # dev rebases + resolves in-session (see prompt)
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
      branch="$det_branch"
      git checkout --quiet -B "$branch" origin/master
      is_resume="false"
    else
      if ! git checkout --quiet -B "$branch" "origin/$branch" 2>/dev/null; then
        echo "continuous: resume FAILED — could not checkout origin/$branch. Falling back." >&2
        branch="$det_branch"
        git checkout --quiet -B "$branch" origin/master
        is_resume="false"
      else
        # Layer 1 recurrence guard (2026-06-07): only RESUME on a CLEAN rebase.
        # A saved branch that's fallen behind a hot file (e.g. character.gd)
        # produces a rebase the dev can't reliably resolve → stall/SIGTERM →
        # infinite [retry] loop (the multi-hour jam). When the rebase conflicts,
        # DISCARD the stale branch and rebuild FRESH from current master: the
        # spec lives in WORK.md and a fresh build has no rebase, so it converges
        # at any dev_concurrency. (Old behaviour bounced to [retry] + reused the
        # same stale branch next time — which never converged.)
        if ! git rebase --quiet origin/master 2>/dev/null; then
          git rebase --abort 2>/dev/null || true
          echo "continuous: saved branch '$branch' stale/conflicting → FRESH build on master (recurrence guard)" >&2
          branch="$det_branch"
          git checkout --quiet -B "$branch" origin/master
          is_resume="false"   # build fresh from the WORK.md spec; no stale-branch rebase
        fi
      fi
    fi
  else
    # Fresh / detail-less path. Use the deterministic per-item branch name
    # and REUSE it if a prior attempt already pushed it to origin (this is
    # the duplicate-branch fix: a [retry] whose `branch:` detail was lost
    # still lands here and recovers the prior work instead of orphaning it).
    branch="$det_branch"
    if git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
      echo "continuous: ↻ worker $WORKER_ID reusing existing branch $branch for '$next_title'"
      git fetch --quiet origin "$branch" 2>/dev/null
      if git checkout --quiet -B "$branch" "origin/$branch" 2>/dev/null \
         && git rebase --quiet origin/master 2>/dev/null; then
        :  # reused + rebased cleanly
      else
        # Layer 1 recurrence guard (2026-06-07): the reused branch is stale /
        # conflicts on rebase → rebuild FRESH on current master instead of
        # attempting a hot-file rebase the dev can't reliably resolve (the cause
        # of the multi-hour jam). The spec lives in WORK.md; a fresh build has no
        # rebase, so it converges. (Earlier approaches — discard+rebuild-then-
        # re-conflict, and hand-conflict-to-dev — both failed under sustained
        # same-file contention.)
        git rebase --abort 2>/dev/null || true
        echo "continuous: worker $WORKER_ID — branch $branch stale/conflicting → FRESH build on master (recurrence guard)" >&2
        git checkout --quiet -B "$branch" origin/master
      fi
    else
      echo "continuous: worker $WORKER_ID → '$next_title' on $branch (fresh)"
      git checkout --quiet -B "$branch" origin/master
    fi
  fi

  local outcome=fail
  for attempt in 1 2; do
    echo "=== attempt $attempt at $(date) ===" >> "$item_log"

    local item_brief
    item_brief=$(echo "$next_json" | python3 -c "
import sys, json, re
d = json.load(sys.stdin)
# claim returns a single dict; defend against legacy list shape too.
it = d[0] if isinstance(d, list) and d else d
if not it: sys.exit()
# Strip ALL leading tags — any [..] bracket tag plus pN priority markers,
# in any order/repetition — so none of them reach the dev brief (and thus
# the COMMIT_SUBJECT the dev echoes back). These are internal workflow
# state, never user-facing; the retry/resume CONTEXT is conveyed via the
# RETRY MODE brief section, and the conv-commit type classifies the change.
# Generic (not a fixed tag list) so a future tag can't slip through.
title = it['title']
while True:
    _t = re.sub(r'^\s*(\[[^\]]+\]|p[0-3])\s*', '', title, flags=re.I)
    if _t == title:
        break
    title = _t
print('## Today\\'s item')
print()
print(title)
# Hide internal subtask metadata (epic-id/seq) from the dev, but capture seq to
# emit a clear 'this is one subtask' instruction.
_seq = None
_test_ref = None
for det in it.get('details', []):
    _ds = det.strip().lower()
    if _ds.startswith('epic-id:'):
        continue
    m = re.match(r'seq:\s*(\d+)', det.strip(), re.I)
    if m:
        _seq = m.group(1); continue
    mt = re.match(r'test-ref:\s*(\S+)', det.strip(), re.I)
    if mt:
        _test_ref = mt.group(1); continue
    print(f'  {det}')
if _test_ref:
    print()
    print('## TEST FIX — you MAY run this one test')
    print(f'This item is a regression in the test: {_test_ref}')
    print('Find the root cause and fix the CODE (or the test itself if the test is wrong).')
    print('You ARE permitted to run THIS test — and ONLY this one — to verify your fix:')
    print(f'  bash scripts/run_local_tests.sh --only {_test_ref}')
    print('Do NOT run the full suite or any other test. The wrapper re-runs only this')
    print('test as the merge gate.')
if _seq:
    print()
    print(f'## SUBTASK {_seq} of a larger feature')
    print('This is ONE subtask of a decomposed feature. Earlier subtasks (lower seq) are')
    print('ALREADY merged to master — build on their code, do NOT re-implement them. Do')
    print('ONLY this subtask\\'s spec above, and leave the game working/shippable on its own.')
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
    if [ "${resolve_conflict:-0}" = "1" ]; then
      item_brief="$item_brief

## ⚠️ REBASE CONFLICT — RESOLVE THIS FIRST

Your prior work for this item is COMPLETE and committed on branch \`$branch\`,
but master has moved and the branch no longer rebases cleanly. (Ignore any note
above claiming the branch is already rebased — it is NOT yet.) Conflicting
file(s): $conflict_files

These conflicts are almost always ADDITIVE — another feature added code to the
same region. Do this BEFORE any other work:
  1. git rebase origin/master
  2. For each conflict, edit the file and KEEP BOTH sides' changes (do not delete
     the other feature's code); make the result valid, coherent GDScript.
  3. git add <files> && git rebase --continue   (repeat until the rebase finishes)
  4. Re-run the gate test(s) to confirm still green.
Only once the rebase is clean should you finish any remaining spec work, then
commit. The wrapper squash-merges the resolved branch to master."
    fi
    echo "$item_brief" > "$item_log.brief"

    # Fire developer under a PROGRESS-AWARE watchdog (not a blind timeout).
    #
    # The old design SIGKILLed the dev after a fixed MAX_DEV_MINUTES. With
    # dev_concurrency=3 that guillotined productive devs mid-work: a dev
    # steadily editing files + running tests at the 30-min mark got killed
    # right at the finish line (2026-05-27: 11 kills/afternoon, all 0-byte
    # logs = killed mid-work, zero ships). A blind clock can't tell a busy
    # dev from a hung one.
    #
    # Instead we POLL the dev once a minute and only kill it if it shows
    # NO progress for DEV_STALL_MINUTES. "Progress" = either the worktree
    # got new file writes (edits / test output) OR claude burned CPU since
    # the last check. A dev that keeps working is never killed, however
    # long it takes. MAX_DEV_MINUTES remains as a generous absolute
    # backstop against a dev that "progresses" forever (e.g. edit-loop).
    SPRAXEL_ITEM_BRIEF="$item_log.brief" bash "$RUN_AGENT" developer >> "$item_log" 2>&1 &
    dev_pid=$!
    (
      stall_secs=$((DEV_STALL_MINUTES * 60))
      abs_secs=$((MAX_DEV_MINUTES * 60))
      started=$(date +%s)
      last_progress=$started
      last_fp=""
      last_pushed=""
      while kill -0 "$dev_pid" 2>/dev/null; do
        sleep 60
        kill -0 "$dev_pid" 2>/dev/null || break
        now=$(date +%s)
        # Progress signal: newest file mtime in the worktree (excl .git +
        # .godot). This captures the dev's REAL output — source edits
        # (Edit/Write) AND test-log files (.factory/local-test-logs) a test
        # run writes. A working dev touches a file within the stall window;
        # a hung/degraded claude touches nothing.
        #
        # We deliberately do NOT use claude's CPU time as a progress signal:
        # claude -p is network-bound (the reasoning is server-side), so a
        # genuinely-hung session still ticks a hair of local CPU on keepalive
        # — enough to fool a "CPU advanced" check. 2026-05-27 incident: w1's
        # claude ran 72 min with 0 file edits in 15 min while the CPU-based
        # check kept resetting the stall timer; it would have wasted the
        # whole 90-min cap. File mtime is the honest signal.
        newest=$(find "$WORK_DIR" -type f \
                   -not -path '*/.git/*' -not -path '*/.godot/*' \
                   -exec stat -f '%m' {} + 2>/dev/null | sort -rn | head -1)
        if [ "${newest:-0}" != "${last_fp:-0}" ]; then
          last_fp="${newest:-0}"; last_progress=$now
        fi
        # Persist committed work to origin each poll (best-effort), so the dev's
        # incremental commits survive even if the WRAPPER itself dies before the
        # end-of-run push. Only pushes when the branch head moved; failures (e.g.
        # a momentary race with the dev's own git) are ignored and retried next
        # poll. The branch is unique to this item, so the force-push is safe.
        head=$(git -C "$WORK_DIR" rev-parse HEAD 2>/dev/null)
        if [ -n "$head" ] && [ "$head" != "$last_pushed" ]; then
          if git -C "$WORK_DIR" push --force-with-lease --quiet origin "$branch":"$branch" 2>/dev/null; then
            last_pushed="$head"
          fi
        fi
        if [ $((now - last_progress)) -ge "$stall_secs" ]; then
          echo "continuous: dev STALLED — no file writes for ${DEV_STALL_MINUTES}m — killing tree (PID $dev_pid)" >> "$item_log"
          kill_tree "$dev_pid" KILL
          # Reclaim any locks the just-killed tree held (its test lock, dev lock).
          sweep_dead_locks "$LOCKS_DIR" "$game_dir/.factory" >> "$item_log" 2>&1
          break
        fi
        if [ $((now - started)) -ge "$abs_secs" ]; then
          echo "continuous: dev hit absolute cap ${MAX_DEV_MINUTES}m (still making progress, but capping) — killing tree (PID $dev_pid)" >> "$item_log"
          kill_tree "$dev_pid" KILL
          sweep_dead_locks "$LOCKS_DIR" "$game_dir/.factory" >> "$item_log" 2>&1
          break
        fi
      done
    ) &
    dev_watchdog_pid=$!
    wait "$dev_pid" 2>/dev/null
    dev_rc=$?
    # Cancel watchdog (and its sleep) once dev is done.
    kill_tree "$dev_watchdog_pid" KILL 2>/dev/null
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
      acquire_lock "$clarify_lock" 60 0.3 || true   # best-effort; fall through on timeout
      (
        trap 'release_lock "'"$clarify_lock"'"' EXIT
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

    # Test gate. The batch test runner (scripts/test_runner.sh) sweeps the whole
    # suite separately and files any failure as a [test_failure] item. The only
    # WRAPPER-driven test run is this gate, and it fires for [test_failure] items
    # only: we re-run ONLY the named test (test_ref) so the fix is verified before
    # it ships. It's cheap (one test, not the suite → no CPU contention). (Devs
    # may also self-run a single test during their work in two cases — a
    # [test_failure] fix and validating a [bug] regression test — but those are
    # dev-side, not this gate; see spraxel-developer.md step 7.)
    if [ "$is_test_failure" = "true" ] && [ -n "$test_ref" ]; then
      echo "continuous: [test_failure] gate — re-running $test_ref" >> "$item_log"
      SPRAXEL_GAME_DIR="$game_dir" SPRAXEL_WORKER_ID="$WORKER_ID" \
        bash "$WORK_DIR/scripts/run_local_tests.sh" --only "$test_ref" --quiet >> "$item_log" 2>&1
      rc=$?
      tf_pass=$(python3 -c "
import json
try:
    print('1' if json.load(open('$game_dir/.factory/local-tests-status-w$WORKER_ID.json')).get('pass') else '0')
except Exception:
    print('0')
")
      if [ "$rc" -ne 0 ] || [ "$tf_pass" != "1" ]; then
        echo "continuous: [test_failure] gate FAILED — $test_ref still failing on attempt $attempt" >> "$item_log"
        [ "$attempt" -lt 2 ] && { git checkout --quiet "$branch"; continue; }
        outcome=fail
        break
      fi
      echo "continuous: [test_failure] gate PASSED — $test_ref now green" >> "$item_log"
    fi

    if ! bash "$RUN_AGENT" reviewer >> "$item_log" 2>&1; then
      echo "continuous: reviewer BLOCKED" >> "$item_log"
      outcome=fail
      break
    fi

    # ── Asset-gap audit (mechanical) ─────────────────────────────────────
    # If the dev added new entity / level / archetype files but the commit
    # body doesn't mention any MANUAL items, block the merge. Catches the
    # "dog-with-Polygon2D-and-no-MANUAL-ART" failure mode (2026-05-27 CEO
    # audit: the dog shipped with programmer art + no follow-up tasks).
    #
    # Patterns checked (file-add only, via --diff-filter=A):
    #   - scenes/enemies/*.tscn      → expects MANUAL - ART  + MANUAL - SFX
    #   - scripts/ai/<file>.gd       → expects MANUAL - ART  + MANUAL - SFX
    #   - scenes/levels/sample/*.tscn → expects MANUAL - LEVEL
    #
    # Escape hatch: if the commit body contains "manual-asset audit: N/A"
    # (with reason), the dev has explicitly attested no follow-ups needed.
    asset_gap=$(python3 - "$item_log" <<'PY'
import re, subprocess, sys
log_path = sys.argv[1]
# List files ADDED in this feat branch vs master
try:
    added = subprocess.check_output(
        ["git", "diff", "--diff-filter=A", "--name-only", "master...HEAD"],
        stderr=subprocess.DEVNULL, text=True
    ).strip().splitlines()
except subprocess.CalledProcessError:
    added = []
triggers = []
for f in added:
    if re.match(r"^scenes/enemies/.+\.tscn$", f):
        triggers.append(("entity", f, ["ART", "SFX"]))
    elif re.match(r"^scripts/ai/.+\.gd$", f):
        triggers.append(("entity-script", f, ["ART", "SFX"]))
    elif re.match(r"^scenes/levels/sample/.+\.tscn$", f):
        triggers.append(("level", f, ["LEVEL"]))
if not triggers:
    sys.exit(0)
# Find the COMMIT_BODY in the item log
try:
    log = open(log_path).read()
except Exception:
    log = ""
m = re.findall(r"COMMIT_BODY:\s*\n(.*?)(?:\nEND_COMMIT_BODY|\Z)", log, re.S)
body = m[-1] if m else ""
if re.search(r"manual-asset audit:\s*N/?A\b", body, re.I):
    sys.exit(0)  # explicit attestation, accept
# Check each trigger has a corresponding manual follow-up mention. Accept both
# the canonical bracket form ("[manual] ART - ...") and the legacy prefix form
# ("MANUAL - ART - ...") — match a manual marker followed by the category word.
missing = []
for kind, path, cats in triggers:
    for cat in cats:
        if not re.search(rf"(?:\[manual\]|MANUAL)\b[^\n]*\b{cat}\b", body, re.I):
            missing.append(f"{path} (new {kind}) missing [manual] {cat}")
if missing:
    for line in missing:
        print(line)
    sys.exit(1)
PY
    )
    asset_gap_rc=$?
    if [ "$asset_gap_rc" -ne 0 ]; then
      echo "continuous: ASSET-GAP audit FAILED — dev shipped a new entity/level without filing MANUAL follow-ups:" >> "$item_log"
      echo "$asset_gap" >> "$item_log"
      echo "$asset_gap" | sed 's/^/  /'
      echo "continuous: (escape hatch: include 'manual-asset audit: N/A — <reason>' in COMMIT_BODY if no follow-up is needed)" >> "$item_log"
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

    # FINAL tag scrub — runs on the fully-assembled subject, so it covers
    # EVERY path that can set it: the dev's COMMIT_SUBJECT, the $next_title
    # fallback (when the dev omits COMMIT_SUBJECT — that fallback uses the
    # raw title which is stripped of [wip:N] only, so [retry]/[bug]/etc.
    # survived → the 2026-05-28 leak), and the feat: prepend above. Generic:
    # preserves the conv-commit prefix, removes any [..] tag + pN marker
    # from the title portion. This is the single chokepoint — no tag reaches
    # a shipped subject regardless of how the subject was built.
    commit_subject=$(printf '%s' "$commit_subject" | python3 -c "
import sys, re
s = sys.stdin.read().strip()
m = re.match(r'^((?:feat|fix|refactor|perf|docs|chore|test|style|build|ci)(?:\([^)]*\))?:\s*)?(.*)\$', s, re.S)
prefix, rest = (m.group(1) or ''), m.group(2)
while True:
    nr = re.sub(r'^\s*(\[[^\]]+\]|p[0-3])\s*', '', rest, flags=re.I)
    if nr == rest:
        break
    rest = nr
print((prefix + rest).strip())
")

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
    if ! acquire_lock "$merge_lock" 60 0.3; then
      echo "continuous: merge lock held >60s — aborting" >> "$item_log"
      outcome=fail
      break
    fi
    # Subshell so cd doesn't leak; trap to release lock no matter what.
    (
      trap 'release_lock "'"$merge_lock"'"' EXIT
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
        # ── Game.md survival gate ────────────────────────────────────────
        # The Reviewer verifies the dev WROTE a Game.md block on the branch,
        # but a block can be absent from the FINAL squash — lost to conflict
        # resolution, or never re-added on a resume/retry rebuild (2026-05-29:
        # CeilingDropTrap shipped doc-less via the reclaim/resume path). Re-check
        # the SQUASHED result: if it has no Game.md change but one is REQUIRED —
        # a [game-feature] always needs a block; the branch changed Game.md so it
        # must survive; or the squash adds a `--demo-feature` debug hook (the
        # deterministic "player-facing" signal that even [feature] items carry) —
        # bounce to the retry path so the dev (re)adds the block.
        if git diff --cached --quiet -- Game.md 2>/dev/null; then
          _need_gm=0
          echo "$next_title" | grep -qiE '\[game-feature\]' && _need_gm=1
          git diff --quiet origin/master..."$branch" -- Game.md 2>/dev/null || _need_gm=1
          git diff --cached -- scripts/systems/debug_boot.gd 2>/dev/null \
            | grep -qE '^\+[[:space:]]*func _demo_|--demo-feature=' && _need_gm=1
          if [ "$_need_gm" -eq 1 ]; then
            echo "continuous: MERGE GATE — player-facing change but Game.md NOT updated in the squash; bouncing to [retry] so the dev (re)adds the Game.md block." >> "$item_log"
            git reset --hard origin/master --quiet 2>/dev/null || true
            git clean -fd --quiet 2>/dev/null || true
            exit 1
          fi
        fi
        if git -c user.email=continuous-bot@spraxel.ai -c user.name='Spraxel Continuous' \
                commit --quiet -m "$commit_message" \
           && git push --quiet origin master; then
          python3 "$WORKMD" ship "$game_dir/WORK.md" "$next_title" >> "$item_log" 2>&1 || true
          # If this was the last child of an epic, auto-ship its parent too.
          python3 "$WORKMD" reconcile-epics "$game_dir/WORK.md" >> "$item_log" 2>&1 || true
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
        #
        # CRITICAL: `git merge --squash` does NOT create a MERGE_HEAD, so
        # `git merge --abort` is a no-op here ("fatal: There is no merge to
        # abort") — the conflicted + staged squash state would PERSIST in
        # game_dir. That left the working tree dirty/UU, which then broke the
        # [retry] self-heal commit ("cannot reach master") AND the next
        # worker's merge, orphaning the item as [wip] (2026-05-29 incident).
        # Hard-reset to clean master + drop untracked leftovers (git clean
        # respects .gitignore, so the .godot cache etc. are safe; this also
        # stops orphan untracked scenario files from polluting test
        # enumeration) so game_dir is pristine for the retry path below.
        git reset --hard origin/master --quiet 2>/dev/null || true
        git clean -fd --quiet 2>/dev/null || true
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
      # Ship report → MORNING.md news digest (reports for Developer+Reviewer,
      # who don't self-report; one line per shipped item).
      printf '%s\n' "- Shipped: $short_title" \
        | bash "$REPO_DIR/scripts/report.sh" continuous >/dev/null 2>&1 || true
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
    acquire_lock "$retry_lock" 60 0.3 || true   # best-effort; fall through on timeout
    (
      trap 'release_lock "'"$retry_lock"'"' EXIT
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
  # force_interactive_developers: a running worker quiesces (behaves like a pause) so
  # the interactive /spraxel-develop loop is the ONLY claimant — no double-developer
  # race. Re-checked every poll, so flipping the flag back to false auto-resumes this
  # worker. tick.sh stops SPAWNING new workers; this idles ones already alive.
  _fid=$(python3 "$REPO_DIR/scripts/spx_config.py" get continuous.force_interactive_developers 2>/dev/null)
  if [ "$_fid" = "true" ] || [ "$_fid" = "True" ]; then
    sleep "$POLL_INTERVAL_SECONDS"
    continue
  fi
  # Test-runner drain. When a batch test-runner run is scheduled or active, the
  # runner must run EXCLUSIVELY — so we stop claiming new items and idle here.
  # This is at the TOP of the loop (a claim gate), NOT the mid-run pause check,
  # so a worker that's mid-item FINISHES + ships it before idling — that's how
  # "wait for current agents to finish" drains cleanly. tick.sh launches the
  # runner once every worker has reached this idle state.
  if [ -e "$CACHE_DIR/test-runner-pending" ] || [ -e "$CACHE_DIR/test-runner-active" ]; then
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
      # Atomic +1 across parallel workers — never lose an increment. BUT when
      # cap_excludes_test_fixes is on, a [test_failure] fix is test hygiene, not
      # a feature ship, so it does NOT count toward target_per_batch (the loop
      # keeps fixing broken tests without parking at the cap).
      if [ "${CAP_EXCLUDES_TEST_FIXES:-0}" = "1" ] && [ "${CURRENT_ITEM_IS_TEST_FAILURE:-false}" = "true" ]; then
        trace "ship: test-fix shipped — NOT counted toward cap (cap_excludes_test_fixes)"
      else
        inc_state shipped_since_last_signal >/dev/null
      fi
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
