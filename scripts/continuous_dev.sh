#!/usr/bin/env bash
# continuous_dev.sh — long-running Developer loop.
#
# Contract: there should ALWAYS be N completed items waiting for the CEO to
# review. The system ships items as fast as Claude + tests will allow, until
# N have shipped since the last CEO interaction. Then it sleeps. Any CEO
# interaction (a non-bot commit, a manual checkin, etc.) resets the counter.
#
# This script is started by tick.sh if it's not already running. It self-
# restarts via the same path if it crashes. Survives Mac sleep (continues
# when the Mac wakes).
#
# Behavior:
#   - Picks the top eligible item from WORK.md ## Todo.
#   - Branches, runs Developer, runs tests, runs Reviewer, merges to master.
#   - On success: increments shipped-since-last-signal counter.
#   - When counter >= target_per_batch: sleeps in 60s ticks, looking for a
#     CEO signal (a non-bot commit or .cache/ceo-checkin.ts touch).
#   - On CEO signal: resets counter to 0, immediately starts shipping again.
#
# Pause:  touch ~/SpraxelAiCompany/.paused   → loop sleeps until .paused gone.
# Force-checkin:  bash scripts/checkin.sh    → resets counter immediately.

set -o pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEDULE="$REPO_DIR/schedule.yaml"
RUN_AGENT="$REPO_DIR/scripts/run_agent.sh"
WORKMD="$REPO_DIR/scripts/workmd.py"
SLUGIFY="$REPO_DIR/scripts/slugify.py"
PAUSED_FLAG="$REPO_DIR/.paused"
LOCKS_DIR="$REPO_DIR/.locks"
CACHE_DIR="$REPO_DIR/.cache"
STATE_FILE="$CACHE_DIR/continuous-state.json"
CHECKIN_FILE="$CACHE_DIR/ceo-checkin.ts"
mkdir -p "$LOCKS_DIR" "$CACHE_DIR"

# --- single-instance lock ---
LOCK="$LOCKS_DIR/continuous.lockdir"
if ! mkdir "$LOCK" 2>/dev/null; then
  exit 0   # another instance is running
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

# Resolve game_dir + target.
game_dir=$(python3 - "$SCHEDULE" <<'PY'
import sys, os, re
with open(sys.argv[1]) as f:
    for line in f:
        m = re.match(r"\s*game_dir:\s*(\S+)", line)
        if m:
            print(os.path.expanduser(m.group(1))); break
PY
)
target_per_batch=$(python3 - "$SCHEDULE" <<'PY'
import sys, re
with open(sys.argv[1]) as f:
    text = f.read()
m = re.search(r"^continuous:\s*\n((?:[ \t]+\S.*\n?)*)", text, re.M)
if m:
    mm = re.search(r"\s*target_per_batch:\s*(\d+)", m.group(1))
    if mm: print(mm.group(1)); sys.exit()
# Fallback to legacy overnight.target_items
m = re.search(r"^overnight:\s*\n((?:[ \t]+\S.*\n?)*)", text, re.M)
if m:
    mm = re.search(r"\s*target_items:\s*(\d+)", m.group(1))
    if mm: print(mm.group(1)); sys.exit()
print(10)
PY
)
if [ -z "$game_dir" ] || [ ! -d "$game_dir" ]; then
  echo "continuous: game_dir not resolvable — abort"
  exit 1
fi

# --- state helpers ---
init_state_if_missing() {
  if [ ! -f "$STATE_FILE" ]; then
    cat > "$STATE_FILE" <<EOF
{
  "shipped_since_last_signal": 0,
  "last_signal_sha": "$(git -C "$game_dir" rev-parse master 2>/dev/null || echo '')",
  "last_signal_ts": "$(date '+%Y-%m-%d %H:%M:%S %Z')",
  "last_ts": "$(date '+%Y-%m-%d %H:%M:%S %Z')"
}
EOF
  fi
}
read_state() {
  python3 -c "import json,sys; print(json.load(open('$STATE_FILE'))['$1'])"
}
write_state() {
  python3 - <<PY
import json
s = json.load(open('$STATE_FILE'))
s['$1'] = '$2' if not '$2'.isdigit() else int('$2')
s['last_ts'] = '$(date '+%Y-%m-%d %H:%M:%S %Z')'
json.dump(s, open('$STATE_FILE','w'), indent=2)
PY
}

