#!/usr/bin/env bash
# overnight_dev.sh — the night-shift Developer loop.
#
# Triggered by tick.sh at 23:00 PT. Picks top-of-Todo items from WORK.md,
# branches, runs Developer agent, runs local tests, runs Reviewer, merges
# to master, pushes. Loops until 10 items land OR 06:00 PT hard stop.
#
# Items the loop touches get one retry. If the second attempt fails, the
# item is escalated to .factory/escalations.md (with a log link) and removed
# from Todo until the CEO resurrects it.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEDULE="$REPO_DIR/schedule.yaml"
RUN_AGENT="$REPO_DIR/scripts/run_agent.sh"
WORKMD="$REPO_DIR/scripts/workmd.py"
SLUGIFY="$REPO_DIR/scripts/slugify.py"
PAUSED_FLAG="$REPO_DIR/.paused"
LOCKS_DIR="$REPO_DIR/.locks"

if [ -e "$PAUSED_FLAG" ]; then
  echo "overnight: paused"
  exit 0
fi

# --- single-instance lock (mkdir-atomic) ---
overnight_lock="$LOCKS_DIR/overnight.lockdir"
mkdir -p "$LOCKS_DIR"
if ! mkdir "$overnight_lock" 2>/dev/null; then
  echo "overnight: already running ($overnight_lock exists)"
  exit 0
fi
trap 'rmdir "$overnight_lock" 2>/dev/null || true' EXIT INT TERM

# --- game_dir + budget from schedule.yaml ---
game_dir=$(python3 - "$SCHEDULE" <<'PY'
import sys, os, re
with open(sys.argv[1]) as f:
    for line in f:
        m = re.match(r"\s*game_dir:\s*(\S+)", line)
        if m:
            print(os.path.expanduser(m.group(1))); break
PY
)
target_items=$(python3 - "$SCHEDULE" <<'PY'
import sys, re
with open(sys.argv[1]) as f:
    text = f.read()
m = re.search(r"^overnight:\s*\n((?:[ \t]+\S.*\n?)*)", text, re.M)
if m:
    mm = re.search(r"\s*target_items:\s*(\d+)", m.group(1))
    if mm: print(mm.group(1)); sys.exit()
print(10)
PY
)
hard_stop_pt=$(python3 - "$SCHEDULE" <<'PY'
import sys, re
with open(sys.argv[1]) as f:
    text = f.read()
m = re.search(r"^overnight:\s*\n((?:[ \t]+\S.*\n?)*)", text, re.M)
if m:
    mm = re.search(r"\s*hard_stop_pt:\s*\"?(\d{2}:\d{2})", m.group(1))
    if mm: print(mm.group(1)); sys.exit()
print("06:00")
PY
)

if [ -z "$game_dir" ] || [ ! -d "$game_dir" ]; then
  echo "overnight: game_dir not resolvable — abort"
  exit 1
fi

LOG_DIR="$REPO_DIR/logs/overnight/$(date +%Y-%m-%d)"
mkdir -p "$LOG_DIR"

