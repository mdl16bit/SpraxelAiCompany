# Operations — CEO handbook

How to drive the offline Spraxel factory day-to-day.

---

## Mental model

You are the **CEO**. You don't write code, run CI, or push feature commits.
You **dictate**, **play-test**, **promote ideas**, **escalate decisions**.
A roster of Claude agents handles the rest, running locally on your Mac.

State lives in **`WORK.md`** at the game repo root — the single source of
truth for everything in flight. Everything else is derivable from WORK.md +
git log.

There are no GitHub Issues. There are no GitHub Actions. There are no
Anthropic `/schedule` routines. There is one local daemon (`launchd`),
one schedule file (`schedule.yaml`), and one CLI you run from your Mac
(`claude -p`). Total recurring cost: $0 above your existing Claude Max plan.

---

## The system in one picture

```
+-----------------------------------------------------------+
|  launchd  (com.spraxel.tick.plist, every 60s)             |
|         |                                                 |
|         v                                                 |
|  scripts/tick.sh                                          |
|  reads schedule.yaml; ensures continuous_dev.sh is alive  |
+-------+------------------------+--------------------------+
        |                        |
        v                        v
run_agent.sh             continuous_dev.sh
(crew: PM, Triager,      (long-running Developer loop;
 Designer, Janitor,       ships items until counter hits
 Blogger, Asset,          target_per_batch; sleeps until
 Morning Briefer)         CEO interacts; resumes)
        |                        |
        +---- claude -p ---------+
                  |
                  v
            Max plan (flat fee, no per-token cost)
                  |
                  v
        WORK.md / Game.md / Philosophy.md / commits
                  |
                  v
        git push origin master   <-- only network egress
```

---

## A day in the system

**Continuous loop** (always on, paced by CEO interaction — no clock time):

| Who | What |
|-----|------|
| **continuous_dev.sh** | Long-running Developer loop. **Runs as N parallel workers** (one process per worker id; default `dev_concurrency: 3` — see `schedule.yaml`). Each worker has its own persistent worktree at `.worktrees/worker-<id>/` and atomically claims items via `workmd.py claim --worker-id N` (tags the item `[wip:N]` so other workers skip it). Picks top eligible `## Todo` item (skips `[idea]`/`[cold]`/`[manual]`/`[future]`/`[escalated]`/`[needs-ceo]`/`[concern]`/`[wip:*]`/`[untriaged]`/`[untriaged-proposal-active]`; picks up `[resume]` and `[retry]`). Branch → Developer → tests → Reviewer → squash-merge → push. **Cap counter is SHARED**: 10 ships across all workers combined drains the batch. Merges serialize via `master-push.lockdir` (~1 s critical section in `game_dir`). Failed items (tests/reviewer/merge): branch preserved on origin, item retagged **`[retry]`** in place with failure feedback in details — next dev fire picks them up silently. Does NOT escalate to CEO for dev-fixable failures. Runs `workmd.py sync-escalations` at start of every iter so `.factory/escalations.md` always reflects current `[escalated]` items. |

Daily crew (all times America/Los_Angeles):

| Time | Who | What |
|------|-----|------|
| 03:00 PT | **playtester** | Actively plays the game (beyond scripted tests). Writes bug candidates to `.factory/inbox/playtest-findings.md`. Does NOT touch WORK.md directly. |
| 04:00 PT | **triager** | Reads playtest findings + local-tests-status.json, appends `[needs-ceo] [bug]` items to `## Todo`. CEO validates before they become live bugs. |
| 05:00 PT | **morning-briefer** | Writes `.factory/local/MORNING.md` (gitignored — CEO-local artifact). 10 features to play-test with launch + amend + reject one-liners, decisions to make, escalations, time-boxed routine. |
| 05:30 PT | **demo-creator** | Always writes `.factory/demos/<date>/recipe.md` (launch + controls + suggested capture command per recently-shipped feature). Best-effort auto-capture via Godot `--write-movie` + ffmpeg → `.mp4` + `.png`. |
| 06:00 PT | **pm** | Re-sorts top of `## Todo`. Biweekly Monday: tags `v0.N`, generates release notes, rolls WORK.md sections. |
| ~06:00 PT | **CEO (you)** | `/spraxel-inbox` → walk MORNING.md sections. ~38 minutes. |
| 09:00 & 21:00 PT | **architect** | Shapes `[untriaged]` work: processes your answered `TRIAGE.md` questionnaires (finalize spec or follow-up), intakes new untriaged items (fast-pass or new questionnaire). Also fires reactively within ~60s of a new `[untriaged]` item. |

Weekly:

| Time | Who | What |
|------|-----|------|
| Tue + Fri 04:30 PT | **designer** | Drops 4-6 `[idea]`-tagged items + 0-3 `[concern]` items into `## Todo`. Concerns flag game-wide issues (feature bloat, philosophical drift). |
| Sat 09:00 PT | **blogger** | Drafts `blog/content/posts/draft-<YYYY-MM-DD>-<slug>.md` from the week's `feat:` commits (player-facing filter — skips test/infra/process). Pushes `blog/<date>` branch; CEO humanizes + merges. |
| Sun 01:00 PT | **janitor** | Cold-archives 30+ day stale items, prunes merged `feat/*` branches + 60+ day logs, sweeps orphan `feat/cont-*` branches whose WORK.md item is gone. |
| 1st 07:00 PT | **asset-librarian** | Scans `assets/`, reports orphans + license gaps. |

Every 30 minutes (separately scheduled — `com.spraxel.localtests.plist`):

- **local-tests** — runs Godot GUT + every `scripts/scenarios/*.gd` headlessly. Writes `.factory/local-tests-status.json`. The Triager reads this nightly.

---

## CEO daily routine (the part that matters)

**The one thing to remember: any time you sit down at the machine, run
`/spraxel-inbox`.** It tells you exactly what the system is waiting on you
for — blocking items first, then your top-10 `MANUAL` tasks, then the
checklist for the current time of day. You never have to remember what to
do; the skill computes it.

You visit the machine up to **three times a day**. The times are *guidance*
(the system never blocks on a clock) and are **configurable** in
`schedule.yaml` → `ceo_routine` — edit them to match your life:

| Visit | Default time | One-line purpose | Typical length |
|-------|--------------|------------------|----------------|
| **Morning** | ~06:15 | Full triage: play-test overnight ships, decide ideas, triage bugs, clear escalations | ~30-40 min |
| **Afternoon** *(optional)* | ~13:00 | Quick unblock: clear `[needs-ceo]`/`[escalated]` so the loop never stalls; dump ideas | ~5 min |
| **Evening** | ~22:00 | Top up: drain dictation, ensure WORK.md has 10+ eligible items for overnight | ~5 min |

Each visit below is a literal checklist — exact files to open, exact
commands to run. Substitute `<game>` with the repo in
`schedule.yaml` → `game_dir` (currently `infiltrators`).

---

# ☀️ MORNING (~06:15, full triage)

### 05:00 AM — System has prepared your day (you're asleep)
By the time you wake, the overnight crew has run: `playtester` (03:00) →
`triager` (04:00) → `morning_briefer` (05:00, writes MORNING.md) →
`demo_creator` (05:30) → `pm` (06:00, reorders Todo). Tue/Fri also get
`designer` (04:30). You wake to a prepared digest.

### 06:00 — 06:38 AM — Morning routine (~38 min — CEO wakes ~06:15)

**Time-boxed**. If you blow past 45 min, stop and commit what you have.

```bash
cd ~/GameProjects/<game>
cat MORNING.md
```

In Claude Code, type `/inbox` to open the walk-through skill (read-only view of MORNING.md).

Walk the sections **in order** — here's what each step actually means in commands:

```bash
WORK=~/GameProjects/<game>/WORK.md
WORKMD=~/SpraxelAiCompany/scripts/workmd.py
```

#### 1. ▶ Overnight result (1 min)

Glance at the commit range in MORNING.md. Any surprises? Drill in:

```bash
cd ~/GameProjects/<game>
git log master --since="yesterday 22:00 PT" --oneline
git show <sha>           # if anything looks weird
```

#### 2. ▶ Play-test (20 min)

For each of the 10 features in MORNING.md, run the listed launch command:

```bash
cd ~/GameProjects/<game>
godot --demo-feature=<slug>
```

Each MORNING.md feature block looks like this:

```
1. [cutscene-engine] Full JSON-driven cinematics  — `6d2d92c`
   Controls: Esc (skip), Space (advance)
   Verify:   Title card fades in, typewriter on subtitles
             Actor portraits appear on left
   Launch:   godot --demo-feature=cutscene-engine
   ❌ Reject: bash ~/SpraxelAiCompany/scripts/reject.sh cutscene-engine "<reason>"
```

Spend 1–2 min per feature verifying the "Verify" lines. Three outcomes per feature:

##### ✓ Accept — it works
Nothing is required — the feature stays on master and rotates off the
play-test list at tomorrow's 05:00 briefer run. But if you want it to clear
**now** (so the dashboard + `/spraxel-inbox` stop nagging you about it as you
work down the list), mark it tested:

```bash
bash ~/SpraxelAiCompany/scripts/playtested.sh cutscene-engine   # by slug or any title substring
bash ~/SpraxelAiCompany/scripts/playtested.sh all               # mark the whole list done at once
```

This only touches your CEO-local tracker (`.factory/local/playtested.json`,
gitignored, auto-resets each day) — it does **not** change the game or
WORK.md. See "Clearing the play-test list" below.

##### ✏️ Amend — keep it, but with feedback
The feature is fundamentally right but needs tweaks (timing, polish, edge cases).
The Developer will iterate on top of the existing code overnight.

```bash
bash ~/SpraxelAiCompany/scripts/amend.sh cutscene-engine \
  "title fade is too slow — 0.3s feels better than 1.0s; also Esc should immediately end the cutscene, not wait for the current line to finish"
```

What it does:
- Appends `[amend] Refine: <title>` to WORK.md `## Todo`
- Includes the original sha as a pointer ("read this, then modify in place")
- Includes your feedback verbatim as scope
- Commits + pushes WORK.md
- The feature **stays shipped on master** — nothing reverts

The Developer picks it up next overnight automatically (no `[needs-ceo]` tag — your
feedback IS the spec), reads the existing code at the referenced sha, and refines it.

##### ❌ Reject — get rid of it
The feature is wrong enough that re-implementing from scratch is cheaper than fixing.

```bash
bash ~/SpraxelAiCompany/scripts/reject.sh cutscene-engine \
  "subtitles cut off the bottom; whole rendering approach is wrong"
```

What it does:
- `git revert` the `feat:` + paired `work: shipped` commits on master
- `git push` — feature is gone from master
- Appends `[reject] Re-implement: <title>` to WORK.md `## Todo`
- Includes your reason as detail so Developer knows what to do differently
- Commits + pushes

Developer picks it up automatically next overnight. If revert hits conflicts
(later commits touched the same files), reject.sh bails with
`git revert --continue` + push instructions printed — you resolve manually
and re-run.

##### Quick decision matrix

| Feature state | Use |
|---|---|
| Works well | (do nothing) |
| Works but needs polish / tuning | `amend.sh <slug> "feedback"` |
| Right idea, partially broken | `amend.sh <slug> "what to fix"` |
| Wrong approach entirely | `reject.sh <slug> "why"` |
| Bug from a NON-shipped state | regular `[bug]` item via dictation |
| Verified good, want it off the list now | `playtested.sh <slug>` (or `all`) |

##### Clearing the play-test list

The dashboard and `/spraxel-inbox` show the *unverified* features as pending
CEO action items. They're pulled from today's MORNING.md ▶ Play-test section.
As you confirm each one works, mark it tested so it drops off:

```bash
bash ~/SpraxelAiCompany/scripts/playtested.sh <substr>   # mark feature(s) matching title/slug
bash ~/SpraxelAiCompany/scripts/playtested.sh all        # mark every one tested
bash ~/SpraxelAiCompany/scripts/playtested.sh --list     # see tested ✓ vs pending ·
bash ~/SpraxelAiCompany/scripts/playtested.sh --reset    # undo today's marks, start over
```

