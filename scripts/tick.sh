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
CONTINUOUS="$REPO_DIR/scripts/continuous_dev.sh"
LOCKS_DIR="$REPO_DIR/.locks"

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

# Parse schedule.yaml crew-agent entries: emit lines of `name|cron`.
agent_entries=$(python3 - "$SCHEDULE" <<'PY'
import sys, re
with open(sys.argv[1]) as f:
    text = f.read()
m = re.search(r"^agents:\s*\n((?:[ \t]+\S.*\n?)*)", text, re.M)
if m:
    for line in m.group(1).splitlines():
        mm = re.match(r"\s*(\w+):\s*\{[^}]*cron:\s*\"([^\"]+)\"", line)
        if mm:
            print(f"{mm.group(1)}|{mm.group(2)}")
PY
)

dispatched=()
errors=()

# Crew agents (PM, Triager, Designer, etc.) — cron-fired.
while IFS='|' read -r name cron; do
  [ -z "$name" ] && continue
  if "$CRON_MATCH" "$cron" >/dev/null 2>&1; then
    if [ -x "$RUN_AGENT" ]; then
      nohup bash "$RUN_AGENT" "$name" >/dev/null 2>&1 &
      dispatched+=("$name")
    else
      errors+=("run_agent.sh not executable")
    fi
  fi
done <<< "$agent_entries"

# Continuous Developer loop — always-on, self-paces against the CEO-checkin
# counter. Ensure it's running; if its lockdir exists but no process owns it
# (crash), clean and respawn.
mkdir -p "$LOCKS_DIR"
CONT_LOCK="$LOCKS_DIR/continuous.lockdir"
if [ -d "$CONT_LOCK" ] && ! pgrep -f "continuous_dev.sh" >/dev/null 2>&1; then
  rmdir "$CONT_LOCK" 2>/dev/null
  errors+=("cleared stale continuous.lockdir")
fi
# Also clean orphan agent lockdirs (developer, reviewer, designer, etc.).
# Without this, a SIGKILLed agent leaves its lockdir behind and every
# subsequent run_agent invocation exits rc=2 — silently wedging the
# continuous loop in a backoff sleep that never recovers.
for lock in "$LOCKS_DIR"/*.lockdir; do
  [ -d "$lock" ] || continue
  agent_name=$(basename "$lock" .lockdir)
  # The continuous.lockdir is handled above; skip.
  [ "$agent_name" = "continuous" ] && continue
  if ! pgrep -f "run_agent.sh $agent_name" >/dev/null 2>&1; then
    rmdir "$lock" 2>/dev/null && errors+=("cleared stale $agent_name.lockdir")
  fi
done
if [ ! -d "$CONT_LOCK" ] && [ -x "$CONTINUOUS" ]; then
  mkdir -p "$REPO_DIR/logs/continuous"
  nohup bash "$CONTINUOUS" >>"$REPO_DIR/logs/continuous/$(date +%Y-%m-%d).log" 2>&1 &
  dispatched+=("continuous_dev spawned")
fi

if [ ${#dispatched[@]} -eq 0 ] && [ ${#errors[@]} -eq 0 ]; then
  echo "$now  tick" >> "$log"
else
  echo "$now  tick dispatched=[${dispatched[*]:-}] errors=[${errors[*]:-}]" >> "$log"
fi
exit 0
