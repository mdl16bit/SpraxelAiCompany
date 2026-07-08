#!/usr/bin/env bash
# tick.sh — the daemon heartbeat. Runs every 60s via launchd.
#
# Reads schedule.yaml + the games registry, evaluates every cron entry against the
# current minute (America/Los_Angeles), and dispatches due agents in the background
# FOR EACH ENABLED GAME. Per-game operational state (locks/cache/worktrees/logs) is
# namespaced via gctx.sh; genuinely-global concerns (pause, token/$ accounting,
# wake-gap wall clock, the daily spend cap, the Sonnet rate-limit) are handled once.
#
# - Single source of cadence is schedule.yaml. Edit it freely; changes apply next tick.
# - Games come from COMPANY_CONFIG.yaml `games:` (or the legacy single `game_dir:`).
# - `touch ~/SpraxelAiCompany/.paused` halts ALL dispatch (in-flight agents continue).
# - Total concurrent dev workers across all games is capped at global.max_total_dev_workers.
# - Logs one summary line per tick to logs/tick/YYYY-MM-DD.log.
# - Never blocks: dispatches go to background; returns within ~1s so launchd's
#   per-minute schedule stays accurate.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEDULE="$REPO_DIR/schedule.yaml"
SPX="$REPO_DIR/scripts/spx_config.py"
TICK_LOGS="$REPO_DIR/logs/tick"
PAUSED_FLAG="$REPO_DIR/.paused"            # GLOBAL master switch
CRON_MATCH="$REPO_DIR/scripts/cron_match.py"
CRON_DUE="$REPO_DIR/scripts/cron_due.py"
RUN_AGENT="$REPO_DIR/scripts/run_agent.sh"
CONTINUOUS="$REPO_DIR/scripts/continuous_dev.sh"
TEST_RUNNER="$REPO_DIR/scripts/test_runner.sh"
GLOBAL_CACHE="$REPO_DIR/.cache"            # GLOBAL: account/machine-wide state
# PID-aware lock helpers (lock_holder_alive / release_lock / sweep_dead_locks).
. "$REPO_DIR/scripts/lockutils.sh"

mkdir -p "$TICK_LOGS" "$GLOBAL_CACHE"
ymd=$(date +%Y-%m-%d)
log="$TICK_LOGS/$ymd.log"
now=$(date '+%Y-%m-%d %H:%M:%S %Z')

# Enabled game slugs (from the registry; legacy game_dir synthesizes one entry).
GAME_SLUGS=()
while IFS=$'\t' read -r _slug _gdir _enabled; do
  [ "$_enabled" = "1" ] && [ -n "$_slug" ] && GAME_SLUGS+=("$_slug")
done < <(python3 "$SPX" games 2>/dev/null)

# ── Hung-agent reaper (safety net, every tick, even when about to pause) ──────
# Reaps each enabled game's own (namespaced) lockdirs. Idempotent + exit-0.
for _slug in ${GAME_SLUGS[@]+"${GAME_SLUGS[@]}"}; do
  bash "$REPO_DIR/scripts/reap_hung_agents.sh" --game "$_slug" >>"$log" 2>&1 || true
done

# ── Token-usage refresh (GLOBAL — zero Claude tokens, pure local JSONL parse) ──
# Recompute the subscription-pool vs API-credit-pool split for the dashboard at
# most once every ~12h; self-heals across wake-gaps. Backgrounded + exit-0.
_tu_cache="$GLOBAL_CACHE/token-usage.json"
if [ ! -f "$_tu_cache" ] || [ -z "$(find "$_tu_cache" -mmin -720 2>/dev/null)" ]; then
  _tu_log="$REPO_DIR/logs/token_usage"; mkdir -p "$_tu_log"
  nohup python3 "$REPO_DIR/scripts/token_usage.py" \
    >>"$_tu_log/$(date +%Y-%m-%d).log" 2>&1 &
fi

# ── Wake-gap detector (GLOBAL — one wall clock for the machine) ───────────────
# Wall-clock seconds since the previous tick. Updated EVERY tick (even when
# paused, below) so an UNPAUSE never looks like a gap — only a real machine
# off/asleep stretch (no ticks at all) leaves it stale.
WALL_STAMP="$GLOBAL_CACHE/last-tick-wall.ts"
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

# Bail if paused (wall stamp already refreshed → unpausing won't fake a wake-gap).
if [ -e "$PAUSED_FLAG" ]; then
  echo "$now  paused" >> "$log"
  exit 0