- The tracker is `<game>/.factory/local/playtested.json` — **CEO-local,
  gitignored, keyed by today's date.** It auto-resets each day: yesterday's
  checkmarks never carry over, so each fresh overnight batch shows up clean.
- Marking is purely cosmetic (clears your action list). It does **not** touch
  the game, master, or WORK.md. `amend`/`reject` are the only verbs that
  change anything. Marking a feature tested is the explicit "✓ Accept" action.
- `amend` and `reject` do **not** auto-mark — if you amend a feature you're
  still "acting" on it, so it stays on the list until you've re-verified the
  refinement (or just `--reset` and re-run the list tomorrow).

#### 3. ▶ Decide — Designer ideas (5 min)

Designer drops appear in WORK.md `## Todo` with `[idea]` tag. Three actions:

```bash
# ACCEPT an idea  → converts [idea] to [untriaged] (sends it INTO shaping,
#                   NOT straight to the build queue — the Architect will
#                   fast-pass it or ask you a questionnaire; see step 3b)
python3 $WORKMD promote $WORK "sleeping-gas grenade"

# REJECT an idea  (delete the line entirely)
python3 $WORKMD drop $WORK "radio-tower mission"

# DEFER  (do nothing — [idea] tag stays, overnight keeps skipping)
```

Accepting an idea no longer drops it straight into the overnight queue — it
enters the **shaping pipeline** (becomes `[untriaged]`). The Architect then
either fast-passes it (if already concrete) or writes you a questionnaire in
`TRIAGE.md`. You finish defining it in step 3b. Reject and defer are unchanged.

The PM reorder summary in MORNING.md is informational — no action required. To see what PM changed:

The PM reorder summary in MORNING.md is informational — no action required. To see what PM changed:

```bash
git log -1 --author='pm-bot' -p WORK.md
```

#### 3b. ▶ Shape — answer triage questionnaires (5 min)

New feature work (from the Producer, an accepted Designer idea, or your own
hand-adds) is born `[untriaged]` and is held out of the build queue until it's
shaped into a concrete spec. The **Architect** agent does the shaping. See the
full reference below ("The shaping loop"); the short version of YOUR job:

```bash
$EDITOR ~/GameProjects/<game>/.factory/local/TRIAGE.md   # one file, all questionnaires
```

Under `## ⏳ Awaiting your answers`, type your choice after each question's
`[Answer]` line (pick a letter or write your own). **Save freely while you work —
it's ignored until you submit.** When done for now, type any word after the
**`[Indicate complete]`** line at the bottom and save — within ~60s the Architect
processes every fully-answered task (finalize / decompose into an epic / ask a
follow-up) and leaves partial ones for later. You don't run anything.

#### 4. ▶ Bug triage (5 min)

Triager appended new `[bug]` items overnight. Actions:

```bash
# BUMP priority   (urgent → p0, or low → p2)
python3 $WORKMD bump $WORK "stairs teleport" p0

# DELETE a duplicate
python3 $WORKMD drop $WORK "duplicate-bug-title-substring"

# KEEP — just leave the line alone; overnight picks it up by priority order.
```

#### 5. ▶ Escalations (1-3 min, usually 0)

**Important distinction (post 2026-05-27 redesign):** the wrapper has two
different "the item didn't land" outcomes, and only ONE of them lands in
your morning routine:

| Outcome | Tag | Who triages | In escalations.md? |
|---------|-----|-------------|---------------------|
| Tests / reviewer / merge failed | `[retry]` | Nobody — silent retry on next dev fire | NO |
| Real CEO-judgment issue (design/PM gameplay-ruiner, paid-asset block, story decision, dev's `clarify` for true ambiguity) | `[escalated]` (manual) or `[needs-ceo]` (via clarify) | **You** | `[escalated]` yes; `[needs-ceo]` no |

**Most mornings this section is empty.** When it isn't, the items are
ones that need your judgment — not your patience.

##### `.factory/escalations.md` is **derived state**

The wrapper regenerates the file from `[escalated]` items in WORK.md on
every iter via `workmd.py sync-escalations`. Properties:

- If a `[escalated]` item exists in WORK.md, the next tick rewrites
  escalations.md to include it. Clearing the file alone does nothing.
- The only way to make an item vanish from escalations.md is to
  retag it in WORK.md: `[escalated]` → `[resume]`.
- The file is a snapshot, not history. No append-only log to filter.
- Item detail lines ARE the source of truth — anything you want
  preserved must live in the WORK.md item.

##### For each `[escalated]` item

```bash
# What's escalated right now (single source of truth):
grep '^\[escalated\]' ~/GameProjects/<game>/WORK.md

# Same thing in nicer formatting:
cat ~/GameProjects/<game>/.factory/escalations.md
```

Two acceptable actions:

**(a) Resume it** — edit the item's detail lines in WORK.md with your
decision/clarification, then flip `[escalated]` → `[resume]`. Wrapper
picks it up next dev fire, checks out the saved branch (from the
`branch:` detail line), rebases on master, hands off to the dev with
your guidance + the prior attempt's context.

```bash
# Either edit WORK.md directly, then change the tag; OR use the CLI:
python3 ~/SpraxelAiCompany/scripts/workmd.py resume $WORK "<title-substring>"
```

**(b) Acknowledge but defer** — read it, do nothing. The item stays
`[escalated]` and reappears in escalations.md every tick until you
decide. Useful when "I'll deal with this Wednesday" is the right call.

##### What you do NOT do

- **Never delete an item from WORK.md** — that's a HARD RULE.
  Items only leave via `ship` (Todo → Shipped header, preserved) or
  janitor's `[cold]` retag (still in Todo, tagged stale). If you
  truly want an item gone forever, you can hand-edit WORK.md, but
  that's a manual CEO action, never automated.
- **Don't hand-edit `.factory/escalations.md`** — it's regenerated
  each tick from WORK.md state. Anything you write there gets
  overwritten. Write into the WORK.md item's detail lines instead.
- **Don't `[retry]` items show up here** — they're handled silently
  by the next dev run. If you see `[retry]` items piling up (5+), it
  may signal a fragile test or reviewer pattern worth investigating,
  but no action is required.

#### 6. ▶ Dictation (5 min, optional)

Anything new from play-testing or stray thoughts:

```bash
echo "the run sound should be QUIETER for ducked-walking" \
  >> ~/GameProjects/<game>/.factory/inbox/raw.md
echo "extraction zone bug back — character #3 stuck after extracting" \
  >> ~/GameProjects/<game>/.factory/inbox/raw.md
```

Then in Claude Code, run the producer skill to convert them:

```
/spraxel-producer
```

It reads `.factory/inbox/raw.md` (and any dictation files), classifies each note (`[bug]` / `[feature]` / `[game-feature]`), assigns priority, appends to WORK.md `## Todo`, commits.

#### 7. Commit your morning edits

Your Decide/Triage/Escalations edits aren't pushed yet. Either commit yourself, or let the next agent run sweep them up naturally (PM/Janitor pick up changes on their next commit):

```bash
cd ~/GameProjects/<game>
git diff WORK.md                    # sanity check
git commit -am "ceo: morning triage $(date +%Y-%m-%d)"
git push
```

#### The four CLI verbs you'll actually use

| Verb | What it does |
|------|--------------|
| `promote <substr>` | Remove `[idea]` / `[cold]` tag → accept idea / resurrect cold item. |
| `drop <substr>` | Delete an item entirely from any section. |
| `bump <substr> pN` | Change priority (p0..p3). |
| `append --section todo …` | Add a new item. (Producer skill does this for you.) |

All four match on title substring (case-insensitive, first match wins). Be specific enough to uniquely match.

During the day the system is quiet (just `local-tests` every 30 min on
master, silent unless something breaks). Live your life — work on art,
music, design, level layout; manually edit WORK.md (CEO can do anything);
drop ideas into `.factory/inbox/raw.md` whenever they hit you.

---

# 🌤️ AFTERNOON (~13:00, optional ~5-min unblock)

**Purpose: make sure the loop isn't stalled waiting on you.** The only
thing that *blocks* the overnight pipeline is an item that needs your
judgment. Run the inbox; if it says "nothing blocking", you're done.

```bash
# In Claude Code — shows blocks + top-10 MANUAL, nothing else if all clear:
/spraxel-inbox
```

If it lists blocking items, clear them (full how-to in the Morning
"Escalations" step above):

```bash
WORK=~/GameProjects/<game>/WORK.md
WORKMD=~/SpraxelAiCompany/scripts/workmd.py

# [needs-ceo] — Developer asked a question. Edit the item's detail lines
#   with your answer, then drop the tag so it re-enters rotation:
python3 $WORKMD promote $WORK "<title-substring>"      # removes a leading tag

# [escalated] — your call. Resume after editing details with guidance:
python3 $WORKMD resume $WORK "<title-substring>"
```

Dump any new ideas while you're here (no need to process now):

```bash
echo "guards should investigate the LAST noise, not the first" \
  >> ~/GameProjects/<game>/.factory/inbox/raw.md
```

---

# 🌙 EVENING (~22:00, ~5-min top-up)

**Purpose: give the overnight batch fuel.** The 3 workers ship until the
10-item cap, then sleep. If the eligible queue is thin, they'll drain it
and idle. Two commands:

```bash
# 1. Drain everything you dictated today into clean WORK.md items:
#    (in Claude Code)
/spraxel-producer

# 2. Confirm there are 10+ eligible items queued for overnight:
python3 ~/SpraxelAiCompany/scripts/workmd.py top ~/GameProjects/<game>/WORK.md -n 12
```

If `top` shows fewer than ~10 eligible items (i.e., most of the top is
`MANUAL`/`[idea]`/`[needs-ceo]`), add a few via dictation + `/spraxel-producer`,
or promote some `[idea]`s. That's the whole evening visit.

Then you're asleep. **3 parallel `continuous_dev.sh` workers** (each in
its own worktree) ship items concurrently until the shared 10-item cap,
then all three sleep until your next checkin. Adjust the worker count in
`schedule.yaml` → `continuous.dev_concurrency` (1 = serial, 3 = default,
more = burns the Max-plan weekly cap faster).

---

## CEO weekly schedule (extras on top of the daily routine)

Most days look like the daily routine above. A few days have additions:

### Tuesday + Friday — Designer days

After Designer fires at 05:00 PT, MORNING.md's **Decide** section will
have 4–6 fresh ranked ideas. Expect the Decide step to take **+5 min**
on these days as you accept / reject / amend each.

### Saturday — Blogger day (+10 min)

Blogger fires at 09:00 PT Saturday. It **always pushes a `blog/<YYYY-MM-DD>` branch**
containing a draft post at `blog/content/posts/draft-<YYYY-MM-DD>-<slug>.md`.
The branch + draft are **not** on `master` — by design, drafts get a review pass
before they land. Your job is to humanize, then merge + publish.

#### 1. Find the draft

```bash
cd ~/GameProjects/<game>
git fetch origin

# List recent blogger branches if you've lost the date:
git branch -a | grep '^[ *]*\(remotes/origin/\)\?blog/'

# Peek without switching branches (fastest):
git show blog/$(date +%Y-%m-%d):blog/content/posts/draft-$(date +%Y-%m-%d)-*.md
```

#### 2. Humanize on the branch

```bash
git checkout blog/$(date +%Y-%m-%d)
# Find the actual filename (slug varies per post):
ls blog/content/posts/draft-$(date +%Y-%m-%d)-*.md
$EDITOR blog/content/posts/draft-$(date +%Y-%m-%d)-<slug>.md
```

What to do in the edit pass:
- **Replace `▸ MEDIA` placeholders.** Every theme section has a comment like
  `<!-- ▸ MEDIA: <slug> — screenshot + clip -->` followed by a TODO image
  + clip line. If `.factory/demos/<date>/<slug>.png` exists, the path
  is already filled in; otherwise, drop in your own screenshot or delete
  the slot. Find them all with `grep "▸ MEDIA" blog/content/posts/draft-*`.
- **Voice pass.** Tighten phrasing, add personality, drop in retro-game
  references where they fit. The bot's tone is competent but flat.
