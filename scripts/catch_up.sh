#!/usr/bin/env bash
# catch_up.sh — re-run daily scheduled agents whose slot TODAY was missed.
#
# Why this exists: launchd fires tick.sh every 60s, and tick's drift-proof
# cron_due only catches a slot missed within a 15-min grace window (so a brief
# sleep doesn't fire a flood of stale runs). When the machine is OFF for hours
# overnight, every daily slot (playtester 03:00 … pm 06:00) blows past that
# window and is abandoned — the CEO then had to ask Claude to replay them every
# morning. This script does that replay deterministically.
#
# It is IDEMPOTENT: it skips any agent that already ran successfully today, only
# runs agents whose cron slot actually occurred earlier today (so it never fires
# a slot that hasn't happened yet, e.g. architect 09:00 when it's 07:00), and
# keeps morning-briefer LAST so its digest reflects the others. Single-instance
# locked, so tick firing it + a manual run can't collide.
#
# Triggers:
#   • tick.sh, automatically, when it detects a wake-gap (last tick was long ago)
#   • the CEO, manually: `bash ~/SpraxelAiCompany/scripts/catch_up.sh`
set -uo pipefail

REPO_DIR="$HOME/SpraxelAiCompany"
SCHEDULE="$REPO_DIR/schedule.yaml"
RUN_AGENT="$REPO_DIR/scripts/run_agent.sh"
SCRIPTS_DIR="$REPO_DIR/scripts"
. "$REPO_DIR/scripts/lockutils.sh"
LOCK="$REPO_DIR/.locks/catch_up.lockdir"

reason="manual"
[ "${1:-}" = "--reason" ] && reason="${2:-manual}"

# Single instance — a second catch_up (e.g. a later tick) just exits.
if ! acquire_lock "$LOCK" 5 0.3; then
  echo "$(date '+%F %T') catch_up: another instance running — skip ($reason)"
  exit 0
fi
trap 'release_lock "$LOCK"' EXIT

[ -e "$REPO_DIR/.paused" ] && { echo "$(date '+%F %T') catch_up: paused — skip"; exit 0; }

echo "=== catch_up $(date '+%a %F %H:%M:%S %Z') — reason: $reason ==="

# Dependency order; morning-briefer LAST so it sees the others' fresh output.
# (Event-triggered jobs like test_runner are NOT slot-based, so not listed.)
ORDER="playtester triager designer demo_creator pm architect janitor blogger asset_librarian morning-briefer"

# run_agent slug → schedule.yaml key (the key uses underscores for some).
sched_key() { case "$1" in morning-briefer) echo morning_briefer ;; *) echo "$1" ;; esac; }

# The cron for a given schedule key, from schedule.yaml's agents: block.
cron_for() {
  python3 - "$SCHEDULE" "$1" <<'PY'
import re, sys
text = open(sys.argv[1]).read(); key = sys.argv[2]
m = re.search(r"^agents:\s*\n((?:[ \t]+\S.*\n?)*)", text, re.M)
if m:
    for line in m.group(1).splitlines():
        mm = re.match(r"\s*(\w+):\s*\{[^}]*cron:\s*\"([^\"]+)\"", line)
        if mm and mm.group(1) == key:
            print(mm.group(2)); break
PY
}

# Did a cron slot for this expr occur TODAY at or before now? (exit 0 = yes)
slot_due_today() {
  python3 - "$SCRIPTS_DIR" "$1" <<'PY'
import sys, datetime
sys.path.insert(0, sys.argv[1])
from cron_match import cron_match
try:
    from zoneinfo import ZoneInfo
    now = datetime.datetime.now(ZoneInfo("America/Los_Angeles"))
except Exception:
    now = datetime.datetime.now()
now = now.replace(second=0, microsecond=0)
dt = now.replace(hour=0, minute=0)
while dt <= now:
    if cron_match(sys.argv[2], dt):
        sys.exit(0)
    dt += datetime.timedelta(minutes=1)
sys.exit(1)
PY
}

# Did this agent already run SUCCESSFULLY today? Read the per-agent success stamp
# run_agent.sh writes (.cache/agent-last-ok/<slug>.ts) — set ONLY on a clean run,
# so a failed/API-error run correctly does NOT count and we re-run it. The slug
# is normalized (_→-) to match run_agent's $agent_slug.
ran_ok_today() {
  local slug="${1//_/-}"
  local stamp="$REPO_DIR/.cache/agent-last-ok/$slug.ts"
  [ -e "$stamp" ] || return 1
  [ "$(date -r "$stamp" +%Y-%m-%d)" = "$(date +%Y-%m-%d)" ]
}

ran=(); skipped=()
for agent in $ORDER; do
  key=$(sched_key "$agent")
  cron=$(cron_for "$key")
  [ -z "$cron" ] && { continue; }                       # not a cron agent
  if ! slot_due_today "$cron"; then
    continue                                            # no slot earlier today
  fi
  if ran_ok_today "$agent"; then
    skipped+=("$agent"); continue                       # already ran ok today
  fi
  echo "--- $(date '+%H:%M:%S') running $agent (slot due today, not yet run) ---"
  if bash "$RUN_AGENT" "$agent"; then
    ran+=("$agent")
  else
    echo "    ⚠ $agent run_agent rc=$?"
    ran+=("$agent(rc!=0)")
  fi
done

echo "=== catch_up done $(date '+%H:%M:%S') — ran: ${ran[*]:-none} | already-ok: ${skipped[*]:-none} ==="
