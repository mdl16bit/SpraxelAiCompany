#!/usr/bin/env bash
# run_local_tests.sh — local Mac test runner; replaces GH Actions test.yml.
#
# What it does (mirrors test.yml's flow):
#   1. Refresh Godot's class-name cache (editor --headless run, ~5-10s)
#   2. Run GUT unit tests (test/unit/*)
#   3. Run every acceptance scenario in scripts/scenarios/*.gd
#   4. Write `.factory/local-tests-status.json` with the result
#   5. On failure: post a 🐛 comment to issue #5 + macOS notification
#   6. On success: silent (Concierge surfaces the status JSON)
#
# Runs via launchd at ~/Library/LaunchAgents/com.spraxel.localtests.plist
# every 30 minutes when the Mac is awake. Use scripts/install_local_tests.sh
# to install/uninstall.
#
# Manual usage:
#   ./scripts/run_local_tests.sh          # full run
#   ./scripts/run_local_tests.sh --quiet  # don't notify on failure
#
# Honors Philosophy.run_mode=dryrun (exits silently).

set -uo pipefail

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

# Helper: bounded run (we lack `timeout` on stock macOS)
run_bounded() {
  local seconds="$1"; shift
  perl -e 'alarm shift @ARGV; exec @ARGV' "$seconds" "$@"
}

STAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
STATUS_FILE="$REPO_DIR/.factory/local-tests-status.json"
LOG_DIR="$REPO_DIR/.factory/local-test-logs"
mkdir -p "$LOG_DIR"
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
  failures+=("GUT: produced no Totals summary (editor-import probably failed)")
elif [ $gut_exit -ne 0 ]; then
  failed=$(echo "$gut_out" | grep -oE "Failures.*: *[0-9]+" | head -1)
  failures+=("GUT: $failed (exit $gut_exit)")
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
  elif ! echo "$out" | grep -qE "SCENARIO $slug: PASS"; then
    failures+=("scenario $slug: silent skip or timeout (no PASS)")
  fi
done

# 4. Write status JSON
PASS=$([ ${#failures[@]} -eq 0 ] && echo "true" || echo "false")
python3 - <<PY
import json, pathlib
data = {
  "stamp": "$STAMP",
  "pass": $PASS,
  "failures": [$(printf '"%s",' "${failures[@]}" | sed 's/,$//')],
  "log": "$LOG"
}
pathlib.Path("$STATUS_FILE").parent.mkdir(parents=True, exist_ok=True)
pathlib.Path("$STATUS_FILE").write_text(json.dumps(data, indent=2))
PY

# 5. Report
if [ ${#failures[@]} -eq 0 ]; then
  echo "[local-tests] ✅ all green at $STAMP" | tee -a "$LOG"
  exit 0
fi

echo "[local-tests] 🐛 ${#failures[@]} failure(s):" | tee -a "$LOG"
for f in "${failures[@]}"; do echo "  - $f" | tee -a "$LOG"; done

# 6. Post to issue #5 (best-effort — won't block on auth issues)
if command -v gh >/dev/null 2>&1; then
  BODY=$(cat <<EOF
🐛 **Local tests failed — $STAMP**

Run on CEO's Mac (replaces test.yml during GH Actions budget freeze).

**Failures (${#failures[@]}):**
$(for f in "${failures[@]}"; do echo "- $f"; done)

Log: \`$LOG\`

Triager will dedup + classify on the next daily run; ticked-real items become real bug issues via Producer.
EOF
)
  # Find Factory Daily Log issue (cached lookup, falls back to #5)
  LOG_ISSUE=$(gh issue list --search "Factory Daily Log in:title" --state open --limit 1 --json number --jq '.[0].number' 2>/dev/null)
  LOG_ISSUE=${LOG_ISSUE:-5}
  gh issue comment "$LOG_ISSUE" --body "$BODY" 2>>"$LOG" || echo "[local-tests] gh comment failed (auth?)" >>"$LOG"
fi

# 7. macOS notification (if not --quiet)
if [ "$QUIET" -eq 0 ] && command -v osascript >/dev/null 2>&1; then
  TITLE="Infiltrators local tests FAILED"
  MSG="${#failures[@]} failures — see issue #5"
  osascript -e "display notification \"$MSG\" with title \"$TITLE\" sound name \"Sosumi\"" 2>/dev/null || true
fi

exit 1
