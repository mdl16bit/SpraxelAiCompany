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

Daily cycle (all times America/Los_Angeles):

| Time | Who | What |
|------|-----|------|
| 23:00 PT | **overnight_dev.sh** | Loop: pick top of `## Todo` → Developer → tests → Reviewer → merge → push. Stops at 10 features OR 06:00 PT. Failed items → `.factory/escalations.md`. |
| 05:00 PT | **triager** | Reads overnight test failures, appends `[bug]` items to `## Todo`. |
| 06:00 PT | **morning-briefer** | Writes `MORNING.md` with: 10 features to play-test, Designer `[idea]` items, new bugs, escalations, time-boxed routine. |
| 07:00 PT | **pm** | Re-sorts top of `## Todo` so the next overnight loop ships the right things. |
| ~07:00 PT | **CEO (you)** | Open `MORNING.md`. Walk the time-boxed sections. ~38 minutes. |

Weekly:

| Time | Who | What |
|------|-----|------|
| Fri 07:00 PT | **designer** | Drops 4-6 `[idea]`-tagged items into `## Todo` for CEO triage. |
| Sat 10:00 PT | **blogger** | Drafts `blog/<YYYY-MM-DD>.md` from the week's commits. Pushes branch; CEO merges manually. |
| Sun 02:00 PT | **janitor** | Cold-archives stale items (30+ days), deletes merged branches, prunes old logs. |
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
cd ~/GameProjects/infiltrators
cat MORNING.md
```

In Claude Code, type `/inbox` to open the walk-through skill (read-only view of MORNING.md).

Walk the sections **in order** — here's what each step actually means in commands:

```bash
WORK=~/GameProjects/infiltrators/WORK.md
WORKMD=~/SpraxelAiCompany/scripts/workmd.py
```

#### 1. ▶ Overnight result (1 min)

Glance at the commit range in MORNING.md. Any surprises? Drill in:

```bash
cd ~/GameProjects/infiltrators
git log master --since="yesterday 22:00 PT" --oneline
git show <sha>           # if anything looks weird
```

#### 2. ▶ Play-test (20 min)

For each of the 10 features in MORNING.md, run the listed launch command:

```bash
cd ~/GameProjects/infiltrators
godot --demo-feature=<slug>
```

Spend 1–2 min per feature verifying the "Look for" line. Mentally tick ✓ or ✗.
Jot fix notes for ✗ — they become Dictation step input.

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

```bash
cat ~/GameProjects/infiltrators/.factory/escalations.md
```

For each entry, **one** of:

```bash
# RESURRECT with clarifying details — addresses the Developer's blocker
python3 $WORKMD append $WORK --section todo \
  "[feature] p1 skill tree system" \
  --detail "scope clarified: SCAFFOLDING only (data structure + 5 example" \
  --detail "skills + UI). Full 300-skill list comes later."

# RESURRECT as-is — Developer was just having a bad night
python3 $WORKMD append $WORK --section todo "[feature] p1 <title>"

# LET IT DIE — do nothing. Item stays out of rotation.
```

`escalations.md` is append-only history. Don't edit it — just read and decide.

#### 6. ▶ Dictation (5 min, optional)

Anything new from play-testing or stray thoughts:

```bash
echo "the run sound should be QUIETER for ducked-walking" \
  >> ~/GameProjects/infiltrators/.factory/inbox/raw.md
echo "extraction zone bug back — character #3 stuck after extracting" \
  >> ~/GameProjects/infiltrators/.factory/inbox/raw.md
```

Then in Claude Code, run the producer skill to convert them:

```
/spraxel-producer
```

It reads `.factory/inbox/raw.md` (and any dictation files), classifies each note (`[bug]` / `[feature]` / `[game-feature]`), assigns priority, appends to WORK.md `## Todo`, commits.

#### 7. Commit your morning edits

Your Decide/Triage/Escalations edits aren't pushed yet. Either commit yourself, or let the next agent run sweep them up naturally (PM/Janitor pick up changes on their next commit):

```bash
cd ~/GameProjects/infiltrators
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
python3 ~/SpraxelAiCompany/scripts/workmd.py top ~/GameProjects/infiltrators/WORK.md -n 12

# Drain any dictation you've accumulated today
# (in Claude Code) /spraxel-producer
```

### 11:00 PM — Overnight kicks off

You're asleep. `overnight_dev.sh` is shipping features.

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

## Setup — first time on this Mac (existing infiltrators game)

If you're setting up Spraxel for the first time on a Mac and the game
repo (infiltrators) is already cloned:

