#!/usr/bin/env bash
# test_runner.sh — the batch test runner.
#
# Developers no longer run tests during feature work (they only write + commit
# them). This runner is the ONE place the whole suite is exercised: it runs
# every test, ONE AT A TIME (serialized → zero CPU contention), and files each
# failure as a [test_failure] work item at the top of WORK.md for a developer
# to fix.
#
# Dispatched by tick.sh — NOT on a cron. Two triggers (see tick.sh):
#   (a) the ship cap maxed out AND all workers have drained, or
#   (b) `force_after_engine_hours` of engine on-time have elapsed since the
#       last run.
# While it runs, tick.sh spawns no new developer workers (it's exclusive).
#
# Budget: runs until every test has run OR `test_runner.max_minutes` elapses
# (schedule.yaml; 0 = run to completion). It TRACKS which test-refs it has run
# this cycle and resumes with the un-run ones next time; once a full cycle
# completes it resets and starts fresh.
#
# Exit code: 0 always (a failing test is filed as work, not a runner error).

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEDULE="$REPO_DIR/schedule.yaml"
WORKMD="$REPO_DIR/scripts/workmd.py"
LOCKS_DIR="$REPO_DIR/.locks"
CACHE_DIR="$REPO_DIR/.cache"
PROGRESS="$CACHE_DIR/test-runner-progress.json"
UPTIME_FILE="$CACHE_DIR/engine-uptime-since-test.json"
PENDING_FLAG="$CACHE_DIR/test-runner-pending"
ACTIVE_FLAG="$CACHE_DIR/test-runner-active"
RUNNER_LOCK="$LOCKS_DIR/test-runner.lockdir"
MASTER_LOCK="$LOCKS_DIR/master-push.lockdir"
. "$REPO_DIR/scripts/lockutils.sh"
mkdir -p "$LOCKS_DIR" "$CACHE_DIR"

log() { echo "[test-runner] $(date '+%H:%M:%S') $*"; }

# --- single-instance guard -------------------------------------------------
if ! acquire_lock "$RUNNER_LOCK" 5 0.3; then
  log "another test_runner holds the lock — exiting"
  exit 0
fi
# Mark active; clear pending. On ANY exit: release lock, clear active, reset
# the engine-uptime counter (this run satisfies the 100h fallback).
: > "$ACTIVE_FLAG"
rm -f "$PENDING_FLAG" 2>/dev/null
cleanup() {
  python3 - "$UPTIME_FILE" <<'PY' 2>/dev/null || true
import json, sys, time
f = sys.argv[1]
json.dump({"seconds": 0, "last_tick_ts": int(time.time())}, open(f, "w"))
PY
  rm -f "$ACTIVE_FLAG" 2>/dev/null
  release_lock "$RUNNER_LOCK"
}
trap cleanup EXIT INT TERM

# --- config ----------------------------------------------------------------
read -r GAME_DIR MAX_MINUTES <<EOF
$(python3 - "$SCHEDULE" <<'PY'
import sys, os, re
text = open(sys.argv[1]).read()
m = re.search(r"game_dir:\s*(\S+)", text)
game = os.path.expanduser(m.group(1)) if m else ""
mm = re.search(r"^test_runner:\s*\n((?:(?:[ \t]+.*)?\n)*?)(?=^\S|\Z)", text, re.M)
maxm = 120
if mm:
    x = re.search(r"^\s+max_minutes:\s*(\d+)", mm.group(1), re.M)
    if x:
        maxm = int(x.group(1))
print(game, maxm)
PY
)
EOF
WORK_MD="$GAME_DIR/WORK.md"
RLT="$GAME_DIR/scripts/run_local_tests.sh"
STATUS_JSON="$GAME_DIR/.factory/local-tests-status-wtr.json"
if [ -z "$GAME_DIR" ] || [ ! -f "$WORK_MD" ] || [ ! -x "$RLT" ]; then
  log "ERROR: game_dir/WORK.md/run_local_tests.sh not found ($GAME_DIR) — aborting"
  exit 0
