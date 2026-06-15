#!/usr/bin/env bash
# interactive_dev_step.sh — lock-critical git/workmd mechanics for the
# interactive developer mode (the `/spraxel-develop` skill).
#
# This is a focused, SERIAL, single-worker subset of continuous_dev.sh's
# claim → merge → ship → retry sequence. The orchestration (picking items,
# running the developer + reviewer as Agent subagents, the retry/review loop)
# lives in the skill; the fragile parts that MUST be correct — the shared
# master-push lock protocol and the squash-merge/ship bookkeeping — live here
# in tested bash so the skill never improvises them.
#
# It mirrors continuous_dev.sh's proven sequences:
#   - claim under master-push.lockdir, commit+push the [wip:0] tag (so it can't
#     be wiped by a concurrent crew push) — continuous_dev.sh:429-470
#   - merge --squash + Game.md gate + ship + push under the lock — :1118-1235
#   - retry/escalate retag under the lock — :1238-1351
#
# Subcommands:
#   claim-one                         → claim top item, set up worktree+branch.
#                                        Prints a JSON object, or "EMPTY" if dry.
#   finish-one <branch> <title> [--subject S] [--body-file F]
#                                     → squash-merge to master, ship, push, cleanup.
#   fail-one <branch> <title> retry|escalate [--detail D]...
#                                     → bounce item back ([retry]) or escalate.
#
# Worker id is fixed at 0 (only one interactive developer ever runs; the mode
# guarantees no headless workers — see tick.sh + continuous_dev.sh flag checks).

set -o pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKMD="$REPO_DIR/scripts/workmd.py"
SLUGIFY="$REPO_DIR/scripts/slugify.py"
SPX="$REPO_DIR/scripts/spx_config.py"
LOCKS_DIR="$REPO_DIR/.locks"
CACHE_DIR="$REPO_DIR/.cache"
MASTER_LOCK="$LOCKS_DIR/master-push.lockdir"
STATE_FILE="$CACHE_DIR/continuous-state.json"   # shared cap-counter state (continuous_dev.sh)
WORKER_ID=0
. "$REPO_DIR/scripts/lockutils.sh"

GAME_DIR="$(python3 "$SPX" get game_dir 2>/dev/null)"
GAME_DIR="${GAME_DIR/#\~/$HOME}"      # expand a leading ~
WORKTREE="$REPO_DIR/.worktrees/interactive"
BOT_ID=(-c user.email=interactive-dev-bot@spraxel.ai -c user.name='Spraxel Interactive Dev')

mkdir -p "$LOCKS_DIR" "$CACHE_DIR" "$REPO_DIR/.worktrees"

die() { echo "interactive_dev_step: $*" >&2; exit 1; }
[ -n "$GAME_DIR" ] && [ -d "$GAME_DIR/.git" ] || [ -f "$GAME_DIR/.git" ] || die "game_dir not found: '$GAME_DIR'"

# Ensure the interactive worktree exists (a worktree of the GAME repo), then
# reset it to a clean detached origin/master so a stale tree never poisons the
# next item. Mirrors continuous_dev.sh's per-worker worktree + clean_slate.
_ensure_worktree() {
  if [ ! -e "$WORKTREE/.git" ]; then
    git -C "$GAME_DIR" worktree prune 2>/dev/null
    git -C "$GAME_DIR" worktree add --detach "$WORKTREE" origin/master --quiet 2>/dev/null \
      || die "could not create worktree at $WORKTREE"
  fi
  git -C "$WORKTREE" checkout --detach origin/master --quiet 2>/dev/null || true
  git -C "$WORKTREE" reset --hard origin/master --quiet 2>/dev/null || true
  git -C "$WORKTREE" clean -fd --quiet 2>/dev/null || true
}

# Deterministic branch name — a pure function of the item (matches
# continuous_dev.sh so a [retry] reuses the same branch the prior attempt pushed).
_branch_for() {
  local title="$1" slug core hash
  slug=$(printf '%s' "$title" | python3 "$SLUGIFY")
  core=$(printf '%s' "$title" | sed -E 's/^[[:space:]]*(\[[a-z-]+\][[:space:]]*)+//I')
  hash=$(printf '%s' "$core" | shasum 2>/dev/null | cut -c1-6)
  printf 'feat/cont-%s-%s' "$slug" "$hash"
}