# --- CEO signal detection ---
# Returns 0 if a CEO signal has happened since last_signal_sha:
#   - a master commit by an author whose email doesn't match *-bot@spraxel.ai
#   - OR the manual checkin file has been touched since last_signal_ts
# Returns 1 if no signal.
ceo_signaled() {
  local last_sha last_ts
  last_sha=$(read_state last_signal_sha)
  last_ts=$(read_state last_signal_ts)
  # Manual checkin: any touch newer than last_signal_ts.
  if [ -f "$CHECKIN_FILE" ]; then
    local checkin_epoch state_epoch
    checkin_epoch=$(stat -f '%m' "$CHECKIN_FILE" 2>/dev/null || echo 0)
    state_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S %Z" "$last_ts" +%s 2>/dev/null || echo 0)
    [ "$checkin_epoch" -gt "$state_epoch" ] && return 0
  fi
  # Git commits by non-bot authors since last_sha.
  cd "$game_dir" || return 1
  if [ -n "$last_sha" ] && git rev-parse --verify --quiet "$last_sha" >/dev/null; then
    local non_bot_commits
    non_bot_commits=$(git log --format='%ae' "${last_sha}..master" 2>/dev/null | grep -v -E '\-bot@spraxel\.ai$' | head -1)
    [ -n "$non_bot_commits" ] && return 0
  fi
  return 1
}

# Reset counter, advance the watermark to current master HEAD.
record_ceo_signal() {
  cd "$game_dir" || return
  local now_sha now_ts
  now_sha=$(git rev-parse master 2>/dev/null || echo '')
  now_ts=$(date '+%Y-%m-%d %H:%M:%S %Z')
  python3 - <<PY
import json
s = json.load(open('$STATE_FILE'))
s['shipped_since_last_signal'] = 0
s['last_signal_sha'] = '$now_sha'
s['last_signal_ts'] = '$now_ts'
s['last_ts'] = '$now_ts'
json.dump(s, open('$STATE_FILE','w'), indent=2)
PY
  echo "continuous: ceo signal detected — counter reset"
}

