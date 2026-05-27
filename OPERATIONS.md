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
| **continuous_dev.sh** | Long-running Developer loop. Picks top eligible `## Todo` item (skips `[idea]`/`[cold]`/`[manual]`/`[future]`/`[escalated]`/`[needs-ceo]`/`[concern]`; picks up `[resume]`). Branch → Developer → tests → Reviewer → squash-merge → push. Counts ships against `schedule.yaml#continuous.target_per_batch` (default 10); sleeps when cap hit until any CEO signal (non-bot commit or `bash scripts/checkin.sh`). Failed items: branch preserved on origin, item retagged `[escalated]` in place, rich summary in `.factory/escalations.md`. |

Daily crew (all times America/Los_Angeles):

| Time | Who | What |
|------|-----|------|
| 04:00 PT | **playtester** | Actively plays the game (beyond scripted tests). Writes bug candidates to `.factory/inbox/playtest-findings.md`. Does NOT touch WORK.md directly. |
| 05:00 PT | **triager** | Reads playtest findings + local-tests-status.json, appends `[needs-ceo] [bug]` items to `## Todo`. CEO validates before they become live bugs. |
| 06:00 PT | **morning-briefer** | Writes `.factory/local/MORNING.md` (gitignored — CEO-local artifact). 10 features to play-test with launch + amend + reject one-liners, decisions to make, escalations, time-boxed routine. |
| 06:30 PT | **demo-creator** | Always writes `.factory/demos/<date>/recipe.md` (launch + controls + suggested capture command per recently-shipped feature). Best-effort auto-capture via Godot `--write-movie` + ffmpeg → `.mp4` + `.png`. |
| 07:00 PT | **pm** | Re-sorts top of `## Todo`. Biweekly Monday: tags `v0.N`, generates release notes, rolls WORK.md sections. |
| ~07:00 PT | **CEO (you)** | `/spraxel-inbox` → walk MORNING.md sections. ~38 minutes. |

Weekly:

| Time | Who | What |
|------|-----|------|
| Tue + Fri 07:00 PT | **designer** | Drops 4-6 `[idea]`-tagged items + 0-3 `[concern]` items into `## Todo`. Concerns flag game-wide issues (feature bloat, philosophical drift). |
| Sat 10:00 PT | **blogger** | Drafts `blog/content/posts/draft-<YYYY-MM-DD>-<slug>.md` from the week's `feat:` commits (player-facing filter — skips test/infra/process). Pushes `blog/<date>` branch; CEO humanizes + merges. |
| Sun 02:00 PT | **janitor** | Cold-archives 30+ day stale items, prunes merged `feat/*` branches + 60+ day logs, sweeps orphan `feat/cont-*` branches whose WORK.md item is gone. |
| 1st 08:00 PT | **asset-librarian** | Scans `assets/`, reports orphans + license gaps. |

Every 30 minutes (separately scheduled — `com.spraxel.localtests.plist`):

- **local-tests** — runs Godot GUT + every `scripts/scenarios/*.gd` headlessly. Writes `.factory/local-tests-status.json`. The Triager reads this nightly.

---

## CEO daily routine (the part that matters)

You wake up around 7 AM. Here's the optimal schedule:

### 06:00 AM — System has prepared your day
You're asleep. `morning-briefer` is writing MORNING.md right now.

### 07:00 — 07:38 AM — Morning routine (~38 min)

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
Do nothing. The feature stays on master and rotates out of the play-test list tomorrow.

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

#### 3. ▶ Decide — Designer ideas (5 min)

Designer drops appear in WORK.md `## Todo` with `[idea]` tag. Three actions:

```bash
# ACCEPT an idea  (remove the [idea] tag → eligible for overnight)
python3 $WORKMD promote $WORK "sleeping-gas grenade"

# REJECT an idea  (delete the line entirely)
python3 $WORKMD drop $WORK "radio-tower mission"

# DEFER  (do nothing — [idea] tag stays, overnight keeps skipping)
```

Or just open WORK.md in any editor and:
- Remove `[idea] ` from the start of a line → accept.
- Delete the line (+ its indented details) → reject.
- Leave it alone → defer.

The PM reorder summary in MORNING.md is informational — no action required. To see what PM changed:

```bash
git log -1 --author='pm-bot' -p WORK.md
```

#### 4. ▶ Bug triage (5 min)

Triager appended new `[bug]` items overnight. Actions:

```bash
# BUMP priority   (urgent → p0, or low → p2)
python3 $WORKMD bump $WORK "stairs teleport" p0

# DELETE a duplicate
python3 $WORKMD drop $WORK "duplicate-bug-title-substring"

# KEEP — just leave the line alone; overnight picks it up by priority order.
```

#### 5. ▶ Escalations (3 min)