# Strip leading state/kind tags + a trailing/leading priority marker, used to
# build a conventional-commit subject when the caller doesn't supply one.
_derive_subject() {
  local raw="$1" body pfx
  body=$(printf '%s' "$raw" | sed -E 's/\[[^]]*\]//g; s/(^|[[:space:]])p[0-3]([[:space:]]|$)/ /g; s/^[[:space:]]+//; s/[[:space:]]+$//')
  # Already conventional? pass through.
  if printf '%s' "$body" | grep -qE '^(feat|fix|chore|refactor|docs|test|perf)(\([^)]*\))?:'; then
    printf '%s' "$body"; return
  fi
  case "$raw" in
    *'[bug]'*|*'[test_failure]'*)        pfx="fix:" ;;
    *'[chore]'*|*'[refactor]'*|*'[epic]'*) pfx="chore:" ;;
    *)                                   pfx="feat:" ;;
  esac
  printf '%s %s' "$pfx" "$body"
}

# ── claim-one ──────────────────────────────────────────────────────────────
cmd_claim_one() {
  # Regenerate escalations.md (idempotent), like the headless loop.
  python3 "$WORKMD" sync-escalations "$GAME_DIR/WORK.md" \
    --escalations "$GAME_DIR/.factory/escalations.md" >/dev/null 2>&1 || true

  if ! acquire_lock "$MASTER_LOCK" 60 0.3; then
    die "claim: master-push lock held >60s"
  fi
  local next_json
  next_json=$(
    trap 'release_lock "'"$MASTER_LOCK"'"' EXIT
    cd "$GAME_DIR" || exit 1
    git fetch --quiet origin master 2>/dev/null
    git checkout --quiet master 2>/dev/null || exit 1
    git reset --hard origin/master --quiet 2>/dev/null
    json=$(python3 "$WORKMD" claim "$GAME_DIR/WORK.md" --worker-id "$WORKER_ID" 2>/dev/null)
    [ -z "$json" ] && exit 3
    git add WORK.md 2>/dev/null
    if ! git diff --cached --quiet; then
      if ! git "${BOT_ID[@]}" commit --quiet -m "chore(claim): interactive-dev" 2>/dev/null >/dev/null \
         || ! git push --quiet origin master 2>/dev/null >/dev/null; then
        git reset --hard origin/master --quiet 2>/dev/null >/dev/null
        exit 4
      fi
    fi
    printf '%s' "$json"
  )
  local rc=$?
  rmdir "$MASTER_LOCK" 2>/dev/null || true
  if [ "$rc" -eq 3 ] || [ -z "$next_json" ]; then echo "EMPTY"; return 0; fi
  [ "$rc" -eq 4 ] && die "claim: lost push race (a crew/other push won) — just re-run claim-one"

  # Parse the claimed item; strip the [wip:N] tag from the title for all
  # downstream use (the WORK.md item keeps it until ship/retry/unclaim).
  local title clean_title branch
  title=$(printf '%s' "$next_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print((d[0] if isinstance(d,list) and d else d)['title'])" 2>/dev/null)
  [ -n "$title" ] || die "claim: malformed JSON from workmd"
  clean_title=$(printf '%s' "$title" | sed -E 's/^\[wip:[0-9]+\][[:space:]]*//')
  branch=$(_branch_for "$clean_title")

  _ensure_worktree
  git -C "$WORKTREE" checkout -B "$branch" origin/master --quiet 2>/dev/null \
    || die "could not check out branch $branch in worktree"

  # Emit a tidy JSON object for the skill: clean title, details, branch, worktree,
  # plus the [test_failure] signal (so the skill can honor cap_excludes_test_fixes).
  CLEAN_TITLE="$clean_title" BRANCH="$branch" WORKTREE="$WORKTREE" \
  python3 - "$next_json" <<'PY'
import json, os, sys, re
raw = json.loads(sys.argv[1])
it = raw[0] if isinstance(raw, list) and raw else raw
title = os.environ["CLEAN_TITLE"]
details = it.get("details", []) if isinstance(it, dict) else []
is_tf = bool(re.match(r'^\[test_failure\]', title, re.I))
test_ref = ""
for d in details:
    m = re.match(r'test-ref:\s*(\S+)', str(d).strip(), re.I)
    if m:
        test_ref = m.group(1); break
print(json.dumps({
    "status": "claimed",
    "title": title,
    "details": details,
    "branch": os.environ["BRANCH"],
    "worktree": os.environ["WORKTREE"],
    "is_test_failure": is_tf,
    "test_ref": test_ref,
}, indent=2))
PY
}

