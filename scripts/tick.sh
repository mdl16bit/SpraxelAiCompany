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
# PID-aware lock helpers (lock_holder_alive / release_lock). Sourced up
# front so BOTH the continuous-wN sweep and the agent-lockdir sweep can use
# them — all lockdirs now contain a holder.pid file, which a plain `rmdir`
# can't remove (non-empty dir). release_lock removes holder.pid first.
. "$REPO_DIR/scripts/lockutils.sh"

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
# Capture run_agent's stdout+stderr to a per-agent dispatch log instead of
# /dev/null. Without this, a failed run (worktree error, lock held, claude
# died producing 0 bytes) was completely invisible — the 2026-05-28 incident
# where morning_briefer's claude emitted nothing and MORNING.md silently went
# stale for a day, with no trace of why.
while IFS='|' read -r name cron; do
  [ -z "$name" ] && continue
  if "$CRON_MATCH" "$cron" >/dev/null 2>&1; then
    if [ -x "$RUN_AGENT" ]; then
      dlog="$REPO_DIR/logs/$name"
      mkdir -p "$dlog"
      nohup bash "$RUN_AGENT" "$name" >>"$dlog/dispatch-$(date +%Y-%m-%d).log" 2>&1 &
      dispatched+=("$name")
    else
      errors+=("run_agent.sh not executable")
    fi
  fi
done <<< "$agent_entries"

# Continuous Developer loop — N parallel workers, self-paced against the
# shared CEO-checkin counter (cap = continuous.target_per_batch across
# all workers combined). Each worker has its own lockdir + worktree.
mkdir -p "$LOCKS_DIR"

# Read dev_concurrency from schedule.yaml (default 1).
dev_concurrency=$(python3 - "$SCHEDULE" <<'PY'
import sys, re
with open(sys.argv[1]) as f:
    text = f.read()
# Allow blank + comment lines inside the continuous: block (previous
# regex stopped at the first blank line, defaulting silently to 1).
m = re.search(r"^continuous:\s*\n((?:(?:[ \t]+.*)?\n)*?)(?=^\S|\Z)", text, re.M)
if m:
    mm = re.search(r"^\s+dev_concurrency:\s*(\d+)", m.group(1), re.M)
    if mm:
        print(mm.group(1)); sys.exit()
print(1)
PY
)

# Sweep stale per-worker continuous lockdirs (wrapper died without releasing,
# e.g. SIGKILL — its EXIT trap never ran). Check the holder.pid (written by
# acquire_lock); if it names a dead process, release_lock removes holder.pid
# THEN rmdirs. A plain `rmdir` here used to fail silently because the lockdir
# is non-empty (holds holder.pid) — the dir persisted, the spawn loop saw it
# and skipped, and the worker never came back (2026-05-27: a SIGKILLed w1
# could not respawn).
for id in $(seq 1 "$dev_concurrency"); do
  lock="$LOCKS_DIR/continuous-w$id.lockdir"
  if [ -d "$lock" ] && ! lock_holder_alive "$lock"; then
    release_lock "$lock"
    errors+=("cleared stale continuous-w$id.lockdir")
  fi
done
# Also sweep the legacy single-worker lockdir from before parallel-dev.
if [ -d "$LOCKS_DIR/continuous.lockdir" ]; then
  rmdir "$LOCKS_DIR/continuous.lockdir" 2>/dev/null
fi

# Also clean orphan agent lockdirs (developer, reviewer, designer, etc.).
# Without this, a SIGKILLed agent leaves its lockdir behind and every
# subsequent run_agent invocation exits rc=2 — silently wedging the
# continuous loop in a backoff sleep that never recovers.
#
# Check via the lockdir's holder.pid file (written by acquire_lock in
# lockutils.sh), not by pgrep'ing process names. The pgrep approach
# was broken for:
#   - `master-push.lockdir`  — not an agent lockdir, never matched any
#                              `run_agent.sh master-push` process, so
#                              tick swept it every minute, including
#                              mid-merge (causing git races).
#   - `developer-worker-N.lockdir` — the dev process cmdline is
#                              `run_agent.sh developer`, NOT
#                              `run_agent.sh developer-worker-N`, so
#                              pgrep never matched even when the dev
#                              was alive. Lockdir got swept 22 times
#                              in a single day while devs were running.
# PID-based check has neither failure mode. (lockutils.sh sourced at top.)
for lock in "$LOCKS_DIR"/*.lockdir; do
  [ -d "$lock" ] || continue
  agent_name=$(basename "$lock" .lockdir)
  case "$agent_name" in
    continuous|continuous-w*) continue ;;
  esac
  if ! lock_holder_alive "$lock"; then
    # holder.pid missing OR names a dead PID — orphan.
    rm -f "$lock/holder.pid" 2>/dev/null
    rmdir "$lock" 2>/dev/null && errors+=("cleared stale $agent_name.lockdir")
  fi
done

# Spawn missing workers (1..dev_concurrency).
#
# Lockdir check is sufficient on its own: continuous_dev.sh's `mkdir
# "$LOCK"` at line 76 is atomic, so even if two ticks race within the
# wrapper's startup window, only one process can hold the lock —
# the other exits 0 cleanly without ever entering the main loop.
#
# DO NOT add `pgrep -f continuous_dev.sh --worker-id N` here as a
# belt-and-suspenders check. The wrapper's dev-watchdog subshell
# (`( sleep $timeout; pkill ... ) &` inside ship_one_item) inherits
# the parent's $0 and appears in `ps` with the identical command
# line as the real wrapper. A pgrep check would (a) wrongly count
# 2x the wrappers, and (b) if the real wrapper SIGKILLed and only
# the orphan watchdog remained, the pgrep would prevent legitimate
# respawn. Trust the lockdir — that's what it's for.
if [ -x "$CONTINUOUS" ]; then
  mkdir -p "$REPO_DIR/logs/continuous"
  for id in $(seq 1 "$dev_concurrency"); do
    lock="$LOCKS_DIR/continuous-w$id.lockdir"
    if [ ! -d "$lock" ]; then
      logf="$REPO_DIR/logs/continuous/$(date +%Y-%m-%d)-w$id.log"
      nohup bash "$CONTINUOUS" --worker-id "$id" >>"$logf" 2>&1 &
      dispatched+=("continuous_dev w$id spawned")
    fi
  done
fi

if [ ${#dispatched[@]} -eq 0 ] && [ ${#errors[@]} -eq 0 ]; then
  echo "$now  tick" >> "$log"
else
  echo "$now  tick dispatched=[${dispatched[*]:-}] errors=[${errors[*]:-}]" >> "$log"
fi
exit 0