# --- the per-item ship logic ---
# Returns 0 on successful ship, 1 on failure, 2 on clarify-only (don't count).
ship_one_item() {
  local LOG_DIR="$REPO_DIR/logs/continuous/$(date +%Y-%m-%d)"
  mkdir -p "$LOG_DIR"
  cd "$game_dir" || return 1
  git fetch --quiet origin master 2>/dev/null
  git checkout --quiet master 2>/dev/null
  git pull --ff-only --quiet origin master 2>/dev/null || true

  local next_json next_title slug branch item_log
  next_json=$(python3 "$WORKMD" top "$game_dir/WORK.md" -n 1)
  next_title=$(echo "$next_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['title'] if d else '')")
  if [ -z "$next_title" ]; then
    echo "continuous: no eligible items in WORK.md ## Todo"
    return 3   # nothing to do
  fi

  slug=$(echo "$next_title" | python3 "$SLUGIFY")
  branch="feat/cont-$(date +%Y%m%d-%H%M)-$slug"
  item_log="$LOG_DIR/$slug.log"
  echo "continuous: → '$next_title' on $branch"

  git checkout --quiet -B "$branch" master

  local outcome=fail
  for attempt in 1 2; do
    echo "=== attempt $attempt at $(date) ===" >> "$item_log"

    local item_brief
    item_brief=$(echo "$next_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
if not d: sys.exit()
it = d[0]
print('## Today\\'s item')
print()
print(it['title'])
for det in it.get('details', []):
    print(f'  {det}')
")
    echo "$item_brief" > "$item_log.brief"

    if ! SPRAXEL_ITEM_BRIEF="$item_log.brief" bash "$RUN_AGENT" developer >> "$item_log" 2>&1; then
      echo "continuous: developer rc=$? on attempt $attempt" >> "$item_log"
      [ "$attempt" -lt 2 ] && continue
      outcome=fail
      break
    fi

    # Mid-run pause check.
    if [ -e "$PAUSED_FLAG" ]; then
      echo "continuous: paused mid-run after developer" >> "$item_log"
      git checkout --quiet master
      git branch -D "$branch" --quiet 2>/dev/null || true
      return 2
    fi

    # Clarify detection — Developer asked questions, didn't implement.
    if python3 -c "
import sys
sys.path.insert(0, '$REPO_DIR/scripts')
from workmd import parse, find_item
wm = parse('$game_dir/WORK.md')
for sec in (wm.todo, wm.current, wm.shipped):
    idx = find_item(sec, '$next_title'.replace('[needs-ceo] ', ''))
    if idx >= 0 and sec[idx].is_needs_ceo:
        sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
      echo "continuous: ↪ clarified '$next_title'" >> "$item_log"
      echo "continuous: ↪ clarified '$next_title'"
      git add WORK.md 2>/dev/null || true
      git diff --cached --quiet || \
        git -c user.email=continuous-bot@spraxel.ai -c user.name='Spraxel Continuous' \
            commit --quiet -m "needs-ceo: clarifications on '$next_title'" 2>/dev/null
      git push --quiet origin master 2>/dev/null || true
      git checkout --quiet master
      git branch -D "$branch" --quiet 2>/dev/null || true
      return 2   # don't count toward batch
    fi

    if ! bash "$game_dir/scripts/run_local_tests.sh" >> "$item_log" 2>&1; then
      echo "continuous: tests FAILED on attempt $attempt" >> "$item_log"
      [ "$attempt" -lt 2 ] && { git checkout --quiet "$branch"; continue; }
      outcome=fail
      break
    fi

    if ! bash "$RUN_AGENT" reviewer >> "$item_log" 2>&1; then
      echo "continuous: reviewer BLOCKED" >> "$item_log"
      outcome=fail
      break
    fi

    git checkout --quiet master
    if git merge --squash --quiet "$branch" \
       && git -c user.email=continuous-bot@spraxel.ai -c user.name='Spraxel Continuous' \
              commit --quiet -m "feat: $next_title" \
       && git push --quiet origin master; then
      python3 "$WORKMD" ship "$game_dir/WORK.md" "$next_title" >> "$item_log" 2>&1 || true
      git add WORK.md 2>/dev/null
      git -c user.email=continuous-bot@spraxel.ai -c user.name='Spraxel Continuous' \
          commit --quiet -m "work: shipped '$next_title'" 2>/dev/null
      git push --quiet origin master 2>/dev/null
      git branch -d "$branch" --quiet 2>/dev/null || true
      outcome=ok
      break
    else
      echo "continuous: merge/push FAILED" >> "$item_log"
      outcome=fail
      break
    fi
  done

  if [ "$outcome" != "ok" ]; then
    git checkout --quiet master
    git branch -D "$branch" --quiet 2>/dev/null || true
    python3 "$WORKMD" escalate "$game_dir/WORK.md" "$next_title" \
      --log "$item_log" >> "$item_log" 2>&1 || true
    git add WORK.md "$game_dir/.factory/escalations.md" 2>/dev/null
    git -c user.email=continuous-bot@spraxel.ai -c user.name='Spraxel Continuous' \
        commit --quiet -m "escalate: '$next_title'" 2>/dev/null
    git push --quiet origin master 2>/dev/null || true
    echo "continuous: ✗ escalated '$next_title'"
    return 1
  fi

  echo "continuous: ✓ shipped '$next_title'"
  return 0
}

# --- main loop ---
init_state_if_missing
echo "continuous: started — target_per_batch=$target_per_batch, game_dir=$game_dir"

idle_streak=0
fail_streak=0
MAX_FAIL_STREAK=3

while true; do
  # Pause check.
  if [ -e "$PAUSED_FLAG" ]; then
    sleep 60
    continue
  fi
  # Rate-limit / cascade brake.
  if [ "$fail_streak" -ge "$MAX_FAIL_STREAK" ]; then
    echo "continuous: $MAX_FAIL_STREAK consecutive failures — backing off 30 min"
    fail_streak=0
    sleep 1800
    continue
  fi
  # CEO signal check.
  if ceo_signaled; then
    record_ceo_signal
  fi
  # Cap check.
  shipped=$(read_state shipped_since_last_signal)
  if [ "$shipped" -ge "$target_per_batch" ]; then
    # At cap — wait for CEO. Re-check every 60s.
    sleep 60
    continue
  fi
  # Ship one item.
  ship_one_item
  rc=$?
  case $rc in
    0) # success
      fail_streak=0
      idle_streak=0
      shipped=$(read_state shipped_since_last_signal)
      write_state shipped_since_last_signal $((shipped + 1))
      ;;
    1) # genuine failure
      fail_streak=$((fail_streak + 1))
      idle_streak=0
      ;;
    2) # clarify / paused mid-flight — don't count
      idle_streak=0
      ;;
    3) # nothing to do (Todo empty of eligible items)
      idle_streak=$((idle_streak + 1))
      if [ "$idle_streak" -ge 5 ]; then
        sleep 300   # 5 idle ticks → sleep 5 min before re-checking
        idle_streak=0
      else
        sleep 30
      fi
      ;;
  esac
done