# ── finish-one ─────────────────────────────────────────────────────────────
cmd_finish_one() {
  local branch="$1" title="$2"; shift 2
  local subject="" body_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --subject)   subject="$2"; shift 2 ;;
      --body-file) body_file="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$branch" ] && [ -n "$title" ] || die "finish-one needs <branch> <title>"

  [ -n "$subject" ] || subject=$(_derive_subject "$title")
  local body=""
  if [ -n "$body_file" ] && [ -s "$body_file" ]; then
    body=$(cat "$body_file")
  else
    # Changelog of the dev's commits on the branch → squash body.
    body=$(git -C "$GAME_DIR" log --reverse --format='- %s' "origin/master..$branch" 2>/dev/null)
  fi
  local commit_message="$subject"
  [ -n "$body" ] && commit_message="$subject"$'\n\n'"$body"
  local short_title
  short_title=$(python3 -c "import sys; t=sys.argv[1].strip(); print(t[:57]+'...' if len(t)>60 else t)" "$title")

  if ! acquire_lock "$MASTER_LOCK" 60 0.3; then die "finish: master-push lock held >60s"; fi
  (
    trap 'release_lock "'"$MASTER_LOCK"'"' EXIT
    cd "$GAME_DIR" || exit 1
    git fetch --quiet origin master 2>/dev/null
    git checkout --quiet master 2>/dev/null || exit 1
    git reset --hard origin/master --quiet 2>/dev/null
    # Drop any stray untracked files (e.g. a dev subagent or a rogue worker that
    # wrote into the main checkout) so they can't block the squash with
    # "untracked working tree files would be overwritten". Respects .gitignore
    # (no -x), so .godot/.factory local caches are left alone.
    git clean -fd --quiet 2>/dev/null || true
    if ! git merge --squash --quiet "$branch"; then
      # Code conflict against current master — dev-fixable. Clean up + bail to retry.
      git reset --hard origin/master --quiet 2>/dev/null || true
      git clean -fd --quiet 2>/dev/null || true
      exit 1
    fi
    # WORK.md is owned by the wrapper via workmd.py — never accept a branch's copy.
    git checkout HEAD -- WORK.md 2>/dev/null || true
    # Game.md survival gate (mirror continuous_dev.sh:1160-1172): a player-facing
    # change must carry a Game.md update in the squash.
    if git diff --cached --quiet -- Game.md 2>/dev/null; then
      _need_gm=0
      echo "$title" | grep -qiE '\[game-feature\]' && _need_gm=1
      git diff --quiet "origin/master...$branch" -- Game.md 2>/dev/null || _need_gm=1
      git diff --cached -- scripts/systems/debug_boot.gd 2>/dev/null \
        | grep -qE '^\+[[:space:]]*func _demo_|--demo-feature=' && _need_gm=1
      if [ "$_need_gm" -eq 1 ]; then
        git reset --hard origin/master --quiet 2>/dev/null || true
        git clean -fd --quiet 2>/dev/null || true
        echo "MERGE_GATE: player-facing change but Game.md not updated in the squash" >&2
        exit 2
      fi
    fi
    if git "${BOT_ID[@]}" commit --quiet -m "$commit_message" && git push --quiet origin master; then
      python3 "$WORKMD" ship "$GAME_DIR/WORK.md" "$title" >/dev/null 2>&1 || true
      python3 "$WORKMD" reconcile-epics "$GAME_DIR/WORK.md" >/dev/null 2>&1 || true
      git add WORK.md 2>/dev/null
      git "${BOT_ID[@]}" commit --quiet -m "chore(work): mark '$short_title' as shipped" 2>/dev/null
      git push --quiet origin master 2>/dev/null
      exit 0
    fi
    exit 1
  )
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    return "$rc"   # 1 = conflict/push fail, 2 = Game.md gate → skill bounces to retry
  fi
  # Cleanup: detach the worktree off the branch, delete it local + remote.
  git -C "$WORKTREE" checkout --detach origin/master --quiet 2>/dev/null || true
  git -C "$GAME_DIR" branch -d "$branch" --quiet 2>/dev/null || true
  git -C "$GAME_DIR" push --quiet origin --delete "$branch" 2>/dev/null || true
  printf '%s\n' "- Shipped: $short_title" | bash "$REPO_DIR/scripts/report.sh" continuous >/dev/null 2>&1 || true
  echo "SHIPPED: $short_title"
  return 0
}

