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

# Startup trace — overwritten each spawn. If the wrapper dies before
# reaching the main loop (e.g., env issue under launchd), this file shows
# the last step it survived. Diagnostic for the launchd-spawn-died-silently
# class of bugs (see 2026-05-26 12:00 PT incident).
TRACE_FILE="$CACHE_DIR/continuous-startup-trace.log"
trace() { echo "$(date '+%Y-%m-%d %H:%M:%S %Z')  $*" >> "$TRACE_FILE"; }
# Truncate at start so old traces don't accumulate.
{
  echo "=== spawn pid=$$ at $(date '+%Y-%m-%d %H:%M:%S %Z') ==="
  echo "  parent_pid=$PPID"
  echo "  PATH=$PATH"
  echo "  HOME=${HOME:-UNSET}"
  echo "  USER=${USER:-UNSET}"
  echo "  LOGNAME=${LOGNAME:-UNSET}"
  echo "  TERM=${TERM:-UNSET}"
  echo "  SHELL=${SHELL:-UNSET}"
  echo "  TZ=${TZ:-UNSET}"
  echo "  PWD=$(pwd)"
  echo "  argv0=${BASH_SOURCE[0]}"
} > "$TRACE_FILE"
trace "step: starting"

# --- single-instance lock ---
LOCK="$LOCKS_DIR/continuous.lockdir"
if ! mkdir "$LOCK" 2>/dev/null; then
  trace "step: exit 0 (lockdir already held — another instance running)"
  exit 0   # another instance is running
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM
trace "step: lock acquired"

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
trace "step: game_dir parsed: '$game_dir'"
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
trace "step: target_per_batch=$target_per_batch"
if [ -z "$game_dir" ] || [ ! -d "$game_dir" ]; then
  trace "step: FATAL — game_dir not resolvable ('$game_dir')"
  echo "continuous: game_dir not resolvable — abort"
  exit 1
fi
trace "step: game_dir validated"

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

# Force the game repo back to a clean master synced with origin. Called at
# the start of every iteration AND before recording an escalation, so a
# single bad item can't silently corrupt the next item or block its own
# escalation from being recorded. Returns 0 if HEAD ends up on clean
# master, 1 otherwise (the only way that fails is a genuinely broken repo
# — disk full, lock held by another process, etc.).
clean_slate() {
  cd "$game_dir" || return 1
  # Abort any in-progress merge/rebase/cherry-pick.
  git merge --abort 2>/dev/null
  git rebase --abort 2>/dev/null
  git cherry-pick --abort 2>/dev/null
  # Drop leftover baseline-test-stash entries from prior failed runs.
  while git stash list 2>/dev/null | grep -q "baseline-test-stash"; do
    git stash drop 2>/dev/null || break
  done
  # Discard any staged / unstaged changes from a wrecked iteration.
  git reset --hard HEAD --quiet 2>/dev/null
  # Force-switch to master, then sync to origin.
  git fetch --quiet origin master 2>/dev/null
  if ! git checkout -f master 2>/dev/null; then
    return 1
  fi
  git reset --hard origin/master --quiet 2>/dev/null
  # Confirm HEAD really is master.
  local head_branch
  head_branch=$(git symbolic-ref --short HEAD 2>/dev/null)
  [ "$head_branch" = "master" ]
}

