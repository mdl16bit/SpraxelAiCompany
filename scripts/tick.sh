#!/usr/bin/env bash
# tick.sh — the daemon heartbeat. Runs every 60s via launchd.
#
# Reads schedule.yaml, evaluates every cron entry against the current minute
# (America/Los_Angeles), and dispatches any due agent in the background.
#
# - Single source of cadence is schedule.yaml. Edit it freely; changes apply
#   on the next tick.
# - `touch ~/SpraxelAiCompany/.paused` to halt all dispatch (existing in-flight
#   agents continue).
# - Logs one summary line per tick to logs/tick/YYYY-MM-DD.log.
# - Never blocks: agent dispatches go to background; this script returns within
#   a second so launchd's per-minute schedule stays accurate.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEDULE="$REPO_DIR/schedule.yaml"
TICK_LOGS="$REPO_DIR/logs/tick"
PAUSED_FLAG="$REPO_DIR/.paused"
CRON_MATCH="$REPO_DIR/scripts/cron_match.py"
RUN_AGENT="$REPO_DIR/scripts/run_agent.sh"
OVERNIGHT="$REPO_DIR/scripts/overnight_dev.sh"

mkdir -p "$TICK_LOGS"
ymd=$(date +%Y-%m-%d)
log="$TICK_LOGS/$ymd.log"
now=$(date '+%Y-%m-%d %H:%M:%S %Z')

# Bail if paused.
if [ -e "$PAUSED_FLAG" ]; then
  echo "$now  paused" >> "$log"
  exit 0
fi

# Bail if claude CLI is missing or broken.
if ! command -v claude >/dev/null 2>&1; then
  echo "$now  ERR claude not on PATH" >> "$log"
  exit 0
fi

# Parse schedule.yaml entries: emit lines of `kind|name|cron`.
# kind = agent | overnight. Uses Python for safer YAML-ish parsing
# (we still use a tiny stdlib parser — no PyYAML dep needed for our flat shape).
entries=$(python3 - "$SCHEDULE" <<'PY'
import sys, re
path = sys.argv[1]
with open(path) as f:
    text = f.read()

# Find the agents: block (flow-style entries).
m = re.search(r"^agents:\s*\n((?:[ \t]+\S.*\n?)*)", text, re.M)
if m:
    for line in m.group(1).splitlines():
        # name: { cron: "X * * * *", description: "..." }
        mm = re.match(r"\s*(\w+):\s*\{[^}]*cron:\s*\"([^\"]+)\"", line)
        if mm:
            print(f"agent|{mm.group(1)}|{mm.group(2)}")

# Find overnight.start_cron.
m = re.search(r"^overnight:\s*\n((?:[ \t]+\S.*\n?)*)", text, re.M)
if m:
    sm = re.search(r"\s*start_cron:\s*\"([^\"]+)\"", m.group(1))
    if sm:
        print(f"overnight|overnight|{sm.group(1)}")
PY
)

dispatched=()
errors=()

while IFS='|' read -r kind name cron; do
  [ -z "$kind" ] && continue
  # Match cron against current minute in PT.
  if "$CRON_MATCH" "$cron" >/dev/null 2>&1; then
    case "$kind" in
      agent)
        if [ -x "$RUN_AGENT" ]; then
          nohup bash "$RUN_AGENT" "$name" >/dev/null 2>&1 &
          dispatched+=("$name")
        else
          errors+=("run_agent.sh not executable")
        fi
        ;;
      overnight)
        if [ -x "$OVERNIGHT" ]; then
          nohup bash "$OVERNIGHT" >/dev/null 2>&1 &
          dispatched+=("overnight")
        else
          # Phase 1: overnight_dev.sh doesn't exist yet. Log and skip.
          errors+=("overnight_dev.sh not yet present (Phase 4)")
        fi
        ;;
    esac
  fi
done <<< "$entries"

if [ ${#dispatched[@]} -eq 0 ] && [ ${#errors[@]} -eq 0 ]; then
  echo "$now  tick" >> "$log"
else
  echo "$now  tick dispatched=[${dispatched[*]:-}] errors=[${errors[*]:-}]" >> "$log"
fi
exit 0