- **Flip `draft: true` → `draft: false`** in the frontmatter when ready.
- **Trim aggressively.** If it's over ~700 words, cut.

```bash
git commit -am "blog: humanize $(date +%Y-%m-%d)"
```

#### 3. Merge + publish

```bash
git checkout master
git merge --no-ff blog/$(date +%Y-%m-%d) -m "blog: $(date +%Y-%m-%d)"
git push origin master
# Then publish to your blog target (Hugo, ghost, substack, etc.)
```

#### 4. (Optional) Clean up the branch

The branch served its purpose; safe to delete locally + remotely:
```bash
git branch -d blog/$(date +%Y-%m-%d)
git push origin --delete blog/$(date +%Y-%m-%d)
```

#### Killing a draft you don't want

If the post isn't worth publishing, just don't merge it. Trash both branches:
```bash
git branch -D blog/$(date +%Y-%m-%d)
git push origin --delete blog/$(date +%Y-%m-%d)
```

#### What the Blogger pulls into the draft

- 7 days of `feat:` / `fix:` commits, grouped thematically (it picks themes).
- Demo Creator assets from `.factory/demos/<recent-dates>/` if any exist
  (real `<slug>.png` + `<slug>.mov` paths).
- PM release notes from `.factory/releases/<latest>.md` if a release was cut.
- Memory of past topics from `.factory/memory/blogger.md` — to avoid repeating
  phrases or themes across weeks.

`/spraxel-inbox` skill adds the humanize step as **step 4** in the morning
routine on Saturdays.

### Sunday — Janitor + Reflection

Janitor fires at 01:00 PT Sunday. No CEO action required — but the
MORNING.md "Janitor" line will tell you what got cold-archived. If you
want to resurrect anything, edit WORK.md to remove the `[cold]` tag.

### Monday (every other) — Release-cut day

On biweekly Mondays, PM auto-cuts a release tag in addition to its
daily reorder. MORNING.md will announce:

> 🚢 PM cut v0.4 on 2026-MM-DD: 6 features, 2 bugs.
> Notes: .factory/releases/v0.4.md
> Branch: release/v0.4

Read the notes to confirm the cut matches reality. The release branch
is for hotfixes — usually you ignore it.

### 1st of the month — Asset Librarian

Asset Librarian fires at 07:00 PT on the 1st of each month. Adds a
"Asset Librarian" line to MORNING.md with orphan count + license gaps.
Address the license gaps when they appear (~5 min).

---

## Setting up & changing schedules

There are **three independent schedules**. All live in plain text you can
edit; the daemon picks up changes within 60 s (the `tick.sh` launchd job
re-reads the files every tick — no restart needed).

### 1. Crew-agent cadences — *when the bots fire*

`schedule.yaml` → `agents:` holds one cron line per agent:

```yaml
agents:
  playtester: { cron: "0 3 * * *",   description: "03:00 PT daily" }
  designer:   { cron: "30 4 * * 2,5", description: "Tue+Fri 04:30 PT" }
```

Cron format is `minute hour day-of-month month day-of-week`, evaluated in
`America/Los_Angeles` (see `scripts/cron_match.py`). Examples:
`0 6 * * *` = 06:00 daily; `30 4 * * 2,5` = 04:30 Tue+Fri; `0 1 * * 0` =
01:00 Sun; `0 7 1 * *` = 07:00 on the 1st.

**Defense in depth:** each agent also reads its cadence from the game's
`Philosophy.md` → `cadence.<agent>` and exits cleanly if today isn't its
day. Keep the two in sync — `schedule.yaml` controls *firing*,
`Philosophy.md` is the agent's own *sanity check*. To move an agent, edit
both.

**To add a new scheduled agent:** (a) drop its spec at
`agents/spraxel-<name>.md`, (b) add a `cron:` line under `agents:` in
`schedule.yaml`, (c) add a matching `cadence.<name>` in `Philosophy.md`.
Next tick runs it. Confirm with `tail -f logs/tick/$(date +%F).log`.

### 2. The continuous (overnight) loop — *how hard it ships*

`schedule.yaml` → `continuous:` — the knobs you'll actually touch:

| Knob | Default | Meaning |
|------|---------|---------|
| `dev_concurrency` | 3 | parallel workers (1 = serial, more = faster but burns the Max cap) |
| `target_per_batch` | 10 | ships per batch before all workers sleep (resets on your checkin) |
| `dev_stall_minutes` | 12 | kill a dev only after this long with **no** progress |
| `max_dev_minutes` | 90 | absolute cap even on a progressing dev |
| `scenario_sample_size` | 4 | random acceptance scenarios per commit (0 = full suite) |

Full table with rationale: see **Configuration reference** below.

### 3. Your own routine — *when YOU show up*

`schedule.yaml` → `ceo_routine:` (morning / afternoon / evening times +
purposes). These drive what `/spraxel-inbox` shows by time of day. They're
guidance only — the system never blocks on the clock. Edit them to match
your life:

```yaml
ceo_routine:
  morning:   { around: "06:15", purpose: "Full triage …" }
  afternoon: { around: "13:00", purpose: "Quick unblock …" }
  evening:   { around: "22:00", purpose: "Top up …" }
```

### Pausing / resuming everything

```bash
touch ~/SpraxelAiCompany/.paused     # tick.sh no-ops; all firing stops
rm    ~/SpraxelAiCompany/.paused     # resume
bash ~/SpraxelAiCompany/scripts/install_daemon.sh status   # is the daemon loaded?
```

### A note on `/schedule` (the Claude Code reminder)

