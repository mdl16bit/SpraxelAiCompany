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
CRON_DUE="$REPO_DIR/scripts/cron_due.py"
AGENT_FIRE_STAMP="$REPO_DIR/.cache/agent-last-fire.json"
RUN_AGENT="$REPO_DIR/scripts/run_agent.sh"
CONTINUOUS="$REPO_DIR/scripts/continuous_dev.sh"
TEST_RUNNER="$REPO_DIR/scripts/test_runner.sh"
LOCKS_DIR="$REPO_DIR/.locks"
CACHE_DIR="$REPO_DIR/.cache"
STATE_FILE="$CACHE_DIR/continuous-state.json"
UPTIME_FILE="$CACHE_DIR/engine-uptime-since-test.json"
TR_PENDING="$CACHE_DIR/test-runner-pending"     # scheduled → draining; no new workers
TR_ACTIVE="$CACHE_DIR/test-runner-active"        # runner running
TR_RUNNER_LOCK="$LOCKS_DIR/test-runner.lockdir"
TR_RAN_SHA="$CACHE_DIR/test-runner-ran-sha"      # last batch the runner fired for
# PID-aware lock helpers (lock_holder_alive / release_lock). Sourced up
# front so BOTH the continuous-wN sweep and the agent-lockdir sweep can use
# them — all lockdirs now contain a holder.pid file, which a plain `rmdir`
# can't remove (non-empty dir). release_lock removes holder.pid first.
. "$REPO_DIR/scripts/lockutils.sh"

mkdir -p "$TICK_LOGS" "$CACHE_DIR"
ymd=$(date +%Y-%m-%d)
log="$TICK_LOGS/$ymd.log"
now=$(date '+%Y-%m-%d %H:%M:%S %Z')

# Wake-gap detector: wall-clock seconds since the previous tick. Updated on
# EVERY tick (even when paused, below) so an UNPAUSE never looks like a gap —
# only a real machine-off/asleep stretch (no ticks ran at all) leaves it stale.
WALL_STAMP="$REPO_DIR/.cache/last-tick-wall.ts"
gap=$(python3 - "$WALL_STAMP" <<'PY' 2>/dev/null || echo 0
import sys, time
f = sys.argv[1]
now = int(time.time())
try: last = int(open(f).read().strip())
except Exception: last = now
open(f, "w").write(str(now))
print(now - last)
PY
)

# Bail if paused (but the wall stamp above is already refreshed, so unpausing
# doesn't trigger a spurious wake-gap catch-up).
if [ -e "$PAUSED_FLAG" ]; then
  echo "$now  paused" >> "$log"
  exit 0
fi

# Engine on-time accumulator. Each UNPAUSED tick adds the elapsed time since
# the previous tick (capped at 120s so sleep/wake or missed ticks don't inflate
# it) to a cumulative counter the batch test runner resets to 0 when it runs.
# tick.sh force-schedules the runner once this passes
# test_runner.force_after_engine_hours. Because this runs AFTER the pause bail,
# paused time is never counted — pausing freezes the count without resetting it.
python3 - "$UPTIME_FILE" <<'PY' 2>/dev/null || true
import json, sys, time
f = sys.argv[1]
now = int(time.time())
try:
    d = json.load(open(f)); last = int(d.get("last_tick_ts", now)); secs = int(d.get("seconds", 0))
except Exception:
    last, secs = now, 0
delta = now - last
if 0 < delta <= 120:
    secs += delta
json.dump({"seconds": secs, "last_tick_ts": now}, open(f, "w"))
PY

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

# Wake-gap catch-up: a long gap since the previous tick means the machine was
# off/asleep through one or more daily slots that cron_due's 15-min grace
# abandoned (the recurring "computer was off overnight — run missed jobs"). Fire
# catch_up.sh once to replay the missed daily agents. It is idempotent (per-agent
# success stamps), only runs slots that already occurred today, single-instance
# locked, and keeps morning-briefer last — so this is safe to fire and a no-op
# when nothing was actually missed. Threshold 30min ≫ normal 60s tick.
if [ "${gap:-0}" -gt 1800 ] && [ -x "$REPO_DIR/scripts/catch_up.sh" ]; then
  cdir="$REPO_DIR/logs/catch_up"; mkdir -p "$cdir"
  nohup bash "$REPO_DIR/scripts/catch_up.sh" --reason "wake-gap $((gap/60))m" \
    >>"$cdir/$(date +%Y-%m-%d).log" 2>&1 &
  dispatched+=("catch_up (wake-gap $((gap/60))m)")
fi

