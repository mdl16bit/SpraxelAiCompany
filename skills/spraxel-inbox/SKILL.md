---
name: spraxel-inbox
description: CEO check-in for any time of day. Computes exactly what the system is BLOCKING/waiting on the CEO for, lists the top-10 MANUAL tasks, then shows the checklist for the current time slot (morning full-triage / afternoon unblock / evening top-up). Use when the user types /spraxel-inbox or /inbox or says "check my inbox", "what needs me", "morning digest", "what do I do".
---

# Spraxel — CEO check-in

The CEO can run this **any time they sit down at the machine**. Your job is
to tell them, in priority order: (1) what is *blocking* the pipeline and
needs their decision, (2) their top-10 `MANUAL` tasks, then (3) the
checklist for the current time of day. The CEO should never have to
remember what to do — you compute it.

## Step 0 — Signal the loop + gather state

Run this first. It resets the ship-counter (so the overnight batch refills
after the CEO interacts) and prints everything you need to build the board:

```bash
bash ~/SpraxelAiCompany/scripts/checkin.sh

SC=~/SpraxelAiCompany/schedule.yaml
GAME=$(python3 -c "import re,os;m=re.search(r'game_dir:\s*(\S+)',open(os.path.expanduser('$SC')).read());print(os.path.expanduser(m.group(1)))")
WORK="$GAME/WORK.md"
NOW_H=$(date +%H); DOW=$(date +%u)   # DOW: 1=Mon … 6=Sat 7=Sun

echo "=== game: $GAME | $(date '+%a %H:%M %Z') ==="

echo ""; echo "### 🔴 BLOCKING (system is waiting on YOU) ###"
echo "-- [needs-ceo] (Developer asked a question) --"
grep -nE '^\[needs-ceo\]' "$WORK" || echo "  (none)"
echo "-- [escalated] (needs your judgment) --"
grep -nE '^\[escalated\]' "$WORK" || echo "  (none)"
[ -f "$GAME/.factory/escalations.md" ] && { echo "-- escalations.md snapshot --"; sed -n '1,40p' "$GAME/.factory/escalations.md"; }
if [ "$DOW" = "6" ]; then
  echo "-- Saturday: blog draft awaiting humanization? --"
  git -C "$GAME" ls-remote --heads origin "blog/$(date +%F)" 2>/dev/null | grep -q . \
    && echo "  YES — branch blog/$(date +%F) exists (see OPERATIONS → Saturday)" || echo "  (no blog branch yet)"
fi

echo ""; echo "### 📋 TOP-10 MANUAL TASKS (your hand-work backlog) ###"
grep -nE '^MANUAL' "$WORK" | head -10 || echo "  (none)"
echo "  (total MANUAL: $(grep -cE '^MANUAL' "$WORK"))"

echo ""; echo "### 💡 Designer ideas to decide ###"
grep -nE '^\[idea\]' "$WORK" | head -8 || echo "  (none)"

echo ""; echo "### 🐛 New bugs to triage ###"
grep -nE '^\[bug\]' "$WORK" | head -8 || echo "  (none)"

echo ""; echo "### 🚢 Overnight ships (since 22:00 yesterday) ###"
git -C "$GAME" log master --grep='^feat:' --author='continuous-bot' \
    --since='yesterday 22:00' --pretty='  %h %s' 2>/dev/null | head -12 || echo "  (none)"

echo ""; echo "### queue depth (eligible items for the next batch) ###"
python3 ~/SpraxelAiCompany/scripts/workmd.py top "$WORK" -n 12 2>/dev/null \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print('  ',len(d if isinstance(d,list) else [d]),'eligible at top')" 2>/dev/null || true

echo ""; echo "### MORNING.md (full digest) ###"
ls "$GAME/.factory/local/MORNING.md" 2>/dev/null && echo "  → cat it in the morning slot" || echo "  (not written yet — morning_briefer runs 05:00)"
```

## Step 1 — Present the board

Summarize the gathered state to the CEO in this order, concise:

1. **🔴 Blocking** — if `[needs-ceo]`, `[escalated]`, or (Sat) a blog branch
   exist, list them and tell the CEO each one needs a decision. **If
   nothing is blocking, say so explicitly: "Nothing blocking — the loop is
   running free."** This is the single most important line.
