#!/usr/bin/env bash
# ship_lib.sh — shared per-item ship-pipeline helpers for BOTH dev modes:
#   continuous_dev.sh       (headless workers)
#   interactive_dev_step.sh (/spraxel-develop skill)
#
# Behavior-critical invariants that MUST stay identical across the two modes
# live here, once. Source AFTER the caller has set: REPO_DIR, WORKMD, SLUGIFY,
# STATE_FILE (for ship_bump_counter). Callers keep mode-specific concerns
# (bot identity, worktree model, exit-code conventions, log destinations).

# ── Branch naming ──────────────────────────────────────────────────────────
# Deterministic feature-branch name — a pure function of the item title, NOT
# the clock or the worker id. A [retry] resumes the prior attempt's branch
# ONLY because every mode recomputes the exact same name (the old
# per-attempt timestamp scheme produced an 18-branch pileup for one item).
# NEVER fork this logic per mode.
ship_branch_for() {   # <title>  →  feat/cont-<slug>-<hash6>
  local title="$1" slug core hash
  slug=$(printf '%s' "$title" | python3 "$SLUGIFY")
  core=$(printf '%s' "$title" | sed -E 's/^[[:space:]]*(\[[a-z-]+\][[:space:]]*)+//I')
  hash=$(printf '%s' "$core" | shasum 2>/dev/null | cut -c1-6)
  printf 'feat/cont-%s-%s' "$slug" "$hash"
}

# ── Cap / state counter ────────────────────────────────────────────────────
# Atomic read-modify-write +1 on a key in $STATE_FILE (lockdir-guarded so
# parallel workers and the interactive skill never lose increments). Prints
# the NEW value. Default key is the shared ship-cap counter, so headless and
# interactive ships bump the SAME number.
ship_bump_counter() {   # [key]
  STATE_FILE="$STATE_FILE" KEY="${1:-shipped_since_last_signal}" python3 - <<'PY'
import json, os, time
from datetime import datetime
sf = os.environ['STATE_FILE']
key = os.environ['KEY']
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

# ── Game.md survival gate ──────────────────────────────────────────────────
# Run with cwd = game_dir and the squash STAGED. Returns 0 = pass, 1 = a
# player-facing change is landing without its Game.md/docs-features update
# surviving the squash (lost to conflict resolution or a resume/retry rebuild
# — the 2026-05-29 CeilingDropTrap doc-less ship). CHECK ONLY: the caller
# does its own reset/clean, logging, and exit-code convention (continuous
# exits 1 → retry; interactive exits 2 → skill bounces to retry).
ship_gamemd_gate() {   # <title> <branch>
  local title="$1" branch="$2" _need_gm=0
  git diff --cached --quiet -- Game.md 2>/dev/null || return 0   # update present
  echo "$title" | grep -qiE '\[game-feature\]' && _need_gm=1
  git diff --quiet "origin/master...$branch" -- Game.md 2>/dev/null || _need_gm=1
  git diff --cached -- scripts/systems/debug_boot.gd 2>/dev/null \
    | grep -qE '^\+[[:space:]]*func _demo_|--demo-feature=' && _need_gm=1
  [ "$_need_gm" -eq 0 ]
}

# ── Strike the shipped item from Todo (with [wip] fallback) ────────────────
# `workmd ship` is a case-insensitive SUBSTRING match on title, so an
# abbreviated/paraphrased title can silently match nothing — leaving the item
# [wip:N] in Todo to be re-claimed forever. Try the given title; on a miss,
# fall back to THIS worker's actual [wip:<id>] claim (excluding
# escalated/needs-ceo/cold); if even that fails, warn LOUDLY on stderr.
# Returns 0 if something was struck, 1 if nothing was.
ship_strike_shipped() {   # <work_md_path> <title> <worker_id>
  local work="$1" title="$2" wid="$3" claimed
  if python3 "$WORKMD" ship "$work" "$title" >/dev/null 2>&1; then
    return 0
  fi
  claimed=$(python3 - "$work" "$wid" "$WORKMD" <<'PY'
import sys, json, subprocess
path, wid, workmd = sys.argv[1], sys.argv[2], sys.argv[3]
wm = json.loads(subprocess.check_output([sys.executable, workmd, "parse", path]))
for it in wm.get("todo", []):
    t = it.get("title", "")
    low = t.lower()
    if f"[wip:{wid}]" in low and not any(x in low for x in ("[escalated]", "[needs-ceo]", "[cold]")):
        print(t); break
PY
)
  if [ -n "$claimed" ] && python3 "$WORKMD" ship "$work" "$claimed" >/dev/null 2>&1; then
    echo "ship_lib: shipped via [wip:$wid] fallback (passed title did not match)" >&2
    return 0
  fi
  echo "ship_lib: WARNING — could not strike shipped item from Todo (title='$title'); WORK.md may re-claim it" >&2
  return 1
}

# ── Per-ship report line ───────────────────────────────────────────────────
# One line per shipped item → MORNING.md 📰 News (Developer+Reviewer don't
# self-report; the loop driver reports for them). Identical for both modes.
ship_report() {   # <short_title>
  printf '%s\n' "- Shipped: $1" \
    | bash "$REPO_DIR/scripts/report.sh" continuous >/dev/null 2>&1 || true
}