fi
if [ "${MAX_MINUTES:-120}" -gt 0 ] 2>/dev/null; then
  DEADLINE=$(( $(date +%s) + MAX_MINUTES * 60 ))
else
  DEADLINE=0   # run to completion
fi
log "start — game=$GAME_DIR max_minutes=${MAX_MINUTES} ($([ "$DEADLINE" = 0 ] && echo 'run to completion' || echo "deadline $(date -r $DEADLINE '+%H:%M')"))"

# --- sync the main checkout to the pushed tip (workers are drained) --------
if acquire_lock "$MASTER_LOCK" 120 0.5; then
  (
    cd "$GAME_DIR" || exit 0
    git fetch --quiet origin master 2>/dev/null
    [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" = "master" ] || git checkout --quiet master 2>/dev/null
    # Only reset if there are no local-only commits (there shouldn't be).
    [ "$(git rev-list --count origin/master..HEAD 2>/dev/null || echo 0)" = "0" ] \
      && git reset --hard origin/master --quiet 2>/dev/null
  )
  release_lock "$MASTER_LOCK"
  log "synced master to origin tip @ $(git -C "$GAME_DIR" rev-parse --short HEAD 2>/dev/null)"
else
  log "WARN: could not acquire master-push lock to sync — running against current checkout"
fi

# --- enumerate the suite + load tracking -----------------------------------
# (no `mapfile` — macOS ships bash 3.2, which lacks it)
ALL_REFS=()
while IFS= read -r _r; do [ -n "$_r" ] && ALL_REFS+=("$_r"); done < <(bash "$RLT" --list 2>/dev/null)
TOTAL=${#ALL_REFS[@]}
if [ "$TOTAL" -eq 0 ]; then
  log "ERROR: --list returned no tests — aborting"
  exit 0
fi

# Determine the un-run refs for THIS cycle (preserving --list order). If the
# prior cycle already covered everything, start a fresh cycle.
# (Refs are passed via a FILE arg, not stdin — a `<<'PY'` heredoc would
#  otherwise commandeer stdin and the pipe would be ignored.)
QUEUE_FILE=$(mktemp); ALL_FILE=$(mktemp)
printf '%s\n' "${ALL_REFS[@]}" > "$ALL_FILE"
python3 - "$PROGRESS" "$ALL_FILE" "$QUEUE_FILE" <<'PY'
import json, sys
progress_file, all_file, queue_file = sys.argv[1], sys.argv[2], sys.argv[3]
all_refs = [l for l in open(all_file).read().splitlines() if l]
try:
    prog = json.load(open(progress_file))
    ran = set(prog.get("ran", []))
except Exception:
    ran = set()
# If everything has run, this is a fresh cycle.
if ran >= set(all_refs):
    ran = set()
queue = [r for r in all_refs if r not in ran]
open(queue_file, "w").write("\n".join(queue))
PY
QUEUE=()
while IFS= read -r _r; do [ -n "$_r" ] && QUEUE+=("$_r"); done < "$QUEUE_FILE"
rm -f "$QUEUE_FILE" "$ALL_FILE"
log "suite: $TOTAL tests; ${#QUEUE[@]} un-run this cycle"

record_ran() {  # append a ref to progress.ran (create cycle_id if new)
  python3 - "$PROGRESS" "$1" <<'PY' 2>/dev/null || true
import json, sys, time
f, ref = sys.argv[1], sys.argv[2]
try: prog = json.load(open(f))
except Exception: prog = {}
prog.setdefault("cycle_id", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
ran = prog.get("ran", [])
if ref not in ran: ran.append(ref)
prog["ran"] = ran
json.dump(prog, open(f, "w"), indent=2)
PY
}

# --- run the queue ---------------------------------------------------------
ran_count=0; fail_count=0; filed_count=0
for ref in "${QUEUE[@]}"; do
  if [ "$DEADLINE" -ne 0 ] && [ "$(date +%s)" -ge "$DEADLINE" ]; then
    log "max_minutes reached — stopping (ran $ran_count this run; will resume next time)"
    break
  fi
  [ -e "$PENDING_FLAG" ] && rm -f "$PENDING_FLAG" 2>/dev/null  # belt-and-suspenders
  SPRAXEL_GAME_DIR="$GAME_DIR" SPRAXEL_WORKER_ID="tr" \
    bash "$RLT" --only "$ref" --quiet >/dev/null 2>&1
  ran_count=$((ran_count + 1))
  record_ran "$ref"
  # Read pass/fail + first failure excerpt from the per-runner status JSON.
  result=$(python3 - "$STATUS_JSON" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("ERR|status json unreadable"); raise SystemExit
ok = bool(d.get("pass"))
exc = (d.get("failures") or d.get("scenario_failures") or [""])[0]
print(("PASS|" if ok else "FAIL|") + (exc or "").replace("\n", " ")[:200])
PY
)
  verdict="${result%%|*}"; excerpt="${result#*|}"
  if [ "$verdict" != "PASS" ]; then
    fail_count=$((fail_count + 1))
    log "FAIL $ref — $excerpt"
    # File a deduped [test_failure] at the top of WORK.md, under the lock.
    if acquire_lock "$MASTER_LOCK" 60 0.5; then
      (
        cd "$GAME_DIR" || exit 0
        git fetch --quiet origin master 2>/dev/null
        [ "$(git rev-list --count origin/master..HEAD 2>/dev/null || echo 0)" = "0" ] \
          && git reset --hard origin/master --quiet 2>/dev/null
        out=$(python3 "$WORKMD" file-test-failure "$WORK_MD" \
              --test-ref "$ref" \
              "[test_failure] p1 $ref failing" \
              --detail "$excerpt" 2>&1)
        if echo "$out" | grep -q '^filed '; then
          git add WORK.md 2>/dev/null
          git -c user.email=testrunner-bot@spraxel.ai -c user.name='Spraxel Test Runner' \
              commit --quiet -m "test: file [test_failure] for $ref" 2>/dev/null
          git push --quiet origin master 2>/dev/null && exit 10
        fi
        exit 0
      )
      [ $? -eq 10 ] && filed_count=$((filed_count + 1))
      release_lock "$MASTER_LOCK"
    fi
  fi
done

# --- cycle bookkeeping + report --------------------------------------------
cycle_done=$(python3 - "$PROGRESS" <<'PY'
import json, sys
try: prog = json.load(open(sys.argv[1]))
except Exception: prog = {}
print(len(prog.get("ran", [])))
PY
)
cycle_complete="no"
if [ "${cycle_done:-0}" -ge "$TOTAL" ]; then
  # Whole suite covered → reset tracking so the next run starts a fresh cycle.
  rm -f "$PROGRESS" 2>/dev/null
  cycle_complete="yes"
  log "full cycle complete — tracking reset"
fi

REPORTS_DIR="$GAME_DIR/.factory/local/reports"
mkdir -p "$REPORTS_DIR"
RTS=$(date -u +%Y-%m-%dT%H-%M-%SZ)
{
  echo "# Test runner — $(date '+%Y-%m-%d %H:%M %Z')"
  echo ""
  echo "- Suite size: $TOTAL tests"
  echo "- Ran this invocation: $ran_count"
  echo "- Failures: $fail_count (filed $filed_count new [test_failure] items; rest were dupes of open ones)"
  echo "- Full cycle complete: $cycle_complete"
} > "$REPORTS_DIR/$RTS-test_runner.md"

log "done — ran $ran_count, failures $fail_count, filed $filed_count, cycle_complete=$cycle_complete"
exit 0