# Crew agents (PM, Triager, Designer, etc.) — cron-fired.
# Capture run_agent's stdout+stderr to a per-agent dispatch log instead of
# /dev/null. Without this, a failed run (worktree error, lock held, claude
# died producing 0 bytes) was completely invisible — the 2026-05-28 incident
# where morning_briefer's claude emitted nothing and MORNING.md silently went
# stale for a day, with no trace of why.
while IFS='|' read -r name cron; do
  [ -z "$name" ] && continue
  # Drift-proof: cron_due catches a slot the 60s tick drifted past (and dedups
  # via a per-agent stamp so a slot fires at most once). Falls back to the plain
  # minute-match if cron_due.py is missing.
  if { [ -x "$CRON_DUE" ] && python3 "$CRON_DUE" "$name" "$cron" --stamp "$AGENT_FIRE_STAMP" >/dev/null 2>&1; } \
     || { [ ! -x "$CRON_DUE" ] && "$CRON_MATCH" "$cron" >/dev/null 2>&1; }; then
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

# Reactive Architect trigger — wake the Architect promptly (instead of waiting
# for its twice-daily cron), lock-guarded so a run never overlaps itself. Two
# cases:
#   1. NEW [untriaged] items exist → needs intake (fast-pass or a questionnaire).
#      `^\[untriaged\]` matches the raw tag only (the closing `]` excludes
#      `[untriaged-proposal-active]`).
#   2. The CEO SUBMITTED answers → TRIAGE.md edited more recently than the
#      Architect last ran (it touches the seen-stamp at the END of every run, so
#      this fires on the CEO's edits, not the Architect's own writes), there are
#      proposal-active items, AND the `[Indicate complete]` token is followed by
#      non-space text — either trailing on the same line OR on any line below it
#      (the CEO's explicit "I'm done for now" signal). The submit gate means
#      saving a half-filled file does NOT wake the Architect — only submitting
#      does, and then it's picked up within ~60s.
arch_game_dir=$(python3 - "$SCHEDULE" <<'PY'
import sys, os, re
m = re.search(r"game_dir:\s*(\S+)", open(sys.argv[1]).read())
print(os.path.expanduser(m.group(1)) if m else "")
PY
)
arch_work_md="$arch_game_dir/WORK.md"
arch_triage="$arch_game_dir/.factory/local/TRIAGE.md"
arch_stamp="$REPO_DIR/.cache/architect-triage-seen.ts"
arch_reason=""
if [ -n "$arch_game_dir" ] && [ -f "$arch_work_md" ]; then
  if grep -qE '^\[untriaged\]' "$arch_work_md"; then
    arch_reason="untriaged present"
  elif [ -f "$arch_triage" ] && grep -qE '^\[untriaged-proposal-active\]' "$arch_work_md" \
       && { [ ! -e "$arch_stamp" ] || [ "$arch_triage" -nt "$arch_stamp" ]; } \
       && awk '
            # Submitted = any non-space text after the [Indicate complete] token,
            # whether on the SAME line (trailing) or on ANY line BELOW it (the CEO
            # often hits Enter and types "done" on the next line). Comment lines
            # (leading #) below the token do NOT count.
            /^\[Indicate complete\]/ {
              r=$0; sub(/^\[Indicate complete\][[:space:]]*/, "", r)
              if (r ~ /[^[:space:]]/) { ok=1; exit }   # trailing same-line text
              seen=1; next
            }
            seen && $0 !~ /^[[:space:]]*#/ && $0 ~ /[^[:space:]]/ { ok=1; exit }
            END { exit(ok?0:1) }
          ' "$arch_triage"; then
    # CEO answered AND submitted (typed text on/after the [Indicate complete]
    # line). Without the submit text we never wake for answers — the CEO saves
    # repeatedly while editing and a half-filled file must not be processed.
    arch_reason="triage submitted"
  fi
fi
if [ -x "$RUN_AGENT" ] && [ -n "$arch_reason" ] \
   && ! lock_holder_alive "$LOCKS_DIR/architect.lockdir"; then
  dlog="$REPO_DIR/logs/architect"
  mkdir -p "$dlog"
  nohup bash "$RUN_AGENT" architect >>"$dlog/reactive-$(date +%Y-%m-%d).log" 2>&1 &
  dispatched+=("architect (reactive: $arch_reason)")
fi

