#!/usr/bin/env bash
# run_local_tests.sh — local Mac test runner.
#
# What it does:
#   1. Refresh Godot's class-name cache (editor --headless run, ~5-10s)
#   2. Run GUT unit tests under test/unit/
#   3. Run every acceptance scenario in scripts/scenarios/*.gd
#   4. Write .factory/local-tests-status.json with the result
#   5. On failure: print summary + macOS notification (unless --quiet)
#
# Honors Philosophy.run_mode=dryrun (exits silently).
#
# Runs via launchd every 30 min, and is also invoked by the continuous
# Developer loop after every commit to gate ship/escalate.
#
# Exit code: 0 = all green, 1 = failures, 2 = setup error.

# Note: not using `set -e` or `set -u` because macOS bash 3.2 errors on
# empty-array references like "${arr[@]}" with set -u, and we rely on
# graceful continuation when individual sub-commands fail.
set -o pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

# Dryrun guard
if grep -qE '^run_mode:\s*"dryrun"' Philosophy.md; then
  echo "[local-tests] Philosophy.run_mode=dryrun — skipping"
  exit 0
fi

# Parallel-dev support. The continuous_dev wrapper invokes this script
# from inside a per-worker GIT WORKTREE (so tests exercise the worker's
# feat-branch checkout, not the main checkout's master state). When
# that happens the wrapper exports:
#   SPRAXEL_GAME_DIR   — absolute path to the MAIN checkout (game repo root)
#   SPRAXEL_WORKER_ID  — integer worker id (1..N)
#
# The shared test lockdir lives under SPRAXEL_GAME_DIR/.factory/ so all
# workers serialize on the SAME lock (otherwise per-worktree lockdirs
# would let N workers godot-spam in parallel — defeating the purpose).
# The per-run status JSON is suffixed with worker id so concurrent
# wrapper reads don't race ("worker A reads what worker B just wrote").
# When run standalone (launchd cron or CEO manual invocation), neither
# env var is set → falls back to REPO_DIR + no suffix (legacy paths).
LOCK_BASE="${SPRAXEL_GAME_DIR:-$REPO_DIR}"
STATUS_SUFFIX=""
[ -n "${SPRAXEL_WORKER_ID:-}" ] && STATUS_SUFFIX="-w${SPRAXEL_WORKER_ID}"

# Serialize parallel test runs. Multiple workers (parallel-dev) + the launchd
# cron all invoke this script; running 3+ godot suites in parallel saturates
# CPU + disk + the class-name cache rebuild, slowing every individual run.
# A single mkdir-based lock acquires before each test session; other invocations
# wait their turn. Each individual run finishes faster (no contention) and the
# class-cache stays warm between back-to-back runs (next run skips the ~30s
# parse step). Stale lock (process died without releasing) is swept after 30 min.
TEST_LOCK="$LOCK_BASE/.factory/.test-running.lockdir"
mkdir -p "$LOCK_BASE/.factory"

# stale godot sweep: kill any headless Godot processes older than 2 hours.
# Guards against the hung-godot incident where non-headless --demo-feature
# runs or scenarios that forgot quit() left processes running indefinitely.
if command -v pgrep &>/dev/null; then
  pgrep -f "Godot.*--headless" 2>/dev/null | while read -r pid; do
    if [ -n "$pid" ]; then
      proc_age=$(( $(date +%s) - $(ps -o lstart= -p "$pid" 2>/dev/null | xargs -I{} date -j -f "%c" "{}" "+%s" 2>/dev/null || echo 0) ))
      if [ "${proc_age:-0}" -gt 7200 ]; then
        echo "[local-tests] stale godot process $pid (age ${proc_age}s) — killing" >&2
        kill "$pid" 2>/dev/null
      fi
    fi
  done
fi

# Sweep stale lockdir if older than 30 minutes (3x typical run time).
if [ -d "$TEST_LOCK" ]; then
  lock_age=$(( $(date +%s) - $(stat -f%m "$TEST_LOCK" 2>/dev/null || echo 0) ))
  if [ "$lock_age" -gt 1800 ]; then
    echo "[local-tests] sweeping stale lock (age ${lock_age}s)" >&2
    rmdir "$TEST_LOCK" 2>/dev/null
  fi
fi
# Block until we can acquire.
wait_start=$(date +%s)
while ! mkdir "$TEST_LOCK" 2>/dev/null; do
  sleep 5
  waited=$(( $(date +%s) - wait_start ))
  if [ "$waited" -gt 1800 ]; then
    echo "[local-tests] ERROR: waited >30 min for test lock; giving up" >&2
    exit 2
  fi
done
trap 'rmdir "$TEST_LOCK" 2>/dev/null' EXIT INT TERM
[ "$QUIET" -eq 0 ] && echo "[local-tests] acquired lock after ${waited:-0}s"