```bash
bash ~/SpraxelAiCompany/scripts/install_daemon.sh
cd ~/GameProjects/infiltrators && bash scripts/install_local_tests.sh
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

### Manually run the overnight loop now

```bash
bash ~/SpraxelAiCompany/scripts/overnight_dev.sh
```

It'll hard-stop at 06:00 PT — useful for a one-off mid-day burst if you've
got dictation backed up.

### Pause everything

```bash
touch ~/SpraxelAiCompany/.paused
```

The daemon keeps ticking but `tick.sh` and `run_agent.sh` and
`overnight_dev.sh` all check this flag and exit silently. Resume with:

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
2. SIGTERM all `overnight_dev.sh / run_agent.sh / claude -p` processes
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
WORK=~/GameProjects/infiltrators/WORK.md
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
Just don't edit while the overnight loop is running (use `.paused`).

### Make a manual code change

No PR ceremony in this workflow. Branch, edit, merge yourself:

```bash
cd ~/GameProjects/infiltrators

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
cd ~/GameProjects/infiltrators

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
  >> ~/GameProjects/infiltrators/.factory/inbox/raw.md
echo "extraction zone bug back — character #3 stuck" \
  >> ~/GameProjects/infiltrators/.factory/inbox/raw.md

# Then in Claude Code:
# /spraxel-producer
# → reads raw.md, classifies each note ([bug]/[feature]/[game-feature]),
#   assigns priority, appends to WORK.md ## Todo, commits.
```

### Quick one-liners

```bash
# "What's next?"
python3 ~/SpraxelAiCompany/scripts/workmd.py top \
  ~/GameProjects/infiltrators/WORK.md -n 5

# "What shipped this week?"
git -C ~/GameProjects/infiltrators log master --since='1 week ago' \
  --oneline --grep='^feat:'

# "What did the agents commit lately?"
git -C ~/GameProjects/infiltrators log master --author='-bot@spraxel.ai' \
  --since='1 week ago' --pretty='%h %an %s'

# "Anything stuck?"
ls ~/SpraxelAiCompany/.locks/  # each lockdir = an in-flight agent

# "Revert something the overnight loop landed but broke things"
cd ~/GameProjects/infiltrators
git revert <sha> && git push origin master
```

### Uninstall

```bash
bash ~/SpraxelAiCompany/scripts/install_daemon.sh stop
cd ~/GameProjects/infiltrators && bash scripts/install_local_tests.sh stop
```

---

## WORK.md cheat sheet

Three sections separated by two dividers (10+ `-` or `=`):

```
# infiltrators — work tracking

## Shipped (previous releases)
v0.3 — pushing mechanic
v0.2 — character switch lock-out
----------
## Shipped since last release         ← overnight loop appends here (chronological)
[game-feature] p1 Run button + stamina bar
[bug] p0 Stairs teleport fixed
==========
## Todo                               ← overnight loop picks from top
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
| `[manual]` or `MANUAL - ` prefix | CEO-only — needs human hands (controller test, art, music) | **NO** (skip until tag/prefix removed) |
| `[needs-ceo]` | Developer added clarifying questions — CEO must answer | **NO** (skip until questions answered + tag removed) |

---

## The agent roster