Claude Code itself sometimes offers `/schedule` — that's a *different*
thing: it schedules a one-off future Claude session (e.g., "remind me to
flip this flag in 3 days"). It is **not** how you schedule Spraxel agents
— those go in `schedule.yaml` as above. Use `/schedule` only for personal
follow-ups tied to a concrete future date.

---

## The game-code contract

For Spraxel to drive a Godot game, the game repo must provide these
files + conventions. `scripts/new_game.sh` scaffolds the common parts;
the game-specific bits (autoloads, scenario format, debug-boot dispatch)
are documented below so a CEO knows what to write.

### Files at the game-repo root (auto-scaffolded by new_game.sh)

| Path | Purpose | Spraxel reads it as... |
|---|---|---|
| `Philosophy.md` | Per-game config + identity + cadence + budgets | Source of truth for `run_mode`, `dev.godot_binary`, model assignments, agent thresholds |
| `WORK.md` | Work queue (Shipped / Todo) | Mutated atomically via `workmd.py` from the framework |
| `Game.md` | Feature inventory; dev appends `### <Feature>` blocks per ship | Read by morning-briefer to surface play-test commands |
| `.gitignore` | Excludes `.factory/`, `.worktrees/`, Godot cache, etc. | Critical — framework state lives under `.factory/` |
| `scripts/run_local_tests.sh` | Test runner (GUT + scenarios) — honors `SPRAXEL_GAME_DIR` + `SPRAXEL_WORKER_ID` env vars from wrapper | Invoked by `continuous_dev.sh` for baseline + post-dev tests |
| `scripts/run_unit_tests.sh` | Fast unit-only runner | Optional manual invocation |
| `scripts/install_local_tests.sh` | Installs `com.spraxel.localtests` launchd plist | One-shot at game setup |

### Conventions the game's GDScript MUST follow

Spraxel doesn't ship game code — only the framework that exercises it.
But the framework makes assumptions about your game's structure:

**1. `scripts/systems/debug_boot.gd` autoload — required.**
- Parses `OS.get_cmdline_user_args()` for `--demo-feature=<slug>`, `--quit-after=N`, `--trace-file=<path>`, `--build-mode=<mode>`.
- Dispatches to `_demo_<snake_slug>()` handlers in a `match` block.
- Each `_demo_<slug>` must implement BOTH branches:
  - `if is_headless:` → load + instantiate `scripts/scenarios/<slug>.gd`
  - else (windowed): load the relevant mission via `MissionRunner.set_mission(...)`, then pre-stage the scene (spawn props, KO guards, etc.) so the feature is immediately exercisable.
- **Use autoload globals directly** (e.g. `MissionRunner.set_mission(x)`), NEVER `Engine.get_singleton("MissionRunner")` — autoloads are NOT engine singletons in Godot 4.6, that call returns null.
- Schedules `_quit_for_headless()` at `quit_after_seconds` AND a `_quit_safety_net()` at 90s if headless OR `--quit-after` was explicit.

**2. `scripts/scenarios/<slug>.gd` — acceptance scenarios.**
- Class extends `Node2D` (or `Node`); each acceptance scenario gets a file in `scripts/scenarios/`.
- `_ready()` runs assertions, prints exactly one of:
  - `SCENARIO <slug> PASS  pass=<N>` (or `SCENARIO <slug>: PASS`)
  - `SCENARIO <slug> FAIL  pass=<N>  fail=<M>`
- Must call `get_tree().quit(0)` (PASS) or `get_tree().quit(1)` (FAIL) — the framework's safety net auto-kills at 90s, but a clean exit is expected for normal runs.

**3. `test/unit/test_<slug>.gd` — GUT unit tests.**
- One file per feature (`test_hide_box.gd`, etc.).
- `extends GutTest`, methods named `test_<behavior>()`.
- Run by `gut_cmdln.gd` from `addons/gut/` (the GUT addon must be installed in the game repo).

**4. Autoloads accessible by name.**
- `MissionRunner` (or the game's equivalent) holds current-mission state and is mutated by the demo handlers + scenarios.
- `Tracer` (optional, infiltrators-specific) for event tracking via `Tracer.emit("evt", data)`.
- All autoloads referenced via global identifier, NOT `Engine.get_singleton(...)`.

**5. Conventional Commits format for dev output.**
- Dev's `COMMIT_SUBJECT:` line uses `feat(scope): ...`, `fix(scope): ...`, etc.
- Body describes the change in 2-6 paragraphs (per dev spec step 9).

The framework will tell you (via the Reviewer's `[block]` findings + the
dev-spec deliverables checklist) when a game-code contract violation
happens. Common ones: missing `--demo-feature=` hook, scenario without
`get_tree().quit()`, `Engine.get_singleton("X")` in demo handlers.

---

## Setup — adding a new game

If you're starting a fresh game and want to wire it into the Spraxel
factory, the bootstrap is one script + a few config edits. The whole
process takes ~10 minutes.

```bash
# 1. Create the game repo (or use an existing one)
mkdir ~/GameProjects/my-new-game && cd ~/GameProjects/my-new-game
git init

# 2. Apply the Spraxel framework template
bash ~/SpraxelAiCompany/scripts/new_game.sh ~/GameProjects/my-new-game \
  --name "My New Game" --ceo your-github-login

# This drops in:
#   Philosophy.md           ← edit run_mode, dev.godot_binary, identity, knobs
#   Game.md                 ← feature inventory; bots append blocks here
#   WORK.md                 ← work tracking (3 sections, 2 dashed-line dividers)
#   .gitignore              ← Godot cache, .uid files, .factory/local/, etc.
#   .factory/               ← runtime state dirs (memory/, inbox/, reviews/, local/)
#   scripts/install_local_tests.sh
#   scripts/run_local_tests.sh      ← full GUT + scenarios + status JSON
#   scripts/run_unit_tests.sh       ← fast unit-test only runner
#   test/unit/.gitkeep              ← Developer agent puts GUT tests here
#   scripts/scenarios/.gitkeep      ← Developer agent puts scenario tests here
```

### Edit Philosophy.md (per-game config)

The template is annotated with `TODO:` markers where game-specific
content goes. The MUST-edit fields:

```yaml
identity:
  name: "My New Game"
  pitch: "<one-line elevator pitch>"
  must_include:    ["<3-5 things this game MUST be>"]
  must_not_include: ["<3-5 things this game must NOT be — the Designer
                     and Producer enforce these>"]
dev:
  language: "GDScript"           # or whatever
  engine: "Godot 4.6.1"
  godot_binary: "/Users/.../Godot.app/Contents/MacOS/Godot"
  main_scene: "res://scenes/<your-title>.tscn"
run_mode: "live"                 # "dryrun" until you're ready
```

The OPTIONAL knobs (have sensible defaults — only edit if you want
non-default behavior). See the "Configuration reference" section above
for the full table.

```yaml
# Per-agent CEO-tunable thresholds — all optional. Defaults shown.
janitor:
  cold_threshold_days:    30
  log_retention_days:     60
morning_briefer:
  playtest_count:         10
dashboard:
  recent_ships:           20
  ceo_actions:            10
designer:
  ideas_per_run:          5

# Model assignments — defaults are fine. Adjust if you're hitting your
# Max-plan weekly cap and want to push more agents onto haiku.
budgets:
  model_assignments:
    developer:        claude-sonnet-4-6
    reviewer:         claude-sonnet-4-6
    designer:         claude-sonnet-4-6
    morning_briefer:  claude-haiku-4-5-20251001
    janitor:          claude-haiku-4-5-20251001
    # ...
```

### Edit schedule.yaml (framework runtime)

```bash
# 4. Tell the daemon which game to target + tune the continuous loop
$EDITOR ~/SpraxelAiCompany/schedule.yaml
```

The MUST-edit field:

```yaml
game_dir: ~/GameProjects/my-new-game
```

The OPTIONAL knobs (defaults are sensible — only touch if you have a
reason). See the "Configuration reference" section above.

```yaml
continuous:
  target_per_batch:       10      # ships before sleep until next CEO signal
  dev_concurrency:        3       # parallel workers; 1 = single, 3 = aggressive
  max_fail_streak:        3       # consecutive failures → backoff
  fail_backoff_seconds:   1800    # 30 min backoff
  poll_interval_seconds:  60      # how often to re-check pause/cap
  idle_threshold:         5       # empty-queue ticks → long sleep
  idle_sleep_seconds:     300

agents:
  # cron expression per agent — edit cadences here. Format:
  #   minute hour day-of-month month day-of-week  (PT timezone)
  playtester:      { cron: "0 4 * * *",  ... }
  triager:         { cron: "0 5 * * *",  ... }
  morning_briefer: { cron: "0 6 * * *",  ... }
  # ...
```

```bash
# 5. Install (or re-install) the daemon — idempotent
bash ~/SpraxelAiCompany/scripts/install_daemon.sh

# 6. Install the local-tests cron in THIS game repo
cd ~/GameProjects/my-new-game
bash scripts/install_local_tests.sh

# 7. (Optional) Install ffmpeg if you want auto-capture of feature demos
# (the demo-creator agent uses Godot's --write-movie + ffmpeg). Without
# ffmpeg, the agent skips auto-capture but still produces recipe.md for
# hand-recording.
brew install ffmpeg
```

Verify everything is loaded:

```bash
launchctl list | grep com.spraxel
# Expect TWO lines:
#   com.spraxel.tick          (1-min daemon dispatching all agents)
#   com.spraxel.localtests    (30-min Godot test runner)

bash ~/SpraxelAiCompany/scripts/install_daemon.sh status

claude --version
# If session expired, run `claude login` in a Claude Code window.
```

Note: the daemon targets ONE game at a time (the `game_dir` in
`schedule.yaml`). For a second game running in parallel you'd need a
second daemon — that's not yet supported (see "Framework wishlist"
below for the deferred-feature note).

## Setup — first time on this Mac (existing game)

If you're setting up Spraxel for the first time on a Mac and the game
repo is already cloned:

```bash
bash ~/SpraxelAiCompany/scripts/install_daemon.sh
cd ~/GameProjects/<game> && bash scripts/install_local_tests.sh
launchctl list | grep com.spraxel        # → expect 2 entries
claude --version                          # → confirms Claude CLI is logged in
```

---

## Common operations

### Manually run one agent

```bash
bash ~/SpraxelAiCompany/scripts/run_agent.sh designer
bash ~/SpraxelAiCompany/scripts/run_agent.sh morning-briefer
bash ~/SpraxelAiCompany/scripts/run_agent.sh pm --dry-run     # see prompt, don't fire
```

Logs land at `~/SpraxelAiCompany/logs/<agent>/<ts>.log`.

### Manually run the continuous loop now

```bash
bash ~/SpraxelAiCompany/scripts/continuous_dev.sh
```

(This is the same script `tick.sh` spawns automatically — usually you don't
run it by hand. It keeps shipping items until it hits the per-CEO-signal cap,
then sleeps.)

### Pause everything

```bash
touch ~/SpraxelAiCompany/.paused
```

The daemon keeps ticking but `tick.sh` and `run_agent.sh` and
`continuous_dev.sh` all check this flag and exit silently. Resume with:

```bash
rm ~/SpraxelAiCompany/.paused
```

### Interrupt protocol — when you need to do a one-off mid-run

If you need to make a manual change while overnight is running (a real
bug emergency, a play-test reveal, anything), use the interrupt scripts.
They safely pause the system, preserve in-flight Developer work, and
get you to a clean master in one command:

```bash
# Pause system + kill in-flight overnight + stash Developer work + checkout master
bash ~/SpraxelAiCompany/scripts/interrupt.sh

# ...now you can edit code, commit, test on master...

# When you're done and your change is committed + pushed:
bash ~/SpraxelAiCompany/scripts/resume.sh
# → restores the pre-interrupt branch + stash, unpauses daemon

# Or, if you want to discard the in-flight Developer work permanently:
bash ~/SpraxelAiCompany/scripts/resume.sh --drop
```

What `interrupt.sh` does:
1. `touch .paused` (block new agent dispatches)
2. SIGTERM all `continuous_dev.sh / run_agent.sh / claude -p` processes
3. Clear stale lockdirs
4. `git stash` any uncommitted work in the game repo (preserves it)
5. `git checkout master && git pull --ff-only`
6. Record state to `.cache/last-interrupt.txt` for `resume.sh`

What `resume.sh` does:
1. Read `.cache/last-interrupt.txt`
2. Checkout the pre-interrupt branch (if any)
3. Pop the stash (if any)
4. `rm .paused` → next tick fires normally

Both scripts are idempotent and refuse to overwrite dirty state.

### Pause one agent only

Comment out the line in `schedule.yaml`. Change applies on the next tick.

### Retune cadences

Edit `~/SpraxelAiCompany/schedule.yaml`. All times are PT, cron format
`m h dom mon dow`. Examples:

- Run PM twice a day: `cron: "0 7,15 * * *"`
- Move Designer to Sunday: `cron: "0 7 * * 0"`
- Bump overnight target from 10 to 15: change `target_items: 10` → `target_items: 15`

No restart needed. The next tick reads the file.

### Run the tick once (for debugging)

```bash
bash ~/SpraxelAiCompany/scripts/tick.sh
tail -5 ~/SpraxelAiCompany/logs/tick/$(date +%Y-%m-%d).log
```

### Read recent logs

```bash
# Tick log (one line per minute)
tail -50 ~/SpraxelAiCompany/logs/tick/$(date +%Y-%m-%d).log

# Last morning briefer run
ls -t ~/SpraxelAiCompany/logs/morning-briefer/ | head -1 | xargs -I{} cat ~/SpraxelAiCompany/logs/morning-briefer/{}

# Last overnight
ls -t ~/SpraxelAiCompany/logs/overnight/ | head -1
```

### Agent health check

`scripts/health_check.sh` scans today's per-agent logs for errors (unknown
model, rate limits, session expiry, fatal traces, etc.) and produces a
markdown block suitable for MORNING.md. The morning-briefer agent runs
this as **step 1** every day at 05:00 PT — the result appears at the top
of MORNING.md.

Run it yourself anytime to spot-check the system:

```bash
bash ~/SpraxelAiCompany/scripts/health_check.sh
```

Output looks like one of:

```
## ✓ Agent health — all clean
12 agent run(s) today, no errors detected.
```

or

```
## ⚠️ Agent health — 2 of 14 run(s) flagged

- **pm** (2026-05-26-0700):
  `Error: unknown model "claude-haiku-99-99"`
  log: `/Users/.../logs/pm/2026-05-26-0700.log`
- **reviewer** (2026-05-26-0023):
  `429: rate limit exceeded`
  log: `/Users/.../logs/reviewer/2026-05-26-0023.log`
```

Patterns it flags: `unknown model`, `model not found`, `rate.?limit`,
`quota exceeded`, `429`, `session expired`, `authentication failed`,
`permission denied`, `fatal:`, `ERROR:`, `unhandled exception`,
`Traceback`. Edit `scripts/health_check.sh` to tune the pattern list.

The check is read-only and idempotent — run it before bed, in the
morning, mid-day, whenever you want a quick "is anything broken?" view.

### Manually move an item

```bash
WORK=~/GameProjects/<game>/WORK.md
WORKMD=~/SpraxelAiCompany/scripts/workmd.py

python3 $WORKMD parse $WORK | head -30
python3 $WORKMD top   $WORK -n 10

# Add — Producer normally does this for you via /spraxel-producer
python3 $WORKMD append $WORK --section todo \
  "[bug] p0 stairs teleport on save/load" \
  --detail "repro: save mid-staircase, load" \
  --detail "char spawns one floor below"

# Mark something shipped manually
python3 $WORKMD ship $WORK "<title substring>"

# Accept a Designer [idea] (remove [idea]/[cold] tag)
python3 $WORKMD promote $WORK "sleeping-gas grenade"

# Reject a Designer idea / dedup a bug. NOTE: HARD RULE is "items in
# WORK.md are never deleted by agents" — but the CEO may delete by hand.
# `drop` is fine for CEO use; agents/scripts must not call it.
python3 $WORKMD drop $WORK "radio-tower mission"

# Change a priority
python3 $WORKMD bump $WORK "stairs teleport" p0

# Manually escalate an item for real CEO judgment (gameplay-ruiner /
# design issue / blocking decision). NOT used for tests/reviewer/merge
# failures — those auto-retry via [retry]. The next sync-escalations
# tick will surface this in `.factory/escalations.md`.
python3 $WORKMD escalate $WORK "<title>" \
  --detail "why: I think this whole approach undermines the stealth core loop"

# Regenerate .factory/escalations.md from current [escalated] items
# (idempotent; wrapper does this automatically every iter).
python3 $WORKMD sync-escalations $WORK

# Flip an [escalated] (or [retry]) item to [resume] so the wrapper picks
# it up from the saved branch on the next dev fire.
python3 $WORKMD resume $WORK "<title-substring>"
```

You can also just **edit WORK.md directly** — the format is human-friendly.
Just don't edit while the continuous loop is running (use `.paused`).

### Make a manual code change

No PR ceremony in this workflow. Branch, edit, merge yourself:

```bash
cd ~/GameProjects/<game>

# Touch up code without agent involvement
git checkout -b ceo/<short-description> master
$EDITOR <files>
bash scripts/run_local_tests.sh        # sanity check
git add <files>
git commit -m "<your message>"

# Merge yourself — straight to master
git checkout master
git merge --no-ff ceo/<short-description> -m "<commit message>"
git push origin master
git branch -d ceo/<short-description>

# Or for tiny edits, skip the branch
$EDITOR <file>
git commit -am "<message>" && git push

# If overnight is mid-flight and you want to commit safely:
touch ~/SpraxelAiCompany/.paused      # halts new agent dispatches
# ...do your edits + commit...
rm ~/SpraxelAiCompany/.paused
```

### Test the game

```bash
cd ~/GameProjects/<game>

# Full suite (GUT unit tests + every scripts/scenarios/*.gd)
bash scripts/run_local_tests.sh
# → exit 0 = pass; details in .factory/local-tests-status.json

# Just unit tests, headless
godot --headless --path . -s addons/gut/gut_cmdln.gd -gdir=test/unit/ -gexit

# Just one scenario
godot --headless --path . scripts/scenarios/<feature>.gd

# Play-test a specific feature (debug-feature hook from Game.md)
godot --demo-feature=<slug>

# Free-roam interactive
godot --path .
```

### Check token budget (Claude Max plan)

Max doesn't expose remaining-tokens as a number. Indirect signals:

```bash
# Is the CLI session alive?
claude --version    # 0 exit = ok; otherwise re-run `claude login` in Claude Code

# Did anything rate-limit recently?
grep -l "rate limit\|429\|quota" ~/SpraxelAiCompany/logs/*/$(date +%Y-%m-%d)*.log

# Last overnight's fail_streak
cat ~/SpraxelAiCompany/.cache/last-overnight.txt
# → fail_streak: 0 healthy; >=3 = likely rate-limited or session expired

# Today's claude -p invocations (rough budget gauge)
ls ~/SpraxelAiCompany/logs/*/$(date +%Y-%m-%d)*.log 2>/dev/null | wc -l
# Heavy day: ~20 (PM, Triager, Morning, plus 10-15 overnight Sonnet runs).
# Max plan should handle that. If you start seeing 429s:
touch ~/SpraxelAiCompany/.paused      # let the weekly cap reset (~24h)
```

### Dictation flow (drop → producer)

```bash
# Drop raw notes whenever they hit you — typed or pasted from voice memos
echo "the run sound should be QUIETER for ducked-walking" \
  >> ~/GameProjects/<game>/.factory/inbox/raw.md
echo "extraction zone bug back — character #3 stuck" \
  >> ~/GameProjects/<game>/.factory/inbox/raw.md

# Then in Claude Code:
# /spraxel-producer
# → reads raw.md, classifies each note ([bug]/[feature]/[game-feature]),
#   assigns priority, appends to WORK.md ## Todo, commits.
```

### Quick one-liners

```bash
# "What's next?"
python3 ~/SpraxelAiCompany/scripts/workmd.py top \
  ~/GameProjects/<game>/WORK.md -n 5

# "What shipped this week?"
git -C ~/GameProjects/<game> log master --since='1 week ago' \
  --oneline --grep='^feat:'

# "What did the agents commit lately?"
git -C ~/GameProjects/<game> log master --author='-bot@spraxel.ai' \
  --since='1 week ago' --pretty='%h %an %s'

# "Anything stuck?"
ls ~/SpraxelAiCompany/.locks/  # each lockdir = an in-flight agent

# "Revert something the continuous loop landed but broke things"
cd ~/GameProjects/<game>
git revert <sha> && git push origin master
```

### Uninstall

```bash
bash ~/SpraxelAiCompany/scripts/install_daemon.sh stop
cd ~/GameProjects/<game> && bash scripts/install_local_tests.sh stop
```

---

## WORK.md cheat sheet

Three sections separated by two dividers (10+ `-` or `=`):

```
# <game> — work tracking

## Shipped (previous releases)
v0.3 — pushing mechanic
v0.2 — character switch lock-out
----------
## Shipped since last release         ← continuous loop appends here (chronological)
[game-feature] p1 Run button + stamina bar
[bug] p0 Stairs teleport fixed
==========
## Todo                               ← continuous loop picks from top
[game-feature] p0 Diving stealth in water
[bug] p0 Extraction zone broken
[game-feature] p1 Skill tree system
  300 skills, 3 levels each, dependency chains
  Lock characters into archetypes based on starting skills
[idea] [feature] p2 Sleeping-gas grenade item  ← Designer drop; overnight SKIPS this
```

Tag reference:

| Tag | Meaning | Overnight picks? |
|-----|---------|------------------|
| `pN` (p0..p3) | Priority — p0 urgent, p3 nice-to-have | yes (sorted by priority) |
| `[bug]` | Repro of broken behavior | yes |
| `[feature]` | System / tooling / UX | yes |
| `[game-feature]` | Player-facing mechanic | yes |
| `[chore]` | Refactor / docs / deps | yes |
| `[idea]` | Designer drop, CEO triage needed | **NO** (promote → `[untriaged]`, into shaping) |
| `[untriaged]` | New feature work awaiting the Architect's first pass (fast-pass or questionnaire) | **NO** (until Architect finalizes/fast-passes) |
| `[untriaged-proposal-active]` | Architect wrote a shaping questionnaire (Q&A in `.factory/local/TRIAGE.md`) | **NO** (until you answer + Architect finalizes) |
| `[cold]` | Janitor archived as stale | **NO** (must remove tag first) |
| `[manual]` or `MANUAL - ` prefix | CEO-only — needs human hands (controller test, art, music, level design) | **NO** (skip until tag/prefix removed) |
| `[needs-ceo]` | Developer added clarifying questions — CEO must answer | **NO** (skip until questions answered + tag removed) |
| `[future]` or `FUTURE - ` prefix | Roadmap item — not ready to schedule (needs scoping, blocked, or deliberately deferred) | **NO** (skip until tag/prefix removed) |
| `[retry]` | Wrapper auto-set after tests/reviewer/merge failed on the prior dev attempt. Saved branch on origin (see `branch:` detail line); failure feedback in details. **No CEO action** — next dev fire picks it up in RETRY MODE, addresses the feedback, tries again. | **yes** (dev resumes from saved branch with failure context) |
| `[escalated]` | **Manually set** by CEO (or triager/designer/PM agent) for items needing real CEO judgment — gameplay-ruiner design issues, paid-asset blockers, story decisions, items the dev truly can't action. **Never auto-set by the wrapper.** Wrapper regenerates `.factory/escalations.md` from these every iter — clearing that file alone doesn't dismiss the item; only retagging in WORK.md does. | **NO** (skip until CEO retags as `[resume]`) |
| `[resume]` | CEO triaged an `[escalated]` item; wrapper picks up, checks out saved branch, rebases on master, hands off to dev with the CEO's clarification in details. | **yes** (dev resumes from saved branch with new guidance) |
| `[concern]` | Designer (or future agents) flagged a game-wide issue (feature bloat, missing fundamentals, philosophical drift). Advisory text, not work to do. CEO triages: delete (dismiss), remove tag (convert into real work item), or leave (defer). | **NO** (skip until tag removed) |
| `[epic]` | Parent of a decomposed feature (Architect-created). Display + completion tracker; auto-ships once its last subtask ships. | **NO** ever (devs build the subtasks, never the parent) |

### The shaping loop — Architect + TRIAGE.md

Every new feature item enters the queue **`[untriaged]`** and is invisible to the
developers until it's been shaped into a concrete spec. The **Architect** agent
(Sonnet; runs 09:00 & 21:00 PT, and reactively within ~60s — see below) owns this.
On each run it does two things:

1. **Intake** — for each `[untriaged]` item it decides:
   - *Already concrete?* → **fast-pass**: strips `[untriaged]` so the item is
     immediately buildable (no questions asked). It's logged under
     `## ✅ Recently cleared without a questionnaire` in TRIAGE.md so you can see
     what it auto-cleared.
   - *Ambiguous?* → writes a short /plan-style **questionnaire** into TRIAGE.md
     and re-tags the item `[untriaged-proposal-active]` (still not buildable).
2. **Review** — reads your answers and either **finalizes** the spec (writes it
   into the WORK.md item, removes the gate tag → the item is now buildable and the
   loop will build it) or asks a **follow-up round** (up to 5) if more is needed.

**Q: Is there one file with every questionnaire?** Yes —
`~/GameProjects/<game>/.factory/local/TRIAGE.md`. ONE file, CEO-local (gitignored),
holds every pending questionnaire grouped by item under `## ⏳ Awaiting your
answers`. Finalized/auto-cleared items move to the `## ✅` sections (auto-pruned).

**Q: How do I answer? Do I just edit the file and save?** Type your choice after
each question's `[Answer]` line. Options are listed one per line; the last is
always "Just type your own answer", so you can pick a letter OR write free text:

```
### T-7f3a · Add hero enemies — recurring named adversaries
Round 1 of 5 · created 2026-05-28 16:40 PDT

Q1. How many distinct hero enemies at launch?

    (a) 1–2
    (b) 3–5
    (c) 6+
    (d) one recurring main villain
    (e) procedural / scales with progress
    (f) Just type your own answer

    [Answer] (b)

Q2. Recur across missions, or per-level?

    (a) recurring across the whole campaign
    ... (e) ...
    (f) Just type your own answer

    [Answer] recurring across the whole campaign
```

