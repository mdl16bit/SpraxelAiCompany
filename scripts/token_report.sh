#!/usr/bin/env bash
# token_report.sh — estimate per-agent invocation share + flag drift.
#
# On the Claude Max plan, you pay a flat fee. There's no per-token billing,
# but you DO have a weekly invocation cap. This script counts `claude -p`
# invocations per agent over a window and compares to the targets in
# policy.budgets.by_agent_percent (resolved via scripts/spx_config.py).
#
# Usage:
#   bash scripts/token_report.sh           # last 7 days
#   bash scripts/token_report.sh --days 30 # last 30 days
#   bash scripts/token_report.sh --since YYYY-MM-DD
#
# Output: a markdown table of agent / target_pct / actual_pct / drift /
#         invocation count. Drift >25% gets flagged with ⚠.

set -o pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGS_DIR="$REPO_DIR/logs"
SPX_CONFIG="$REPO_DIR/scripts/spx_config.py"

DAYS=7
SINCE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --days) DAYS="$2"; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    *) echo "unknown: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$SINCE" ]; then
  SINCE=$(date -v-${DAYS}d +%Y-%m-%d 2>/dev/null || date -d "$DAYS days ago" +%Y-%m-%d)
fi

# Resolve policy.budgets.by_agent_percent via the config loader (honors a game's
# GAME_CONFIG.yaml override of COMPANY_CONFIG.yaml). Import spx_config directly
# and emit key\tvalue lines.
targets=$(SPX_DIR="$(dirname "$SPX_CONFIG")" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.environ["SPX_DIR"])
try:
    from spx_config import get
    data = get("policy.budgets.by_agent_percent", default={})
except Exception:
    data = {}
if isinstance(data, dict):
    for k, v in data.items():
        print(f"{k}\t{v}")
PY
)

if [ -z "$targets" ]; then
  echo "policy.budgets.by_agent_percent not set — nothing to compare against." >&2
  exit 1
fi

# Count invocations per agent. Each .log file under logs/<agent>/ = one
# invocation. Skip .prompt and .brief mirror files.
declare_compat_count() {
  local agent="$1"
  find "$LOGS_DIR/$agent" -type f -name '*.log' \
       -not -name '*.prompt' -not -name '*.brief' 2>/dev/null \
    | awk -F/ -v since="$SINCE" '{
        # Filename format: YYYY-MM-DD-HHMM.log → extract date
        fname = $NF
        date = substr(fname, 1, 10)
        if (date >= since) count++
      } END { print count + 0 }'
}

# Total invocations across all agents.
total=0
declare_compat_each() {
  for d in "$LOGS_DIR"/*/; do
    [ -d "$d" ] || continue
    a=$(basename "$d")
    [ "$a" = "tick" ] && continue
    [ "$a" = "overnight" ] && continue
    [ "$a" = "continuous" ] && continue
    echo "$a"
  done
}
agents=$(declare_compat_each | sort -u)

for a in $agents; do
  c=$(declare_compat_count "$a")
  total=$((total + c))
done

echo "# Token / invocation report — since $SINCE"
echo
echo "Total \`claude -p\` invocations: **$total**"
echo
printf "| Agent              | Target %% | Actual %% | Drift  | Invocations |\n"
printf "|--------------------|----------|----------|--------|-------------|\n"

# For each agent in targets, show row. Sort by agent name.
echo "$targets" | sort | while IFS=$'\t' read -r agent target; do
  count=$(declare_compat_count "$agent")
  if [ "$total" -gt 0 ]; then
    actual=$(awk -v c="$count" -v t="$total" 'BEGIN { printf "%.1f", (c/t)*100 }')
  else
    actual="0.0"
  fi
  drift=$(awk -v a="$actual" -v t="$target" 'BEGIN { printf "%+.1f", a - t }')
  flag=$(awk -v d="$drift" 'BEGIN { d = d < 0 ? -d : d; if (d > 25) print "⚠"; else print " " }')
  printf "| %-18s | %7s%% | %7s%% | %+6s | %11s | %s\n" \
    "$agent" "$target" "$actual" "$drift" "$count" "$flag"
done
echo
echo "Agents with no logs in window:"
echo "$targets" | while IFS=$'\t' read -r agent target; do
  count=$(declare_compat_count "$agent")
  [ "$count" -eq 0 ] && echo "  - $agent (target ${target}%, but 0 invocations)"
done
