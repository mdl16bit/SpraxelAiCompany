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

# Helper: bounded run (stock macOS lacks `timeout`)
run_bounded() {
  local seconds="$1"; shift
  perl -e 'alarm shift @ARGV; exec @ARGV' "$seconds" "$@"
}

STAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
STATUS_FILE="$REPO_DIR/.factory/local-tests-status.json"
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
  if echo "$out" | grep -qE "^(ERROR:|SCRIPT ERROR|Parse error)"; then
    failures+=("scenario $slug: script error")
  elif echo "$out" | grep -qE "SCENARIO .* FAIL"; then
    failures+=("scenario $slug: printed FAIL")
  elif ! echo "$out" | grep -qE "SCENARIO $slug[: ]+PASS"; then
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