fi

# ── Hard spend guardrail — GLOBAL daily_run_cap (policy.budgets.daily_run_cap) ──
# If set >0, halt the WHOLE system (touch .paused) once this many agent runs have
# happened TODAY across ALL games — a hard ceiling so a runaway day can't silently
# bill metered $$. Counts per-game logs (logs/<slug>/<agent>/) AND legacy flat logs.
# 0 = disabled (default).
_run_cap=$(python3 "$SPX" get policy.budgets.daily_run_cap 2>/dev/null)
if [ "${_run_cap:-0}" -gt 0 ] 2>/dev/null; then
  _runs_today=$(find "$REPO_DIR/logs" -maxdepth 3 -name "$(date +%Y-%m-%d)-*.log" ! -name '*.prompt' 2>/dev/null \
                  | grep -vcE '/(continuous|tick|catch_up|token_usage)/')
  if [ "${_runs_today:-0}" -ge "$_run_cap" ]; then
    printf 'daily_run_cap reached: %s agent runs on %s (cap %s). System auto-paused — investigate the spend, then `rm %s` to resume.\n' \
      "$_runs_today" "$(date +%Y-%m-%d)" "$_run_cap" "$PAUSED_FLAG" > "$PAUSED_FLAG"
    echo "$now  HALTED — daily_run_cap reached ($_runs_today/$_run_cap)" >> "$log"
    exit 0
  fi
fi

# Bail if claude CLI is missing or broken.
if ! command -v claude >/dev/null 2>&1; then
  echo "$now  ERR claude not on PATH" >> "$log"
  exit 0
fi

# ── Global config read once (applies across games) ───────────────────────────
# Crew-agent cron entries: lines of `name|cron` (shared schedule for all games).
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

# GLOBAL total-worker ceiling (shared pool across all games). Per-game
# dev_concurrency + force_interactive are read inside the loop (a game may be
# headless while another is interactive).
max_total_workers=$(python3 "$SPX" get global.max_total_dev_workers --default 9999 2>/dev/null); max_total_workers=${max_total_workers:-9999}

# test-runner trigger config (shared).
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
tr_force_secs=$(( tr_force_hours * 3600 ))