# --- compute hard-stop epoch in PT ---
# If "now" is already past hard_stop_pt today, hard stop is hard_stop_pt tomorrow.
hard_stop_h=${hard_stop_pt%:*}
hard_stop_m=${hard_stop_pt#*:}
now_h=$(TZ=America/Los_Angeles date +%H)
if [ "$now_h" -ge "$hard_stop_h" ]; then
  hard_stop_epoch=$(TZ=America/Los_Angeles date -v+1d -v"${hard_stop_h}H" -v"${hard_stop_m}M" -v0S +%s)
else
  hard_stop_epoch=$(TZ=America/Los_Angeles date -v"${hard_stop_h}H" -v"${hard_stop_m}M" -v0S +%s)
fi
echo "overnight: target=$target_items items, hard_stop=$(date -r "$hard_stop_epoch" '+%Y-%m-%d %H:%M %Z'), game_dir=$game_dir"

# --- pull master fresh ---
cd "$game_dir"
git fetch --quiet origin master
git checkout --quiet master
if ! git pull --ff-only --quiet origin master; then
  echo "overnight: master pull failed — abort"
  exit 1
fi

# --- main loop ---
attempted_titles=()           # already attempted this run (success or fail)
shipped=0
fail_streak=0                 # consecutive claude-CLI failures → bail
MAX_FAIL_STREAK=3

while true; do
  # budget checks
  now_epoch=$(date +%s)
  if [ "$shipped" -ge "$target_items" ]; then
    echo "overnight: hit target ($shipped)"
    break
  fi
  if [ "$now_epoch" -ge "$hard_stop_epoch" ]; then
    echo "overnight: hard stop reached (shipped=$shipped)"
    break
  fi
  if [ "$fail_streak" -ge "$MAX_FAIL_STREAK" ]; then
    echo "overnight: $MAX_FAIL_STREAK consecutive claude failures — bailing"
    break
  fi

  # pick next eligible item (skip [idea], [cold], and already-attempted)
  skip_args=()
  for t in "${attempted_titles[@]}"; do skip_args+=(--skip "$t"); done
  next_json=$(python3 "$WORKMD" top "$game_dir/WORK.md" -n 1 "${skip_args[@]}")
  next_title=$(echo "$next_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['title'] if d else '')")
  if [ -z "$next_title" ]; then
    echo "overnight: no eligible items left in Todo"
    break
  fi

  attempted_titles+=("$next_title")
  slug=$(echo "$next_title" | python3 "$SLUGIFY")
  branch="feat/overnight-$(date +%Y%m%d)-$slug"
  item_log="$LOG_DIR/$slug.log"
  echo "overnight: → '$next_title' on $branch"

  # checkout fresh branch off master
  git checkout --quiet master
  git checkout --quiet -B "$branch"

  outcome=skip
  for attempt in 1 2; do
    {
      echo "=== attempt $attempt on '$next_title' at $(date) ==="
    } >> "$item_log"

    # Build a per-item prompt suffix for the Developer agent.
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
    # Write a one-shot prompt override file the run_agent will look at.
    echo "$item_brief" > "$item_log.brief"

    # Fire developer.
    if SPRAXEL_ITEM_BRIEF="$item_log.brief" bash "$RUN_AGENT" developer >> "$item_log" 2>&1; then
      fail_streak=0
    else
      rc=$?
      echo "overnight: developer FAILED rc=$rc on attempt $attempt" >> "$item_log"
      if [ "$rc" -eq 1 ]; then
        # claude CLI failure (vs item-level blocker reported via exit 0 + status)
        fail_streak=$((fail_streak + 1))
      fi
      [ "$attempt" -lt 2 ] && continue
      outcome=fail
      break
    fi

    # Run local tests (already managed by separate launchd; here we invoke directly).
    if bash "$game_dir/scripts/run_local_tests.sh" >> "$item_log" 2>&1; then
      :  # tests passed
    else
      echo "overnight: tests FAILED on attempt $attempt" >> "$item_log"
      [ "$attempt" -lt 2 ] && { git checkout --quiet "$branch"; continue; }
      outcome=fail
      break
    fi

    # Run reviewer; exit 0 = clean, exit 1 = blocking.
    if bash "$RUN_AGENT" reviewer >> "$item_log" 2>&1; then
      :  # clean
    else
      echo "overnight: reviewer BLOCKED on attempt $attempt" >> "$item_log"
      outcome=fail
      break
    fi

    # All gates passed — squash-merge to master, push.
    git checkout --quiet master
    if git merge --squash --quiet "$branch" \
       && git -c user.email=overnight-bot@spraxel.ai -c user.name='Spraxel Overnight' \
              commit --quiet -m "feat: $next_title" \
       && git push --quiet origin master; then
      # Move the item Todo → Shipped-since
      python3 "$WORKMD" ship "$game_dir/WORK.md" "$next_title" >> "$item_log" 2>&1 || true
      git add WORK.md
      git -c user.email=overnight-bot@spraxel.ai -c user.name='Spraxel Overnight' \
          commit --quiet -m "work: shipped '$next_title'" \
        && git push --quiet origin master
      shipped=$((shipped + 1))
      outcome=ok
      echo "overnight: ✓ shipped '$next_title' (total=$shipped)"
      break
    else
      echo "overnight: merge/push FAILED on attempt $attempt" >> "$item_log"
      outcome=fail
      break
    fi
  done

  if [ "$outcome" != "ok" ]; then
    # Escalate the item: drop from Todo, append to .factory/escalations.md.
    git checkout --quiet master
    git branch -D "$branch" --quiet 2>/dev/null || true
    python3 "$WORKMD" escalate "$game_dir/WORK.md" "$next_title" \
      --log "$item_log" >> "$item_log" 2>&1 || true
    git add WORK.md "$game_dir/.factory/escalations.md" 2>/dev/null || true
    git -c user.email=overnight-bot@spraxel.ai -c user.name='Spraxel Overnight' \
        commit --quiet -m "escalate: '$next_title'" >> "$item_log" 2>&1 || true
    git push --quiet origin master 2>/dev/null || true
    echo "overnight: ✗ escalated '$next_title'"
  fi
done

# --- summary ---
echo "overnight: done — shipped=$shipped, attempted=${#attempted_titles[@]}, hard_stop=$(date -r "$hard_stop_epoch" '+%H:%M')"
cat > "$REPO_DIR/.cache/last-overnight.txt" <<EOF
ts: $(date '+%Y-%m-%d %H:%M:%S %Z')
shipped: $shipped
attempted: ${#attempted_titles[@]}
hard_stop: $(date -r "$hard_stop_epoch" '+%Y-%m-%d %H:%M %Z')
fail_streak: $fail_streak
log_dir: $LOG_DIR
EOF
exit 0