| Agent | Cadence | Model | What it does |
|-------|---------|-------|--------------|
| **overnight_dev** | nightly 23:00 → 06:00 PT | n/a (shell) | Loops up to 10 features. Branches → Developer → tests → Reviewer → merge. |
| **developer** | called by overnight | sonnet | Implements one WORK.md item end-to-end on a feature branch. **Always adds a GUT test under `test/unit/` and runs `bash scripts/run_local_tests.sh` before committing.** No test = the commit is not done. |
| **reviewer** | called by overnight | haiku | Reads `git diff master...HEAD`, writes findings, exits 0 (clean) or 1 (blocking). |
| **triager** | daily 05:00 PT | haiku | Reads overnight test failures, dedupes, appends `[bug]` items to ## Todo. |
| **morning-briefer** | daily 06:00 PT | haiku | Writes MORNING.md — runs `health_check.sh` first, then 10 features to play-test, decisions to make, escalations. |
| **pm** | daily 07:00 PT | haiku | Reorders top of ## Todo by priority and bug/feature balance. |
| **designer** | weekly Fri 07:00 PT | sonnet | Proposes 4-6 `[idea]`-tagged items for CEO triage. |
| **blogger** | weekly Sat 10:00 PT | sonnet | Drafts devlog from week's commits, pushes `blog/<date>` branch. |
| **janitor** | weekly Sun 02:00 PT | haiku | Cold-archives 30+ day stale items, prunes branches + logs. |
| **asset-librarian** | monthly 1st 08:00 PT | haiku | Scans assets/, reports orphans + license gaps. |
| **producer** | on-demand (`/spraxel-producer`) | sonnet | Converts CEO dictation → clean WORK.md items. |
| **demo-creator** | (stub — deferred) | — | "Video taker" — recording feature demos. Not yet implemented. |

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
| **`workmd.py`** | Parser + CLI for WORK.md. Subcommands: `parse / top / append / ship / escalate / promote / drop / bump / clarify`. Atomic mkdir-locked. | every agent + CEO |
| **`cron_match.py`** | Evaluates a 5-field cron expression against `now` in a timezone. Used by `tick.sh` to decide who fires. | `tick.sh` |
| **`slugify.py`** | Title → kebab-case branch slug. | `continuous_dev.sh` for branch names |
| **`health_check.sh`** | Scans today's `logs/*/<YYYY-MM-DD>*.log` for error patterns (unknown model, rate limit, session expired, fatal, traceback). Outputs a markdown block. | `morning-briefer` agent (step 1), CEO manually |
| **`checkin.sh`** | Explicit CEO signal — touches `.cache/ceo-checkin.ts`. `continuous_dev.sh` polls this and resets the counter on detection. | CEO manually when read-only interaction wasn't enough |
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
| **demo-creator** | (stub) | not yet implemented | — | — |

### Skills (`~/SpraxelAiCompany/skills/`)

| Skill | Trigger | Purpose |
|-------|---------|---------|
| **`/spraxel-inbox`** (or `/inbox`) | CEO types in Claude Code | Walks the morning routine: opens MORNING.md, surfaces sections in order, quick commands |
| **`/spraxel-producer`** (or `/producer`) | CEO types in Claude Code | Converts `.factory/inbox/raw.md` + dictation files into clean WORK.md items |

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
cat ~/GameProjects/infiltrators/.factory/escalations.md | tail -40
```

If `fail_streak: 3` appears in `~/SpraxelAiCompany/.cache/last-overnight.txt`,
the Claude CLI hit 3 consecutive failures (likely rate limit or session
expiry). Re-auth and re-run.

### "I committed code at midnight and now overnight fails to push"

The overnight loop fetches and rebases at start, but if you committed
between its fetch and its push, the push fails. Easy fix: run a quick
manual rebase next morning, or just wait — the next night picks up where
it left off.

### "WORK.md got corrupted by two agents writing at once"

`workmd.py` uses an atomic mkdir-lock, so this shouldn't happen between
agents. But manual `vim WORK.md` while an agent is mid-write **can**
corrupt the file. Recovery:

```bash
cd ~/GameProjects/infiltrators
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
| Mac electricity | Marginal — overnight loop adds ~10-30 min of CPU per night. |

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
  exits 1 often and the overnight loop escalates everything. CEO has to
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
| Today's CEO routine | `~/GameProjects/infiltrators/MORNING.md` |
| What's in flight / queued | `~/GameProjects/infiltrators/WORK.md` |
| What's been shipped | git log + WORK.md `## Shipped *` sections |
| Failed items waiting on you | `~/GameProjects/infiltrators/.factory/escalations.md` |
| Last test run | `~/GameProjects/infiltrators/.factory/local-tests-status.json` |
| Reviewer's notes per branch | `~/GameProjects/infiltrators/.factory/reviews/<branch>.md` |
| Agent run logs | `~/SpraxelAiCompany/logs/<agent>/<ts>.log` |
| Daemon ticks | `~/SpraxelAiCompany/logs/tick/<YYYY-MM-DD>.log` |
| Quick "is anything broken?" | `bash ~/SpraxelAiCompany/scripts/health_check.sh` |
| Schedule config | `~/SpraxelAiCompany/schedule.yaml` |
| Bootstrap a new game | `bash ~/SpraxelAiCompany/scripts/new_game.sh <dir>` |
| Pause + preserve in-flight work | `bash ~/SpraxelAiCompany/scripts/interrupt.sh` |
| Resume after a manual change | `bash ~/SpraxelAiCompany/scripts/resume.sh` |
| Game's design tenets | `~/GameProjects/infiltrators/Philosophy.md` |
| Feature inventory | `~/GameProjects/infiltrators/Game.md` |
| WORK.md format spec | `~/SpraxelAiCompany/docs/WORK_MD_FORMAT.md` |