**What an escalation is**: the wrapper tried to ship an item, failed twice,
and gave up. Two things happen on escalation (post 2026-05-26 redesign):

1. The item **stays in WORK.md `## Todo`** but the `[escalated]` tag is
   added to its title. The wrapper's `top_n` filter skips `[escalated]`,
   so it won't auto-retry until you triage. Failure summary (why, attempt
   timestamps, branch name, last commit) lands as indented detail lines
   under the item.
2. The dev's feature branch is **pushed to origin** (preserved). A rich
   self-contained markdown block is appended to `.factory/escalations.md`
   for history. **Master is never modified** by a failed attempt.

So you triage **inside WORK.md** — you do NOT re-paste items from
escalations.md. Two scans:

```bash
# All escalated items needing triage:
grep '^\[escalated\]' ~/GameProjects/<game>/WORK.md

# Full history with rich context if you want to read:
cat ~/GameProjects/<game>/.factory/escalations.md
```

##### For each `[escalated]` item, three options

**(a) Trash it** — delete the line(s) from WORK.md and save. The next
janitor run will sweep the orphaned branch from origin. Use when the
attempt convinced you the item isn't worth pursuing.

**(b) Resume it** — edit the title/details to tighten the spec, then
flip `[escalated]` → `[resume]`. Wrapper picks it up next overnight,
checks out the saved branch, rebases on master, and hands off to the dev
with full failure context.

```bash
# Either edit WORK.md directly, then change the tag; OR use the CLI:
python3 ~/SpraxelAiCompany/scripts/workmd.py resume $WORK "<title-substring>"
```

**(c) Park it** — replace `[escalated]` with `FUTURE - ` (still on the
roadmap, not now) or `MANUAL - ` (you've decided it's human-only). The
branch stays on origin until janitor sweeps it. The item stays visible
in WORK.md so you remember.

##### What you DON'T do
- **Don't edit `.factory/escalations.md`** — it's append-only history.
  The triage signal is what you do in WORK.md, not what you do here.
- **Don't paste items from escalations.md back into WORK.md** — that's
  the old workflow. They're already there now (with `[escalated]`).
- **Don't `git revert` an escalate commit** — the escalation already
  preserved the branch on origin; rebooting via revert can lose work.

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

### 07:38 AM — 10:00 PM — You go live your life

System is quiet during the day (just `local-tests` every 30 min on master,
silent unless something breaks). You're free to:

- Work on art, music, design, level layout.
- Manually edit WORK.md (CEO can do anything).
- Run individual agents on demand: `bash ~/SpraxelAiCompany/scripts/run_agent.sh <name>`.
- Drop ideas into `.factory/inbox/raw.md` whenever they hit you.

### 10:00 PM — Optional: top up the queue

Before bed, if you want a productive overnight:

```bash
# Sanity check WORK.md has enough items at the top
python3 ~/SpraxelAiCompany/scripts/workmd.py top ~/GameProjects/<game>/WORK.md -n 12

# Drain any dictation you've accumulated today
# (in Claude Code) /spraxel-producer
```

### 11:00 PM — Continuous loop keeps shipping

You're asleep. `continuous_dev.sh` ships until the 10-item cap, then sleeps.

---

## CEO weekly schedule (extras on top of the daily routine)

Most days look like the daily routine above. A few days have additions:

### Tuesday + Friday — Designer days

After Designer fires at 07:00 PT, MORNING.md's **Decide** section will
have 4–6 fresh ranked ideas. Expect the Decide step to take **+5 min**
on these days as you accept / reject / amend each.

### Saturday — Blogger day (+10 min)

Blogger fires at 10:00 PT Saturday. It **always pushes a `blog/<YYYY-MM-DD>` branch**
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

Janitor fires at 02:00 PT Sunday. No CEO action required — but the
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

Asset Librarian fires at 08:00 PT on the 1st of each month. Adds a
"Asset Librarian" line to MORNING.md with orphan count + license gaps.
Address the license gaps when they appear (~5 min).

---

## Setup — adding a new game

If you're starting a fresh game and want to wire it into the Spraxel
factory, the bootstrap is one script + a few config edits:

```bash
# 1. Create the game repo (or use an existing one)
mkdir ~/GameProjects/my-new-game && cd ~/GameProjects/my-new-game
git init

# 2. Apply the Spraxel framework template
bash ~/SpraxelAiCompany/scripts/new_game.sh ~/GameProjects/my-new-game \
  --name "My New Game" --ceo your-github-login

# This drops in:
#   Philosophy.md           ← edit run_mode, dev.godot_binary, must_include
#   Game.md                 ← feature inventory; bots append blocks here
#   WORK.md                 ← work tracking (3 sections, 2 dashed-line dividers)
#   .gitignore              ← Godot cache, .uid files, etc.
#   .factory/               ← runtime state dirs
#   scripts/install_local_tests.sh
#   scripts/run_local_tests.sh      ← full GUT + scenarios + status JSON
#   scripts/run_unit_tests.sh       ← fast unit-test only runner
#   test/unit/.gitkeep              ← Developer agent puts GUT tests here
#   scripts/scenarios/.gitkeep      ← Developer agent puts scenario tests here

# 3. Edit Philosophy.md: set the godot binary path
$EDITOR ~/GameProjects/my-new-game/Philosophy.md
# Change:  dev.godot_binary: "/Users/.../Godot.app/Contents/MacOS/Godot"
# Confirm: run_mode: "live"
```