# ── GLOBAL dev-worker ceiling accounting ─────────────────────────────────────
# Count live continuous workers across ALL games, then spawn only up to the
# remaining budget so a 2nd game can't blow past the machine/token ceiling.
live_workers=0
for _l in "$REPO_DIR"/state/*/locks/continuous-w*.lockdir; do
  [ -d "$_l" ] || continue
  lock_holder_alive "$_l" && live_workers=$((live_workers + 1))
done
spawn_budget=$(( max_total_workers - live_workers ))
[ "$spawn_budget" -lt 0 ] && spawn_budget=0

dispatched=()
errors=()

# Wake-gap catch-up (per enabled game). A long gap means the machine was
# off/asleep through one or more daily slots cron_due's grace abandoned. catch_up
# is idempotent, only replays slots that already occurred today, single-instance
# locked per game, and keeps morning-briefer last — safe to fire; no-op if nothing
# was missed.
_wakegap=$(python3 "$SPX" get continuous.wake_gap_threshold_secs --default 1800 2>/dev/null); _wakegap=${_wakegap:-1800}
if [ "${gap:-0}" -gt "$_wakegap" ] && [ -x "$REPO_DIR/scripts/catch_up.sh" ]; then
  cdir="$REPO_DIR/logs/catch_up"; mkdir -p "$cdir"
  for _slug in ${GAME_SLUGS[@]+"${GAME_SLUGS[@]}"}; do
    nohup bash "$REPO_DIR/scripts/catch_up.sh" --game "$_slug" --reason "wake-gap $((gap/60))m" \
      >>"$cdir/$(date +%Y-%m-%d).log" 2>&1 &
    dispatched+=("catch_up:$_slug (wake-gap $((gap/60))m)")
  done
fi

# ════════════════════════════════════════════════════════════════════════════
# PER-GAME LOOP — everything below is namespaced to one game at a time.
# ════════════════════════════════════════════════════════════════════════════
for GAME_SLUG in ${GAME_SLUGS[@]+"${GAME_SLUGS[@]}"}; do
  # Resolve this game's namespaced paths (sets GAME_DIR, LOCKS_DIR, CACHE_DIR,
  # GAME_LOGS_DIR, WORKTREES_DIR; exports SPRAXEL_GAME so children inherit it).
  if ! . "$REPO_DIR/scripts/gctx.sh" --game "$GAME_SLUG"; then
    errors+=("gctx failed for $GAME_SLUG"); continue
  fi
  game_dir="$GAME_DIR"
  work_md="$game_dir/WORK.md"
  AGENT_FIRE_STAMP="$CACHE_DIR/agent-last-fire.json"
  STATE_FILE="$CACHE_DIR/continuous-state.json"
  UPTIME_FILE="$CACHE_DIR/engine-uptime-since-test.json"
  TR_PENDING="$CACHE_DIR/test-runner-pending"
  TR_ACTIVE="$CACHE_DIR/test-runner-active"
  TR_RUNNER_LOCK="$LOCKS_DIR/test-runner.lockdir"
  TR_RAN_SHA="$CACHE_DIR/test-runner-ran-sha"
  mkdir -p "$LOCKS_DIR" "$CACHE_DIR"

  # ── Crew-health monitor (hourly per game) ──────────────────────────────────
  # 2026-06-24→07-08 every crew run failed ("Prompt is too long") with ZERO
  # signal to the CEO for 2 weeks. Compare each crew agent's agent-last-ok
  # stamp age against its cron cadence (2× expected interval + 6h sleep slack).
  # Newly-stale agents get a report (→ MORNING.md News + /spraxel-inbox) once;
  # full state in $CACHE_DIR/crew-health.txt.
  HEALTH_STAMP="$CACHE_DIR/crew-health.last"
  if [ ! -f "$HEALTH_STAMP" ] || [ -z "$(find "$HEALTH_STAMP" -mmin -60 2>/dev/null)" ]; then
    touch "$HEALTH_STAMP"
    _stale=$(AGENT_ENTRIES="$agent_entries" python3 - "$CACHE_DIR/agent-last-ok" <<'PY' 2>/dev/null
import os, sys, time
okdir = sys.argv[1]
now = time.time()
for line in os.environ.get("AGENT_ENTRIES", "").splitlines():
    if "|" not in line:
        continue
    name, cron = line.split("|", 1)
    f = cron.split()
    interval_days = 1.0
    if len(f) == 5:
        dom, dow = f[2], f[4]
        if dow != "*":
            interval_days = 7.0 / max(len(dow.split(",")), 1)
        elif dom != "*":
            interval_days = 31.0
    thresh = 2 * interval_days * 86400 + 6 * 3600
    p = os.path.join(okdir, name.replace("_", "-") + ".ts")
    try:
        age_h = int((now - os.path.getmtime(p)) / 3600)
    except OSError:
        print(f"{name}|no successful run on record")
        continue
    if age_h * 3600 > thresh:
        print(f"{name}|last success {age_h}h ago (cron: {cron})")
PY
)
    UNHEALTHY_STATE="$CACHE_DIR/crew-health.unhealthy"
    _prev=$(cat "$UNHEALTHY_STATE" 2>/dev/null || true)
    printf '%s\n' "$_stale" > "$CACHE_DIR/crew-health.txt"
    printf '%s\n' "$_stale" | awk -F'|' 'NF {print $1}' > "$UNHEALTHY_STATE"
    while IFS='|' read -r _an _why; do
      [ -n "$_an" ] || continue
      case " $_prev " in *" $_an "*) continue ;; esac   # already reported while unhealthy
      printf '%s\n' \
        "- ⚠ CREW-HEALTH: **$_an** looks dead — $_why. Check logs/$GAME_SLUG/$_an/ (tail the newest .log)." \
        | bash "$REPO_DIR/scripts/report.sh" crew_health --game "$GAME_SLUG" >/dev/null 2>&1 || true
      echo "$now  crew-health: $_an STALE ($_why)" >> "$log"
    done <<EOF_STALE
$_stale
EOF_STALE
  fi

  # Per-game worker count. force_interactive_developers => no headless workers
  # (the CEO drives dev from /spraxel-develop); treat dev_concurrency as 0.
  dev_concurrency=$(python3 "$SPX" get continuous.dev_concurrency --default 1 --game "$GAME_SLUG" 2>/dev/null); dev_concurrency=${dev_concurrency:-1}
  _force_interactive=$(python3 "$SPX" get continuous.force_interactive_developers --game "$GAME_SLUG" 2>/dev/null)
  if [ "$_force_interactive" = "true" ] || [ "$_force_interactive" = "True" ]; then
    dev_concurrency=0
  fi

  # Engine on-time accumulator (per game). Each UNPAUSED tick adds the elapsed
  # time since the previous tick (capped at 120s) to a cumulative counter that
  # THIS game's test runner resets to 0 when it runs. Paused time isn't counted
  # (we bailed above before reaching here).
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

  # ── Escalations sync (this game) — keep the derived escalations.md current ──
  # Pure-local, zero-Claude-token regeneration of .factory/escalations.md from
  # the [escalated] items in WORK.md. The headless continuous_dev.sh loop does
  # this every iteration, but in force_interactive_developers mode that loop
  # never runs, so escalations.md drifts stale between /spraxel-develop sessions
  # (the CEO's derived escalations surface + the dashboard/briefer input). Doing
  # it here — every UNPAUSED tick, for every game — keeps it always in sync.
  # Idempotent, cheap (a local WORK.md parse), backgrounded, never fatal.
  if [ -f "$work_md" ]; then
    ( python3 "$REPO_DIR/scripts/workmd.py" sync-escalations "$work_md" \
        --escalations "$game_dir/.factory/escalations.md" >/dev/null 2>&1 || true ) &
  fi

  # ── Crew agents (PM, Triager, Designer, …) — cron-fired for THIS game ───────
  # Drift-proof: cron_due catches a slot the 60s tick drifted past (dedup via a
  # per-GAME stamp so a slot fires at most once per game). Falls back to a plain
  # minute-match if cron_due.py is missing.
  while IFS='|' read -r name cron; do
    [ -z "$name" ] && continue
    if { [ -x "$CRON_DUE" ] && python3 "$CRON_DUE" "$name" "$cron" --stamp "$AGENT_FIRE_STAMP" >/dev/null 2>&1; } \
       || { [ ! -x "$CRON_DUE" ] && "$CRON_MATCH" "$cron" >/dev/null 2>&1; }; then
      if [ -x "$RUN_AGENT" ]; then
        dlog="$GAME_LOGS_DIR/$name"; mkdir -p "$dlog"
        nohup bash "$RUN_AGENT" "$name" --game "$GAME_SLUG" >>"$dlog/dispatch-$(date +%Y-%m-%d).log" 2>&1 &
        dispatched+=("$GAME_SLUG/$name")
      else
        errors+=("run_agent.sh not executable")
      fi
    fi
  done <<< "$agent_entries"

  # ── Reactive Architect trigger (this game) ─────────────────────────────────
  # 1. NEW [untriaged] items exist → needs intake. `^\[untriaged\]` matches the
  #    raw tag only (closing `]` excludes `[untriaged-proposal-active]`).
  # 2. The CEO SUBMITTED answers → TRIAGE.md edited more recently than the
  #    Architect last ran, there are proposal-active items, AND `[Indicate
  #    complete]` is followed by non-space text (same line or any line below).
  arch_triage="$game_dir/.factory/local/TRIAGE.md"
  arch_stamp="$CACHE_DIR/architect-triage-seen.ts"
  arch_reason=""
  if [ -f "$work_md" ]; then
    if grep -qE '^\[untriaged\]' "$work_md"; then
      arch_reason="untriaged present"
    elif [ -f "$arch_triage" ] && grep -qE '^\[untriaged-proposal-active\]' "$work_md" \
         && { [ ! -e "$arch_stamp" ] || [ "$arch_triage" -nt "$arch_stamp" ]; } \
         && awk '
              /^\[Indicate complete\]/ {
                r=$0; sub(/^\[Indicate complete\][[:space:]]*/, "", r)
                if (r ~ /[^[:space:]]/) { ok=1; exit }
                seen=1; next
              }
              seen && $0 !~ /^[[:space:]]*#/ && $0 ~ /[^[:space:]]/ { ok=1; exit }
              END { exit(ok?0:1) }
            ' "$arch_triage"; then
      arch_reason="triage submitted"
      # A triage submit IS a CEO interaction → reset THIS game's ship-counter
      # (TRIAGE.md is git-ignored, so the loop's commit-based signal never fires
      # on it; touch the per-game checkin stamp here instead).
      touch "$CACHE_DIR/ceo-checkin.ts" 2>/dev/null \
        && echo "$(date '+%F %T') tick: $GAME_SLUG triage submitted — reset ship-counter (CEO signal)" >> "$log"
    fi
  fi
  if [ -x "$RUN_AGENT" ] && [ -n "$arch_reason" ] \
     && ! lock_holder_alive "$LOCKS_DIR/architect.lockdir"; then
    dlog="$GAME_LOGS_DIR/architect"; mkdir -p "$dlog"
    nohup bash "$RUN_AGENT" architect --game "$GAME_SLUG" >>"$dlog/reactive-$(date +%Y-%m-%d).log" 2>&1 &
    dispatched+=("$GAME_SLUG/architect (reactive: $arch_reason)")
  fi

  # ── Self-heal stranded work (this game), debounced ~once/10min per game ─────
  heal_stamp="$CACHE_DIR/heal-sections.min"
  now_min=$(( $(date +%s) / 600 ))
  if [ -f "$work_md" ] && [ "$(cat "$heal_stamp" 2>/dev/null)" != "$now_min" ]; then
    echo "$now_min" > "$heal_stamp"
    moved=$(bash "$REPO_DIR/scripts/with_master_lock.sh" --game "$GAME_SLUG" \
              -m "chore(work): heal-sections — relocate stranded buildable work to Todo" \
              heal-sections 2>/dev/null | grep -c '^  - ' || true)
    [ "${moved:-0}" -gt 0 ] && dispatched+=("$GAME_SLUG/heal-sections: $moved → Todo")
  fi

  # ── Designer when THIS game's buildable queue is DRY (≤1 dry-run/day/game) ──
  dz_stamp="$CACHE_DIR/designer-dry-ran.date"
  if [ -x "$RUN_AGENT" ] && [ -f "$work_md" ] \
     && [ "$(cat "$dz_stamp" 2>/dev/null)" != "$(date +%F)" ] \
     && ! lock_holder_alive "$LOCKS_DIR/designer.lockdir"; then
    buildable=$(python3 "$REPO_DIR/scripts/workmd.py" top "$work_md" -n 25 2>/dev/null \
      | python3 -c 'import sys,json,re
try: d=json.load(sys.stdin)
except Exception: d=[]
print(sum(1 for i in d if not re.search(r"PERMANENT|do not close", i["title"], re.I)))' 2>/dev/null || echo 1)
    if [ "$buildable" = "0" ]; then
      date +%F > "$dz_stamp"
      dlog="$GAME_LOGS_DIR/designer"; mkdir -p "$dlog"
      nohup bash "$RUN_AGENT" designer --game "$GAME_SLUG" >>"$dlog/dry-$(date +%Y-%m-%d).log" 2>&1 &
      dispatched+=("$GAME_SLUG/designer (reactive: queue dry → daily)")
    fi
  fi

  # ── Lock hygiene (this game's namespaced lockdirs) ─────────────────────────
  # Sweep stale per-worker continuous lockdirs (wrapper died without releasing).
  for id in $(seq 1 "$dev_concurrency"); do
    lock="$LOCKS_DIR/continuous-w$id.lockdir"
    if [ -d "$lock" ] && ! lock_holder_alive "$lock"; then
      release_lock "$lock"
      errors+=("$GAME_SLUG cleared stale continuous-w$id.lockdir")
    fi
  done
  # Legacy single-worker lockdir from before parallel-dev.
  if [ -d "$LOCKS_DIR/continuous.lockdir" ]; then
    rmdir "$LOCKS_DIR/continuous.lockdir" 2>/dev/null
  fi
  # Orphan agent lockdirs (developer, reviewer, designer, …) — PID-based check.
  # NEVER touch long-lived continuous-w* locks (handled above).
  for lock in "$LOCKS_DIR"/*.lockdir; do
    [ -d "$lock" ] || continue
    agent_name=$(basename "$lock" .lockdir)
    case "$agent_name" in
      continuous|continuous-w*) continue ;;
    esac
    if ! lock_holder_alive "$lock"; then
      rm -f "$lock/holder.pid" 2>/dev/null
      rmdir "$lock" 2>/dev/null && errors+=("$GAME_SLUG cleared stale $agent_name.lockdir")
    fi
  done
  # Dead-holder TEST locks in the game repo's .factory.
  sweep_dead_locks "$game_dir/.factory" >/dev/null 2>&1

  # Reap orphaned [wip:N] claims (this game). Debounced internally.
  bash "$REPO_DIR/scripts/sweep_orphan_wips.sh" --game "$GAME_SLUG" 2>&1 | grep -v '^$' || true

  # Stale test-runner cleanup (this game): active flag set but runner lock dead.
  if [ -e "$TR_ACTIVE" ] && ! lock_holder_alive "$TR_RUNNER_LOCK"; then
    rm -f "$TR_ACTIVE" 2>/dev/null
    python3 -c "import json,time;json.dump({'seconds':0,'last_tick_ts':int(time.time())},open('$UPTIME_FILE','w'))" 2>/dev/null || true
    errors+=("$GAME_SLUG cleared stale test-runner active flag (runner died)")
  fi

  # ── Test-runner trigger decision (this game) ───────────────────────────────
  # Drained = no developer worker mid-item: no live developer-worker-* lock AND
  # no [wip:N] item in WORK.md.
  tr_drained=1
  for dl in "$LOCKS_DIR"/developer-worker-*.lockdir; do
    [ -d "$dl" ] || continue
    if lock_holder_alive "$dl"; then tr_drained=0; break; fi
  done
  if [ "$tr_drained" -eq 1 ] && [ -f "$work_md" ] && grep -qE '\[wip:[0-9]+\]' "$work_md"; then
    tr_drained=0
  fi
  tr_shipped=$(python3 -c "import json;print(json.load(open('$STATE_FILE')).get('shipped_since_last_signal',0))" 2>/dev/null || echo 0)
  tr_last_sha=$(python3 -c "import json;print(json.load(open('$STATE_FILE')).get('last_signal_sha',''))" 2>/dev/null || echo "")
  tr_uptime=$(python3 -c "import json;print(json.load(open('$UPTIME_FILE')).get('seconds',0))" 2>/dev/null || echo 0)
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
      dispatched+=("$GAME_SLUG/test_runner SCHEDULED ($tr_reason)")
    fi
  fi

  # ── Spawn missing dev workers (this game) — bounded by the GLOBAL ceiling ───
  # UNLESS a test-runner run is scheduled/active (must run alone) OR
  # dev_concurrency is 0 (force_interactive_developers). The `-ge 1` guard is
  # load-bearing: on macOS `seq 1 0` counts DOWN to "1 0" (NOT empty).
  if [ -x "$CONTINUOUS" ] && [ ! -e "$TR_PENDING" ] && [ ! -e "$TR_ACTIVE" ] && [ "${dev_concurrency:-0}" -ge 1 ]; then
    cdir="$GAME_LOGS_DIR/continuous"; mkdir -p "$cdir"
    for id in $(seq 1 "$dev_concurrency"); do
      lock="$LOCKS_DIR/continuous-w$id.lockdir"
      if [ ! -d "$lock" ]; then
        if [ "$spawn_budget" -le 0 ]; then
          errors+=("$GAME_SLUG w$id deferred — global worker ceiling ($max_total_workers) reached")
          continue
        fi
        logf="$cdir/$(date +%Y-%m-%d)-w$id.log"
        nohup bash "$CONTINUOUS" --worker-id "$id" --game "$GAME_SLUG" >>"$logf" 2>&1 &
        spawn_budget=$(( spawn_budget - 1 ))
        dispatched+=("$GAME_SLUG/continuous_dev w$id spawned")
      fi
    done
  fi

  # ── Launch the test runner once SCHEDULED + workers DRAINED (this game) ─────
  if [ -e "$TR_PENDING" ] && [ ! -e "$TR_ACTIVE" ] && [ "$tr_drained" -eq 1 ] \
     && ! lock_holder_alive "$TR_RUNNER_LOCK" && [ -x "$TEST_RUNNER" ]; then
    echo "$tr_last_sha" > "$TR_RAN_SHA"
    trlog="$GAME_LOGS_DIR/test_runner"; mkdir -p "$trlog"
    nohup bash "$TEST_RUNNER" --game "$GAME_SLUG" >>"$trlog/$(date +%Y-%m-%d).log" 2>&1 &
    dispatched+=("$GAME_SLUG/test_runner LAUNCHED")
  fi
done
# ════════════════════════════════════════════════════════════════════════════

if [ ${#dispatched[@]} -eq 0 ] && [ ${#errors[@]} -eq 0 ]; then
  echo "$now  tick" >> "$log"
else
  echo "$now  tick dispatched=[${dispatched[*]:-}] errors=[${errors[*]:-}]" >> "$log"
fi
exit 0