Rules: only edit the `[Answer]` lines. **Don't** edit the `T-####` ids or the
`###`/`##` headers. A **blank `[Answer]` = "not answered yet"** (it does NOT mean
"you decide" — if you want the Architect to choose, use the "type your own
answer" option and say so).

**Q: Does it get looked at automatically? How do my answers get back into the
system?** You can **save as often as you like while editing — the Architect
ignores the file until you submit.** When you're done answering for now, type any
word after the **`[Indicate complete]`** line at the bottom of the Awaiting
section and save. That's the signal: within ~60s `tick.sh` wakes the Architect
(it also runs 09:00 & 21:00 PT). It processes every task whose questions are ALL
answered, finalizes/decomposes them, logs them under "✅ Recently finalized",
then clears `[Indicate complete]`. (Manual nudge anytime the system's running:
`bash ~/SpraxelAiCompany/scripts/run_agent.sh architect`.)

**Q: What if I only fill out some of it?** Fine — answer whole tasks you have time
for and submit. The Architect processes the **fully-answered** tasks and leaves
the rest exactly as you left them (partial answers preserved) for next time. A
partially- or un-answered task means only "didn't get to it yet"; it's never
built and never guessed at. (To kill an item instead of answering: `workmd.py drop`.)

**Where untriaged items come from:** the Producer tags new feature items
`[untriaged]`; accepting a Designer `[idea]` (`promote`) converts it to
`[untriaged]`; and you tag your own hand-adds (see "Adding new work by hand"
below). Bugs and `MANUAL` items never enter this loop.

### Subtasks & epics

When the Architect shapes a complex feature, it can split it into a parent
`[epic] <feature>` item plus a sequence of child **subtask** items, instead of
one big item a developer has to land all at once. Mechanics:

- Children are normal items sharing an `epic-id: E-xxxx` detail, ordered by a
  `seq: N` detail. They get the full lifecycle (`[wip]`, ship, `[retry]` +
  branch preservation) like any item.
- **Strictly sequential:** a child is only claimable once every lower-`seq`
  sibling has shipped. So work within a feature is serialized (each subtask
  builds on the prior one's merged code), while the 3 workers stay parallel
  across *different* features. If subtask 1 is in-flight, a second worker skips
  the whole feature and takes another mainline item.
- The `[epic]` parent is never built directly; `reconcile-epics` (run by the
  loop after each ship) moves it to Shipped once its last subtask lands.
- The Architect decides single-item vs. epic at finalize time and records the
  breakdown in `TRIAGE.md` so you can see (and re-shape) the split.
- **Backward-compatible:** any item with no `epic-id` is built whole, exactly as
  before. Existing backlog is untouched.

### Adding new work by hand — the `[untriaged]` rule

All NEW feature work enters through the shaping gate. The three intake sources
tag items at the source (there is no auto-tagger):

| Source | What it tags |
|--------|--------------|
| Producer (`/spraxel-producer`) | new `[game-feature]`/`[feature]`/`[chore]` → `[untriaged]` |
| Designer (via your `promote`) | accepting an `[idea]` converts it to `[untriaged]` |
| **You, hand-editing WORK.md** | tag new feature items `[untriaged]` yourself |

So when you (or Claude on your behalf) hand-add feature work and commit WORK.md,
**prepend `[untriaged]`** — e.g. `[untriaged] [feature] p2 <title>`. The Architect
then shapes it. **Exempt (never `[untriaged]`):**
- `[bug]` items — concrete; they keep their normal flow.
- `MANUAL - …` items — your hand-work, never built by the loop.

Existing backlog items are left as-is; the gate applies only to new additions.

### `MANUAL - ` sub-category labels

When the Developer ships a feature that needs CEO follow-up (placeholder
art, fake SFX, etc.), it appends a `MANUAL - <CATEGORY> - <desc>` item
to `## Todo`. The sub-category is documentary only — doesn't affect the
loop — but helps you batch-process during morning routine:

| Sub-category | Means |
|--------------|-------|
| `MANUAL - ART -` | Sprite / icon / texture / animation work needed |
| `MANUAL - MUSIC -` | Music track or loop needed |
| `MANUAL - SFX -` | Sound effect needed |
| `MANUAL - WRITING -` | Copy, story, dialogue, names, flavor text |
| `MANUAL - LEVEL -` | Level layout / hand-crafted design |
| `MANUAL - TUNING -` | Numbers feel wrong; needs balance pass |
| `MANUAL - VOICE -` | Voice acting / casting |
| `MANUAL - DESIGN -` | Design decision (mechanic feel, UX call) |
| `MANUAL - NARRATIVE -` | Story / plot / mission narrative |

Example overnight commit body referencing follow-ups:
```
feat: add duck mechanic

tests: + test_duck.gd
follow-ups added to WORK.md:
  - MANUAL - ART - Duck sprite + ducked-walk animation
```

### `FUTURE - ` parked roadmap items

`FUTURE - <desc>` or `[future] <desc>` marks something you want to do
**eventually** but isn't ready to schedule yet. Overnight skips these
the same way it skips `MANUAL` and `[needs-ceo]` — they sit in `## Todo`
as a visible roadmap without competing for tonight's batch.

Use it when:
- **You haven't scoped it yet.** Idea is good, but you don't know what
  "done" looks like — needs a design pass before the Developer can ship it.
- **Blocked on something.** Depends on a system that hasn't been built yet,
  a third-party decision, a real-world asset, etc.
- **Deliberately deferred.** It's on the roadmap for v0.4, but you're
  shipping v0.2 right now.

Difference from neighbors:
- `MANUAL - ` = human-only forever (art, audio, casting); will never
  become AI-eligible.
- `FUTURE - ` = AI-eligible later; just not now. Flip to a regular item
  by removing the prefix/tag when ready.
- `[needs-ceo]` = Developer already tried, got stuck, asked questions —
  CEO answers, removes tag, Developer retries.

Examples:
```
FUTURE - Co-op multiplayer (network layer needs design)
FUTURE - DLC mission pack
[future] [game-feature] p2 Mid-mission gear-swap drone — needs gear-system v2 first
```

---

## The agent roster

| Agent | Cadence | Model | What it does |
|-------|---------|-------|--------------|
| **continuous_dev.sh** | always on (paced by CEO signal cap) | n/a (shell) | Long-running Developer loop. Ships items until target_per_batch since last CEO signal, then sleeps. Spawned + watched by `tick.sh`. |
| **developer** | called by continuous loop, per item | sonnet | Implements one WORK.md item end-to-end on a feature branch. **MANDATORY**: GUT test under `test/unit/`, Game.md block with `First encounter` + `Tutorial prompt` for player-facing features, debug-feature hook, scenario file. Reviewer blocks merge if any are missing. Handles `[amend]`, `[reject]`, `[resume]` items differently (read prior code first). |
| **reviewer** | called by continuous loop, per item | haiku | Reads `git diff master...HEAD`, writes findings, exits 0 (clean) or 1 (blocking). Blocks merge on missing test, missing/incomplete Game.md, missing scenario file, missing debug-feature hook. |
| **playtester** | daily 03:00 PT | sonnet | Actively plays the game to find problems. Beyond test scenarios — input spam, edge cases, mechanic combos. Writes candidates to `.factory/inbox/playtest-findings.md`. Does NOT touch WORK.md directly. |
| **triager** | daily 03:00 PT | haiku | Reads playtest findings + test failures, appends as `[needs-ceo] [bug]` items. CEO validates in MORNING.md before they become live bugs. |
| **morning-briefer** | daily 04:00 PT | haiku | Writes `.factory/local/MORNING.md` (gitignored — never commit). 10 features to play-test with launch + amend + reject one-liners, decisions to make, real `[escalated]` items needing CEO judgment (usually 0 — auto-retries are silent and not surfaced). Shows a one-line `[retry]` queue count FYI but no action required. Runs `health_check.sh` first to surface agent failures. |
| **demo-creator** | daily 05:30 PT | sonnet | ALWAYS writes `.factory/demos/<date>/recipe.md` with per-feature launch + controls + capture commands. BEST-EFFORT auto-captures `.mp4` + `.png` via Godot `--write-movie` + ffmpeg (no Screen Recording permission needed; still requires Mac awake + ffmpeg installed). Blogger reads recipe.md as source of truth. |
| **pm** | daily 05:00 PT + biweekly Mon release-cut | haiku | Reorders ## Todo. On release day: tags `v0.N`, generates release notes, rolls WORK.md sections. |
| **designer** | Tue + Fri 04:30 PT | sonnet | Reads Philosophy + memory + inspiration. Drops 4-6 ranked `[idea]` items + 0-3 `[concern]` items (game-wide issue flags: feature bloat, missing fundamentals, philosophical drift). |
| **architect** | daily 09:00 & 21:00 PT + reactive (within ~60s of a new `[untriaged]` item) | sonnet | Shapes `[untriaged]` feature work into buildable specs. Processes answered questionnaires in `.factory/local/TRIAGE.md` (finalize spec → item buildable, or ask ≤5 follow-up rounds), and intakes new untriaged items (fast-pass concrete ones via `shape-pass`, else write a /plan-style questionnaire via `shape-start`). On finalize, decides single item vs. decomposing a complex feature into a parent `[epic]` + sequential subtasks (`shape-epic`). Bugs + MANUAL items are exempt. |
| **blogger** | weekly Sat 09:00 PT | sonnet | Drafts devlog from week's `feat:` commits ONLY (strict player-facing filter — skips fix(test):/chore:/refactor:/docs:/test:/work:/escalate:/ceo:). Writes `blog/content/posts/draft-<date>-<slug>.md` with `▸ MEDIA` placeholders. Pushes `blog/<date>` branch; CEO humanizes + merges. |
| **janitor** | weekly Sun 01:00 PT | haiku | Cold-archives 30+ day stale items (retag to `[cold]` — never deletes), prunes merged branches, prunes 60+ day logs. Sweeps orphan `feat/cont-*` branches whose WORK.md item is gone (cleanup for `[escalated]`/`[resume]`/`[retry]` branches whose items the CEO has deleted by hand). |
| **asset-librarian** | monthly 1st 07:00 PT | haiku | Scans assets/, reports orphans + license gaps. |
| **producer** | on-demand (`/spraxel-producer`) | sonnet | Converts CEO dictation → clean WORK.md items. Flags ⚠️ concerns inline (cliché/complexity/balance/drift) but always appends the item — concerns are advisory, never gatekeep. |

---

## Configuration reference

Two files hold all CEO-tunable knobs. The split is intentional:

- **`schedule.yaml`** (in this framework repo) — **how the daemon runs**.
  Cron expressions, parallel-worker count, ship-cap, retry/backoff
  policy. Shared across all games this Mac runs.
- **`Philosophy.md`** (in each game repo) — **what this game cares
  about**. Identity, model assignments, per-agent thresholds, dashboard
  preferences, dev binary. One per game.

If you have to choose, ask "does it depend on the game?" → Philosophy.md;
"does it depend on the daemon's runtime behavior?" → schedule.yaml.

### `schedule.yaml#continuous` knobs (framework runtime)

| Knob | Default | What it does |
|---|---|---|
| `target_per_batch` | 10 | Ships per CEO signal before all workers sleep. Shared across parallel workers. |
| `retry_per_item` | 1 | Max attempts per developer item before bouncing to `[retry]`. |
| `dev_concurrency` | 1 | Parallel worker count (worktrees + claude sessions). Each shares the cap. |
| `max_fail_streak` | 3 | Consecutive failures (any worker) before the cascade brake kicks in. |
| `fail_backoff_seconds` | 1800 | Sleep duration when fail-streak brake fires. |
| `poll_interval_seconds` | 60 | Cadence to re-check pause flag + cap counter. |
| `idle_threshold` | 5 | Empty-queue ticks before dropping to long sleep. |
| `idle_sleep_seconds` | 300 | Long sleep duration when queue is empty. |

### `schedule.yaml#agents` knobs

Cron expression per crew agent. Edit freely — changes apply on next tick
(within 60s). All evaluated in America/Los_Angeles. Format:
`minute hour day-of-month month day-of-week`.

### `Philosophy.md` knobs (per-game)

| Section | Knob | Default | What it does |
|---|---|---|---|
| `identity` | `name`, `pitch`, `must_include`, `must_not_include` | (game-specific) | Used by Designer/Producer to filter ideas against the game's tone. |
| `cadence` | `<agent>: "<English description>"` | (matches schedule.yaml crons) | Defense-in-depth: agents read this and exit cleanly if today isn't their day. Update both schedule.yaml AND Philosophy.cadence if you change. |
| `budgets` | `monthly_usd_hard_cap`, `by_agent_percent` | (game-specific) | Informational on Max plan. `token_report.sh` warns if actual usage drifts >25% from target. |
| `budgets.model_assignments` | per-agent: `claude-haiku-*` / `claude-sonnet-*` / `claude-opus-*` | (game-specific) | **SOURCE OF TRUTH** for which model each agent uses. `run_agent.sh` reads this. |
| `designer` | `ideas_per_run` | 5 | How many `[idea]` items the Designer drops per run. |
| `designer` | `quality_criteria` | (game-specific) | Sentence describing what counts as a "good" idea. |
| `ceo` | `do_not_disturb` | `["00:00-07:30"]` | Time windows when agents must not page the CEO. |
| `blog` | `voice`, `template`, `publish_target` | (game-specific) | Blogger reads this for tone + format. |
| `dev` | `godot_binary` | (system path) | Used by `run_local_tests.sh` + `capture_demo.sh`. |
| `dev` | `velocity_issues_per_release` | 6 | Producer/PM target for parallel issues in flight. |
| `janitor` | `cold_threshold_days` | 30 | Untouched Todo items get `[cold]` retag after this many days. |
| `janitor` | `log_retention_days` | 60 | Delete agent log files older than this. |
| `morning_briefer` | `playtest_count` | 10 | Features to surface in MORNING.md ▶ Play-test section. |
| `dashboard` | `recent_ships` | 20 | "Last N shipped" rows in `dashboard.py`. |
| `dashboard` | `ceo_actions` | 10 | "Next N CEO action items" rows. |
| `run_mode` | `live` / `dryrun` | `live` | Hard kill-switch — `dryrun` makes agents log what they'd do without writing anything. |

All Philosophy.md knobs are optional; agents read the default if the
field is missing. So a minimal Philosophy.md just needs `identity` +
`run_mode` to work — everything else is tuning over time.

---

## Reference: scripts, agents, processes

### Scripts in `~/SpraxelAiCompany/scripts/`

| Script | Purpose | Invoked by |
|--------|---------|------------|
| **`tick.sh`** | The launchd-fired heartbeat. Every 60s: reads `schedule.yaml`, fires due crew agents, spawns `continuous_dev.sh` if not running. | `com.spraxel.tick.plist` (launchd) |
| **`continuous_dev.sh`** | Long-running Developer loop. Ships items from `## Todo` until `target_per_batch` reached since last CEO signal, then sleeps. Detects clarifications + lock-conflicts; baseline-aware test gate. Single instance via `.locks/continuous.lockdir`. | spawned by `tick.sh` if not alive |
| **`run_agent.sh <name>`** | Wraps one Claude invocation. Reads the agent spec, composes prompt (spec + Philosophy + WORK.md + optional `SPRAXEL_ITEM_BRIEF`), passes `--model` based on spec frontmatter, calls `claude -p`. Per-agent lock prevents double-fire. | `tick.sh` (cron), `continuous_dev.sh` (per item), CEO manually |
| **`install_daemon.sh`** | Drops `com.spraxel.tick.plist` into `~/Library/LaunchAgents/`. Args: `install` / `stop` / `status` / `restart`. | CEO, one-time |
| **`new_game.sh <dir>`** | Bootstraps a new game repo with Philosophy.md, Game.md, WORK.md, `.gitignore`, `.factory/`, `test/unit/`, `scripts/scenarios/`, and the local-tests cron installer. | CEO, when starting a new game |
| **`workmd.py`** | Parser + CLI for WORK.md. Subcommands: `parse / top / append / ship / escalate / resume / promote / drop / bump / clarify / release-cut` + shaping: `shape-list / shape-start / shape-detail / shape-finalize / shape-pass` + epics: `shape-epic / reconcile-epics`. Atomic mkdir-locked. | every agent + CEO |
| **`cron_match.py`** | Evaluates a 5-field cron expression against `now` in a timezone. Used by `tick.sh` to decide who fires and by `spraxel_report.py` to compute next firings. | `tick.sh`, `spraxel_report.py` |
| **`slugify.py`** | Title → kebab-case branch slug. | `continuous_dev.sh` for branch names |
| **`health_check.sh`** | Scans today's `logs/*/<YYYY-MM-DD>*.log` for error patterns (unknown model, rate limit, session expired, fatal, traceback). Outputs a markdown block. | `morning-briefer` agent (step 1), CEO manually |
| **`spraxel_report.py`** | Status snapshot generator: right-now state, last 24h, last 7 days, next 20 scheduled events. Pure-local read-only — no Claude tokens. Powers `/spraxel-report`. | CEO via `/spraxel-report` skill or directly |
| **`dashboard.py`** | Always-on TUI dashboard. Auto-refresh every 5 s (configurable via `--interval`). Compact view: status / tick / wrapper / cap counter / current item / today's totals / **next 10 scheduled fires** / **next 10 CEO action items** (urgency-ordered: `[needs-ceo]` > `[escalated]` > triage questionnaires (`TRIAGE.md`) > play-test > `[bug]` > `[idea]` > MANUAL > dictation backlog; color-coded) / **last 20 shipped** (sha + relative age + clean subject) / last log line. Stdlib only — no tokens, no third-party deps. Run in a terminal you leave open. | CEO, runs continuously while logged in |
| **`token_report.sh`** | Counts `claude -p` invocations per agent over a window. Compares to `Philosophy.budgets.by_agent_percent`. Flags drift >25%. | CEO manually (weekly check); not yet scheduled |
| **`capture_demo.sh <slug>`** | Records a Godot --demo-feature run via Godot's built-in Movie Maker (`--write-movie`) + ffmpeg encoding to H.264 .mp4 + extracts a .png still at 3s. No Screen Recording permission needed (engine framebuffer, not screen pixels). Requires ffmpeg on PATH; exits rc=3 if missing. Exits rc=5 with warning if recording is suspiciously short (test-style scenarios that auto-quit). | `demo-creator` agent |
| **`backfill_escalations.py`** | One-shot migration. Reads pre-redesign `.factory/escalations.md` entries (terse with log-link format), restores items to WORK.md as `[escalated]`, rewrites escalations.md with the new self-contained per-block format. Idempotent. | CEO, one-time per game repo |
| **`checkin.sh`** | Explicit CEO signal — touches `.cache/ceo-checkin.ts`. `continuous_dev.sh` polls this and resets the counter on detection. | CEO manually when read-only interaction wasn't enough |
| **`amend.sh <slug-or-sha> "feedback"`** | CEO keeps a shipped feature but queues a refinement pass. Appends `[amend] Refine: <title>` to WORK.md `## Todo` with sha + feedback. Master untouched — Developer iterates on existing code next overnight. | CEO during play-test |
| **`reject.sh <slug-or-sha> "reason"`** | CEO undoes a shipped feature. `git revert` the `feat:` + paired `work: shipped` commits on master, appends `[reject] Re-implement: <title>` to WORK.md `## Todo` with sha + reason. Developer re-implements next overnight, knowing the old approach was wrong. | CEO during play-test |
| **`playtested.sh <substr>\|all\|--list\|--reset`** | The "✓ Accept" action. Marks play-test feature(s) verified for TODAY so they drop off the dashboard + `/spraxel-inbox` action list. Writes only `.factory/local/playtested.json` (CEO-local, gitignored, auto-resets daily) — does not touch the game, master, or WORK.md. | CEO during play-test |
| **`interrupt.sh`** | Pause-and-stash protocol: sets `.paused`, kills the whole continuous_dev/run_agent/claude tree, clears stale locks, `git stash` in the game repo, checks out master. Pairs with `resume.sh`. | CEO when interrupting mid-run |
| **`resume.sh`** | Restores pre-interrupt state: pops stash, checks out original branch, removes `.paused`. Flags: `--drop` (discard stash), `--no-resume` (keep paused). | CEO after a manual change |
| **`yaml_to_workmd.py`** | One-shot migration: WORK.yaml → WORK.md. Used during the offline migration; safe to keep around. | migration only |
| **`generate_release_notes.py`** | Reads git log between two tags, generates a release-notes markdown. | CEO at release time |
| **`generate_game_md_inventory.py`** | Walks `scripts/`, generates the auto-section of Game.md (feature inventory). | optional CEO use |

### Scripts inside the game repo (`~/GameProjects/<game>/scripts/`)

These get installed by `new_game.sh`. They're not part of the framework's daemon — they're game-side test infrastructure.

| Script | Purpose | Invoked by |
|--------|---------|------------|
| **`run_local_tests.sh`** | The test-gate runner. Refreshes Godot's class cache, runs GUT under `test/unit/`, runs every `scripts/scenarios/*.gd` via `--demo-feature=<slug>`, writes `.factory/local-tests-status.json`. Exit 0 = green, 1 = failures, 2 = setup error. | `com.spraxel.localtests.plist` (every 30 min), `continuous_dev.sh` after every Developer commit, CEO manually |
| **`run_unit_tests.sh`** | Fast GUT-only runner. No class-cache refresh, no scenarios, no notifications. | CEO iterating on a specific test |
| **`install_local_tests.sh`** | Drops `com.spraxel.localtests.plist`. Args: `install` / `stop` / `status`. | CEO, one-time per game repo |

### Long-running processes

When the system is healthy, these are the processes you should see in `ps`:

```
$ pgrep -fl 'continuous_dev|run_agent|com.spraxel|claude --model'

PID  PPID  COMMAND
N    1     /usr/sbin/launchd ...com.spraxel.tick.plist...        (launchd dispatcher)
N    1     /usr/sbin/launchd ...com.spraxel.localtests.plist...  (test cron dispatcher)
N    1     bash continuous_dev.sh                                (the Developer loop)
N    cont  bash run_agent.sh developer                           (current Developer)
N    rag   claude --model claude-sonnet-4-6 -p                   (current claude inv)
```

Things to watch for that mean trouble:
- **Two `continuous_dev.sh` running** → race condition. Run `bash scripts/interrupt.sh` and resume.
- **`run_agent.sh` with parent PID 1** → orphan (the wrapper died but the child survived). Holds `.locks/<agent>.lockdir`. Same fix: `interrupt.sh`.
- **`claude --model ...` running >30 min** → either a real long Developer (fine) or claude hung. If `ps` CPU isn't advancing, kill it.

### Agents (`~/SpraxelAiCompany/agents/spraxel-*.md`)

11 agent specs + `_shared.md` (universal rules referenced by all).

| Agent | Model | Cadence | Triggered by | Writes to |
|-------|-------|---------|--------------|-----------|
| **developer** | sonnet | per item | `continuous_dev.sh` | game branch (code), commits |
| **reviewer** | haiku | per item | `continuous_dev.sh` after tests pass | `.factory/reviews/<branch>.md` |
| **triager** | haiku | daily 03:00 PT | `tick.sh` cron | WORK.md `## Todo` (appends `[bug]` items) |
| **morning-briefer** | haiku | daily 04:00 PT | `tick.sh` cron | `MORNING.md` |
| **pm** | haiku | daily 05:00 PT | `tick.sh` cron | WORK.md `## Todo` (re-orders) |
| **designer** | sonnet | Tue + Fri 04:30 PT | `tick.sh` cron | WORK.md `## Todo` (appends `[idea]` items) |
| **architect** | sonnet | 09:00 & 21:00 PT + reactive on `[untriaged]` | `tick.sh` cron + reactive grep | WORK.md (shape-* tag/spec edits) + `.factory/local/TRIAGE.md` |
| **blogger** | sonnet | Sat 09:00 PT | `tick.sh` cron | `blog/<date>` branch |
| **janitor** | haiku | Sun 01:00 PT | `tick.sh` cron | WORK.md (cold-archives), branches (deletes merged), logs (prunes >60 days) |
| **asset-librarian** | haiku | monthly 1st 07:00 PT | `tick.sh` cron | `.factory/asset-report-<date>.md`, MORNING.md note |
| **producer** | sonnet | on-demand (`/spraxel-producer`) | CEO via skill | WORK.md `## Todo` (from `.factory/inbox/raw.md`) |
| **demo-creator** | sonnet | daily 05:30 PT | `tick.sh` cron | `.factory/demos/<date>/recipe.md` (always) + best-effort `.mp4`+`.png` (when Mac awake + ffmpeg installed) |

### Skills (`~/SpraxelAiCompany/skills/`, hardlinked to `~/.claude/skills/`)

| Skill | Trigger | Purpose |
|-------|---------|---------|
| **`/spraxel-inbox`** (or `/inbox`) | CEO types in Claude Code | Walks the morning routine: opens MORNING.md, surfaces sections in order, quick commands |
| **`/spraxel-producer`** (or `/producer`) | CEO types in Claude Code | Converts `.factory/inbox/raw.md` + dictation files into clean WORK.md items; flags ⚠️ concerns inline |
| **`/spraxel-report`** (or `/report`) | CEO types in Claude Code, or "what's going on?" | Immediate system status: now / last 24h / last week / next 20 scheduled events. Runs `scripts/spraxel_report.py` (no Claude tokens used for data gathering) |

### Per-agent memory files

Each agent has a persistent memory file at `<game-dir>/.factory/memory/<agent>.md`:

| Agent | Memory file | What it tracks |
|-------|-------------|----------------|
| `developer` | `.factory/memory/developer.md` | Cross-cutting notes — module fragility, item-title patterns, autoload init gotchas |
| `reviewer` | `.factory/memory/reviewer.md` | Recurring code smells; auto-opens chores when patterns repeat |
| `pm` | `.factory/memory/pm.md` | Release decisions, velocity trends, items repeatedly re-ordered |
| `designer` | `.factory/memory/designer.md` | What's been proposed (prevent re-pitch), inspiration drawn from |
| `triager` | `.factory/memory/triager.md` | Bugs already promoted; dedup history |
| `playtester` | `.factory/memory/playtester.md` | Features tested, edge cases covered, next areas to focus on |
| `demo-creator` | `.factory/memory/demo-creator.md` | Captured features + dates, skips (no `--demo-feature` hook) |
| `morning-briefer` | `.factory/memory/morning-briefer.md` | Themes surfaced, what CEO ignores, recurring escalations |
| `blogger` | `.factory/memory/blogger.md` | Topics covered, voice notes from CEO |
| `janitor` | `.factory/memory/janitor.md` | Cold-archived items, branches deleted, space reclaimed |
| `asset-librarian` | `.factory/memory/asset-librarian.md` | Long-standing orphans, license gaps over time |
| `producer` | `.factory/memory/producer.md` | Classification call patterns, CEO phrasings |

Memory is opt-in for each run: agents read at start, write one paragraph
at end. CEO can read/edit/delete any memory file at any time.

### State + cache files

| Path | Purpose |
|------|---------|
| `~/SpraxelAiCompany/.paused` | Touch-flag: when present, all agent dispatches no-op. `rm` to resume. |
| `~/SpraxelAiCompany/.locks/<agent>.lockdir` | Per-agent atomic lock. Held while agent is in-flight. Stale lockdirs from crashes are cleaned by `tick.sh`. |
| `~/SpraxelAiCompany/.cache/continuous-state.json` | Counter, last CEO signal SHA + timestamp. Read by `continuous_dev.sh` each loop iteration. |
| `~/SpraxelAiCompany/.cache/ceo-checkin.ts` | Touched by `scripts/checkin.sh`. Polled by `continuous_dev.sh` for "manual signal" detection. |
| `~/SpraxelAiCompany/.cache/last-interrupt.txt` | Pre-interrupt branch + stash ref, used by `resume.sh`. |
| `~/SpraxelAiCompany/logs/tick/<YYYY-MM-DD>.log` | One line per minute from `tick.sh`. |
| `~/SpraxelAiCompany/logs/<agent>/<ts>.log` | Full claude conversation log per agent invocation. |
| `~/SpraxelAiCompany/logs/continuous/<YYYY-MM-DD>/<slug>.log` | Per-item ship log (Developer + tests + Reviewer + merge). |

### Game-side state (`~/GameProjects/<game>/.factory/`)

| Path | Purpose |
|------|---------|
| `escalations.md` | Append-only log of items the Developer couldn't ship. Morning Briefer surfaces these. |
| `local-tests-status.json` | Last `run_local_tests.sh` result: pass/fail, list of failures, log path. |
| `reviews/<branch>.md` | Per-branch Reviewer findings. |
| `inbox/raw.md` | Where CEO dumps dictation; `/spraxel-producer` drains this. |
| `inbox/dictation/*.md` | Phone voice-memo exports; `/spraxel-producer` also drains these. |
| `local-test-logs/<stamp>.log` | Full output of each `run_local_tests.sh` run (gitignored). |

---

## Troubleshooting

### "No agents are firing"

```bash
# Is the daemon loaded?
launchctl list | grep com.spraxel.tick
# → should print one line with the label

# Are ticks happening?
tail -10 ~/SpraxelAiCompany/logs/tick/$(date +%Y-%m-%d).log
# → should be one line per minute, with "tick" or "tick dispatched=..."

# Is the system paused?
ls ~/SpraxelAiCompany/.paused 2>/dev/null && echo "PAUSED — rm to resume"
```

### "Did any agent fail today?"

First stop — the health check:

```bash
bash ~/SpraxelAiCompany/scripts/health_check.sh
```

If it says "all clean" and you still suspect something, scan the tick log
for dispatches that didn't produce a follow-up log file. (Same output the
morning briefer puts at the top of MORNING.md.)

### "Agent ran but did nothing"

Check the agent log:

```bash
ls -t ~/SpraxelAiCompany/logs/<agent>/ | head -3 | while read f; do
  echo "=== $f ==="; tail -20 ~/SpraxelAiCompany/logs/<agent>/$f
done
```

Common causes:
- Philosophy.md `run_mode: "dryrun"` — agents exit silently. Flip to `live`.
- Claude session expired — re-run `claude login` in Claude Code.
- Wrong model ID for the agent (claude-CLI errors with `unknown model`).
  The health check catches this — `bash scripts/health_check.sh`.
- Nothing to do (Janitor with no stale items, PM with no reorder needed).

### "Overnight loop didn't ship anything"

```bash
# What did it try?
ls -t ~/SpraxelAiCompany/logs/overnight/ | head -1 | xargs -I{} ls ~/SpraxelAiCompany/logs/overnight/{}

# Recent escalations
cat ~/GameProjects/<game>/.factory/escalations.md | tail -40
```

If `fail_streak: 3` appears in `~/SpraxelAiCompany/.cache/last-overnight.txt`,
the Claude CLI hit 3 consecutive failures (likely rate limit or session
expiry). Re-auth and re-run.

### "I committed code mid-cycle and now the continuous loop fails to push"

The continuous loop fetches and rebases at start of each item, but if
you committed between its fetch and its push, the push fails. Easy fix: run a quick
manual rebase next morning, or just wait — the next night picks up where
it left off.

### "WORK.md got corrupted by two agents writing at once"

`workmd.py` uses an atomic mkdir-lock, so this shouldn't happen between
agents. But manual `vim WORK.md` while an agent is mid-write **can**
corrupt the file. Recovery:

```bash
cd ~/GameProjects/<game>
git log --oneline -5 WORK.md
git show <last-good-sha>:WORK.md > WORK.md.recovered
diff WORK.md WORK.md.recovered
# If recovery is good:
mv WORK.md.recovered WORK.md && git add WORK.md && git commit -m "fix WORK.md"
```

---

## Cost model

| Resource | Cost |
|----------|------|
| `claude -p` invocations | Flat — included in Claude Max plan. No marginal cost per run. |
| GitHub commits + pushes | $0 — unlimited on free private repos. |
| GitHub Actions | $0 — we don't use them anymore. |
| Anthropic `/schedule` routines | $0 — we don't use them anymore. |
| LFS storage | $0 if you stay under 1 GB total LFS objects. |
| Mac electricity | Marginal — continuous loop runs claude in bursts, mostly idle between dev calls. |

The system's only **bounded** resource is your Claude Max weekly token
quota. Sonnet runs (Developer, Designer, Blogger) consume most. If you hit
the cap mid-week, all `claude -p` calls return 429 until the cap resets.
See "Risks" below for mitigation.

---

## Risks

- **Claude Max weekly cap**: 10 overnight Developer runs/night × 7 nights
  = 70 Sonnet calls/week, plus Designer, Blogger, daily Concierge/PM/Triager
  (Haiku, cheap). Should fit comfortably in the Max cap, but if you hit
  it, the system 429s silently until reset.
  *Mitigation*: monitor `~/SpraxelAiCompany/logs/<agent>/` for "rate limit"
  in recent logs. Add to TODO: a simple `claude --version`-like daily
  health check in `tick.sh`.

- **launchd skips ticks on sleep**: if your Mac sleeps for an hour, the
  daemon skips that hour. `RunAtLoad=true` so it resumes when you log in.
  Overnight loop schedules at 23:00; if you closed the lid at 22:30 and
  opened it at 09:00, you lost the night.
  *Mitigation*: `sudo pmset -a sleep 0` if you want to keep the Mac awake;
  or accept the occasional missed night.

- **Bot identity leaks**: if an agent forgets to set `git -c user.email=...`
  per-commit, it commits as the CEO. Each agent spec reiterates this in
  `_shared.md`; the overnight wrapper also sets it explicitly on the
  merge commit and the WORK.md update.

- **Designer floods the queue**: 4-6 items every Friday × 52 weeks = 200+
  unvetted ideas/year. The Janitor cold-archives 30+ day stale items, but
  CEO triage at 5 min/Friday isn't sufficient long-term.
  *Mitigation*: lower `cron: "0 7 * * 5"` to `"0 7 1,15 * 5"` (biweekly)
  if it builds up.

- **Reviewer over-blocks**: if the Reviewer agent gets pessimistic, it
  exits 1 often and the continuous loop escalates everything. CEO has to
  re-tune the spec.
  *Mitigation*: regular review of `.factory/reviews/<branch>.md` files.
  Most should be `clean`.

---

## What I'm NOT doing in this workflow

- No GitHub Issues (deleted).
- No GitHub Actions (deleted from both repos).
- No `/schedule` Anthropic routines (you should delete them in claude.ai
  Settings → Scheduled tasks; they're costing per-token).
- No PR ceremony (overnight merges directly to master after Reviewer +
  tests pass).
- No `keepalive.yml` (no GH cron to keep alive).
- No `cost-report.yml` (cost is flat).
- No `factory-log.yml` (no event ledger; everything is in git log + logs/).
- No `Concierge` / `Factory Daily Log issue #5` (replaced by MORNING.md).

### Design decisions FAQ — why we don't do those things

These are the "decided once, don't revisit" rationale notes. Each was
weighed against the offline single-operator constraint and ruled out.

**Why no PR workflow?**
Decided 2026-05-25: in a one-person studio, PRs add ceremony without
value. The overnight loop does Developer → tests → Reviewer → merge in
one shot. If a feature lands broken, `git revert` is cheap and you find
out in the next play-test. The CEO is the only reviewer that matters,
and reviewing in MORNING.md (or `git show`) is faster than navigating
GitHub UI.

**Why no GitHub Issues?**
Decided 2026-05-25: WORK.md is simpler, faster, fully offline, and
unifies the queue + ship log in one file. Editing WORK.md in any text
editor is more pleasant than navigating GitHub UI. Tag taxonomy
(`[idea]`/`[needs-ceo]`/`[escalated]`/`[retry]`/...) gives us the
same routing power as Issue labels with zero round-trip latency.

**Why no GitHub Actions?**
Decided 2026-05-25: marginal Actions cost (free-tier minutes) constrained
the cadence. All workflows are now local shell scripts driven by launchd.
Loss: no auto-CI on PRs — but there are no PRs now, and `run_local_tests.sh`
runs on every developer commit anyway.

**Why no `/schedule` Anthropic routines?**
Decided 2026-05-25: `/schedule` bills per-token, separate from the Max
plan. `claude -p` headless on Max is flat-fee under the weekly cap. Same
agents, no marginal cost.

**Why no Concierge agent?**
Decided 2026-05-25: renamed to `morning-briefer`, writes MORNING.md
instead of a GitHub issue body. "Concierge" as a concept presupposed
GH issues; `morning-briefer` presupposes a local file.

**Why no Conflict-resolver / Auto-merge / Keepalive agents?**
Decided 2026-05-25: these existed to keep the GitHub-Actions cascade
running. With no PRs and no event-driven chains, they vanished.

### Framework wishlist (deferred, not committed)

Things that aren't built yet because there's no current need. Each is
fine to leave for now; revisit when the constraint actually hits.

- **Multi-game bootstrap**: `scripts/new_game.sh` works, but running two
  games in parallel needs either a daemon per game or `tick.sh` extended
  to iterate multiple `game_dir` entries in `schedule.yaml`. Defer until
  you actually start a second game. (See also the cross-reference in
  the "A day in the system" section above.)
- **Token-usage backpressure**: if `claude -p` starts returning 429
  (Max weekly cap hit), the agents all silently fail. Could add a
  health check in `tick.sh` that greps recent logs for `429` / `rate
  limit` and auto-touches `.paused` for 24h. Defer until you actually
  hit the cap.
- **Push notifications**: no external alert when MORNING.md changes —
  CEO has to open it. macOS Notification Center via `osascript -e
  'display notification ...'` at 05:05 PT, or an iOS Shortcut watching
  `MORNING.md` via iCloud Drive, are both plausible. Defer until the
  routine feels under-attended.

### Obsolete commands — DO NOT use

If you have old notes from the GH-Actions days, these are all dead now. They
either silently no-op or point at things that don't exist:

```
gh issue list ...           # no issues — WORK.md is the source of truth
gh pr list / pr checkout    # no PRs — overnight merges directly to master
gh run list / run watch     # no Actions — local launchd + claude -p instead
gh workflow run ...         # no workflows
gh pr edit --add-label X    # no labels driving anything
```

Anthropic `/schedule` routines (PM, Designer, Triager, Concierge, Janitor,
Blogger, Asset Librarian, Keepalive :17/:47) — delete them in claude.ai →
Settings → Scheduled tasks; they billed per token, separate from your Max
plan.

---

## Files-of-truth (where to look for X)

| What | Where |
|------|-------|
| Today's CEO routine | `~/GameProjects/<game>/MORNING.md` |
| What's in flight / queued | `~/GameProjects/<game>/WORK.md` |
| What's been shipped | git log + WORK.md `## Shipped *` sections |
| Failed items waiting on you | `~/GameProjects/<game>/.factory/escalations.md` |
| Last test run | `~/GameProjects/<game>/.factory/local-tests-status.json` |
| Reviewer's notes per branch | `~/GameProjects/<game>/.factory/reviews/<branch>.md` |
| Agent run logs | `~/SpraxelAiCompany/logs/<agent>/<ts>.log` |
| Daemon ticks | `~/SpraxelAiCompany/logs/tick/<YYYY-MM-DD>.log` |
| Quick "is anything broken?" | `bash ~/SpraxelAiCompany/scripts/health_check.sh` |
| Schedule config | `~/SpraxelAiCompany/schedule.yaml` |
| Bootstrap a new game | `bash ~/SpraxelAiCompany/scripts/new_game.sh <dir>` |
| Pause + preserve in-flight work | `bash ~/SpraxelAiCompany/scripts/interrupt.sh` |
| Resume after a manual change | `bash ~/SpraxelAiCompany/scripts/resume.sh` |
| Game's design tenets | `~/GameProjects/<game>/Philosophy.md` |
| Feature inventory | `~/GameProjects/<game>/Game.md` |
| WORK.md format spec | `~/SpraxelAiCompany/docs/WORK_MD_FORMAT.md` |