# Find Godot binary (read from Philosophy.dev.godot_binary)
GODOT=$(python3 -c "
import yaml, re
text = open('Philosophy.md').read()
fm = re.search(r'^---\n(.*?)\n---', text, re.DOTALL).group(1)
data = yaml.safe_load(fm)
print(data.get('dev', {}).get('godot_binary', ''))
")
if [ -z "$GODOT" ] || [ ! -x "$GODOT" ]; then
  echo "[local-tests] ERROR: Godot binary not found at '$GODOT'"
  exit 2
fi

# Helper: bounded run (stock macOS lacks `timeout`).
# The previous perl-alarm version relied on SIGALRM killing the
# exec'd child. Godot apparently sometimes ignores or swallows SIGALRM
# (see 2026-05-27 hung-godot incident — two processes ran for 27 hours).
# Switching to a fork-the-killer pattern: spawn the command in the
# background, then a separate sleeper that SIGKILLs by PID when the
# deadline hits. SIGKILL can't be blocked.
run_bounded() {
  local seconds="$1"; shift
  "$@" &
  local cmd_pid=$!
  ( sleep "$seconds"; kill -KILL "$cmd_pid" 2>/dev/null ) &
  local killer_pid=$!
  wait "$cmd_pid" 2>/dev/null
  local rc=$?
  # Cancel the killer if the command finished first.
  kill -TERM "$killer_pid" 2>/dev/null
  wait "$killer_pid" 2>/dev/null
  return $rc
}

STAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# Status file is per-worker when SPRAXEL_WORKER_ID is set (parallel-dev),
# else the legacy global path (single-worker mode + launchd cron).
# Always written under LOCK_BASE so all workers + the launchd cron read
# the SAME directory regardless of which worktree this script runs from.
STATUS_FILE="$LOCK_BASE/.factory/local-tests-status${STATUS_SUFFIX}.json"
LOG_DIR="$REPO_DIR/.factory/local-test-logs"
mkdir -p "$LOG_DIR" "$(dirname "$STATUS_FILE")"
LOG="$LOG_DIR/$STAMP.log"

echo "[local-tests] $STAMP — starting" | tee "$LOG"

failures=()

# 1. Editor import (populate class_name cache)
echo "[local-tests] populating class-name cache..." | tee -a "$LOG"
run_bounded 60 "$GODOT" --editor --headless --path . --quit-after 30 >>"$LOG" 2>&1 || true

# 2. GUT unit tests
echo "[local-tests] running GUT unit tests..." | tee -a "$LOG"
gut_out=$(run_bounded 120 "$GODOT" --headless --path . \
    -s res://addons/gut/gut_cmdln.gd \
    -gdir=res://test/unit \
    -ginclude_subdirs \
    -gexit 2>&1)
gut_exit=$?
echo "$gut_out" >>"$LOG"
if ! echo "$gut_out" | grep -qE "^Totals|Run Summary"; then
  failures+=("GUT: no Totals summary produced (editor-import probably failed)")
elif [ $gut_exit -ne 0 ]; then
  failed=$(echo "$gut_out" | grep -oE "Failures.*: *[0-9]+" | head -1)
  failures+=("GUT: ${failed:-non-zero exit} (rc=$gut_exit)")
fi

# 3. Acceptance scenarios
echo "[local-tests] running acceptance scenarios..." | tee -a "$LOG"
shopt -s nullglob
for scenario in scripts/scenarios/*.gd; do
  base=$(basename "$scenario" .gd)
  [ "$base" = "_base" ] && continue
  slug=$(echo "$base" | tr '_' '-')
  echo "[local-tests] scenario: $slug" >>"$LOG"
  out=$(run_bounded 30 "$GODOT" --headless --path . -- --demo-feature="$slug" --trace-file="/tmp/$slug.jsonl" --quit-after=10 2>&1)
  echo "$out" >>"$LOG"
  # Check PASS first: Godot always emits "ERROR: N resources still in use at
  # exit" after quit() even on a clean run — that cleanup line must NOT
  # override an explicit SCENARIO ... PASS printed before it.
  if echo "$out" | grep -qE "SCENARIO $slug[: ]+PASS"; then
    : # explicit pass — cleanup ERRORs are noise, ignore them
  elif echo "$out" | grep -qE "SCENARIO .* FAIL"; then
    failures+=("scenario $slug: printed FAIL")
  elif echo "$out" | grep -qE "^(SCRIPT ERROR|Parse error)"; then
    failures+=("scenario $slug: script error")
  elif echo "$out" | grep -qE "^ERROR:"; then
    # Runtime ERROR without any PASS/FAIL line → something went wrong
    failures+=("scenario $slug: script error")
  else
    failures+=("scenario $slug: silent skip or timeout (no PASS)")
  fi
done

# 4. Write status JSON.  Build it in Python directly (no bash → Python
#    interpolation, which caused 'pass: false' parse errors previously).
python3 - "$STATUS_FILE" "$STAMP" "$LOG" "${failures[@]}" <<'PY'
import json, pathlib, sys
status_file, stamp, log_file, *failures = sys.argv[1:]
data = {
    "stamp":    stamp,
    "pass":     len(failures) == 0,
    "failures": failures,
    "log":      log_file,
}
pathlib.Path(status_file).parent.mkdir(parents=True, exist_ok=True)
pathlib.Path(status_file).write_text(json.dumps(data, indent=2))
PY

# 5. Report
if [ ${#failures[@]} -eq 0 ]; then
  echo "[local-tests] ✅ all green at $STAMP" | tee -a "$LOG"
  exit 0
fi

echo "[local-tests] 🐛 ${#failures[@]} failure(s):" | tee -a "$LOG"
for f in "${failures[@]}"; do
  echo "  - $f" | tee -a "$LOG"
done

# Test failures are surfaced via:
#   - $STATUS_FILE (JSON, read by morning-briefer + dashboard.py)
#   - $LOG (per-run output)
#   - triager agent (batches into [bug] WORK.md items the next morning)
# No macOS notification — they were noisy + the CEO doesn't need a beep
# for transient test failures the [retry] loop will handle on its own.

exit 1