Then wire the framework's daemon to point at this game:

```bash
# 4. Tell the daemon which game to target
$EDITOR ~/SpraxelAiCompany/schedule.yaml
# Change:  game_dir: ~/GameProjects/my-new-game

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
second daemon — that's not yet supported. See TODO.md.

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
this as **step 1** every day at 06:00 PT — the result appears at the top
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

# Reject / delete entirely (Designer idea, duplicate bug, anything)
python3 $WORKMD drop $WORK "radio-tower mission"

# Change a priority
python3 $WORKMD bump $WORK "stairs teleport" p0

# Push to escalations (out of rotation, kept for history)
python3 $WORKMD escalate $WORK "<title>" --log "(manual)"
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
| `[idea]` | Designer drop, CEO triage needed | **NO** (must remove tag first) |
| `[cold]` | Janitor archived as stale | **NO** (must remove tag first) |
| `[manual]` or `MANUAL - ` prefix | CEO-only — needs human hands (controller test, art, music, level design) | **NO** (skip until tag/prefix removed) |
| `[needs-ceo]` | Developer added clarifying questions — CEO must answer | **NO** (skip until questions answered + tag removed) |
| `[future]` or `FUTURE - ` prefix | Roadmap item — not ready to schedule (needs scoping, blocked, or deliberately deferred) | **NO** (skip until tag/prefix removed) |
| `[escalated]` | Wrapper tried 2x, failed. Saved branch on origin (see `branch:` detail line). CEO triages: trash / resume / park. | **NO** (skip until CEO retags as `[resume]` or other) |
| `[resume]` | CEO triaged an escalation. Wrapper picks it up, checks out saved branch, rebases on master, hands off to dev with full failure context. | **yes** (dev resumes from saved branch instead of fresh) |
| `[concern]` | Designer (or future agents) flagged a game-wide issue (feature bloat, missing fundamentals, philosophical drift). Advisory text, not work to do. CEO triages: delete (dismiss), remove tag (convert into real work item), or leave (defer). | **NO** (skip until tag removed) |

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
| **playtester** | daily 04:00 PT | sonnet | Actively plays the game to find problems. Beyond test scenarios — input spam, edge cases, mechanic combos. Writes candidates to `.factory/inbox/playtest-findings.md`. Does NOT touch WORK.md directly. |
| **triager** | daily 05:00 PT | haiku | Reads playtest findings + test failures, appends as `[needs-ceo] [bug]` items. CEO validates in MORNING.md before they become live bugs. |
| **morning-briefer** | daily 06:00 PT | haiku | Writes `.factory/local/MORNING.md` (gitignored — never commit). 10 features to play-test with launch + amend + reject one-liners, decisions to make, escalations. Runs `health_check.sh` first to surface agent failures. |
| **demo-creator** | daily 06:30 PT | sonnet | ALWAYS writes `.factory/demos/<date>/recipe.md` with per-feature launch + controls + capture commands. BEST-EFFORT auto-captures `.mp4` + `.png` via Godot `--write-movie` + ffmpeg (no Screen Recording permission needed; still requires Mac awake + ffmpeg installed). Blogger reads recipe.md as source of truth. |
| **pm** | daily 07:00 PT + biweekly Mon release-cut | haiku | Reorders ## Todo. On release day: tags `v0.N`, generates release notes, rolls WORK.md sections. |
| **designer** | Tue + Fri 07:00 PT | sonnet | Reads Philosophy + memory + inspiration. Drops 4-6 ranked `[idea]` items + 0-3 `[concern]` items (game-wide issue flags: feature bloat, missing fundamentals, philosophical drift). |
| **blogger** | weekly Sat 10:00 PT | sonnet | Drafts devlog from week's `feat:` commits ONLY (strict player-facing filter — skips fix(test):/chore:/refactor:/docs:/test:/work:/escalate:/ceo:). Writes `blog/content/posts/draft-<date>-<slug>.md` with `▸ MEDIA` placeholders. Pushes `blog/<date>` branch; CEO humanizes + merges. |
| **janitor** | weekly Sun 02:00 PT | haiku | Cold-archives 30+ day stale items, prunes merged branches, prunes 60+ day logs. Sweeps orphan `feat/cont-*` branches whose WORK.md item is gone (escalated-branch cleanup). |
| **asset-librarian** | monthly 1st 08:00 PT | haiku | Scans assets/, reports orphans + license gaps. |
| **producer** | on-demand (`/spraxel-producer`) | sonnet | Converts CEO dictation → clean WORK.md items. Flags ⚠️ concerns inline (cliché/complexity/balance/drift) but always appends the item — concerns are advisory, never gatekeep. |

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
| **`workmd.py`** | Parser + CLI for WORK.md. Subcommands: `parse / top / append / ship / escalate / resume / promote / drop / bump / clarify / release-cut`. Atomic mkdir-locked. | every agent + CEO |
| **`cron_match.py`** | Evaluates a 5-field cron expression against `now` in a timezone. Used by `tick.sh` to decide who fires and by `spraxel_report.py` to compute next firings. | `tick.sh`, `spraxel_report.py` |
| **`slugify.py`** | Title → kebab-case branch slug. | `continuous_dev.sh` for branch names |
| **`health_check.sh`** | Scans today's `logs/*/<YYYY-MM-DD>*.log` for error patterns (unknown model, rate limit, session expired, fatal, traceback). Outputs a markdown block. | `morning-briefer` agent (step 1), CEO manually |
| **`spraxel_report.py`** | Status snapshot generator: right-now state, last 24h, last 7 days, next 20 scheduled events. Pure-local read-only — no Claude tokens. Powers `/spraxel-report`. | CEO via `/spraxel-report` skill or directly |
| **`token_report.sh`** | Counts `claude -p` invocations per agent over a window. Compares to `Philosophy.budgets.by_agent_percent`. Flags drift >25%. | CEO manually (weekly check); not yet scheduled |
| **`capture_demo.sh <slug>`** | Records a Godot --demo-feature run via Godot's built-in Movie Maker (`--write-movie`) + ffmpeg encoding to H.264 .mp4 + extracts a .png still at 3s. No Screen Recording permission needed (engine framebuffer, not screen pixels). Requires ffmpeg on PATH; exits rc=3 if missing. Exits rc=5 with warning if recording is suspiciously short (test-style scenarios that auto-quit). | `demo-creator` agent |
| **`backfill_escalations.py`** | One-shot migration. Reads pre-redesign `.factory/escalations.md` entries (terse with log-link format), restores items to WORK.md as `[escalated]`, rewrites escalations.md with the new self-contained per-block format. Idempotent. | CEO, one-time per game repo |
| **`checkin.sh`** | Explicit CEO signal — touches `.cache/ceo-checkin.ts`. `continuous_dev.sh` polls this and resets the counter on detection. | CEO manually when read-only interaction wasn't enough |
| **`amend.sh <slug-or-sha> "feedback"`** | CEO keeps a shipped feature but queues a refinement pass. Appends `[amend] Refine: <title>` to WORK.md `## Todo` with sha + feedback. Master untouched — Developer iterates on existing code next overnight. | CEO during play-test |
| **`reject.sh <slug-or-sha> "reason"`** | CEO undoes a shipped feature. `git revert` the `feat:` + paired `work: shipped` commits on master, appends `[reject] Re-implement: <title>` to WORK.md `## Todo` with sha + reason. Developer re-implements next overnight, knowing the old approach was wrong. | CEO during play-test |
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
| **triager** | haiku | daily 05:00 PT | `tick.sh` cron | WORK.md `## Todo` (appends `[bug]` items) |
| **morning-briefer** | haiku | daily 06:00 PT | `tick.sh` cron | `MORNING.md` |
| **pm** | haiku | daily 07:00 PT | `tick.sh` cron | WORK.md `## Todo` (re-orders) |
| **designer** | sonnet | Tue + Fri 07:00 PT | `tick.sh` cron | WORK.md `## Todo` (appends `[idea]` items) |
| **blogger** | sonnet | Sat 10:00 PT | `tick.sh` cron | `blog/<date>` branch |
| **janitor** | haiku | Sun 02:00 PT | `tick.sh` cron | WORK.md (cold-archives), branches (deletes merged), logs (prunes >60 days) |
| **asset-librarian** | haiku | monthly 1st 08:00 PT | `tick.sh` cron | `.factory/asset-report-<date>.md`, MORNING.md note |
| **producer** | sonnet | on-demand (`/spraxel-producer`) | CEO via skill | WORK.md `## Todo` (from `.factory/inbox/raw.md`) |
| **demo-creator** | sonnet | daily 06:30 PT | `tick.sh` cron | `.factory/demos/<date>/recipe.md` (always) + best-effort `.mp4`+`.png` (when Mac awake + ffmpeg installed) |

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