# ── fail-one ───────────────────────────────────────────────────────────────
cmd_fail_one() {
  local branch="$1" title="$2" mode="$3"; shift 3
  [ -n "$title" ] && [ -n "$mode" ] || die "fail-one needs <branch> <title> <retry|escalate> [--detail ...]"
  # Preserve the branch on origin so a later [retry]/[resume] resumes it.
  if [ -n "$branch" ] && git -C "$GAME_DIR" rev-parse --verify "$branch" >/dev/null 2>&1; then
    git -C "$GAME_DIR" push --quiet --force-with-lease origin "$branch":"$branch" 2>/dev/null || true
  fi
  local stripped
  stripped=$(printf '%s' "$title" | sed -E 's/^\[(resume|retry|escalated|wip:[0-9]+)\][[:space:]]*//')
  acquire_lock "$MASTER_LOCK" 60 0.3 || true
  (
    trap 'release_lock "'"$MASTER_LOCK"'"' EXIT
    cd "$GAME_DIR" || exit 1
    git fetch --quiet origin master 2>/dev/null
    git checkout --quiet master 2>/dev/null || exit 1
    git reset --hard origin/master --quiet 2>/dev/null
    if [ "$mode" = "escalate" ]; then
      python3 "$WORKMD" escalate "$GAME_DIR/WORK.md" "$stripped" \
        --escalations "$GAME_DIR/.factory/escalations.md" \
        --detail "branch: $branch" "$@" >/dev/null 2>&1 || exit 1
      msg="chore(escalate): $stripped — needs CEO"
    else
      python3 "$WORKMD" retry "$GAME_DIR/WORK.md" "$stripped" \
        --detail "branch: $branch" "$@" >/dev/null 2>&1 || exit 1
      msg="chore(retry): $stripped — bounced back to queue"
    fi
    git add WORK.md 2>/dev/null
    git diff --cached --quiet && exit 0
    git "${BOT_ID[@]}" commit --quiet -m "${msg:0:72}" 2>/dev/null || exit 1
    git push --quiet origin master 2>/dev/null
  )
  rmdir "$MASTER_LOCK" 2>/dev/null || true
  echo "${mode}: $stripped"
}

# ── append-manual ──────────────────────────────────────────────────────────
# Append a CEO-facing [manual] asset-gap item to the canonical WORK.md ## Todo,
# committed + pushed under the master-push lock. The /spraxel-develop skill calls
# this for each [manual] follow-up a dev subagent REPORTS — the dev must not edit
# WORK.md itself (finish-one discards any branch WORK.md change), so this is how
# those follow-ups get persisted.
cmd_append_manual() {
  local title="$1"; shift   # remaining args: --detail "..." [--detail "..."] ...
  [ -n "$title" ] || die "append-manual needs a <title> (+ optional --detail ...)"
  acquire_lock "$MASTER_LOCK" 60 0.3 || true
  (
    trap 'release_lock "'"$MASTER_LOCK"'"' EXIT
    cd "$GAME_DIR" || exit 1
    git fetch --quiet origin master 2>/dev/null
    git checkout --quiet master 2>/dev/null || exit 1
    git reset --hard origin/master --quiet 2>/dev/null
    python3 "$WORKMD" append "$GAME_DIR/WORK.md" --section todo "$title" "$@" >/dev/null 2>&1 || exit 1
    git add WORK.md 2>/dev/null
    git diff --cached --quiet && exit 0
    git "${BOT_ID[@]}" commit --quiet -m "chore(work): asset-gap follow-up" 2>/dev/null || exit 1
    git pull --rebase --quiet origin master 2>/dev/null
    git push --quiet origin master 2>/dev/null
  )
  rmdir "$MASTER_LOCK" 2>/dev/null || true
  echo "APPENDED: $title"
}

# ── bump-cap ───────────────────────────────────────────────────────────────
# Atomically +1 `shipped_since_last_signal` in the shared continuous-state.json
# — the SAME cap counter a headless worker pumps via inc_state (continuous_dev.sh)
# — so the dashboard "Cap counter X/N" and any cap-keyed logic treat an interactive
# /spraxel-develop ship identically to a headless ship. The skill calls this after a
# successful ship, EXCEPT a [test_failure] fix when continuous.cap_excludes_test_fixes
# is true (same exclusion the headless main loop applies). Prints the new value.
cmd_bump_cap() {
  STATE_FILE="$STATE_FILE" python3 - <<'PY'
import json, os, time
from datetime import datetime
sf = os.environ['STATE_FILE']
key = 'shipped_since_last_signal'
lock = sf + '.lockdir'
deadline = time.time() + 10
while True:
    try:
        os.mkdir(lock); break
    except FileExistsError:
        if time.time() > deadline: raise SystemExit(2)
        time.sleep(0.05)
try:
    s = json.load(open(sf)) if os.path.exists(sf) else {key: 0}
    s[key] = int(s.get(key, 0)) + 1
    s['last_ts'] = datetime.now().astimezone().strftime('%Y-%m-%d %H:%M:%S %Z')
    json.dump(s, open(sf, 'w'), indent=2)
    print(s[key])
finally:
    try: os.rmdir(lock)
    except FileNotFoundError: pass
PY
}

case "${1:-}" in
  claim-one)     shift; cmd_claim_one "$@" ;;
  finish-one)    shift; cmd_finish_one "$@" ;;
  fail-one)      shift; cmd_fail_one "$@" ;;
  append-manual) shift; cmd_append_manual "$@" ;;
  bump-cap)      shift; cmd_bump_cap "$@" ;;
  *) echo "usage: interactive_dev_step.sh {claim-one | finish-one <branch> <title> | fail-one <branch> <title> retry|escalate | append-manual <title> [--detail ...] | bump-cap}" >&2; exit 2 ;;
esac