# --- the per-item ship logic ---
# Returns 0 on successful ship, 1 on failure, 2 on clarify-only (don't count).
ship_one_item() {
  local LOG_DIR="$REPO_DIR/logs/continuous/$(date +%Y-%m-%d)"
  mkdir -p "$LOG_DIR"
  cd "$game_dir" || return 1

  # Self-heal: previous iteration may have left a conflicted index, an
  # in-progress merge, a stale stash, or HEAD on a feature branch. Without
  # this, the next item silently runs on the wrong branch / poisoned tree.
  if ! clean_slate; then
    echo "continuous: clean_slate FAILED at iter start — abort"
    return 1
  fi

  local next_json next_title slug branch item_log
  next_json=$(python3 "$WORKMD" top "$game_dir/WORK.md" -n 1)
  next_title=$(echo "$next_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['title'] if d else '')")
  if [ -z "$next_title" ]; then
    echo "continuous: no eligible items in WORK.md ## Todo"
    return 3   # nothing to do
  fi

  slug=$(echo "$next_title" | python3 "$SLUGIFY")
  item_log="$LOG_DIR/$slug.log"

  # ── Resume path ───────────────────────────────────────────────────────────
  # If the item is tagged [resume], the CEO triaged a prior escalation and
  # wants the dev to pick up the saved branch. Extract the branch name from
  # the item's details (looking for a "branch: <name>" line), check it out,
  # and rebase onto current master so the dev resumes on an up-to-date base.
  local is_resume="false"
  local saved_branch=""
  if echo "$next_title" | grep -qiE '^\[resume\]'; then
    is_resume="true"
    saved_branch=$(echo "$next_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
if d:
    for det in d[0].get('details', []):
        det = det.strip()
        if det.lower().startswith('branch:'):
            print(det.split(':', 1)[1].strip())
            break
")
  fi

  if [ "$is_resume" = "true" ] && [ -n "$saved_branch" ]; then
    branch="$saved_branch"
    echo "continuous: ↻ resuming '$next_title' on $branch"
    # Fetch the saved branch from origin and check it out locally.
    if ! git fetch --quiet origin "$branch" 2>/dev/null; then
      echo "continuous: resume FAILED — branch '$branch' missing on origin. Falling back to fresh start." >&2
      branch="feat/cont-$(date +%Y%m%d-%H%M)-$slug"
      git checkout --quiet -B "$branch" master
      is_resume="false"
    else
      if ! git checkout --quiet -B "$branch" "origin/$branch" 2>/dev/null; then
        echo "continuous: resume FAILED — could not checkout origin/$branch. Falling back." >&2
        branch="feat/cont-$(date +%Y%m%d-%H%M)-$slug"
        git checkout --quiet -B "$branch" master
        is_resume="false"
      else
        # Rebase the saved branch onto current master. If rebase conflicts,
        # abort, re-tag as [escalated] with "rebase conflict" note.
        if ! git rebase --quiet master 2>/dev/null; then
          git rebase --abort 2>/dev/null || true
          echo "continuous: resume FAILED — rebase conflicts. Re-escalating." >&2
          clean_slate
          # Re-mark the item as [escalated] (replacing [resume]) with the conflict note.
          python3 "$WORKMD" escalate "$game_dir/WORK.md" "${next_title#\[resume\] }" \
            --detail "RE-ESCALATED $(date '+%Y-%m-%d %H:%M %Z'): rebase of '$branch' onto master conflicted — hand-merge needed." \
            2>/dev/null
          git add WORK.md 2>/dev/null
          git -c user.email=continuous-bot@spraxel.ai -c user.name='Spraxel Continuous' \
              commit --quiet -m "chore(escalate): rebase conflict on resume — '$(echo "$next_title" | sed -E 's/^\[resume\] //' | cut -c1-50)...'" 2>/dev/null
          git push --quiet origin master 2>/dev/null || true
          return 1
        fi
      fi
    fi
  else
    branch="feat/cont-$(date +%Y%m%d-%H%M)-$slug"
    echo "continuous: → '$next_title' on $branch"
    git checkout --quiet -B "$branch" master
  fi

  local outcome=fail
  local baseline_failures=""
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
    # Resume-mode prompt suffix: tell the dev they're picking up prior work
    # on an existing branch (already checked out + rebased on master).
    if [ "$is_resume" = "true" ]; then
      item_brief="$item_brief

## RESUME MODE

You are resuming a previously-escalated work item. The branch \`$branch\` is
already checked out and rebased on current master — the prior dev's commits
are visible in \`git log\`. The CEO has reviewed the failure and edited the
item details above (their feedback is what you should act on).

Read what was tried (\`git log --oneline -10\` + \`git show <sha>\`) and either:
  - Build on the existing code with new commits
  - Or revert / amend specific bad pieces and replace them

Do NOT delete the branch or reset to master. Commit your changes; the wrapper
folds everything into one squash-merge to master at the end."
    fi
    echo "$item_brief" > "$item_log.brief"

    # Fire developer. Capture the real exit code (the `if !` form drops it to 0).
    SPRAXEL_ITEM_BRIEF="$item_log.brief" bash "$RUN_AGENT" developer >> "$item_log" 2>&1
    dev_rc=$?
    if [ "$dev_rc" -eq 2 ]; then
      # rc=2 = developer.lockdir held (orphan or concurrent fire). NOT a real
      # failure — wait for the lock to clear, then retry the SAME item.
      echo "continuous: developer LOCKED — waiting (will retry same item, not escalate)" >> "$item_log"
      git checkout --quiet master
      git branch -D "$branch" --quiet 2>/dev/null || true
      for waited in 30 60 120 240 480 600; do
        sleep "$waited"
        [ ! -d "$REPO_DIR/.locks/developer.lockdir" ] && break
      done
      if [ -d "$REPO_DIR/.locks/developer.lockdir" ]; then
        echo "continuous: lock still held after 25 min — giving up this iteration" >> "$item_log"
        return 2   # treat as "nothing shipped" — outer loop sleeps + retries
      fi
      attempt=0   # next loop iteration becomes attempt 1
      continue
    elif [ "$dev_rc" -ne 0 ]; then
      echo "continuous: developer rc=$dev_rc on attempt $attempt" >> "$item_log"
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

    # Baseline-aware test gate: capture pre-Developer test state once per item,
    # then re-run after Developer's changes. Only count NEW failures (tests
    # that passed before this change but fail after). Pre-existing failures
    # in unrelated modules are noted but don't trigger escalation.
    if [ -z "${baseline_failures:-}" ]; then
      # First attempt: capture baseline from master (before Developer's commit).
      git stash push --quiet -m "baseline-test-stash" 2>/dev/null
      git checkout --quiet master 2>/dev/null
      bash "$game_dir/scripts/run_local_tests.sh" --quiet >> "$item_log" 2>&1 || true
      baseline_failures=$(python3 -c "
import json
try:
    d = json.load(open('$game_dir/.factory/local-tests-status.json'))
    print('\\n'.join(d.get('failures', [])))
except Exception:
    pass
")
      git checkout --quiet "$branch" 2>/dev/null
      git stash pop --quiet 2>/dev/null
      echo "continuous: baseline failures captured ($(echo "$baseline_failures" | grep -c .))" >> "$item_log"
    fi

    # Run tests on Developer's branch.
    bash "$game_dir/scripts/run_local_tests.sh" --quiet >> "$item_log" 2>&1
    rc=$?
    if [ $rc -ne 0 ]; then
      current_failures=$(python3 -c "
import json
try:
    d = json.load(open('$game_dir/.factory/local-tests-status.json'))
    print('\\n'.join(d.get('failures', [])))
except Exception:
    pass
")
      # Compare: anything in current_failures NOT in baseline_failures = new.
      new_failures=$(comm -23 <(echo "$current_failures" | sort -u) <(echo "$baseline_failures" | sort -u))
      if [ -n "$new_failures" ]; then
        echo "continuous: tests FAILED — NEW failures on attempt $attempt:" >> "$item_log"
        echo "$new_failures" >> "$item_log"
        [ "$attempt" -lt 2 ] && { git checkout --quiet "$branch"; continue; }
        outcome=fail
        break
      fi
      echo "continuous: tests had failures but all were pre-existing (baseline match) — accepting" >> "$item_log"
    fi

    if ! bash "$RUN_AGENT" reviewer >> "$item_log" 2>&1; then
      echo "continuous: reviewer BLOCKED" >> "$item_log"
      outcome=fail
      break
    fi

    # Build a clean commit subject for the squash-merge. The developer is
    # supposed to print `COMMIT_SUBJECT: <conv-commit subject>` near the end
    # of its run (per spraxel-developer.md step 9). If present, use that
    # verbatim. Otherwise fall back to a cleaned version of the WORK.md
    # title — at least capitalize + strip trailing punctuation + truncate
    # parenthetical tangents — so the commit doesn't echo the CEO's
    # colloquial dictation language onto master.
    commit_subject=$(grep -E '^COMMIT_SUBJECT:[[:space:]]*' "$item_log" 2>/dev/null \
                     | tail -1 \
                     | sed -E 's/^COMMIT_SUBJECT:[[:space:]]*//')
    if [ -z "$commit_subject" ]; then
      commit_subject=$(python3 -c "
import sys
t = sys.argv[1].strip().rstrip(' ?.,;:!')
# Capitalize first letter if lowercase
if t and t[0].islower():
    t = t[0].upper() + t[1:]
# If too long + has a parenthetical, drop the parenthetical
if len(t) > 80 and '(' in t:
    t = t.split('(')[0].strip().rstrip(' -—:,')
# Cap at 100 chars hard
print('feat: ' + t[:100])
" "$next_title")
    fi
    # Ensure it starts with a conv-commit type. If the dev forgot, prepend feat:.
    case "$commit_subject" in
      feat:*|fix:*|refactor:*|perf:*|docs:*|chore:*|test:*|style:*|build:*|ci:*) ;;
      feat\(*|fix\(*|refactor\(*|perf\(*|docs\(*|chore\(*|test\(*) ;;
      *) commit_subject="feat: $commit_subject" ;;
    esac

    # Same cleanup for the `work: shipped` follow-up — truncate very long
    # titles so the bookkeeping commit subject doesn't blow out git log.
    short_title=$(python3 -c "
import sys
t = sys.argv[1].strip()
if len(t) > 60:
    t = t[:57] + '...'
print(t)
" "$next_title")

    git checkout --quiet master
    if git merge --squash --quiet "$branch" \
       && git -c user.email=continuous-bot@spraxel.ai -c user.name='Spraxel Continuous' \
              commit --quiet -m "$commit_subject" \
       && git push --quiet origin master; then
      python3 "$WORKMD" ship "$game_dir/WORK.md" "$next_title" >> "$item_log" 2>&1 || true
      git add WORK.md 2>/dev/null
      git -c user.email=continuous-bot@spraxel.ai -c user.name='Spraxel Continuous' \
          commit --quiet -m "chore(work): mark '$short_title' as shipped" 2>/dev/null
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
    # Capture the dev's branch state BEFORE clean_slate wipes the working
    # tree (we want to preserve the branch on origin so CEO can resume from
    # it after triage).
    local last_commit_sha=""
    last_commit_sha=$(git rev-parse --short "$branch" 2>/dev/null || echo "")

    # Push the failed branch to origin so the work isn't lost when local
    # tree is reset. The CEO can later flip [escalated] → [resume] and the
    # wrapper will pull this branch back down.
    if [ -n "$last_commit_sha" ]; then
      git push --quiet --force-with-lease origin "$branch":"$branch" 2>/dev/null || \
        echo "continuous: WARNING — could not push failed branch '$branch' to origin" >> "$item_log"
    fi

    # Self-heal before the escalation bookkeeping commit. Without this, a
    # wrecked tree would block the escalate commit or land it on the wrong
    # branch.
    if ! clean_slate; then
      echo "continuous: ESCALATION self-heal FAILED — cannot reach master to record '$next_title'" >> "$item_log"
      echo "continuous: ⚠️  could not escalate '$next_title' — fail_streak will brake the loop"
      return 1
    fi

    # Build a self-contained markdown summary block from the item log.
    # The CEO reads this in escalations.md AND in WORK.md item details —
    # no log-link chasing required.
    local summary_file="$item_log.summary.md"
    python3 - "$item_log" "$next_title" "$branch" "$last_commit_sha" > "$summary_file" <<'PY'
import sys, re, time, os
log_path, title, branch, last_sha = sys.argv[1:5]
clean_title = re.sub(r'^\[(resume|escalated)\]\s*', '', title, flags=re.I)
try:
    with open(log_path) as f:
        log = f.read()
except FileNotFoundError:
    log = ""
attempts = []
for chunk in re.split(r'=== attempt (\d+) at (.*?) ===', log):
    pass
# Simpler: re-split by attempt header lines.
parts = re.split(r'^=== attempt (\d+) at (.*?) ===\s*$', log, flags=re.M)
# parts[0] = preamble (ignored); then triples of (n, ts, body)
i = 1
while i + 2 < len(parts):
    n, ts, body = parts[i], parts[i+1], parts[i+2]
    # Extract baseline failure list (one capture per attempt usually)
    baseline_match = re.search(r"baseline failures captured \((\d+)\)", body)
    baseline_count = int(baseline_match.group(1)) if baseline_match else 0
    new_fail_match = re.search(r"NEW failures on attempt \d+:\s*\n(.*?)(?=\n===|\nescalated:|\Z)", body, re.S)
    new_fails = []
    if new_fail_match:
        for line in new_fail_match.group(1).splitlines():
            line = line.strip()
            if line and not line.startswith("continuous:") and not line.startswith("["):
                new_fails.append(line)
    # Detect categorical failure modes
    if "reviewer BLOCKED" in body:
        new_fails.insert(0, "reviewer rejected the diff")
    if "developer rc=" in body and not new_fails:
        rc_match = re.search(r"developer rc=(\d+)", body)
        new_fails.append(f"dev agent crashed (rc={rc_match.group(1) if rc_match else '?'})")
    if "merge/push FAILED" in body:
        new_fails.append("merge to master failed")
    attempts.append({
        "n": int(n), "ts": ts.strip(),
        "baseline": baseline_count, "new": new_fails,
    })
    i += 3
out = []
out.append("")
out.append(f"## Escalated {time.strftime('%Y-%m-%d %H:%M %Z')} — {clean_title}")
out.append("")
out.append("**Outcome**: not merged. Master unchanged. Feature branch preserved on origin.")
out.append("")
if not attempts:
    out.append("**Why it failed**: could not parse failure details from per-item log.")
else:
    cats = set()
    for a in attempts:
        for f in a["new"]:
            cats.add(f)
    if cats:
        out.append(f"**Why it failed**: " + "; ".join(sorted(cats)) + ".")
    else:
        out.append("**Why it failed**: see attempt details below.")
out.append("")
for a in attempts:
    out.append(f"**Attempt {a['n']}** ({a['ts']}):")
    if a["baseline"]:
        out.append(f"  - {a['baseline']} pre-existing baseline failure(s) ignored")
    if a["new"]:
        for f in a["new"]:
            out.append(f"  - NEW: {f}")
    else:
        out.append("  - no NEW failures captured (see log for details)")
    out.append("")
out.append(f"**Branch saved on origin**: `{branch}` @ `{last_sha or 'unknown'}`")
out.append("")
out.append("**How to proceed**: edit the WORK.md item above to add scope/clarifications,")
out.append("then change the `[escalated]` tag to `[resume]` (or run")
out.append("`python3 scripts/workmd.py resume WORK.md \"<title>\"`). The wrapper will pick")
out.append("it up next overnight and resume the dev on this branch. To trash instead,")
out.append("delete the WORK.md item line — janitor will sweep the orphan branch.")
out.append("")
print("\n".join(out))
PY

    # Build the per-item detail lines that will live under the WORK.md item.
    # Aggregate new failures for a one-line "why" detail.
    local why_line
    why_line=$(grep -h "NEW failures on attempt" "$item_log" 2>/dev/null | head -1)
    local detail_args=()
    detail_args+=(--detail "outcome: not merged; master unchanged")
    detail_args+=(--detail "branch: $branch")
    [ -n "$last_commit_sha" ] && detail_args+=(--detail "last-commit: $last_commit_sha")
    if [ -n "$why_line" ]; then
      detail_args+=(--detail "why: see escalations.md entry below")
    fi
    detail_args+=(--detail "to retry: change [escalated] → [resume] and edit scope above")

    python3 "$WORKMD" escalate "$game_dir/WORK.md" "$next_title" \
      --summary-file "$summary_file" \
      "${detail_args[@]}" \
      >> "$item_log" 2>&1 || true
    rm -f "$summary_file"

    # Build a clean short title for the escalate commit subject (the body
    # in WORK.md + escalations.md has the full context).
    esc_short=$(python3 -c "
import sys, re
t = re.sub(r'^\[(resume|escalated)\]\s*', '', sys.argv[1]).strip().rstrip(' ?.,;:!')
if t and t[0].islower():
    t = t[0].upper() + t[1:]
print(t[:60] + ('...' if len(t) > 60 else ''))
" "$next_title")
    git add WORK.md "$game_dir/.factory/escalations.md" 2>/dev/null
    git -c user.email=continuous-bot@spraxel.ai -c user.name='Spraxel Continuous' \
        commit --quiet -m "chore(escalate): $esc_short — tests failed after 2 attempts" 2>/dev/null
    git push --quiet origin master 2>/dev/null || true
    echo "continuous: ✗ escalated '$next_title' — branch '$branch' preserved on origin"
    return 1
  fi

  echo "continuous: ✓ shipped '$next_title'"
  return 0
}

# --- main loop ---
init_state_if_missing
trace "step: state initialized"
echo "continuous: started — target_per_batch=$target_per_batch, game_dir=$game_dir"
trace "step: entering main loop (startup complete)"

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
