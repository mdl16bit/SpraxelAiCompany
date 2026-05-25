#!/usr/bin/env bash
# health_check.sh — scan today's agent logs for errors/failures.
#
# Called by the morning-briefer to surface agent failures in MORNING.md.
# Also callable manually: `bash scripts/health_check.sh`.
#
# Output (stdout):
#   - If no issues: "## ✓ Agent health — all clean" + count line
#   - If issues:    markdown block listing each affected agent + first error
#
# Exit code: always 0 (so callers don't think the check itself failed).
#
# Pure bash 3.2-compatible — no mapfile, no associative arrays.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGS_DIR="$REPO_DIR/logs"
TODAY=$(date +%Y-%m-%d)

# Patterns that signal real trouble (vs. informational mentions).
# Single ERE alternation for one fast grep pass.
PATTERN='unknown model|model not found|rate.?limit|quota exceeded|\b429\b|session expired|authentication failed|permission denied|^fatal:|^ERROR:|unhandled exception|Traceback'

# Collect today's per-agent logs into a temp file (avoid arrays for portability).
TMP_LIST=$(mktemp -t spraxel-health-XXXX)
TMP_FLAGGED=$(mktemp -t spraxel-flagged-XXXX)
trap 'rm -f "$TMP_LIST" "$TMP_FLAGGED"' EXIT

find "$LOGS_DIR" -type f -name "${TODAY}*.log" \
  -not -path "$LOGS_DIR/tick/*" \
  -not -name "*.prompt" \
  -not -name "*.brief" 2>/dev/null > "$TMP_LIST"

total_runs=$(wc -l < "$TMP_LIST" | tr -d ' ')

# For each log, grep for the first matching pattern; if hit, record it.
while IFS= read -r log; do
  [ -z "$log" ] && continue
  hit=$(grep -i -m1 -E "$PATTERN" "$log" 2>/dev/null)
  if [ -n "$hit" ]; then
    # Format: <log path>|<first error line>
    printf '%s|%s\n' "$log" "$hit" >> "$TMP_FLAGGED"
  fi
done < "$TMP_LIST"

flagged_count=$(wc -l < "$TMP_FLAGGED" | tr -d ' ')

if [ "$flagged_count" -eq 0 ]; then
  echo "## ✓ Agent health — all clean"
  echo "$total_runs agent run(s) today, no errors detected."
  exit 0
fi

echo "## ⚠️ Agent health — $flagged_count of $total_runs run(s) flagged"
echo
while IFS='|' read -r log hit; do
  agent=$(basename "$(dirname "$log")")
  ts=$(basename "$log" .log)
  # Truncate long error lines to keep MORNING.md scannable
  hit_short=$(echo "$hit" | cut -c1-100)
  echo "- **$agent** ($ts):"
  echo "  \`$hit_short\`"
  echo "  log: \`$log\`"
done < "$TMP_FLAGGED"
exit 0
