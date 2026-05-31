---
name: spraxel-inbox
description: CEO check-in for any time of day — gives the SAME full digest as a fresh MORNING.md plus what's blocking right now, and saves a dated STATUS_REPORT. Computes what the system is BLOCKING/waiting on the CEO for, regenerates the full morning-style briefing (overnight ships, play-test, decide, bugs, shape, escalations, reviewer rejections, demos), and shows the action checklist for the current time slot. Use when the user types /spraxel-inbox or /inbox or says "check my inbox", "what needs me", "morning digest", "status report", "what do I do".
---

# Spraxel — CEO check-in (= a fresh MORNING.md, any time)

The CEO can run this **any time they sit down at the machine**. Two jobs:
1. The fast answer: **what is blocking** the pipeline and needs their decision.
2. The full picture: **the same digest the 05:00 morning-briefer produces** —
   regenerated on demand so it's never stale — saved as a dated `STATUS_REPORT`.

The CEO should never have to remember what to do — you compute it.

## Step 0 — Signal the loop + gather the blocking board

Run this first. It resets the ship-counter (so the overnight batch refills after
the CEO interacts) and prints the fast "what needs you" board:

```bash
bash ~/SpraxelAiCompany/scripts/checkin.sh

SC=~/SpraxelAiCompany/schedule.yaml
GAME=$(python3 -c "import re,os;m=re.search(r'game_dir:\s*(\S+)',open(os.path.expanduser('$SC')).read());print(os.path.expanduser(m.group(1)))")
WORK="$GAME/WORK.md"
NOW_H=$(date +%H); DOW=$(date +%u)   # DOW: 1=Mon … 6=Sat 7=Sun

echo "=== game: $GAME | $(date '+%a %H:%M %Z') ==="

echo ""; echo "### 🔴 BLOCKING (system is waiting on YOU) ###"
echo "-- [needs-ceo] (candidate bug to validate, or Developer question) --"
grep -nE '^\[needs-ceo\]' "$WORK" || echo "  (none)"
echo "-- [escalated] (needs your judgment) --"
grep -nE '^\[escalated\]' "$WORK" || echo "  (none)"
[ -f "$GAME/.factory/escalations.md" ] && { echo "-- escalations.md snapshot --"; sed -n '1,40p' "$GAME/.factory/escalations.md"; }
echo "-- triage questionnaires awaiting your answers (Architect) --"
TRIAGE="$GAME/.factory/local/TRIAGE.md"
if [ -f "$TRIAGE" ]; then
  awk '/^##[[:space:]].*Awaiting/{f=1;next} /^##[[:space:]]/{f=0} f&&/^### /{print "  "$0}' "$TRIAGE" \
    | grep . || echo "  (none awaiting)"
  echo "  → fill the [Answer] lines in: $TRIAGE  (just save the file — that's the whole hand-back)"
else
  echo "  (none yet — Architect writes these as untriaged work arrives)"
fi
if [ "$DOW" = "6" ]; then
  echo "-- Saturday: blog draft awaiting humanization? --"
  git -C "$GAME" ls-remote --heads origin "blog/$(date +%F)" 2>/dev/null | grep -q . \
    && echo "  YES — branch blog/$(date +%F) exists (see OPERATIONS → Saturday)" || echo "  (no blog branch yet)"
fi

echo ""; echo "### 📋 TOP-10 MANUAL TASKS (your hand-work backlog) ###"
grep -nE '^\[manual\]|^MANUAL' "$WORK" | head -10 || echo "  (none)"
echo "  (total MANUAL: $(grep -cE '^\[manual\]|^MANUAL' "$WORK"))"
```

## Step 1 — Present the blocking board (the most important line)

Summarize Step 0 to the CEO, concise:
1. **🔴 Blocking** — list any `[needs-ceo]`, `[escalated]`, awaiting triage
   questionnaires, or (Sat) a blog branch, and say each needs a decision.
   **If nothing is blocking, say so explicitly: "Nothing blocking — the loop is
   running free."** That one line is the whole point of the fast board.
2. **📋 Top-10 MANUAL** — the CEO's hand-work backlog (art, music, design, story
   the bots can't do). Show these so they can pick one.

## Step 2 — Regenerate the full digest (= a brand-new MORNING.md) + save it dated

This is what makes the inbox equal to a fresh morning briefing. Reuse the briefer
(single source of truth — no drift), but skip the work if a fresh one already
exists:

```bash
M="$GAME/.factory/local/MORNING.md"
# "Fresh" = written today AND has real content (a markdown header). The CEO often
# CLEARS MORNING.md after working it (leaves a blank line), so `-s` alone isn't
# enough — `grep -q '^#'` rejects a cleared/blank file so we regenerate it.
if [ "$(date -r "$M" +%F 2>/dev/null)" = "$(date +%F)" ] && grep -q '^#' "$M" 2>/dev/null; then
  echo "MORNING.md is fresh ($(date -r "$M" '+%H:%M')) — using it."
else
  echo "MORNING.md missing/stale/cleared — regenerating via the briefer…"
  bash ~/SpraxelAiCompany/scripts/run_agent.sh morning-briefer
fi
# Save a dated snapshot (lands in reports/, which the Janitor auto-prunes >14d).
mkdir -p "$GAME/.factory/local/reports"
SR="$GAME/.factory/local/reports/STATUS_REPORT-$(date +%F).md"
cp "$M" "$SR" 2>/dev/null && echo "saved status report → $SR"
sed -n '1,200p' "$M"
```

Then **present every section of MORNING.md to the CEO** — overnight result,
play-test list (with the launch / ✓Done / ✏️Amend / ❌Reject one-liners), decide,
bugs, shape, escalations, reviewer rejections, demos. This is the "basically the
same as a fresh MORNING.md" deliverable. Tell them the dated copy lives at
`STATUS_REPORT-<date>.md`.

> The morning-briefer is a *daily* agent, so it regenerates fine on demand any
> day. If `run_agent.sh` fails or returns "not scheduled", fall back to the
> blocking board from Step 1 — that still covers everything urgent.

## Step 3 — Action depth for the current time slot

The digest is the same all day; how much you ACT on it depends on the slot
(boundaries are configurable in `schedule.yaml` → `ceo_routine`):

### ☀️ Morning (~05:00–11:00) — full triage (~30–40 min)
Work the whole digest: play-test the ships, decide ideas, triage candidate bugs,
answer triage questionnaires, clear blocks. Use the verbs below.

### 🌤️ Afternoon (~11:00–18:00) — quick unblock (~5 min)
Only goal: nothing is blocking the loop. If Step 1 said "nothing blocking",
**you're done** (optionally dump ideas to `.factory/inbox/dictation/`). Otherwise
clear the blocks with the verbs below.

### 🌙 Evening (~18:00–05:00) — top up (~5 min)
1. Drain dictation: `/spraxel-producer`.
2. Confirm overnight fuel: `python3 ~/SpraxelAiCompany/scripts/workmd.py top "$WORK" -n 12`.
   If fewer than ~10 eligible, accept some `[idea]`s or add items via dictation.

## The action verbs — ALL mutate WORK.md, so ALL go through `with_master_lock.sh`

A bare `workmd.py <verb>` edits WORK.md without committing, and the next worker's
`reset --hard origin/master` silently eats it. The wrapper locks + syncs +
commits + pushes atomically (see docs/WORKER_OPERATIONS.md §4). Define once:
`WML=~/SpraxelAiCompany/scripts/with_master_lock.sh`.

| Verb | Command | Use |
|---|---|---|
| **approve** | `bash $WML approve "<substr>"` | validate a `[needs-ceo]` candidate bug / answered question → live, dev-claimable |
| **approve all** | `bash $WML approve all` | validate EVERY `[needs-ceo] [bug]` candidate at once (Developer questions left untouched) |
| **promote** | `bash $WML promote "<substr>" [--detail … / --retitle …]` | accept an `[idea]` (→ shaping) / resurrect `[cold]`, optionally with edits |
| **promote all** | `bash $WML promote all` | accept EVERY `[idea]` at once → all into shaping ([cold]/[future] untouched) |
| **drop** | `bash $WML drop "<substr>"` | reject an idea / delete a duplicate or false-positive bug |
| **bump** | `bash $WML bump "<substr>" p0` | change priority |
| **resume** | `bash $WML resume "<substr>"` | un-block an `[escalated]` item AFTER editing its detail lines with guidance |
| **amend** | `bash ~/SpraxelAiCompany/scripts/amend.sh <slug> "feedback"` | keep a shipped feature but queue a refinement |
| **reject** | `bash ~/SpraxelAiCompany/scripts/reject.sh <slug> "why"` | revert a shipped feature + re-queue |

Note: clearing a `[needs-ceo]` tag is **`approve`**, NOT `promote` (`promote` only
handles `[idea]`/`[cold]`). `amend`/`reject` already hold the lock internally.

## Hard rules

- **Never hand-edit the canonical WORK.md and walk away** — use the verbs above
  (they commit + push under the lock). An uncommitted edit gets wiped by a worker.
- **Never delete an item** unless it's truly finished/shipped — reject/defer via
  tags (`drop` is for false positives / dupes / rejected ideas).
- **Don't hand-edit `.factory/escalations.md`** — it's regenerated each tick from
  WORK.md `[escalated]` items. Put guidance in the item's detail lines, then `resume`.
- **Don't manually move items between WORK.md sections** — the loop + Janitor do that.

## Time box

Morning ≤ 45 min, afternoon/evening ≤ 5 min. Half-done is fine — the loop runs
every night; the rest surfaces in tomorrow's digest (and the next `/spraxel-inbox`).