# Self-heal stranded work: an agent that hand-edits WORK.md (instead of
# `workmd.py append --section todo`) can drop a buildable candidate into a
# shipped section (## Shipped since last release), where top_n/the workers can't
# see it — the queue then looks "exhausted" while real work sits invisible
# (2026-05-31: 7 candidate bugs the Triager mis-filed). heal-sections moves any
# [needs-ceo] item + any open-candidate [bug] back to ## Todo. Idempotent + a
# no-op commit-wise when nothing's stranded; debounced to ~once/10min so it
# doesn't hammer the master-push lock.
heal_stamp="$REPO_DIR/.cache/heal-sections.min"
now_min=$(( $(date +%s) / 600 ))
if [ -n "$arch_game_dir" ] && [ -f "$arch_work_md" ] \
   && [ "$(cat "$heal_stamp" 2>/dev/null)" != "$now_min" ]; then
  echo "$now_min" > "$heal_stamp"
  moved=$(bash "$REPO_DIR/scripts/with_master_lock.sh" \
            -m "chore(work): heal-sections — relocate stranded buildable work to Todo" \
            heal-sections 2>/dev/null | grep -c '^  - ' || true)
  [ "${moved:-0}" -gt 0 ] && dispatched+=("heal-sections: $moved stranded item(s) → Todo")
fi