2. **📋 Top-10 MANUAL** — the CEO's hand-work backlog (art, music, design,
   story calls the bots can't do). Always show these so the CEO can pick
   one to work on.
3. Then move to the **time-of-day checklist** below.

## Step 2 — Run the checklist for the current time slot

Pick the slot from the current hour (times are configurable in
`schedule.yaml` → `ceo_routine`; default boundaries below):

### ☀️ Morning (roughly 05:00–11:00) — full triage (~30-40 min)

1. **Overnight result** — `cat "$GAME/.factory/local/MORNING.md"`; glance
   at the ship list. `git show <sha>` anything surprising.
2. **Play-test** — for each shipped feature, run its launch line from
   MORNING.md (`godot --demo-feature=<slug>`) and check the "Verify" line.
   Per feature: works → do nothing; needs polish →
   `bash ~/SpraxelAiCompany/scripts/amend.sh <slug> "feedback"`;
   wrong → `bash ~/SpraxelAiCompany/scripts/reject.sh <slug> "why"`.
3. **Decide ideas** — for each `[idea]`: accept = `python3 $WORKMD promote $WORK "<substr>"`;
   reject = `python3 $WORKMD drop $WORK "<substr>"`; defer = leave it.
4. **Triage bugs** — `python3 $WORKMD bump $WORK "<substr>" p0` to raise;
   `drop` duplicates; leave the rest.
5. **Clear blocks** — for each `[needs-ceo]`/`[escalated]`: edit the item's
   detail lines in WORK.md with your answer, then
   `python3 $WORKMD resume $WORK "<substr>"` (or `promote` for `[needs-ceo]`).
6. **Dictate** fixes from play-testing into `.factory/inbox/raw.md`, then
   run `/spraxel-producer`.
7. Commit: `git -C "$GAME" commit -am "ceo: morning triage $(date +%F)" && git -C "$GAME" push`.

### 🌤️ Afternoon (roughly 11:00–18:00) — quick unblock (~5 min)

Only goal: make sure nothing is blocking the loop. If Step-1 said "nothing
blocking", **you're done** — optionally dump ideas to
`.factory/inbox/raw.md`. If there were blocks, clear them as in Morning
step 5.

### 🌙 Evening (roughly 18:00–05:00) — top up (~5 min)

1. Drain dictation: `/spraxel-producer`.
2. Confirm fuel for overnight:
   `python3 $WORKMD top "$WORK" -n 12`. If fewer than ~10 eligible (top is
   mostly `MANUAL`/`[idea]`), add items via dictation or `promote` some
   `[idea]`s.

## The action verbs (all match a title substring, case-insensitive)

| Verb | Command | Use |
|---|---|---|
| promote | `python3 $WORKMD promote $WORK "<substr>"` | accept `[idea]`, resurrect `[cold]`, drop a leading tag |
| drop | `python3 $WORKMD drop $WORK "<substr>"` | reject idea / delete duplicate bug |
| bump | `python3 $WORKMD bump $WORK "<substr>" p0` | change priority |
| resume | `python3 $WORKMD resume $WORK "<substr>"` | un-block an `[escalated]` item after editing its details |
| amend | `bash ~/SpraxelAiCompany/scripts/amend.sh <slug> "feedback"` | keep a shipped feature but refine it |
| reject | `bash ~/SpraxelAiCompany/scripts/reject.sh <slug> "why"` | revert a shipped feature + re-queue |

Define once at the top of your session:
`WORKMD=~/SpraxelAiCompany/scripts/workmd.py` and `WORK="$GAME/WORK.md"`.

## Hard rules

- **Never delete an item from WORK.md** unless it's truly finished/shipped.
  Reject/defer via tags, not deletion. (CEO *may* hand-edit, but it's never
  automated.)
- **Don't hand-edit `.factory/escalations.md`** — it's regenerated each
  tick from WORK.md `[escalated]` items. Put guidance in the WORK.md item's
  detail lines, then `resume`.
- **Don't manually move items between WORK.md sections** — the loop +
  Janitor handle that.

## Time box

Morning ≤ 45 min, afternoon/evening ≤ 5 min. Half-done is fine — the loop
runs every night; the rest surfaces in tomorrow's digest.