# Designer when the buildable queue is DRY. The Designer normally runs Tue+Fri
# (cron), but when developers have NOTHING to build — `top` returns no eligible
# items (only [manual]/[future]/untriaged/epic-gated left, ignoring the permanent
# pinned dashboard chore) — fire it to refill the idea pipeline. Fires on ANY day,
# INCLUDING Tue/Fri: if the scheduled morning batch is already exhausted by
# mid-day, this tops it up (previously the Tue/Fri skip left the queue dry until
# the next day — exactly the "queue exhausted, no designer planned" gap). Date-
# stamped to ≤1 dry-run/day so it can't spam; on Tue/Fri it may add one run on
# top of the scheduled one when genuinely dry — which is the point.
dz_stamp="$REPO_DIR/.cache/designer-dry-ran.date"
if [ -x "$RUN_AGENT" ] && [ -n "$arch_game_dir" ] && [ -f "$arch_work_md" ] \
   && [ "$(cat "$dz_stamp" 2>/dev/null)" != "$(date +%F)" ] \
   && ! lock_holder_alive "$LOCKS_DIR/designer.lockdir"; then
  buildable=$(python3 "$REPO_DIR/scripts/workmd.py" top "$arch_work_md" -n 25 2>/dev/null \
    | python3 -c 'import sys,json,re
try: d=json.load(sys.stdin)
except Exception: d=[]
print(sum(1 for i in d if not re.search(r"PERMANENT|do not close", i["title"], re.I)))' 2>/dev/null || echo 1)
  if [ "$buildable" = "0" ]; then
    date +%F > "$dz_stamp"
    dlog="$REPO_DIR/logs/designer"; mkdir -p "$dlog"
    nohup bash "$RUN_AGENT" designer >>"$dlog/dry-$(date +%Y-%m-%d).log" 2>&1 &
    dispatched+=("designer (reactive: queue dry → daily)")
  fi
fi

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

# Also reap dead-holder TEST locks in the game repo's .factory (e.g. a
# SIGKILL'd / orphaned run_local_tests left `.test-running*.lockdir` behind).
# These live OUTSIDE .locks and were previously only self-healed lazily by the
# next test waiter; sweeping them every tick keeps them from wedging a worker.
[ -n "$arch_game_dir" ] && sweep_dead_locks "$arch_game_dir/.factory" >/dev/null 2>&1

# Reap orphaned [wip:N] claims — items tagged claimed by a worker that's been
# killed/restarted and is no longer on that item's branch. A stale claim looks
# taken, so no worker can grab it → silent starvation. Same idea as the dead-lock
# sweep, but for WORK.md claims. Debounced internally (needs 2 consecutive
# sweeps) so a just-claimed-not-yet-branched item is never falsely released.
bash "$REPO_DIR/scripts/sweep_orphan_wips.sh" 2>&1 | grep -v '^$' || true

# Stale test-runner cleanup: if the active flag is set but the runner lock has
# no live holder, the runner was SIGKILL'd before its EXIT trap could clean up.
# Clear the active flag (so dev workers resume) and zero the on-time counter
# (so the force trigger doesn't immediately re-fire into a crash loop — the cap
# trigger still covers routine QA; progress.json is kept so the next run
# resumes the unfinished cycle).
if [ -e "$TR_ACTIVE" ] && ! lock_holder_alive "$TR_RUNNER_LOCK"; then
  rm -f "$TR_ACTIVE" 2>/dev/null
  python3 -c "import json,time;json.dump({'seconds':0,'last_tick_ts':int(time.time())},open('$UPTIME_FILE','w'))" 2>/dev/null || true
  errors+=("cleared stale test-runner active flag (runner died)")
fi

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
# ── Batch test runner: triggers + exclusive gating ──────────────────────────
# The runner (scripts/test_runner.sh) sweeps the whole suite serially and files
# [test_failure] items. It runs EXCLUSIVELY: while scheduled/active, no new dev
# workers spawn and existing workers drain (they idle on the flag at top-of-loop
# — see continuous_dev.sh). Two triggers: (1) ship cap maxed + workers drained,
# (2) force_after_engine_hours of on-time elapsed since the last run.
tr_cfg=$(python3 - "$SCHEDULE" <<'PY'
import sys, re
text = open(sys.argv[1]).read()
def block(name):
    m = re.search(rf"^{name}:\s*\n((?:(?:[ \t]+.*)?\n)*?)(?=^\S|\Z)", text, re.M)
    return m.group(1) if m else ""
def val(blk, key, default):
    m = re.search(rf"^\s+{key}:\s*(\d+)", blk, re.M)
    return m.group(1) if m else str(default)
print(val(block("continuous"), "target_per_batch", 10),
      val(block("test_runner"), "force_after_engine_hours", 100))
PY
)
tr_target=$(echo "$tr_cfg" | awk '{print $1}')
tr_force_hours=$(echo "$tr_cfg" | awk '{print $2}')

# Drained = no developer worker is mid-item: no live developer-worker-* lock AND
# no [wip:N] item in WORK.md.
tr_drained=1
for dl in "$LOCKS_DIR"/developer-worker-*.lockdir; do
  [ -d "$dl" ] || continue
  if lock_holder_alive "$dl"; then tr_drained=0; break; fi
done
if [ "$tr_drained" -eq 1 ] && [ -f "$arch_work_md" ] && grep -qE '\[wip:[0-9]+\]' "$arch_work_md"; then
  tr_drained=0
fi

tr_shipped=$(python3 -c "import json;print(json.load(open('$STATE_FILE')).get('shipped_since_last_signal',0))" 2>/dev/null || echo 0)
tr_last_sha=$(python3 -c "import json;print(json.load(open('$STATE_FILE')).get('last_signal_sha',''))" 2>/dev/null || echo "")
tr_uptime=$(python3 -c "import json;print(json.load(open('$UPTIME_FILE')).get('seconds',0))" 2>/dev/null || echo 0)
tr_force_secs=$(( tr_force_hours * 3600 ))

# Decide whether to SCHEDULE (set pending). ran-sha guards against re-firing for
# the same at-cap batch (it only resets when the CEO checks in → new last_sha).
if [ ! -e "$TR_PENDING" ] && [ ! -e "$TR_ACTIVE" ] && [ -x "$TEST_RUNNER" ]; then
  tr_reason=""
  if [ "${tr_uptime:-0}" -ge "$tr_force_secs" ] 2>/dev/null; then
    tr_reason="engine on-time >= ${tr_force_hours}h"
  elif [ "${tr_shipped:-0}" -ge "${tr_target:-10}" ] 2>/dev/null \
       && [ "$tr_drained" -eq 1 ] \
       && [ "$(cat "$TR_RAN_SHA" 2>/dev/null)" != "$tr_last_sha" ]; then
    tr_reason="ship cap reached + workers drained"
  fi
  if [ -n "$tr_reason" ]; then
    : > "$TR_PENDING"
    dispatched+=("test_runner SCHEDULED ($tr_reason)")
  fi
fi

# Spawn missing workers — UNLESS a test-runner run is scheduled/active (it must
# run alone, so we stop refilling the worker pool and let it drain).
if [ -x "$CONTINUOUS" ] && [ ! -e "$TR_PENDING" ] && [ ! -e "$TR_ACTIVE" ]; then
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

# Launch the runner once SCHEDULED, workers have DRAINED, and it isn't already
# running. Stamp ran-sha so this at-cap batch isn't re-triggered next tick.
if [ -e "$TR_PENDING" ] && [ ! -e "$TR_ACTIVE" ] && [ "$tr_drained" -eq 1 ] \
   && ! lock_holder_alive "$TR_RUNNER_LOCK" && [ -x "$TEST_RUNNER" ]; then
  echo "$tr_last_sha" > "$TR_RAN_SHA"
  trlog="$REPO_DIR/logs/test_runner"; mkdir -p "$trlog"
  nohup bash "$TEST_RUNNER" >>"$trlog/$(date +%Y-%m-%d).log" 2>&1 &
  dispatched+=("test_runner LAUNCHED")
fi

if [ ${#dispatched[@]} -eq 0 ] && [ ${#errors[@]} -eq 0 ]; then
  echo "$now  tick" >> "$log"
else
  echo "$now  tick dispatched=[${dispatched[*]:-}] errors=[${errors[*]:-}]" >> "$log"
fi
exit 0
