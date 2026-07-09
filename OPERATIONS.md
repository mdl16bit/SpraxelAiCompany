# Operations — the Spraxel instruction manual

How to drive the offline Spraxel factory. Read this front to back and you
know everything you have to do: Part I the mental model, Part II blank Mac
→ running factory, Part III your daily job, Part IV the machinery, Part V
extending it, Part VI troubleshooting + every reference table.

> **Edition note.** Content refreshed 2026-07-08; restructured into six
> parts 2026-07-09. New this week: **TASTE.md** wired into
> Designer/Architect, **per-item cost accounting** (`item_cost.py` + 💸),
> shared **`ship_lib.sh`**, **awake-band** crons + `ceo_routine` JST
> columns, **ART_BRIEF.md** + the ASSETS.md license ledger, and the
> delegate-all **jam runbook**. The June→July deltas (always-on dev loop,
> interactive-developer mode, config consolidation, multi-game, WORK.md
> 4-section layout, Game.md index, crew-health monitor — `7d0edeb`) are
> reflected throughout.

> ⚠️ **Update discipline — this manual stays true or it dies.**
> 1. **Same commit.** Any commit/PR that changes behavior documented here
>    updates this manual **in the same commit**. "I'll document it later"
>    is how handbooks rot.
> 2. **Monthly rot check.** The 1st-of-month Asset Librarian slot doubles
>    as the manual rot check: grep this file for referenced scripts/paths
>    that no longer exist; file a `[chore]` per hit.

## Table of contents

**[Part I — What this is](#part-i--what-this-is)** — [Mental model](#mental-model) · [The system in one picture](#the-system-in-one-picture) · [A day in the system](#a-day-in-the-system) · [The money model](#the-money-model)

**[Part II — Start here: zero to running](#part-ii--start-here-zero-to-running)** — [What you need](#what-you-need) · [1 Clone](#step-1--clone-the-two-repos) · [2 Daemon](#step-2--install-the-daemon) · [3 Skills](#step-3--install-the-skills) · [4 Git auth](#step-4--git-auth-that-survives-sleep) · [5 macOS permissions](#step-5--macos-permissions) · [6 First game](#step-6--your-first-game) · [7 Verify](#step-7--verify-everything)

**[Part III — Operating it daily](#part-iii--operating-it-daily)** — [CEO daily routine](#ceo-daily-routine-the-part-that-matters) · [Morning](#the-morning-visit--full-triage-0615) · [Afternoon](#the-afternoon-visit--quick-unblock-1300) · [Evening](#the-evening-visit--top-up-2200) · [Weekly extras](#ceo-weekly-schedule-extras-on-top-of-the-daily-routine) · [Shaping loop / TRIAGE.md](#the-shaping-loop--architect--triagemd) · [Adding work by hand](#adding-new-work-by-hand--the-untriaged-rule) · [Running dev batches](#running-dev-batches--spraxel-develop)

**[Part IV — The machinery](#part-iv--the-machinery)** — [The two developer modes](#the-two-developer-modes) · [Reviewer findings](#reviewer-findings--factoryreviewsslugmd) · [WORK.md cheat sheet](#workmd-cheat-sheet) · [Testing](#testing--the-batch-test-runner--test_failure) · [Subtasks & epics](#subtasks--epics) · [manual labels](#manual-sub-category-labels) · [future items](#future-parked-roadmap-items) · [The agent roster](#the-agent-roster) · [Schedules](#setting-up--changing-schedules) · [Monitoring & crew health](#monitoring--crew-health)

**[Part V — Extending it](#part-v--extending-it)** — [New game](#setup--adding-a-new-game) · [Game-code contract](#the-game-code-contract) · [TASTE.md](#tastemd--the-ceo-taste-profile) · [Art + licensing](#art-production--art_briefmd-and-the-assetsmd-license-ledger) · [itch channel](#the-itchio-channel--builds-ship-themselves) · [Jam mode](#jam-mode--the-delegate-all-experiment) · [Agent specs](#writing-and-changing-agent-specs)

**[Part VI — Troubleshooting + reference](#part-vi--troubleshooting--reference)** — [Troubleshooting](#troubleshooting) · [Risks](#risks) · [Common operations](#common-operations) · [Configuration reference](#configuration-reference) · [Scripts, agents, skills, state](#reference-scripts-agents-processes) · [What we deliberately don't do](#what-im-not-doing-in-this-workflow) · [Files-of-truth](#files-of-truth-where-to-look-for-x)

---

# Part I — What this is

You are the CEO of a one-human game company. This part is orientation — the
mental model, the cast, the daily rhythm, and where the money goes.

## Mental model

You are the **CEO**. You don't write code, run CI, or push feature commits.
You **dictate**, **play-test**, **promote ideas**, **escalate decisions**.
A roster of Claude agents handles the rest, running locally on your Mac.

State lives in **`WORK.md`** at the game repo root — the single source of
truth for everything in flight. Everything else is derivable from WORK.md +
git log.

There are no GitHub Issues. There are no GitHub Actions. There are no
Anthropic `/schedule` routines. There is one local daemon (`launchd`),
one config file (`COMPANY_CONFIG.yaml`, plus a per-game `GAME_CONFIG.yaml`
overlay — `schedule.yaml` survives only as a back-compat symlink), and one
CLI (`claude`). **Cost note (post-2026-06-15 billing split):** interactive
Claude Code sessions stay on your subscription, but headless `claude -p`
runs are **metered** API-credit spend. That's why dev work currently runs
in interactive-developer mode (see "The two developer modes") and why
`policy.budgets.daily_run_cap` (250) auto-pauses a runaway day.

## The system in one picture

```
+---------------------------------------------------------------+
|  launchd  (com.spraxel.tick.plist, every 60s)                 |
|         |                                                     |
|         v                                                     |
|  scripts/tick.sh                                              |
|  reads COMPANY_CONFIG.yaml (+ per-game GAME_CONFIG.yaml via   |
|  spx_config.py); iterates the games: registry; per game:      |
|  fires due crew agents, monitors crew health hourly, and      |
|  keeps the dev loop alive (headless mode) or spawns NO        |
|  workers (interactive mode — the default right now)           |
+-------+--------------------------+----------------------------+
        |                          |
        v                          v
run_agent.sh               dev work, one of two modes:
(crew: PM, Triager,        A) continuous_dev.sh workers
 Designer, Architect,         (headless claude -p, METERED)
 Playtester, Janitor,      B) /spraxel-develop in YOUR
 Blogger, Asset, Demo,        Claude Code session
 Morning Briefer)             (subscription-side) ← ACTIVE
        |                          |
        +---- claude ---------------+
                  |     both ship until target_per_batch (8)
                  v     since the last CEO signal, then park
        WORK.md / Game.md index + docs/features/ / commits
                  |
                  v
        git push origin master   <-- only network egress
```

## A day in the system

**Ship loop** (always on, paced by CEO interaction — no clock time):

| Who | What |
|-----|------|
| **the ship loop** (continuous_dev.sh workers, or `/spraxel-develop` in interactive mode — see "The two developer modes") | Long-running Developer loop. In headless mode it **runs as N parallel workers** (one process per worker id; default `dev_concurrency: 3` — see `COMPANY_CONFIG.yaml`), each with its own persistent worktree at `.worktrees/<slug>/worker-<id>/`; in interactive mode (**currently active**) a single `/spraxel-develop` session works in `.worktrees/<slug>/interactive`. Items are atomically claimed via `workmd.py claim --worker-id N` (tags the item `[wip:N]` so other claimants skip it). Picks top eligible up-and-coming item (skips `[idea]`/`[cold]`/`[manual]`/`[future]`/`[escalated]`/`[needs-ceo]`/`[concern]`/`[wip:*]`/`[untriaged]`/`[untriaged-proposal-active]`; picks up `[resume]` and `[retry]`). Branch → Developer → Reviewer → squash-merge → push. **Cap counter is SHARED**: **8** ships (`target_per_batch`) across all workers combined drains the batch. Merges serialize via the namespaced master-push lock (~1 s critical section). Failed items (tests/reviewer/merge): branch preserved on origin, item retagged **`[retry]`** in place with failure feedback in details — next dev fire picks them up silently (after `retry_escalate_threshold` (5) total attempts the poison-pill brake auto-escalates instead). Does NOT escalate to CEO for dev-fixable failures. Runs `workmd.py sync-escalations` each iter so `.factory/escalations.md` always reflects current `[escalated]` items. |

Daily crew (all times America/Los_Angeles):

| Time | Who | What |
|------|-----|------|
| 03:00 PT | **playtester** | Actively plays the game (beyond scripted tests). Runs an environment pre-flight first, then **classifies each finding `gameplay` / `harness` / `environment`** (only gameplay findings are bug candidates) and emits **hands-on test recipes** for the CEO. Writes to `.factory/inbox/playtest-findings.md`. Does NOT touch WORK.md directly. |
| 04:00 PT | **triager** | Reads playtest findings + local-tests-status.json, appends `[needs-ceo] [bug]` items to `## Up-and-coming work`. CEO validates before they become live bugs. |
| 05:00 PT | **morning-briefer** | Writes `.factory/local/MORNING.md` (gitignored — CEO-local artifact). Its 📰 News section **opens with a mandatory 🩺 crew-health line** (from `state/<slug>/cache/crew-health.txt`). 10 features to play-test with launch + amend + reject one-liners, decisions to make, escalations, time-boxed routine. |
| 05:30 PT | **demo-creator** | Writes `.factory/demos/<date>/recipe.md` with FULL recipes for the **top 3** recently-shipped features only (the rest get a one-line "also shipped" list). Auto-captures only **capture-ready demo scenarios** via Godot `--write-movie` + ffmpeg → `.mp4` + `.png`; test-style auto-quit scenarios hit the rc=5 skip ledger instead of being retried forever. |
| 06:00 PT | **pm** | Re-sorts the up-and-coming section. Release cuts fire on the **calendar** (`cadence.release` — biweekly; currently Saturdays for infiltrators) **or the size trigger, same day** (finished section ≥40 items or WORK.md >150KB): tags `v0.N`, generates release notes, `workmd.py release-cut` externalizes the finished section to `WORK_v<version>.md`. |
| ~06:00 PT | **CEO (you)** | `/spraxel-inbox` → walk MORNING.md sections. ~38 minutes. |
| 06:30 & 21:00 PT | **architect** | Shapes `[untriaged]` work: processes your answered `TRIAGE.md` questionnaires (finalize spec or follow-up), intakes new untriaged items (fast-pass or new questionnaire). Also fires reactively within ~60s of a new `[untriaged]` item. |

Weekly:

| Time | Who | What |
|------|-----|------|
| Tue + Fri 04:30 PT | **designer** | Drops 4-6 `[idea]`-tagged items + 0-3 `[concern]` items into `## Up-and-coming work`. Concerns flag game-wide issues (feature bloat, philosophical drift). |
| Tue + Fri 06:45 PT | **blogger** | Cron fires Tue+Fri but the cadence is **release-driven, not calendar-filler**: it drafts when a release was cut since the last post (release notes as the post's spine), or after ≥14 days + ≥3 fresh player-facing ships; otherwise it exits cleanly. Drafts `blog/content/posts/draft-<YYYY-MM-DD>-<slug>.md` with **exactly ONE hero media slot** (the lead theme's clip). Pushes `blog/<date>` branch; CEO humanizes + merges. |
| Sun 01:00 PT | **janitor** | Cold-archives 30+ day stale items, prunes merged `feat/*` branches + 60+ day logs, sweeps orphan `feat/cont-*` branches whose WORK.md item is gone. |
| 1st 07:00 PT | **asset-librarian** | Scans `assets/`, reports orphans + license gaps. |

Testing (no longer a 30-min cron — see "Testing" below):

- **batch test runner** (`test_runner.sh`) — dispatched by `tick.sh` when the
  ship cap maxes out + workers drain, or after 100h of engine on-time. Runs the
  whole suite serially and files failures as `[test_failure]` items. The old
  `com.spraxel.localtests` 30-min daemon is retired.

## The money model

**The 2026-06-15 billing split changed this section fundamentally**: headless
`claude -p` runs now bill as **metered API credits**, while interactive
Claude Code sessions stay on the flat subscription. The cost lever is
therefore *where* work runs — which is why dev work (the token-heavy part)
runs in interactive-developer mode.

| Resource | Cost |
|----------|------|
| Interactive sessions (`/spraxel-develop` dev+review subagents, your CEO sessions) | Flat — included in the Claude subscription. This is where the heavy Sonnet work lives. |
| Headless `claude -p` invocations (scheduled crew agents) | **Metered** — API-credit spend per token since 2026-06-15. The dashboard shows an estimated daily $ via `token_usage.py` + `policy.pricing`. Kept cheap by Haiku-heavy crew assignments + byte-capped prompts. |
| Runaway-day protection | `policy.budgets.daily_run_cap: 250` — `tick.sh` auto-touches `.paused` past that many runs/day. |
| GitHub commits + pushes | $0 — unlimited on free private repos. |
| GitHub Actions | $0 — we don't use them anymore. |
| Anthropic `/schedule` routines | $0 — we don't use them anymore. |
| LFS storage | $0 if you stay under 1 GB total LFS objects. |
| Mac electricity | Marginal — the loop runs claude in bursts, mostly idle between dev calls. |

The **bounded** resources are the subscription's usage caps (Sonnet-cap
detection auto-falls back to Opus via `sonnet_cap.py`) and the metered
credit pool for the crew. See "Risks" below for mitigation.

### Per-item cost accounting — what each ship costs

Since 2026-07-08 (`4124c2d`), every shipped item gets a **cost stamp**:
both dev modes source `scripts/ship_lib.sh`, whose `ship_report` helper
calls `scripts/item_cost.py` over the item's build window — it sums
assistant-message usage from the local `~/.claude/projects/**/*.jsonl`
transcripts and prices it via `policy.pricing` (per-MTok, longest-prefix
model match). Zero Claude tokens. Where you see it: **(1)** the per-ship 📰
News line `- Shipped: <title> (~$0.84 tokens)`; **(2)** the per-game ledger
`state/<slug>/cache/item-costs.tsv` — one tab-separated row per priced ship
(timestamp, cost, title) for trend analysis; **(3)** the morning-briefer's
roll-up in 📰 News: `💸 Batch cost: ~$<sum> across <N> priced ships
(ledger: state/<slug>/cache/item-costs.tsv)` — it never invents costs for
unpriced lines.

```bash
# Ad-hoc window costing (flags: --until, --dir-filter worker-<id>,
# --pool all/api_credit/subscription, --json):
python3 ~/SpraxelAiCompany/scripts/item_cost.py --since "2026-07-09T06:00"
# → $0.84  (in=112k out=9k cache_w=48k cache_r=1.2m)  [pool=all]
```

Attribution: headless workers are clean (`--dir-filter worker-<id>` scopes
to that worker's worktree transcripts); interactive `/spraxel-develop`
items bill inside YOUR session transcript, so the window is an
approximation. **Cost is decoration, never a gate** — a failed estimate
prints nothing, blocks nothing. Account-wide spend is the other lens:
`python3 scripts/token_usage.py` reports subscription (week) vs api_credit
(month) pools against `policy.budgets.monthly_usd_hard_cap` (250,
informational); the dashboard renders that split but does NOT read
item-costs.tsv.

---

# Part II — Start here: zero to running

A blank Mac to a running factory in seven steps (~30 minutes, plus one
onboarding interview for your first game). Every step ends with a
verification — don't move on until it passes. Machine already running?
Skim steps 4-5 anyway: they're the two setup gotchas that bite LATER.

## What you need

| Prerequisite | Check | Notes |
|---|---|---|
| macOS, you logged in | — | the scheduler is `launchd`; agents only run while the Mac is awake |
| Claude Code CLI, logged in | `claude --version` | re-auth via `claude login` inside a Claude Code window |
| git + private GitHub repos | `git --version` | `git push origin master` is the system's only network egress |
| `gh` CLI, authenticated | `gh auth status` | step 4's credential fix (+ `gh repo create` for new games) |
| python3 | `python3 --version` | every framework script (`spx_config.py`, `workmd.py`, dashboards) |
| Godot binary *(Godot games)* | launch it once | absolute path goes in `GAME_CONFIG.yaml` → `dev.godot_binary` |
| ffmpeg *(optional)* | `ffmpeg -version` | demo auto-capture; without it demo-creator still writes recipes |

## Step 1 — clone the two repos

```bash
git clone git@github.com:<you>/SpraxelAiCompany.git ~/SpraxelAiCompany
mkdir -p ~/GameProjects
git clone git@github.com:<you>/<game>.git ~/GameProjects/<game>   # per existing game
```

The framework expects itself at `~/SpraxelAiCompany`; games live wherever
the `games:` registry points. Verify the registry resolves:

```bash
python3 ~/SpraxelAiCompany/scripts/spx_config.py games
```

## Step 2 — install the daemon

```bash
bash ~/SpraxelAiCompany/scripts/install_daemon.sh
```

Drops `com.spraxel.tick.plist` into `~/Library/LaunchAgents/` — one launchd
job running `scripts/tick.sh` every `tick.interval_secs` (60s), with
`RunAtLoad=true` (first tick ~immediately) and `AbandonProcessGroup=true`
(without it launchd kills spawned dev workers when a tick exits). The plist
exports `USER`/`LOGNAME` so headless `claude` can reach the macOS keychain
— a 0-byte agent log saying "Not logged in" means reinstall the daemon.
Other verbs: `stop` / `status` / `restart`. Verify:

```bash
launchctl list | grep com.spraxel.tick                  # exactly one line
tail -f ~/SpraxelAiCompany/logs/tick/$(date +%F).log    # one line per minute
```

## Step 3 — install the skills

```bash
bash ~/SpraxelAiCompany/scripts/install_skills.sh
```

Claude Code only discovers skills under `~/.claude/skills/` — NOT this
repo's `skills/` — so this symlinks each skill there (symlinks, so repo
edits apply immediately). Idempotent. **If a `/spraxel-*` command is ever
missing from Claude Code, re-run this script** — that's the whole diagnosis
(never a size issue). Expect `+ <name> → <target>` per skill and
`done (5 linked/updated)`, then restart Claude Code. Verify:

```bash
ls -l ~/.claude/skills | grep spraxel
# → spraxel-develop, spraxel-inbox, spraxel-launch, spraxel-producer, spraxel-report
```

## Step 4 — git auth that survives sleep

```bash
gh auth setup-git
```

The default osxkeychain credential helper LOCKS when the Mac sleeps — every
`git push` then silently fails and the whole dev loop stalls with no error
you'll ever see (this has happened; see Risks). `gh auth setup-git` rewires
git to use `gh` as the credential helper instead. Verify:

```bash
gh auth status
git -C ~/GameProjects/<game> push --dry-run origin master
```

## Step 5 — macOS permissions

Grant **Full Disk Access to your terminal app** (System Settings → Privacy
& Security → Full Disk Access → add Terminal/iTerm/whatever runs `claude`).
Grant it to the TERMINAL, not the claude binary — the binary's path is
versioned, so auto-updates silently invalidate a per-binary grant. This
fixes the recurring "…would like to access data from other apps" popup.
Optional: keep the Mac awake (`sudo pmset -a sleep 0`, or `caffeinate
-dims &`) — sleep isn't fatal (the wake-gap detector replays missed
slots), but awake is simpler.

## Step 6 — your first game

In Claude Code, type **`/spraxel-launch`**. It interviews you (name + slug,
pitch, must/must-not-include, engine + run/test commands, philosophy,
cadence), scaffolds via `scripts/new_game.sh`, registers the game in the
`games:` registry ALONGSIDE existing games, wires up tests, and can seed
starter work with an inline designer→architect pass. Manual path + per-file
details: Part V ("Setup — adding a new game"). Verify:

```bash
python3 ~/SpraxelAiCompany/scripts/spx_config.py games          # game listed, enabled
python3 ~/SpraxelAiCompany/scripts/spx_config.py paths <slug>   # namespaced state dirs
```

## Step 7 — verify everything

```bash
# In Claude Code — full status snapshot (now / 24h / 7d / next 20 scheduled):
/spraxel-report

# Or without a session:
bash ~/SpraxelAiCompany/scripts/health_check.sh              # → "all clean"
cat ~/SpraxelAiCompany/state/<slug>/cache/crew-health.txt    # empty = green
python3 ~/SpraxelAiCompany/scripts/dashboard.py              # live TUI — leave it open
```

The crew fires in the 03:00–07:00 PT awake band, so a fresh install shows
its first real activity tomorrow morning. Don't want to wait?

```bash
bash ~/SpraxelAiCompany/scripts/run_agent.sh morning-briefer
cat ~/GameProjects/<slug>/.factory/local/MORNING.md
```

From here, your job is Part III.

---

# Part III — Operating it daily

The CEO job: three short visits a day, a few weekly extras, and two written
interfaces — play-test verdicts and TRIAGE.md answers. When in doubt at any
hour, `/spraxel-inbox` tells you exactly what's waiting on you.

## CEO daily routine (the part that matters)

**The one thing to remember: any time you sit down at the machine, run
`/spraxel-inbox`.** It tells you exactly what the system is waiting on you
for — blocking items first, then your top-10 `MANUAL` tasks, then the
checklist for the current time of day. You never have to remember what to
do; the skill computes it.

You visit the machine up to **three times a day**. The times are *guidance*
(the system never blocks on a clock) and are **configurable** in
`COMPANY_CONFIG.yaml` → `ceo_routine` — edit them to match your life:

| Visit | Default time | One-line purpose | Typical length |
|-------|--------------|------------------|----------------|
| **Morning** | ~06:15 | Full triage: play-test overnight ships, decide ideas, triage bugs, clear escalations | ~30-40 min |
| **Afternoon** *(optional)* | ~13:00 | Quick unblock: clear `[needs-ceo]`/`[escalated]` so the loop never stalls; dump ideas | ~5 min |
| **Evening** | ~22:00 | Top up: drain dictation, ensure WORK.md has 8+ eligible items for the next batch | ~5 min |

Each visit below is a literal checklist — exact files to open, exact
commands to run. Substitute `<game>` with a game from the
`COMPANY_CONFIG.yaml` → `games:` registry (each enabled game runs
concurrently; currently `infiltrators`).

## The morning visit — full triage (~06:15)

### 05:00 AM — System has prepared your day (you're asleep)
By the time you wake, the early-morning crew has run: `playtester` (03:00) →
`triager` (04:00) → `morning_briefer` (05:00, writes MORNING.md) →
`demo_creator` (05:30) → `pm` (06:00, reorders Todo). Tue/Fri also get
`designer` (04:30). You wake to a prepared digest.

### 06:00 — 06:38 AM — Morning routine (~38 min — CEO wakes ~06:15)

**Time-boxed**. If you blow past 45 min, stop and commit what you have.

```bash
cd ~/GameProjects/<game>
cat .factory/local/MORNING.md
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
The Developer will iterate on top of the existing code on the next dev fire.

```bash
bash ~/SpraxelAiCompany/scripts/amend.sh cutscene-engine \
  "title fade is too slow — 0.3s feels better than 1.0s; also Esc should immediately end the cutscene, not wait for the current line to finish"
```

What it does:
- Appends `[amend] Refine: <title>` to WORK.md `## Up-and-coming work`
- Includes the original sha as a pointer ("read this, then modify in place")
- Includes your feedback verbatim as scope
- Commits + pushes WORK.md
- The feature **stays shipped on master** — nothing reverts

The Developer picks it up automatically on the next dev fire (no `[needs-ceo]` tag — your
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
- Appends `[reject] Re-implement: <title>` to WORK.md `## Up-and-coming work`
- Includes your reason as detail so Developer knows what to do differently
- Commits + pushes

Developer picks it up automatically on the next dev fire. If revert hits conflicts
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
  checkmarks never carry over, so each fresh batch shows up clean.
- Marking is purely cosmetic (clears your action list). It does **not** touch
  the game, master, or WORK.md. `amend`/`reject` are the only verbs that
  change anything. Marking a feature tested is the explicit "✓ Accept" action.
- `amend` and `reject` do **not** auto-mark — if you amend a feature you're
  still "acting" on it, so it stays on the list until you've re-verified the
  refinement (or just `--reset` and re-run the list tomorrow).

#### 3. ▶ Decide — Designer ideas (5 min)

Designer drops appear in WORK.md `## Up-and-coming work` with `[idea]` tag. Three actions:

```bash
# ACCEPT an idea  → converts [idea] to [untriaged] (sends it INTO shaping,
#                   NOT straight to the build queue — the Architect will
#                   fast-pass it or ask you a questionnaire; see step 3b)
python3 $WORKMD promote $WORK "sleeping-gas grenade"

# REJECT an idea  (delete the line entirely)
python3 $WORKMD drop $WORK "radio-tower mission"

# DEFER  (do nothing — [idea] tag stays, the loop keeps skipping)
```

Accepting an idea no longer drops it straight into the build queue — it
enters the **shaping pipeline** (becomes `[untriaged]`). The Architect then
either fast-passes it (if already concrete) or writes you a questionnaire in
`TRIAGE.md`. You finish defining it in step 3b. Reject and defer are unchanged.

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
it's ignored until you submit.** When done for now, type any word as the submit
token at the bottom and save — it counts on the **`[Indicate complete]`** line
itself OR on any line below it — within ~60s the Architect
processes every fully-answered task (finalize / decompose into an epic / ask a
follow-up) and leaves partial ones for later. You don't run anything.

#### 4. ▶ Bug triage (5 min)

Triager + Playtester appended new candidate bugs before dawn as **`[needs-ceo] [bug]`**.
⚠️ They are NOT in the build queue yet — workers skip `[needs-ceo]` until you
validate — so leaving one alone DEFERS it; it does not get fixed. Use the safe
wrapper (`with_master_lock.sh` locks + syncs + commits + pushes; a bare
`workmd.py` edit gets eaten by a worker's `reset --hard` — see WORKER_OPERATIONS.md §4):

```bash
WML=~/SpraxelAiCompany/scripts/with_master_lock.sh
# ACCEPT — clear [needs-ceo] → live [bug] the ship loop fixes
bash $WML approve "_cache_scene_lights"
# REJECT — false positive / duplicate / intended behavior
bash $WML drop "duplicate-bug-title-substring"
# PRIORITIZE — accept, then bump to p0
bash $WML approve "stairs teleport" && bash $WML bump "stairs teleport" p0
# DEFER — leave it: stays [needs-ceo], reappears next briefing (NOT fixed meanwhile)
```

#### 5. ▶ Escalations (1-3 min, usually 0)

Escalations are rare CEO-judgment calls. Most come from the dev loop; the
**Designer** also escalates here when implemented or planned work conflicts with
`Philosophy.md` (tagged with a severity — minor/moderate/major). Triage each the
same way: `resume` after editing (do via loop), do it yourself on the branch,
amend/reject the offending feature, or drop the flag to dismiss.

**The easiest way to answer:** each `[escalated]` item also surfaces in
`.factory/local/TRIAGE.md` as an **`ESC · <title>` resolution ballot** (the
Architect writes it, with concrete options just like a shaping questionnaire).
Answer it there alongside your shaping answers and submit — the Architect
applies your decision (retag/resume/drop) for you. The WORK.md-side flow
below is the manual equivalent.

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

It reads `.factory/inbox/raw.md` (and any dictation files), classifies each note (`[bug]` / `[feature]` / `[game-feature]`), assigns priority, appends to WORK.md `## Up-and-coming work`, commits.

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
| `approve <substr>` | Remove `[needs-ceo]` tag → validate a candidate bug / answered question → live, dev-claimable. |
| `drop <substr>` | Delete an item entirely from any section. |
| `bump <substr> pN` | Change priority (p0..p3). |
| `append --section todo …` | Add a new item. (Producer skill does this for you.) |

⚠️ These all mutate the canonical `WORK.md` — run them via
`bash ~/SpraxelAiCompany/scripts/with_master_lock.sh <verb> <args>` (it locks,
syncs, commits + pushes). A bare `workmd.py <verb>` leaves the edit uncommitted,
where a worker's `reset --hard origin/master` silently discards it. See
WORKER_OPERATIONS.md §4.

All four match on title substring (case-insensitive, first match wins). Be specific enough to uniquely match.

During the day the system is quiet (the batch test runner only fires when
the ship cap drains or on the engine-hours fallback, silent unless
something breaks). Live your life — work on art,
music, design, level layout; manually edit WORK.md (CEO can do anything);
drop ideas into `.factory/inbox/raw.md` whenever they hit you.

## The afternoon visit — quick unblock (~13:00)

**Purpose: make sure the loop isn't stalled waiting on you.** The only
thing that *blocks* the pipeline is an item that needs your
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

# [needs-ceo] — Developer asked a question (or a candidate bug). Edit the item's
#   detail lines with your answer, then clear the tag so it re-enters rotation:
bash ~/SpraxelAiCompany/scripts/with_master_lock.sh approve "<title-substring>"

# [escalated] — your call. Resume after editing details with guidance:
bash ~/SpraxelAiCompany/scripts/with_master_lock.sh resume "<title-substring>"
```

Dump any new ideas while you're here (no need to process now):

```bash
echo "guards should investigate the LAST noise, not the first" \
  >> ~/GameProjects/<game>/.factory/inbox/raw.md
```

## The evening visit — top up (~22:00)

**Purpose: give the next batch fuel.** The ship loop builds until the
8-item cap (`target_per_batch`) since your last signal, then parks. If the
eligible queue is thin, it drains it and idles. Two commands:

```bash
# 1. Drain everything you dictated today into clean WORK.md items:
#    (in Claude Code)
/spraxel-producer

# 2. Confirm there are 8+ eligible items queued for the next batch:
python3 ~/SpraxelAiCompany/scripts/workmd.py top ~/GameProjects/<game>/WORK.md -n 12
```

If `top` shows fewer than ~8 eligible items (i.e., most of the top is
`MANUAL`/`[idea]`/`[needs-ceo]`), add a few via dictation + `/spraxel-producer`,
or promote some `[idea]`s. That's the whole evening visit.

How the batch actually builds depends on the mode (see "The two developer
modes"): in headless mode, **parallel `continuous_dev.sh` workers** (each in
its own `.worktrees/<slug>/worker-<id>` worktree) ship items concurrently
until the shared 8-item cap, then sleep until your next checkin — adjust the
worker count via `COMPANY_CONFIG.yaml` → `continuous.dev_concurrency`
(1 = serial, 3 = default; `global.max_total_dev_workers` caps the sum across
games). In **interactive mode (current)**, nothing builds unless a
`/spraxel-develop` session is running — leave one parked and it self-resumes
the next batch when you poke the system.

## CEO weekly schedule (extras on top of the daily routine)

Most days look like the daily routine above. A few days have additions:

### Tuesday + Friday — Designer days

After Designer fires at 04:30 PT, MORNING.md's **Decide** section will
have 4–6 fresh ranked ideas. Expect the Decide step to take **+5 min**
on these days as you accept / reject / amend each.

### Tuesday + Friday — Blogger slots (+10 min when it drafts)

Blogger's cron fires at 06:45 PT Tue+Fri (22:45 JST — in the both-continents awake band), but it only actually drafts when
there's something to say — **release-driven**: a release was cut since the
last post (usual case), or ≥14 days have passed with ≥3 fresh player-facing
ships; otherwise it exits cleanly and you do nothing. When it drafts, it
pushes a `blog/<YYYY-MM-DD>` branch containing a draft post at
`blog/content/posts/draft-<YYYY-MM-DD>-<slug>.md`.
The branch + draft are **not** on `master` — by design, drafts get a review pass
before they land. Your job is to humanize, then merge + publish.

#### 1. Find the draft

```bash
cd ~/GameProjects/<game>
git fetch origin

# List recent blogger branches if you've lost the date:
git branch -a | grep '^[ *]*\(remotes/origin/\)\?blog/'

# Resolve the exact draft path (git show does NOT expand globs, so you need the
# real filename — the slug varies per post):
DRAFT=$(git ls-tree -r --name-only origin/blog/$(date +%F) | grep '^blog/content/posts/draft-')

# Peek without switching branches (fastest) — exact-path form, always works:
git -C ~/GameProjects/<game> show origin/blog/$(date +%F):"$DRAFT"
```

> On blog weeks, MORNING.md prints this exact `git ... show origin/blog/<date>:<path>`
> line for you under **📝 Blog draft to read** — copy it straight from there.

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

- `feat:` / `fix:` commits since the last post, grouped thematically (it
  picks ONE lead theme; **the post gets exactly one hero media slot**, on
  that lead theme).
- Demo Creator assets from `.factory/demos/<recent-dates>/` if any exist
  (real `<slug>.png` + capture paths).
- PM release notes from `.factory/releases/<latest>.md` — when a release was
  cut, these are the spine of the post.
- Memory of past topics from `.factory/memory/blogger.md` (mandatory read) —
  to avoid repeating phrases or themes across posts.

`/spraxel-inbox` skill adds the humanize step to the morning routine on
days a fresh draft branch exists.

### Sunday — Janitor + Reflection

Janitor fires at 01:00 PT Sunday. No CEO action required — but the
MORNING.md "Janitor" line will tell you what got cold-archived. If you
want to resurrect anything, edit WORK.md to remove the `[cold]` tag.

### Release-cut day (biweekly, per `cadence.release`)

On the biweekly release day (`cadence.release` in GAME_CONFIG — currently
Saturdays for infiltrators), PM auto-cuts a release tag in addition to its
daily reorder. It can ALSO cut **off-calendar on the size trigger** (finished
section ≥40 items or WORK.md >150KB — a survival rule: an oversized WORK.md
blows up every crew prompt). Either way the cut runs `workmd.py release-cut`,
which **externalizes the "Finished since last release" section to a
`WORK_v<version>.md` file** at the game-repo root. MORNING.md will announce:

> 🚢 PM cut v0.4 on 2026-MM-DD: 6 features, 2 bugs.
> Notes: .factory/releases/v0.4.md
> Branch: release/v0.4

Read the notes to confirm the cut matches reality. The release branch
is for hotfixes — usually you ignore it. (If the PM ever misses its size
trigger, the Janitor has a failsafe: at WORK.md >200KB or ≥80 finished
items it cuts an interim patch-version archive itself and reports it
prominently.)

### 1st of the month — Asset Librarian

Asset Librarian fires at 07:00 PT on the 1st of each month. Adds a
"Asset Librarian" line to MORNING.md with orphan count + license gaps.
Address the license gaps when they appear (~5 min).

## The shaping loop — Architect + TRIAGE.md

Every new feature item enters the queue **`[untriaged]`** and is invisible to the
developers until it's been shaped into a concrete spec. The **Architect** agent
(Opus — a bad spec costs full dev+review+retry cycles; runs 09:00 & 21:00 PT,
and reactively within ~60s — see below) owns this.
On each run it does two things (plus a third: writing **`ESC ·` resolution
ballots** for any `[escalated]` items, so you can answer those in TRIAGE.md
too):

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
word as the submit token at the bottom of the Awaiting section and save — it
counts on the **`[Indicate complete]`** line itself OR on any line below it.
That's the signal: within ~60s `tick.sh` wakes the Architect
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

## Adding new work by hand — the `[untriaged]` rule

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
- `[manual] …` items — your hand-work, never built by the loop.

Existing backlog items are left as-is; the gate applies only to new additions.

## Running dev batches — `/spraxel-develop`

In interactive-developer mode (the current default) nothing ships unless a
`/spraxel-develop` session is running. Mechanics live in Part IV ("The two
developer modes"); the operating rules:

- **Start one:** in Claude Code, type `/spraxel-develop` (build to the
  8-item batch cap, then park) or `/spraxel-develop N` (build N, stop).
- **It never asks.** The loop runs fully autonomously to the cap — no
  mid-run "continue?" prompts. If it genuinely can't act on an item, the
  item lands back in WORK.md as `[retry]` or `[needs-ceo]` and it moves on.
- **Parked ≠ dead.** After the cap it parks and self-resumes on a CEO poke
  (non-bot commit, `bash scripts/checkin.sh`, or saving TRIAGE.md) — leave
  the session open overnight. The dashboard shows `RUNNING/PAUSED
  (interactive-dev)` via the heartbeat marker.
- **Sonnet cap:** if the dev subagent hits the Sonnet usage cap,
  `sonnet_cap.py` flips it to Opus and re-probes later — no action needed.

---

# Part IV — The machinery

What runs underneath: the two developer modes, the per-item ship pipeline,
WORK.md's tag lifecycle, the batch test runner, the agent roster, the
schedules, and health monitoring. (The release train is covered in Part
III's "Release-cut day" and the WORK.md cheat sheet below.)

## The two developer modes

Since the **2026-06-15 billing split**, headless `claude -p` runs bill as
metered API credits while interactive Claude Code sessions stay on the
subscription. Development can therefore run in one of two modes, switched by
ONE config key: **`continuous.force_interactive_developers`** (COMPANY_CONFIG,
overridable per game in GAME_CONFIG).

**Mode A — headless continuous loop** (`force_interactive_developers: false`).
The classic setup: `tick.sh` keeps `continuous_dev.sh` alive, which runs
`dev_concurrency` (3) parallel workers, each in its own worktree at
`.worktrees/<slug>/worker-<id>/`, shipping items via headless `claude -p`
(**metered** post-June-15). Fully unattended — this is what "the loop keeps
building while you sleep" originally meant.

**Mode B — interactive developers** (`force_interactive_developers: true` —
**the CURRENTLY ACTIVE mode**, set in COMPANY_CONFIG and infiltrators'
GAME_CONFIG). `tick.sh` forces `dev_concurrency` to 0 — it spawns **NO
headless dev workers** (an already-running worker idles within ~60s). Crew
agents are unchanged (still headless on schedule). YOU drive dev work from a
Claude Code session with the **`/spraxel-develop`** skill
(`skills/spraxel-develop/SKILL.md` + `scripts/interactive_dev_step.sh`): the
session claims items one by one (claim → build → independent review →
squash-merge → ship → push) using a **Sonnet dev subagent + Haiku review
subagent** per item via the Agent tool — all **subscription-side**, not
metered. It works in the `.worktrees/<slug>/interactive` worktree.
`/spraxel-develop N` builds N items then stops; bare `/spraxel-develop`
builds to the batch cap, then parks and self-resumes on a CEO poke (a
non-bot commit, `checkin.sh`, or saving TRIAGE.md). It runs fully
autonomously to the cap — it never pauses mid-run to ask you anything. A
heartbeat marker keeps the dashboard showing `RUNNING (interactive-dev)`.
If Sonnet hits its usage cap, `scripts/sonnet_cap.py` flips the dev subagent
to Opus and re-probes Sonnet later (`policy.sonnet_cap_reprobe_secs`).

Both modes share the same pipeline semantics (claim tags, Reviewer gate,
`[retry]`, escalations) and the same **shared batch cap**:
`continuous.target_per_batch` (**8**) ships since the last CEO signal, then
the loop parks until you interact again. To switch modes, flip the config
key; the next tick picks it up.

## Reviewer findings — `.factory/reviews/<slug>.md`

Before the ship loop merges a feature, the **Reviewer** agent reads the
dev's `git diff master...HEAD` and writes its findings to
`.factory/reviews/<item-slug>.md` — one file per item, **gitignored (local-only)**,
overwritten on each attempt (so it always reflects the latest verdict). Format:

```
## Verdict
clean | blocking
## Findings
- [info]    <noteworthy, not blocking>
- [warning] <fixable, not critical>
- [block]   <correctness / contract violation — gates the merge>
```

A `[block]` finding **is a rejection**: the merge is blocked, the item bounces
to `[retry]`, and the next dev run reads this file verbatim to fix it. You never
*have* to act on these — the retry loop handles them — but they're the clearest
window into *why* something didn't ship.

**MORNING.md surfaces new rejections for you.** Under "▶ Reviewer rejections", it
lists any review with a `[block]` finding modified since your last briefing, so
you can spot an item that keeps getting bounced (a sign it's under-specified or
hitting a fragile reviewer pattern). To browse them all:
`ls -t <game>/.factory/reviews/` and open the slug you care about.

## WORK.md cheat sheet

Four sections separated by divider lines (10+ `-` or `=`), 2026-07 layout —
reordered so the CEO's action surface is at the top and history is a footer:

```
# <game> — work tracking

## Up-and-coming work                 ← the dev loop picks from the top
[game-feature] p0 Diving stealth in water
[bug] p0 Extraction zone broken
[game-feature] p1 Skill tree system
  300 skills, 3 levels each, dependency chains
  Lock characters into archetypes based on starting skills
[idea] [feature] p2 Sleeping-gas grenade item  ← Designer drop; the loop SKIPS this
==========
## Finished since last release        ← the loop appends here as items ship
[game-feature] p1 Run button + stamina bar
[bug] p0 Stairs teleport fixed
==========
## Next work                          ← parked backlog: [future]/[cold]/[manual]
[future] Co-op multiplayer
==========
## Shipped (previous releases)        ← archive FOOTER (headers only)
v0.2 — archived to WORK_v0.2.md
v0.1 — archived to WORK_v0.1.md
```

On a release cut (`workmd.py release-cut`), the whole "Finished since last
release" section is **externalized to a `WORK_v<version>.md` file** at the
game-repo root and the footer gets a one-line pointer — WORK.md itself stays
small (every crew prompt embeds sections of it, so size is a survival
constraint; see the PM's size trigger and the Janitor failsafe).

Tag reference:

| Tag | Meaning | Loop picks? |
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
| `[test_failure]` | A regression filed by the batch test runner, queued at the TOP of `## Up-and-coming work` with a `test-ref: <kind>:<id>` detail. | yes — but only ONE is worked at a time (others gated → workers take normal items); the fixing dev may run the named test. |

## Testing — the batch test runner + `[test_failure]`

**Developers run NO tests during feature work.** They write + commit tests but
never execute any. Running the suite on every commit with 3 workers meant three
Godot processes thrashing the CPU at once (30–40 min test phases, stalls, almost
no commits). Instead a dedicated **batch test runner** (`scripts/test_runner.sh`)
is the one place the whole suite runs.

- **What it does:** runs every test ONE AT A TIME (serial → zero contention),
  tracking which test-refs it has run this cycle. Each failure becomes a
  `[test_failure]` item at the TOP of `## Up-and-coming work` (deduped by test-ref). It runs
  until the whole suite is covered OR `test_runner.max_minutes` (default 120)
  elapses, resuming with un-run tests next time and resetting once a full cycle
  completes.
- **Two triggers (tick.sh dispatches it — it is NOT cron-scheduled):**
  1. the ship cap maxes out (`target_per_batch` reached since the last CEO
     checkin) **and** all developer workers have drained, or
  2. `test_runner.force_after_engine_hours` (default 100) of engine on-time have
     elapsed since its last run (paused time doesn't count and never resets it).
- **Exclusive:** while a run is scheduled or active, `tick.sh` spawns no new
  workers and existing workers finish their current item then idle — the runner
  runs alone. The dashboard Status shows `running — test runner scheduled` (then
  `… running`).
- **Fixing a `[test_failure]`:** workers claim it like any item, EXCEPT only one
  is in flight at a time (others gated). The fixing dev MAY run ONLY that test
  (`run_local_tests.sh --only <test-ref>`); the wrapper re-runs exactly that test
  as the merge gate.
- The old `com.spraxel.localtests` 30-min full-suite daemon has been **retired** —
  the triggered runner supersedes it.

## Subtasks & epics

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

## `[manual]` sub-category labels

When the Developer ships a feature that needs CEO follow-up (placeholder
art, fake SFX, etc.), it appends a `[manual] [<category>] <desc>` item
to `## Up-and-coming work`. The sub-category is documentary only — doesn't affect the
loop — but helps you batch-process during morning routine:

| Sub-category | Means |
|--------------|-------|
| `[manual] [art]` | Sprite / icon / texture / animation work needed |
| `[manual] [music]` | Music track or loop needed |
| `[manual] [sfx]` | Sound effect needed |
| `[manual] [writing]` | Copy, story, dialogue, names, flavor text |
| `[manual] [level]` | Level layout / hand-crafted design |
| `[manual] [tuning]` | Numbers feel wrong; needs balance pass |
| `[manual] [voice]` | Voice acting / casting |
| `[manual] [design]` | Design decision (mechanic feel, UX call) |
| `[manual] [narrative]` | Story / plot / mission narrative |

Example ship-commit body referencing follow-ups:
```
feat: add duck mechanic

tests: + test_duck.gd
follow-ups added to WORK.md:
  - [manual] [art] Duck sprite + ducked-walk animation
```

## `[future]` parked roadmap items

`[future] <desc>` or `[future] <desc>` marks something you want to do
**eventually** but isn't ready to schedule yet. The dev loop skips these
the same way it skips `MANUAL` and `[needs-ceo]` — they sit in the
`## Next work` section as a visible roadmap without competing for the
current batch.

Use it when:
- **You haven't scoped it yet.** Idea is good, but you don't know what
  "done" looks like — needs a design pass before the Developer can ship it.
- **Blocked on something.** Depends on a system that hasn't been built yet,
  a third-party decision, a real-world asset, etc.
- **Deliberately deferred.** It's on the roadmap for v0.4, but you're
  shipping v0.2 right now.

Difference from neighbors:
- `[manual] ` = human-only forever (art, audio, casting); will never
  become AI-eligible.
- `[future] ` = AI-eligible later; just not now. Flip to a regular item
  by removing the prefix/tag when ready.
- `[needs-ceo]` = Developer already tried, got stuck, asked questions —
  CEO answers, removes tag, Developer retries.

Examples:
```
[future] Co-op multiplayer (network layer needs design)
[future] DLC mission pack
[future] [game-feature] p2 Mid-mission gear-swap drone — needs gear-system v2 first
```

## The agent roster

| Agent | Cadence | Model | What it does |
|-------|---------|-------|--------------|
| **the ship loop** (continuous_dev.sh, or `/spraxel-develop` interactive — **current**) | always on (paced by CEO signal cap) | n/a (driver) | Long-running Developer loop. Ships items until `target_per_batch` (8) since last CEO signal, then parks. Headless: spawned + watched by `tick.sh`. Interactive: you run the skill; it parks + self-resumes on a poke. |
| **developer** | called by the ship loop, per item | sonnet (opus while Sonnet-capped) | Implements one WORK.md item end-to-end on a feature branch. **MANDATORY**: GUT test under `test/unit/`, a `docs/features/<slug>.md` feature file (with `First encounter` + `Tutorial prompt`) + its Game.md index line for player-facing features, debug-feature hook, scenario file. Reviewer blocks merge if any are missing. Handles `[amend]`, `[reject]`, `[resume]` items differently (read prior code first). |
| **reviewer** | called by the ship loop, per item | haiku | Reads `git diff master...HEAD`, writes findings, exits 0 (clean) or 1 (blocking). Blocks merge on missing test, missing/incomplete `docs/features/<slug>.md` + Game.md index line, missing scenario file, missing debug-feature hook, god-file growth past `max_file_lines` (1500). |
| **playtester** | daily 03:00 PT | sonnet | Actively plays the game to find problems. Beyond test scenarios — input spam, edge cases, mechanic combos. Environment pre-flight first; classifies every finding `gameplay` / `harness` / `environment` (only gameplay = bug candidates) and emits hands-on test recipes for the CEO. Writes candidates to `.factory/inbox/playtest-findings.md`. Does NOT touch WORK.md directly. |
| **triager** | daily 04:00 PT | haiku | Reads playtest findings + test failures, appends as `[needs-ceo] [bug]` items. CEO validates in MORNING.md before they become live bugs. |
| **morning-briefer** | daily 05:00 PT | sonnet | Writes `.factory/local/MORNING.md` (gitignored — never commit). 📰 News opens with the mandatory 🩺 crew-health line. 10 features to play-test with launch + amend + reject one-liners, decisions to make, real `[escalated]` items needing CEO judgment (usually 0 — auto-retries are silent and not surfaced). Shows a one-line `[retry]` queue count FYI but no action required. Runs `health_check.sh` first to surface agent failures. Sums per-item cost stamps into the 💸 Batch cost line (see The money model). |
| **demo-creator** | daily 05:30 PT | sonnet | Writes `.factory/demos/<date>/recipe.md` with FULL recipes for the **top 3** ships only (the rest get one-liners). Auto-captures ONLY capture-ready demo scenarios via Godot `--write-movie` + ffmpeg (no Screen Recording permission needed; still requires Mac awake + ffmpeg); test-style auto-quit scenarios go on the rc=5 skip ledger. Blogger reads recipe.md as source of truth. |
| **pm** | daily 06:00 PT + release cuts (calendar `cadence.release` OR size trigger) | sonnet | Reorders the up-and-coming section. On a cut (biweekly day, or same-day when the finished section hits ≥40 items / WORK.md >150KB): tags `v0.N`, generates release notes, `release-cut` externalizes the finished section to `WORK_v<version>.md`. |
| **designer** | Tue + Fri 04:30 PT (+ daily when dry) | sonnet | Reads **`TASTE.md` first (REQUIRED)** — never proposes into a Rejects pattern, biases toward Loves. Then Philosophy + memory + inspiration. Drops 4-6 ranked `[idea]` items + 0-3 `[concern]` items (game-wide issue flags: feature bloat, missing fundamentals, philosophical drift). **Audits all implemented + planned work against Philosophy.md and escalates ANY conflict (even slight, severity-tagged) to the CEO.** **Cadence:** scheduled Tue+Fri; `tick.sh` ALSO dispatches it on any other day when the buildable queue is dry (developers have no eligible items left — only `[manual]`/`[future]`/`[untriaged]`/epic-gated, ignoring the pinned dashboard chore), at most once/day, to refill the idea pipeline. |
| **architect** | daily 06:30 & 21:00 PT + reactive (within ~60s of a new `[untriaged]` item) | **opus** | Shapes `[untriaged]` feature work into buildable specs. Processes answered questionnaires in `.factory/local/TRIAGE.md` (finalize spec → item buildable, or ask ≤5 follow-up rounds), intakes new untriaged items (fast-pass concrete ones via `shape-pass`, else write a /plan-style questionnaire via `shape-start`), and writes `ESC ·` resolution ballots for `[escalated]` items. On finalize, decides single item vs. decomposing a complex feature into a parent `[epic]` + sequential subtasks (`shape-epic`). Bugs + MANUAL items are exempt. Reads `TASTE.md` before every questionnaire — `(Recommended)` picks match the CEO's revealed taste — and appends newly-revealed patterns to its Maintenance log. |
| **blogger** | Tue + Fri 06:45 PT, **release-driven** (drafts only when a release was cut, or ≥14 days + ≥3 fresh ships) | sonnet | Drafts devlog from player-facing `feat:` commits since the last post ONLY (skips fix(test):/chore:/refactor:/docs:/test:/work:/escalate:/ceo:), with **ONE hero media slot** on the lead theme. Writes `blog/content/posts/draft-<date>-<slug>.md`. Pushes `blog/<date>` branch; CEO humanizes + merges. |
| **janitor** | weekly Sun 01:00 PT | haiku | Cold-archives 30+ day stale items (retag to `[cold]` — never deletes), prunes merged branches, prunes 60+ day logs, prunes old demo folders. Sweeps orphan `feat/cont-*` branches whose WORK.md item is gone (cleanup for `[escalated]`/`[resume]`/`[retry]` branches whose items the CEO has deleted by hand). **WORK.md size failsafe**: if the PM missed its size-triggered cut (WORK.md >200KB or ≥80 finished items), cuts an interim patch-version archive itself. |
| **asset-librarian** | monthly 1st 07:00 PT | haiku | Scans assets/, reports orphans + license gaps. |
| **producer** | on-demand (`/spraxel-producer`) | sonnet | Converts CEO dictation → clean WORK.md items. Flags ⚠️ concerns inline (cliché/complexity/balance/drift) but always appends the item — concerns are advisory, never gatekeep. |

## Setting up & changing schedules

There are **three independent schedules**. All live in plain text you can
edit; the daemon picks up changes within 60 s (the `tick.sh` launchd job
re-reads the files every tick — no restart needed).

### 1. Crew-agent cadences — *when the bots fire*

`COMPANY_CONFIG.yaml` → `agents:` holds one cron line per agent
(`schedule.yaml` still exists but is just a back-compat symlink to it):

```yaml
agents:
  playtester: { cron: "0 3 * * *",   description: "03:00 PT daily" }
  designer:   { cron: "30 4 * * 2,5", description: "Tue+Fri 04:30 PT" }
```

Cron format is `minute hour day-of-month month day-of-week`, evaluated in
`America/Los_Angeles` (see `scripts/cron_match.py`). Examples:
`0 6 * * *` = 06:00 daily; `30 4 * * 2,5` = 04:30 Tue+Fri; `0 1 * * 0` =
01:00 Sun; `0 7 1 * *` = 07:00 on the 1st.

**Why the crons cluster at 03:00–07:00 PT (the "awake band").** The Mac
must be AWAKE for a cron slot to fire. The crew clusters in roughly
03:00–08:00 PT: early morning at home AND evening JST while the CEO travels
in Japan — one band that's plausibly awake on both continents (the
`agents:` block comment in COMPANY_CONFIG.yaml is the canonical rationale).
Slept-through slots are NOT lost — the wake-gap detector fires
`catch_up.sh`, replaying every slot due today — and the Architect's cron
slots are backstops to its ~60s reactive `[untriaged]` trigger.

**Defense in depth:** some agents also read a cadence self-check through the
config loader (e.g. the game's `GAME_CONFIG.yaml` → `cadence.blogger`) and
exit cleanly if today isn't their day. Where a `cadence.<agent>` entry
exists, keep it in sync with the cron — the `agents:` cron controls
*firing*, the cadence entry is the agent's own *sanity check*.

**To add a new scheduled agent:** (a) drop its spec at
`agents/spraxel-<name>.md`, (b) add a `cron:` line under `agents:` in
`COMPANY_CONFIG.yaml`, (c) add a `models.<name>` assignment there too.
Next tick runs it. Confirm with `tail -f logs/tick/$(date +%F).log`.

### 2. The continuous dev loop — *how hard it ships*

`COMPANY_CONFIG.yaml` → `continuous:` — the knobs you'll actually touch:

| Knob | Default | Meaning |
|------|---------|---------|
| `force_interactive_developers` | **true** (currently) | **the mode switch** — true = NO headless dev workers; drive dev via `/spraxel-develop` (subscription-side). See "The two developer modes". |
| `dev_concurrency` | 3 | parallel headless workers (1 = serial; ignored/forced to 0 in interactive mode) |
| `target_per_batch` | **8** | ships per batch before the loop parks (resets on your checkin; shared across workers) |
| `dev_stall_minutes` | 15 | kill a dev only after this long with **no** progress |
| `max_dev_minutes` | 90 | absolute cap even on a progressing dev |
| `retry_escalate_threshold` | 5 | total `[retry]` attempts on one item before auto-escalating (poison-pill brake) |
| `test_runner.max_minutes` | 120 | wall-clock budget per batch test-runner run (0 = run to completion) |
| `test_runner.force_after_engine_hours` | 100 | force a test-runner run after this much engine on-time since the last |

Full table with rationale: see **Configuration reference** below.

### 3. Your own routine — *when YOU show up*

`COMPANY_CONFIG.yaml` → `ceo_routine:` (morning / afternoon / evening times +
purposes). These drive what `/spraxel-inbox` shows by time of day. They're
guidance only — the system never blocks on the clock. Edit them to match
your life:

```yaml
ceo_routine:
  timezone: "America/Los_Angeles"
  morning:   { around: "06:15", jst: "22:15", purpose: "Full triage …" }
  afternoon: { around: "13:00", jst: "05:00", purpose: "Quick unblock …" }
  evening:   { around: "22:00", jst: "14:00", purpose: "Top up …" }
```

The **`jst:` column** is the same visit slot while traveling in Japan — the
crew's 03:00–07:00 PT band is your JST evening, so the "morning" digest is
ready by your Japan late evening either way.

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
— those go in `COMPANY_CONFIG.yaml` as above. Use `/schedule` only for personal
follow-ups tied to a concrete future date.

## Monitoring & crew health

Two layers exist. **Passive (automatic):** `tick.sh` runs an hourly
**crew-health monitor** per game — any agent whose last successful run is
older than 2× its cron cadence lands in `state/<slug>/cache/crew-health.txt`,
newly-stale agents get a one-time crew_health report, and MORNING.md's
📰 News opens with a mandatory 🩺 crew-health line. **Active (on demand):**
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

---

# Part V — Extending it

Adding a game, teaching the crew your taste, commissioning real art,
running an unsupervised jam, and changing the agents themselves.

## Setup — adding a new game

If you're starting a fresh game and want to wire it into the Spraxel
factory, the guided path is the **`/spraxel-launch`** skill in Claude Code —
it interviews you (identity, inspirations, config), runs the bootstrap,
registers the game in the multi-game registry alongside the existing games,
and can seed starter work. The manual path below is what it automates; the
whole process takes ~10 minutes.

```bash
# 1. Create the game repo (or use an existing one)
mkdir ~/GameProjects/my-new-game && cd ~/GameProjects/my-new-game
git init

# 2. Apply the Spraxel framework template
bash ~/SpraxelAiCompany/scripts/new_game.sh ~/GameProjects/my-new-game \
  --name "My New Game" --ceo your-github-login

# This drops in:
#   GAME_CONFIG.yaml        ← per-game config overrides (identity, knobs, models)
#   Philosophy.md           ← prose-only design tenets
#   Game.md                 ← feature INDEX; per-feature files in docs/features/
#   WORK.md                 ← work tracking (4-section layout)
#   .gitignore              ← Godot cache, .uid files, .factory/local/, etc.
#   .factory/               ← runtime state dirs (memory/, inbox/, reviews/, local/)
#   scripts/run_local_tests.sh      ← full GUT + scenarios + status JSON
#   scripts/run_unit_tests.sh       ← fast unit-test only runner
#   test/unit/.gitkeep              ← Developer agent puts GUT tests here
#   scripts/scenarios/.gitkeep      ← Developer agent puts scenario tests here
```

**Template ↔ live-contract sync (2026-07-08):** the scaffold tracks current
conventions — WORK.md ships the 2026-07 4-section layout, Philosophy.md is
prose-only (aim <2KB, zero config keys), Game.md scaffolds as an INDEX with
per-feature blocks in `docs/features/<slug>.md` (developers create that dir
as features ship). `TASTE.md` is NOT scaffolded — it's mined from real
decisions weeks later (see the TASTE.md chapter). ⚠️ Known wart:
`new_game.sh`'s printed "next steps" still mentions the old single-game
`schedule.yaml game_dir:` model — ignore it; the `games:` registry (below)
is the current path.

### Edit GAME_CONFIG.yaml (per-game config)

All per-game config lives in `GAME_CONFIG.yaml`, deep-merged on top of
`COMPANY_CONFIG.yaml` by `scripts/spx_config.py` (`Philosophy.md` is
prose-only — write your design tenets there in plain English). The
MUST-edit fields:

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
```

The OPTIONAL knobs (have sensible company-wide defaults — only override if
you want non-default behavior for THIS game). See the "Configuration
reference" section for the full table.

```yaml
# Per-agent CEO-tunable thresholds — all optional. Defaults shown.
janitor:
  cold_threshold_days:    30
  log_retention_days:     60
morning_briefer:
  playtest_count:         10
designer:
  ideas_per_run:          5

# Dev-mode override — e.g. keep this game's dev work subscription-side:
continuous:
  force_interactive_developers: true

# Model overrides — company defaults (COMPANY_CONFIG models:) are fine.
models:
  developer: sonnet
  reviewer:  haiku
```

### Register the game in COMPANY_CONFIG.yaml

```bash
# 4. Add the game to the multi-game registry + tune the continuous loop
$EDITOR ~/SpraxelAiCompany/COMPANY_CONFIG.yaml
```

The MUST-edit field — add an entry under `games:` (alongside existing
games; every enabled game runs concurrently):

```yaml
games:
  my-new-game:
    dir: ~/GameProjects/my-new-game
    enabled: true
```

The OPTIONAL knobs (defaults are sensible — only touch if you have a
reason). See the "Configuration reference" section in Part VI.

```yaml
continuous:
  target_per_batch:       8       # ships before parking until next CEO signal
  dev_concurrency:        3       # parallel workers; 1 = single, 3 = aggressive
  max_fail_streak:        3       # consecutive failures → backoff
  fail_backoff_seconds:   1800    # 30 min backoff
  poll_interval_seconds:  60      # how often to re-check pause/cap
  idle_threshold:         5       # empty-queue ticks → long sleep
  idle_sleep_seconds:     300

global:
  max_total_dev_workers:  4       # worker ceiling across ALL games combined

agents:
  # cron expression per agent — edit cadences here. Format:
  #   minute hour day-of-month month day-of-week  (PT timezone)
  playtester:      { cron: "0 3 * * *",  ... }
  triager:         { cron: "0 4 * * *",  ... }
  morning_briefer: { cron: "0 5 * * *",  ... }
  # ...
```

```bash
# 5. Install (or re-install) the daemon — idempotent
bash ~/SpraxelAiCompany/scripts/install_daemon.sh

# 6. (Optional) Install ffmpeg if you want auto-capture of feature demos
# (the demo-creator agent uses Godot's --write-movie + ffmpeg). Without
# ffmpeg, the agent skips auto-capture but still produces recipe.md for
# hand-recording.
brew install ffmpeg
```

(No per-game test daemon anymore — the old `com.spraxel.localtests` 30-min
cron is retired; the batch test runner is dispatched by `tick.sh`.)

Verify everything is loaded:

```bash
launchctl list | grep com.spraxel
# Expect ONE line:
#   com.spraxel.tick          (1-min daemon dispatching all agents, all games)

bash ~/SpraxelAiCompany/scripts/install_daemon.sh status

claude --version
# If session expired, run `claude login` in a Claude Code window.
```

The daemon iterates EVERY enabled game in the `games:` registry each tick —
per-game state is namespaced (`state/<slug>/`, `logs/<slug>/`,
`.worktrees/<slug>/`) so games never collide, and
`global.max_total_dev_workers` caps total headless dev load across games.

## The game-code contract

For Spraxel to drive a Godot game, the game repo must provide these
files + conventions. `scripts/new_game.sh` scaffolds the common parts;
the game-specific bits (autoloads, scenario format, debug-boot dispatch)
are documented below so a CEO knows what to write.

### Files at the game-repo root (auto-scaffolded by new_game.sh)

| Path | Purpose | Spraxel reads it as... |
|---|---|---|
| `GAME_CONFIG.yaml` | Per-game config overrides, deep-merged on top of `COMPANY_CONFIG.yaml` by `scripts/spx_config.py` | Source of truth for identity, `cadence.*`, per-agent thresholds, model overrides, `dev.godot_binary`, `continuous.force_interactive_developers`, `policy.run_mode` |
| `Philosophy.md` | **Prose-only** design tenets — identity, tone, what the game must/mustn't be. No YAML knobs anymore (those all moved to GAME_CONFIG.yaml) | Read by Designer/Producer/Developer for taste + drift audits |
| `WORK.md` | Work queue (see "WORK.md cheat sheet" for the 4-section layout) | Mutated atomically via `workmd.py` from the framework |
| `Game.md` | **Feature INDEX** (sharded 2026-07-08 — it was 498KB, now ~50KB): controls + grouped inventory with **one index line per feature**, linking to per-feature files. | Read by crew agents as the catalog of what exists |
| `docs/features/<slug>.md` | **One file per feature** — the Developer creates it for **every player-facing ship** (MANDATORY; the Reviewer **blocks the merge** if it's missing/stale/incomplete) plus the matching Game.md index line. Each file has the 9 fields: **What it does · Controls · First encounter · Tutorial prompt (≤80 chars) · Debug hook (`--demo-feature=<slug>`) · Trace events · Test scenario · Unit test · Acceptance (2–4 bullets)**. Bugs/chores skip it unless they change player-facing behavior. (Canonical spec: `agents/spraxel-developer.md`.) | Read by morning-briefer/playtester to surface play-test commands |
| `.gitignore` | Excludes `.factory/`, Godot cache, etc. | Critical — framework state lives under `.factory/` |
| `scripts/run_local_tests.sh` | Test runner (GUT + scenarios) — honors `SPRAXEL_GAME_DIR` + `SPRAXEL_WORKER_ID` env vars; `--list` / `--only <ref>` | Invoked by `test_runner.sh` (batch) and per-`[test_failure]` merge gates |
| `scripts/run_unit_tests.sh` | Fast unit-only runner | Optional manual invocation |
| `scripts/install_local_tests.sh` | Installs `com.spraxel.localtests` launchd plist — **legacy; the 30-min daemon is retired** (batch test runner supersedes it) | Historical; skip at game setup |

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

## TASTE.md — the CEO taste profile

`~/GameProjects/<game>/TASTE.md` is the CEO's **revealed** taste — mined
from ~6 weeks of actual promote/drop/amend/questionnaire decisions, every
claim carrying a receipt (commit sha, `T-####` triage id, or doc path).
Philosophy.md is what you SAY; TASTE.md is what you DO — and for idea
selection, TASTE.md wins where they conflict. Sections: **Loves**
(greenlight-fast patterns), **Rejects** (don't propose), **Amend patterns**
(how you shrink scope — e.g. you take the `(Recommended)` option ~85% of
the time), **Priority tells**, **Stated vs revealed**, **Open questions**,
and a **Maintenance** append-log. Wiring (shipped 2026-07-08, `f7e5c27`):

- **Designer** (`agents/spraxel-designer.md`): REQUIRED read *before
  generating a single idea*. Never propose into a Rejects pattern — silent
  re-proposals of rejected shapes are the #1 trust burner; an idea
  contradicting a Reject must say so and argue why this one's different.
  Bias toward Loves; pre-shrink scope per the Amend patterns.
- **Architect** (`agents/spraxel-architect.md`): reads it before writing
  any questionnaire. `(Recommended)` picks must match your demonstrated
  preferences — you take the recommendation ~80% of the time, so the
  recommendation effectively IS the decision; Reject-pattern options are
  omitted or flagged. **Maintenance duty:** when a CEO answer/dismissal
  reveals a genuinely NEW pattern, it appends one dated line
  (`- YYYY-MM-DD: <pattern> (receipt: <sha/T-id>)`) to the Maintenance
  section, committed with its WORK.md commit under the master-push lock;
  entries with 3+ receipts fold into the main sections at the next mining.

**Not scaffolded.** TASTE.md can't exist at launch — no decisions to mine
yet. It's produced by a periodic mining pass over git history, WORK.md
promotions, TRIAGE.md answers, and agent memories (infiltrators': first
mined 2026-07-08). For a new game, mine one after ~4-6 weeks of real
triage; both agent specs tolerate its absence until then.

## Art production — ART_BRIEF.md and the ASSETS.md license ledger

`~/GameProjects/<game>/docs/ART_BRIEF.md` is the **commission-ready art
brief** — for a human contract artist (its Appendix A) or a gen-AI art
operator (Appendix B). Governing rule: **every asset is drop-in** — name
the PNG/MP3 correctly, put it in the right folder, relaunch, and it
overrides the programmatic placeholder with zero code changes (`ASSETS.md`
at the game root is the how-to: paths, precedence, fallback chain). The
whole game today is 100% programmatic placeholder art. **The 3-wave plan**
(named characters before props, always):

1. **Wave 1 — named characters + the 8 core thieves** (66 files): each
   core thief gets 6 animation strips + a portrait, plus the named NPCs.
2. **Wave 2 — guards/enemies by type** (43 files): 8 guard types ×
   (3 strips + static + portrait) + devices (drone, camera, turret).
3. **Wave 3 — props, effects, audio**: the consolidated `[manual] [art]` /
   `[manual] [sfx]` backlog — ~30 prop sprites, environment/UI/cutscene
   art quoted separately, ~25 audio line-items.

Milestones: M1 style-lock (1 asset) → M2 Wave 1 → M3 Wave 2 → M4 Wave 3.

**Licensing discipline — commercial rights or it doesn't merge.** All
delivered artwork is **work-for-hire** (copyright vests in you on payment),
falling back to a perpetual, irrevocable, worldwide, **exclusive**
royalty-free commercial license where WFH is unenforceable; the artist
warrants no encumbered third-party or AI material. Every accepted asset
gets one line in an `## License ledger` section of `ASSETS.md` (create it
on first delivery): `<path> — <artist/source> — <license: WFH / exclusive>
— <date> — <invoice/ref>`. **No asset merges without its ledger line.**
Gen-AI assets meet the same bar: generator terms must permit full
commercial use, and the ledger line names tool + prompt. The monthly Asset
Librarian flags ledger gaps (never edits ASSETS.md itself). The brief's
TODO-CEO items are harvested into WORK.md as `[untriaged]` for the
Architect to shape.

## The itch.io channel — builds ship themselves

Every PM release cut exports the game headlessly and pushes builds to
itch.io (`scripts/publish_itch.sh`, release-cut step 7). Infiltrators
pushes to **spraxel/infiltrators**, channels `macos` (universal .zip) +
`windows` (single .exe, embedded pack). The page is auto-created as a
HIDDEN DRAFT on the first push.

**One-time CEO setup (in order):**
```bash
butler login          # opens a browser; authorize once, cached forever
# then push the current release by hand to create the draft page:
bash ~/SpraxelAiCompany/scripts/publish_itch.sh --game infiltrators --version v0.2
```
Then on https://itch.io/dashboard → the new project: set **Visibility →
Restricted** (or Draft + share the secret URL), set the **Generative AI
disclosure** (Yes → Code, Text & Dialog), and you're done — every future
release cut updates the same page automatically.

**Anytime by hand:** the same `publish_itch.sh` line (any `--version`
string); `--dry-run` exports without pushing. Failures never block a
release cut — the PM reports them and you re-run by hand.

**Per-game config** (GAME_CONFIG.yaml — a game with no `publish:` block is
simply never pushed):
```yaml
publish:
  itch_target: "spraxel/infiltrators"
  itch_presets: "macos-playtest,windows-playtest"   # preset → channel = text before first "-"
```
Presets live in the game repo's `export_presets.cfg`. Gotchas we hit so
you don't: universal macOS export requires the project setting
`rendering/textures/vram_compression/import_etc2_astc=true`; export
templates must be installed for the exact Godot version
(`~/Library/Application Support/Godot/export_templates/<version>/`);
macOS builds are unsigned — testers right-click → Open past Gatekeeper.

## Jam mode — the delegate-all experiment

The **delegate-all jam** is a ~48-hour experiment: launch a brand-new tiny
game as a second registered game with `policy.delegate_all: true` and let
the factory run fully unsupervised — Designer ideas auto-accepted, the
Architect answering its own `(Recommended)` options, developers deciding
instead of filing `[needs-ceo]`, placeholders generated instead of
`[manual]` items, work uncapped (`target_per_batch: 999`). The leash is
`policy.budgets.daily_run_cap` (jam config: 120 runs/day ≈ $40-70 — jam
devs run HEADLESS, i.e. metered API-credit spend); the kill switch is
`touch ~/SpraxelAiCompany/.paused`. The full pre-flight, launch, monitoring
and post-mortem procedure is **`~/SpraxelAiCompany/docs/JAM_RUNBOOK.md`** —
follow it verbatim. The whole thing in 5 steps (mirrors the runbook's
"⚡ Quick start"):

```bash
# 1. One-time pre-flight (your hands, ~10 min):
gh auth setup-git                        # pushes never stall on the keychain
gh repo create jam-2026-08 --private     # the jam's remote (any name)
caffeinate -dims &                       # keep the Mac awake all weekend

# 2. In a Claude session, type:
#      /spraxel-launch
#    and say: "delegate-all jam per JAM_RUNBOOK — name it jam-2026-08,
#    Godot, skip the Philosophy interview."

# 3. Claude applies the jam GAME_CONFIG block (see the runbook) + registers
#    the game in COMPANY_CONFIG.yaml games: — you just confirm.

# 4. Start the clock:
rm ~/SpraxelAiCompany/.paused

# 5. ~48 hours later, stop it:
touch ~/SpraxelAiCompany/.paused
```

While it runs: `/spraxel-report` for status; spend shows in
`state/<jamname>/cache/item-costs.tsv`. Note `rm .paused` un-pauses
EVERYTHING (infiltrators' crew included — want jam-only? set infiltrators
`enabled: false` for the weekend).

## Writing and changing agent specs

Every crew agent is a markdown spec at `agents/spraxel-<name>.md`, plus
`agents/_shared.md` (universal rules — bot git identity, config via
`spx_config.py`, report piping — referenced by all specs). `run_agent.sh`
composes the prompt from the spec + tenets + WORK.md sections at fire time,
so **editing a spec changes the agent's next run — no restart, no build**.
To add a scheduled agent: (a) write `agents/spraxel-<name>.md`, (b) add a
`cron:` line under `agents:` in COMPANY_CONFIG.yaml, (c) add a
`models.<name>` assignment there too; the next tick runs it (verify:
`tail -f logs/tick/$(date +%F).log`). Conventions when changing a spec:

- **Models live in config, not specs** — `models:` in COMPANY_CONFIG (or
  the game override) is the truth; never hardcode a model id in a spec.
- **Keep the cadence self-check in sync** — if the agent reads a
  `cadence.<agent>` self-check from GAME_CONFIG, update it with the cron.
- **Inputs are contracts** — if you wire in a required input (the way
  TASTE.md went into Designer/Architect — see the TASTE.md chapter above),
  state what happens when the file is missing, or new games break.
- **Mind the memory** — `.factory/memory/<agent>.md` persists across runs;
  stale memory can fight a behavior-changing edit. Edit/clear it freely.
- **Update this manual in the same commit** (update-discipline box, top).

---

# Part VI — Troubleshooting + reference

Failure modes first, then the lookup tables: common operations, every
config knob, every script, every agent, every skill, every file-of-truth.

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
- Config `policy.run_mode: "offline"` (COMPANY_CONFIG or the game's
  GAME_CONFIG) — agents exit silently. Flip to `live`.
- Claude session expired — re-run `claude login` in Claude Code.
- Wrong model ID for the agent (claude-CLI errors with `unknown model`).
  The health check catches this — `bash scripts/health_check.sh`.
- Nothing to do (Janitor with no stale items, PM with no reorder needed).

### "The dev loop didn't ship anything"

First: which mode are you in? In interactive mode (**current**), nothing
ships unless a `/spraxel-develop` session is running — check the dashboard
for `PAUSED (interactive-dev)`. Then:

```bash
# What did it try?
ls -t ~/SpraxelAiCompany/logs/<slug>/continuous/$(date +%Y-%m-%d)/ 2>/dev/null

# Loop state (counter, fail streak, last CEO signal)
cat ~/SpraxelAiCompany/state/<slug>/cache/continuous-state.json

# Recent escalations
cat ~/GameProjects/<game>/.factory/escalations.md | tail -40
```

A fail streak ≥ 3 in `continuous-state.json` means the Claude CLI hit 3
consecutive failures (likely rate limit, Sonnet cap, or session expiry).
Check `sonnet_cap.py is-capped`, re-auth if needed, and re-run.

### How the system fails — and how you find out

The instructive war story: **2026-06 → 2026-07-08**, WORK.md grew unchecked
past 400KB, and for ~2 weeks EVERY scheduled crew run died instantly with
"Prompt is too long" — the wrapper counted the fatal replies as retryable
failures, so there was **zero signal**: no MORNING.md, no triage, no
briefings, just silence the CEO didn't notice. Four defenses now exist so
that failure mode (and its cousins) can't stay silent:

1. **Crew-health monitor** — `tick.sh` checks hourly, per game: any agent
   whose last *successful* run is older than 2× its cron cadence lands in
   `state/<slug>/cache/crew-health.txt`; newly-stale agents get a one-time
   crew_health report.
2. **The 🩺 line** — MORNING.md's 📰 News section MUST open with the
   crew-health status, so a dead agent is in your face every morning (and a
   dead *briefer* is conspicuous by its absent MORNING.md — check
   `crew-health.txt` directly if the file didn't update).
3. **Prompt byte-caps** — `run_agent.sh` hard-caps every embedded WORK.md
   section, so an oversized file degrades a prompt instead of killing the
   run; the PM's size-triggered release cut and the Janitor's interim-archive
   failsafe keep WORK.md small in the first place.
4. **Fatal replies escalate** — `run_agent.sh` treats fatal model replies
   ("Prompt is too long", etc.) as non-retryable escalations instead of
   silently retrying into a 30-min-backoff loop.

If you ever suspect silence, the 10-second check is:
`cat ~/SpraxelAiCompany/state/<slug>/cache/crew-health.txt` (empty = green).

### "I committed code mid-cycle and now the dev loop fails to push"

The ship loop fetches and rebases at start of each item, but if
you committed between its fetch and its push, the push fails. Easy fix: run a quick
manual rebase, or just wait — the next batch picks up where
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

## Risks

- **Usage caps + metered spend**: heavy Sonnet dev work rides the
  subscription cap; crew runs bill metered credits. A Sonnet-cap death used
  to look like a mysterious 75-byte log and a retry storm.
  *Mitigation (built)*: `sonnet_cap.py` auto-falls back to Opus while
  capped; the crew-health monitor + 🩺 MORNING.md line surface dead agents;
  `daily_run_cap` (250) auto-pauses a runaway metered day.

- **launchd skips ticks on sleep**: if your Mac sleeps for an hour, the
  daemon skips that hour. `RunAtLoad=true` so it resumes when you log in.
  *Mitigation (built)*: the wake-gap detector — a tick arriving
  >`wake_gap_threshold_secs` (30 min) after the previous one triggers
  `catch_up.sh`, which idempotently replays every crew slot that was due
  today (morning-briefer last). Note it deliberately skips the test runner —
  after a long outage, run the suite manually. `sudo pmset -a sleep 0` if
  you want to keep the Mac awake instead.

- **Locked keychain stalls pushes**: Mac sleep can lock the osxkeychain git
  helper — every push then silently fails and the whole loop stalls.
  *Mitigation*: `gh auth setup-git` re-wires credentials.

- **Bot identity leaks**: if an agent forgets to set `git -c user.email=...`
  per-commit, it commits as the CEO. Each agent spec reiterates this in
  `_shared.md`; the ship-loop wrapper also sets it explicitly on the
  merge commit and the WORK.md update.

- **Designer floods the queue**: 4-6 items every Tue+Fri = 400+ unvetted
  ideas/year. The Janitor cold-archives 30+ day stale items, but CEO triage
  at 5 min/drop isn't sufficient long-term.
  *Mitigation*: trim the `designer` cron (e.g. weekly) or lower
  `designer.ideas_per_run` if it builds up.

- **Reviewer over-blocks**: if the Reviewer agent gets pessimistic, it
  exits 1 often and everything bounces to `[retry]` (and eventually the
  poison-pill auto-escalation). CEO has to re-tune the spec.
  *Mitigation*: regular review of `.factory/reviews/<branch>.md` files.
  Most should be `clean`.

- **WORK.md bloat kills crew prompts**: the June→July 2026 outage. An
  un-cut finished section blows every prompt past the input limit.
  *Mitigation (built)*: PM size-triggered cuts (≥40 items / >150KB),
  Janitor interim-archive failsafe (>200KB / ≥80 items), run_agent.sh
  byte-capped embeds, crew-health monitor to catch it anyway.

## Common operations

### Manually run one agent

```bash
bash ~/SpraxelAiCompany/scripts/run_agent.sh designer
bash ~/SpraxelAiCompany/scripts/run_agent.sh morning-briefer
bash ~/SpraxelAiCompany/scripts/run_agent.sh pm --dry-run     # see prompt, don't fire
```

Logs land at `~/SpraxelAiCompany/logs/<slug>/<agent>/<ts>.log`
(namespaced per game).

### Manually run the dev loop now

In interactive mode (**current**), type `/spraxel-develop` in a Claude Code
session — that IS the dev loop. In headless mode:

```bash
bash ~/SpraxelAiCompany/scripts/continuous_dev.sh
```

(That's the same script `tick.sh` spawns automatically in headless mode —
usually you don't run it by hand. It keeps shipping items until it hits the
per-CEO-signal cap, then sleeps. With `force_interactive_developers: true`
it idles immediately.)

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

If you need to make a manual change while the dev loop is running (a real
bug emergency, a play-test reveal, anything), use the interrupt scripts.
They safely pause the system, preserve in-flight Developer work, and
get you to a clean master in one command:

```bash
# Pause system + kill in-flight agents + stash Developer work + checkout master
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
6. Record state to `state/<slug>/cache/last-interrupt.txt` for `resume.sh`

What `resume.sh` does:
1. Read `state/<slug>/cache/last-interrupt.txt`
2. Checkout the pre-interrupt branch (if any)
3. Pop the stash (if any)
4. `rm .paused` → next tick fires normally

Both scripts are idempotent and refuse to overwrite dirty state.

### Pause one agent only

Comment out the line in `COMPANY_CONFIG.yaml`. Change applies on the next tick.

### Retune cadences

Edit `~/SpraxelAiCompany/COMPANY_CONFIG.yaml`. All times are PT, cron format
`m h dom mon dow`. Examples:

- Run PM twice a day: `cron: "0 7,15 * * *"`
- Move Designer to Sunday: `cron: "0 7 * * 0"`
- Bump the batch cap from 8 to 12: change `target_per_batch: 8` → `target_per_batch: 12`

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

# Last morning briefer run (agent logs are namespaced per game slug)
ls -t ~/SpraxelAiCompany/logs/<slug>/morning_briefer/ | head -1 | xargs -I{} cat ~/SpraxelAiCompany/logs/<slug>/morning_briefer/{}

# Per-item ship logs from the dev loop
ls -t ~/SpraxelAiCompany/logs/<slug>/continuous/$(date +%Y-%m-%d)/ | head
```

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

# If the dev loop is mid-flight and you want to commit safely:
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

# Play-test a specific feature (debug-feature hook from docs/features/<slug>.md)
godot --demo-feature=<slug>

# Free-roam interactive
godot --path .
```

### Check token budget / spend

Post-2026-06-15, there are two pools to watch: the **subscription cap**
(interactive sessions — `/spraxel-develop` dev+review subagents) and the
**metered API-credit pool** (headless `claude -p` crew runs — the dashboard
shows an estimated $ figure via `scripts/token_usage.py` + the
`policy.pricing` table). Signals:

```bash
# Is the CLI session alive?
claude --version    # 0 exit = ok; otherwise re-run `claude login` in Claude Code

# Did anything rate-limit recently? (logs are namespaced per game)
grep -rl "rate limit\|429\|quota" ~/SpraxelAiCompany/logs/<slug>/*/$(date +%Y-%m-%d)*.log

# Dev-loop state (counter, fail streak, last CEO signal)
cat ~/SpraxelAiCompany/state/<slug>/cache/continuous-state.json

# Is Sonnet capped right now? (agents auto-fall back to Opus while it is)
python3 ~/SpraxelAiCompany/scripts/sonnet_cap.py is-capped && echo "capped — running on Opus"

# Today's headless runs (metered!) — the daily_run_cap brake pauses the whole
# system automatically at policy.budgets.daily_run_cap (250) runs/day.
ls ~/SpraxelAiCompany/logs/<slug>/*/$(date +%Y-%m-%d)*.log 2>/dev/null | wc -l

# Manual brake if spend looks wrong:
touch ~/SpraxelAiCompany/.paused
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
#   assigns priority, appends to WORK.md ## Up-and-coming work, commits.
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
ls ~/SpraxelAiCompany/state/<slug>/locks/  # each lockdir = an in-flight agent

# "Any crew agent silently dead?"
cat ~/SpraxelAiCompany/state/<slug>/cache/crew-health.txt  # empty = all green

# "Revert something the dev loop landed but broke things"
cd ~/GameProjects/<game>
git revert <sha> && git push origin master
```

### Uninstall

```bash
bash ~/SpraxelAiCompany/scripts/install_daemon.sh stop
# (if the retired com.spraxel.localtests plist is still loaded from the old days:)
cd ~/GameProjects/<game> && bash scripts/install_local_tests.sh stop
```

## Configuration reference

Two files hold all CEO-tunable knobs, and **every read goes through ONE
loader**: `scripts/spx_config.py get <dotted.key> [--game <slug>]`, which
resolves `COMPANY_CONFIG.yaml` first, then deep-merges the game's
`GAME_CONFIG.yaml` on top. The split is intentional:

- **`COMPANY_CONFIG.yaml`** (in this framework repo) — **company-wide
  defaults + how the daemon runs**. The `games:` registry, cron
  expressions, model assignments, worker counts, ship-cap, retry/backoff
  policy, budgets. Shared across all games this Mac runs. (`schedule.yaml`
  is now just a back-compat symlink to this file.)
- **`GAME_CONFIG.yaml`** (in each game repo) — **per-game overrides**.
  Identity, cadence, per-agent thresholds, dev binary, model overrides —
  any COMPANY_CONFIG key, overridden for that game.

(`Philosophy.md` is **prose-only** now — design tenets in plain English, no
YAML. All former Philosophy knobs live in GAME_CONFIG.yaml.)

If you have to choose, ask "does it depend on the game?" → GAME_CONFIG.yaml;
"is it a company-wide default or daemon behavior?" → COMPANY_CONFIG.yaml.

### `COMPANY_CONFIG.yaml#continuous` knobs (framework runtime)

| Knob | Default | What it does |
|---|---|---|
| `force_interactive_developers` | **true** (current) | Mode switch: true = NO headless dev workers; dev runs via `/spraxel-develop` (subscription-side). See "The two developer modes". |
| `target_per_batch` | **8** | Ships per CEO signal before the loop parks. Shared across parallel workers. |
| `retry_per_item` | 1 | Max attempts per developer item (within one run) before bouncing to `[retry]`. |
| `retry_escalate_threshold` | 5 | Total `[retry]` attempts on ONE item before the poison-pill brake auto-escalates it. |
| `dev_concurrency` | 3 | Parallel headless worker count (worktrees + claude sessions). Each shares the cap. `global.max_total_dev_workers` (4) caps the sum across games. |
| `max_file_lines` | 1500 | "No god files" cap — reviewer blocks growth past this. |
| `max_fail_streak` | 3 | Consecutive failures (any worker) before the cascade brake kicks in. |
| `fail_backoff_seconds` | 1800 | Sleep duration when fail-streak brake fires. |
| `poll_interval_seconds` | 60 | Cadence to re-check pause flag + cap counter. |
| `idle_threshold` | 5 | Empty-queue ticks before dropping to long sleep. |
| `idle_sleep_seconds` | 300 | Long sleep duration when queue is empty. |
| `dev_stall_minutes` | 15 | Kill a dev after this long with NO worktree writes. |
| `max_dev_minutes` | 90 | Absolute per-dev backstop. |
| `wake_gap_threshold_secs` | 1800 | Tick gap that counts as "Mac was asleep" → catch_up replays missed crew agents. |

### Other `COMPANY_CONFIG.yaml` sections

| Section | What it holds |
|---|---|
| `games:` | The multi-game registry — one entry per game (`dir`, `enabled`); every enabled game runs concurrently, namespaced by slug. |
| `agents:` | Cron expression per crew agent. Edit freely — changes apply on next tick (within 60s). All evaluated in America/Los_Angeles. Format: `minute hour day-of-month month day-of-week`. |
| `models:` | **SOURCE OF TRUTH** for agent → model. Currently: architect=opus; developer/designer/playtester/producer/blogger/demo_creator/pm/morning_briefer=sonnet; reviewer/triager/janitor/asset_librarian=haiku. `models.ids` maps short names → full model ids (a model upgrade is a config edit, not a code edit). |
| `policy:` | `run_mode`, `delegate_all` (full-autonomy switch), `sonnet_cap_reprobe_secs`, `budgets` (incl. **`daily_run_cap: 250`** — auto-pause runaway brake), `pricing` (per-MTok rates for the dashboard's metered-$ estimate). |
| `test_runner:` | `max_minutes` (120), `force_after_engine_hours` (100), `interactive_sweep_after_hours` (interactive-mode opt-in sweep). |
| `reaper:` / `agent_retry:` / `tick:` / `dashboard:` | Hung-agent reaping limits, per-invocation retry policy, tick interval, dashboard rendering counts (`recent_ships: 15`, `ceo_actions: 10`). |

### `GAME_CONFIG.yaml` knobs (per-game)

| Section | Knob | Default | What it does |
|---|---|---|---|
| `identity` | `name`, `pitch`, `must_include`, `must_not_include` | (game-specific) | Used by Designer/Producer to filter ideas against the game's tone. |
| `cadence` | `release`, `blogger`, … | (game-specific) | Release cadence (e.g. `"biweekly saturdays"`) + agent cadence self-checks. Keep `cadence.blogger` in sync with the COMPANY_CONFIG cron. |
| `continuous` | `force_interactive_developers` | inherits company value | Per-game dev-mode override (infiltrators: `true`). |
| `designer` | `ideas_per_run` | 5 | How many `[idea]` items the Designer drops per run. |
| `designer` | `quality_criteria` | (game-specific) | Sentence describing what counts as a "good" idea. |
| `ceo` | `do_not_disturb` | `["00:00-07:30"]` | Time windows when agents must not page the CEO. |
| `blog` | `voice`, `template`, `publish_target` | (game-specific) | Blogger reads this for tone + format. |
| `dev` | `godot_binary` | (system path) | Used by `run_local_tests.sh` + `capture_demo.sh`. |
| `dev` | `velocity_issues_per_release` | 6 | PM release-capacity target (`infinite` disables the capacity gate). |
| `janitor` | `cold_threshold_days` | 30 | Untouched items get `[cold]` retag after this many days. |
| `janitor` | `log_retention_days` | 60 | Delete agent log files older than this. |
| `janitor` | `demo_retention_days` | 30 | Prune demo folders older than this. |
| `morning_briefer` | `playtest_count` | 10 | Features to surface in MORNING.md ▶ Play-test section. |
| `models` | per-agent short name / full id | inherits company `models:` | Per-game model overrides. |
| `policy.run_mode` | `live` / `offline` | `live` | Hard kill-switch — gates whether agents actually do work. |

All GAME_CONFIG knobs are optional; the loader falls back to the
COMPANY_CONFIG value (or the agent's built-in default) if a key is missing.
So a minimal GAME_CONFIG.yaml just needs `identity` + `dev.godot_binary` —
everything else is tuning over time.

## Reference: scripts, agents, processes

### Scripts in `~/SpraxelAiCompany/scripts/`

| Script | Purpose | Invoked by |
|--------|---------|------------|
| **`tick.sh`** | The launchd-fired heartbeat. Every 60s: reads COMPANY_CONFIG (+ per-game GAME_CONFIG via the loader), **iterates every enabled game in `games:`**, fires due crew agents, keeps `continuous_dev.sh` alive (headless mode; spawns NO dev workers in interactive mode), accrues engine on-time, dispatches the batch test runner when triggered (cap+drained, or 100h), runs the **hourly crew-health monitor**, replays missed crew slots after a Mac-sleep wake gap (`catch_up.sh`), and enforces the `daily_run_cap` auto-pause brake. | `com.spraxel.tick.plist` (launchd) |
| **`continuous_dev.sh`** | Long-running headless Developer loop (Mode A). Ships items until `target_per_batch` reached since last CEO signal, then sleeps. Detects clarifications + lock-conflicts. Devs run NO tests (except re-running a `[test_failure]`'s named test as that item's merge gate); idles while a test-runner run is scheduled/active, and idles when `force_interactive_developers` is on. Per-worker lock `state/<slug>/locks/continuous-wN.lockdir`. | spawned by `tick.sh` if not alive (headless mode) |
| **`interactive_dev_step.sh`** | The `/spraxel-develop` skill's helper (Mode B — **current**): per-game claim/fail/ship/merge subcommands, cap-status, heartbeat marker, orphan-claim release. Owns all lock + WORK.md mutations so the interactive session never hand-edits state. | the `/spraxel-develop` skill |
| **`ship_lib.sh`** | Shared per-item ship-pipeline helpers that BOTH dev modes source — behavior-critical invariants live here ONCE: deterministic branch names (`ship_branch_for`), atomic counter bumps (`ship_bump_counter`), the Game.md survival gate, striking shipped items, and `ship_report` (the per-ship 📰 News line + its cost stamp via `ship_item_cost`, appended to `state/<slug>/cache/item-costs.tsv`). Callers set `REPO_DIR`/`WORKMD`/`SLUGIFY`/`STATE_FILE` before sourcing. | sourced by `continuous_dev.sh` + `interactive_dev_step.sh` |
| **`spx_config.py`** | THE config loader: `get <dotted.key> [--game <slug>]`, `game-dir`, `current`/`set-current`. Resolves COMPANY_CONFIG.yaml, deep-merges GAME_CONFIG.yaml. Every agent + script reads config through it. | everything |
| **`gctx.sh`** | Game-context shim: given `--game <slug>`, exports the namespaced dirs (`LOCKS_DIR`/`CACHE_DIR`/`GAME_LOGS_DIR`/`WORKTREES_DIR` → `state/<slug>/…`, `logs/<slug>/…`, `.worktrees/<slug>/…`). | sourced by the other scripts |
| **`sonnet_cap.py`** | Sonnet usage-cap detector + auto-fallback flag: while capped, Sonnet agents (and the interactive dev subagent) run on Opus; re-probes Sonnet after `policy.sonnet_cap_reprobe_secs` (or the cap message's reset time). | `run_agent.sh`, `/spraxel-develop` |
| **`catch_up.sh`** | Wake-gap replayer: after the Mac slept through cron slots, idempotently re-fires every crew agent that was due today (morning-briefer last). Skips the test runner — run the suite manually after an outage. | `tick.sh` (wake-gap detector), CEO manually |
| **`test_runner.sh`** | The batch test runner. Runs the WHOLE suite serially (no contention), files each failure as a `[test_failure]` item at the top of the queue. Tracks progress across runs; budget `test_runner.max_minutes`. Exclusive via `state/<slug>/locks/test-runner.lockdir`. NOT cron-fired. | dispatched by `tick.sh` (cap+drained, or `force_after_engine_hours`) |
| **`run_agent.sh <name>`** | Wraps one Claude invocation. Reads the agent spec, composes the prompt (spec + tenets + WORK.md sections + optional `SPRAXEL_ITEM_BRIEF`) — **every embedded section is byte-capped** (an oversized WORK.md degrades the prompt instead of killing the run) — resolves the model via `COMPANY_CONFIG models:` (Sonnet-cap fallback to Opus), calls `claude -p`. Treats fatal replies ("Prompt is too long" etc.) as **non-retryable escalations** instead of silent retries. Per-agent lock prevents double-fire. | `tick.sh` (cron), `continuous_dev.sh` (per item), CEO manually |
| **`install_daemon.sh`** | Drops `com.spraxel.tick.plist` into `~/Library/LaunchAgents/`. Args: `install` / `stop` / `status` / `restart`. | CEO, one-time |
| **`install_skills.sh`** | Symlinks every `skills/*/` dir into `~/.claude/skills/` (the only place Claude Code discovers skills). Idempotent; re-run whenever a `/spraxel-*` command is missing or you add/rename a skill. | CEO, setup + after skill changes |
| **`new_game.sh <dir>`** | Bootstraps a new game repo with GAME_CONFIG.yaml, Philosophy.md (prose), Game.md index, WORK.md, `.gitignore`, `.factory/`, `test/unit/`, `scripts/scenarios/`. The `/spraxel-launch` skill wraps this with a full onboarding interview. | CEO, when starting a new game |
| **`workmd.py`** | Parser + CLI for WORK.md (4-section layout). Subcommands: `parse / top / append / ship / escalate / resume / promote / drop / bump / clarify / claim / release-wip / sync-escalations / release-cut` (externalizes the finished section to `WORK_v<version>.md`) + shaping: `shape-list / shape-start / shape-detail / shape-finalize / shape-pass` + epics: `shape-epic / reconcile-epics`. Atomic mkdir-locked. | every agent + CEO |
| **`cron_match.py`** | Evaluates a 5-field cron expression against `now` in a timezone. Used by `tick.sh` to decide who fires and by `spraxel_report.py` to compute next firings. | `tick.sh`, `spraxel_report.py` |
| **`slugify.py`** | Title → kebab-case branch slug. | `continuous_dev.sh` for branch names |
| **`health_check.sh`** | Scans today's `logs/*/<YYYY-MM-DD>*.log` for error patterns (unknown model, rate limit, session expired, fatal, traceback). Outputs a markdown block. | `morning-briefer` agent (step 1), CEO manually |
| **`spraxel_report.py`** | Status snapshot generator: right-now state, last 24h, last 7 days, next 20 scheduled events. Pure-local read-only — no Claude tokens. Powers `/spraxel-report`. | CEO via `/spraxel-report` skill or directly |
| **`dashboard.py`** | Always-on TUI dashboard. Auto-refresh every 5 s (configurable via `--interval`). Compact view: status (incl. `RUNNING/PAUSED (interactive-dev)` from the `/spraxel-develop` heartbeat) / tick / wrapper / cap counter / current item / today's totals + estimated metered $ / **next 10 scheduled fires** / **next 10 CEO action items** (urgency-ordered: `[needs-ceo]` > `[escalated]` > triage questionnaires (`TRIAGE.md`) > play-test > `[bug]` > `[idea]` > MANUAL > dictation backlog; color-coded) / **last 15 shipped** (sha + relative age + clean subject) / last log line. Stdlib only — no tokens, no third-party deps. Run in a terminal you leave open. | CEO, runs continuously while logged in |
| **`token_report.sh`** | Counts `claude -p` invocations per agent over a window. Compares to `policy.budgets.by_agent_percent` (config). Flags drift >`drift_warn_percent` (25). | CEO manually (weekly check); not yet scheduled |
| **`item_cost.py`** | Per-item token-cost estimator: sums assistant-message usage from the `~/.claude/projects/**/*.jsonl` transcripts inside a time window, prices via `policy.pricing` (longest-prefix model match). `--since <epoch/ISO> [--until …] [--dir-filter worker-<id>] [--pool all/api_credit/subscription] [--json]`. Zero Claude tokens; prints `$0.00` + exit 0 when nothing matches — cost is decoration, never a gate. | `ship_lib.sh` (`ship_report`), CEO ad hoc |
| **`capture_demo.sh <slug>`** | Records a Godot --demo-feature run via Godot's built-in Movie Maker (`--write-movie`) + ffmpeg encoding to H.264 .mp4 + extracts a .png still at 3s. No Screen Recording permission needed (engine framebuffer, not screen pixels). Requires ffmpeg on PATH; exits rc=3 if missing. Exits rc=5 with warning if recording is suspiciously short (test-style scenarios that auto-quit). | `demo-creator` agent |
| **`backfill_escalations.py`** | One-shot migration. Reads pre-redesign `.factory/escalations.md` entries (terse with log-link format), restores items to WORK.md as `[escalated]`, rewrites escalations.md with the new self-contained per-block format. Idempotent. | CEO, one-time per game repo |
| **`checkin.sh`** | Explicit CEO signal — touches `state/<slug>/cache/ceo-checkin.ts`. The ship loop polls this and resets the batch counter on detection (a parked `/spraxel-develop` also resumes on it). | CEO manually when read-only interaction wasn't enough |
| **`with_master_lock.sh [-m msg] [--game <slug>] <workmd-verb> …`** | The SAFE wrapper for CEO WORK.md edits: takes the master-push lock, syncs, runs the `workmd.py` verb, commits + pushes. A bare `workmd.py` edit can be eaten by a worker's `reset --hard`. | CEO (approve/drop/bump/promote/resume) |
| **`report.sh <agent>`** | Agents pipe a dated markdown activity report to it at end of run → `.factory/local/reports/<ts>-<agent>.md` (CEO-local, Janitor-pruned). The Morning Briefer distills all reports since the last briefing into MORNING.md's 📰 News section. (Developer/Reviewer don't self-report — the continuous loop writes one ship report per shipped item.) | every agent (auto, per `_shared.md`) |
| **`amend.sh <slug-or-sha> "feedback"`** | CEO keeps a shipped feature but queues a refinement pass. Appends `[amend] Refine: <title>` to WORK.md `## Up-and-coming work` with sha + feedback. Master untouched — Developer iterates on existing code on the next dev fire. | CEO during play-test |
| **`reject.sh <slug-or-sha> "reason"`** | CEO undoes a shipped feature. `git revert` the `feat:` + paired `work: shipped` commits on master, appends `[reject] Re-implement: <title>` to WORK.md `## Up-and-coming work` with sha + reason. Developer re-implements on the next dev fire, knowing the old approach was wrong. | CEO during play-test |
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
| **`run_local_tests.sh`** | Runs GUT under `test/unit/` + every `scripts/scenarios/*.gd`, writes `.factory/local-tests-status.json`. Exit 0 = green, 1 = failures, 2 = setup error. NEW: `--list` enumerates canonical test-refs; `--only <ref>` runs exactly one test. | `test_runner.sh` (`--list` + `--only` per ref); `continuous_dev.sh` (`--only` for a `[test_failure]` fix gate); CEO manually |
| **`run_unit_tests.sh`** | Fast GUT-only runner. No class-cache refresh, no scenarios, no notifications. | CEO iterating on a specific test |
| **`install_local_tests.sh`** | Drops `com.spraxel.localtests.plist`. Args: `install` / `stop` / `status`. **Legacy — the 30-min test daemon is retired**; keep only for `stop` on old installs. | (retired) |

### Long-running processes

When the system is healthy, these are the processes you should see in `ps`
(in interactive-developer mode — the current default — there is **no**
`continuous_dev.sh` worker; dev work lives inside your Claude Code session
instead):

```
$ pgrep -fl 'continuous_dev|run_agent|com.spraxel|claude --model'

PID  PPID  COMMAND
N    1     /usr/sbin/launchd ...com.spraxel.tick.plist...        (launchd dispatcher)
N    1     bash continuous_dev.sh                                (headless mode only)
N    cont  bash run_agent.sh developer                           (current Developer)
N    rag   claude --model claude-sonnet-4-6 -p                   (current claude inv)
```

Things to watch for that mean trouble:
- **Two `continuous_dev.sh` with the same worker id** → race condition. Run `bash scripts/interrupt.sh` and resume.
- **Any `continuous_dev.sh` dev activity while `force_interactive_developers` is true** → mode confusion; it should idle. Check the tick log.
- **`run_agent.sh` with parent PID 1** → orphan (the wrapper died but the child survived). Holds `state/<slug>/locks/<agent>.lockdir` (the reaper kills it past its class limit). Same fix: `interrupt.sh`.
- **`claude --model ...` running >30 min** → either a real long Developer (fine) or claude hung. If `ps` CPU isn't advancing, kill it.

### Agents (`~/SpraxelAiCompany/agents/spraxel-*.md`)

13 agent specs + `_shared.md` (universal rules referenced by all).

| Agent | Model | Cadence | Triggered by | Writes to |
|-------|-------|---------|--------------|-----------|
| **developer** | sonnet | per item | the ship loop (`continuous_dev.sh` or `/spraxel-develop`) | game branch (code), commits |
| **reviewer** | haiku | per item | the ship loop, pre-merge | `.factory/reviews/<branch>.md` |
| **playtester** | sonnet | daily 03:00 PT | `tick.sh` cron | `.factory/inbox/playtest-findings.md` (classified findings + CEO test recipes) |
| **triager** | haiku | daily 04:00 PT | `tick.sh` cron | WORK.md (appends `[needs-ceo] [bug]` items) |
| **morning-briefer** | sonnet | daily 05:00 PT | `tick.sh` cron | `.factory/local/MORNING.md` (🩺 crew-health line first in 📰 News) |
| **demo-creator** | sonnet | daily 05:30 PT | `tick.sh` cron | `.factory/demos/<date>/recipe.md` (top-3 recipes) + best-effort captures (rc=5 skip ledger) |
| **pm** | sonnet | daily 06:00 PT (+ release cuts: calendar or size trigger) | `tick.sh` cron | WORK.md (re-orders; `release-cut` → `WORK_v<version>.md`) |
| **designer** | sonnet | Tue + Fri 04:30 PT (+ dry-queue days) | `tick.sh` cron | WORK.md (appends `[idea]` items) |
| **architect** | **opus** | 06:30 & 21:00 PT + reactive on `[untriaged]` | `tick.sh` cron + reactive grep | WORK.md (shape-* tag/spec edits) + `.factory/local/TRIAGE.md` (questionnaires + `ESC ·` ballots) |
| **blogger** | sonnet | Tue + Fri 06:45 PT (release-driven self-gate) | `tick.sh` cron | `blog/<date>` branch |
| **janitor** | haiku | Sun 01:00 PT | `tick.sh` cron | WORK.md (cold-archives; interim size-failsafe archive), branches (deletes merged), logs (prunes >60 days) |
| **asset-librarian** | haiku | monthly 1st 07:00 PT | `tick.sh` cron | `.factory/asset-report-<date>.md`, MORNING.md note |
| **producer** | sonnet | on-demand (`/spraxel-producer`) | CEO via skill | WORK.md (from `.factory/inbox/raw.md`) |

### Skills (`~/SpraxelAiCompany/skills/`, linked into `~/.claude/skills/` by `scripts/install_skills.sh` — if a `/spraxel-*` command is missing, re-run that script)

| Skill | Trigger | Purpose |
|-------|---------|---------|
| **`/spraxel-develop [N]`** | CEO types in Claude Code | **The interactive dev loop** (current dev mode): claims + builds WORK.md items with Sonnet dev / Haiku review subagents, ships to the batch cap, parks + self-resumes on a poke. Subscription-side. |
| **`/spraxel-inbox`** (or `/inbox`) | CEO types in Claude Code | Full CEO digest any time of day: what's blocking, morning-style briefing, action checklist for the current time slot |
| **`/spraxel-producer`** (or `/producer`) | CEO types in Claude Code | Converts `.factory/inbox/raw.md` + dictation files into clean WORK.md items; flags ⚠️ concerns inline |
| **`/spraxel-report`** (or `/report`) | CEO types in Claude Code, or "what's going on?" | Immediate system status: now / last 24h / last week / next 20 scheduled events. Runs `scripts/spraxel_report.py` (no Claude tokens used for data gathering) |
| **`/spraxel-launch`** | CEO types in Claude Code | Onboards a NEW game/project: interview → scaffold via `new_game.sh` → register in the `games:` registry alongside existing games → optionally seed starter work |

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

All per-game operational state is **namespaced by game slug** (multi-game):
locks + caches under `state/<slug>/`, logs under `logs/<slug>/`, worktrees
under `.worktrees/<slug>/`.

| Path | Purpose |
|------|---------|
| `~/SpraxelAiCompany/.paused` | Touch-flag: when present, all agent dispatches no-op. `rm` to resume. (Also auto-touched by the `daily_run_cap` brake.) |
| `~/SpraxelAiCompany/state/<slug>/locks/<agent>.lockdir` | Per-agent atomic lock. Held while agent is in-flight. Stale lockdirs from crashes are cleaned by `tick.sh` / the reaper. |
| `~/SpraxelAiCompany/state/<slug>/cache/continuous-state.json` | Counter, last CEO signal SHA + timestamp. Read by the ship loop each iteration. |
| `~/SpraxelAiCompany/state/<slug>/cache/ceo-checkin.ts` | Touched by `scripts/checkin.sh`. Polled by the ship loop for "manual signal" detection. |
| `~/SpraxelAiCompany/state/<slug>/cache/crew-health.txt` | Hourly crew-health snapshot (empty = all green). Feeds MORNING.md's 🩺 line. |
| `~/SpraxelAiCompany/state/<slug>/cache/item-costs.tsv` | Per-item spend ledger — one tab-separated row per priced ship (timestamp, cost, title), appended by `ship_lib.sh`'s `ship_report`; summed into MORNING.md's 💸 Batch cost line. |
| `~/SpraxelAiCompany/state/<slug>/cache/last-interrupt.txt` | Pre-interrupt branch + stash ref, used by `resume.sh`. |
| `~/SpraxelAiCompany/.worktrees/<slug>/worker-<id>/` | Persistent per-worker git worktree (headless mode). Interactive mode uses `.worktrees/<slug>/interactive/`. |
| `~/SpraxelAiCompany/logs/tick/<YYYY-MM-DD>.log` | One line per minute from `tick.sh`. |
| `~/SpraxelAiCompany/logs/<slug>/<agent>/<ts>.log` | Full claude conversation log per agent invocation. |
| `~/SpraxelAiCompany/logs/<slug>/continuous/<YYYY-MM-DD>/w<id>-<slug>.log` | Per-item ship log (Developer + Reviewer + merge). |

### Game-side state (`~/GameProjects/<game>/.factory/`)

| Path | Purpose |
|------|---------|
| `escalations.md` | **Derived snapshot** of current `[escalated]` items — regenerated from WORK.md every iter by `sync-escalations` (don't hand-edit; retag in WORK.md instead). |
| `local/MORNING.md` | The daily CEO briefing (gitignored, CEO-local). |
| `local/TRIAGE.md` | Architect questionnaires + `ESC ·` escalation ballots (gitignored, CEO-local). |
| `local-tests-status.json` | Last `run_local_tests.sh` result: pass/fail, list of failures, log path. |
| `reviews/<branch>.md` | Per-branch Reviewer findings (gitignored — ephemeral, local-only). |
| `inbox/raw.md` | Where CEO dumps dictation; `/spraxel-producer` drains this. |
| `inbox/dictation/*.md` | Phone voice-memo exports; `/spraxel-producer` also drains these. |
| `demos/<date>/recipe.md` | Demo-creator recipes (top-3) + captures. |
| `local-test-logs/<stamp>.log` | Full output of each `run_local_tests.sh` run (gitignored). |

## What I'm NOT doing in this workflow

- No GitHub Issues (deleted).
- No GitHub Actions (deleted from both repos).
- No `/schedule` Anthropic routines (you should delete them in claude.ai
  Settings → Scheduled tasks; they're costing per-token).
- No PR ceremony (the ship loop merges directly to master after Reviewer +
  tests pass).
- No `keepalive.yml` (no GH cron to keep alive).
- No `cost-report.yml` (spend is tracked locally — `token_usage.py` + the dashboard's $ estimate).
- No `factory-log.yml` (no event ledger; everything is in git log + logs/).
- No `Concierge` / `Factory Daily Log issue #5` (replaced by MORNING.md).

### Design decisions FAQ — why we don't do those things

These are the "decided once, don't revisit" rationale notes. Each was
weighed against the offline single-operator constraint and ruled out.

**Why no PR workflow?**
Decided 2026-05-25: in a one-person studio, PRs add ceremony without
value. The ship loop does Developer → Reviewer → merge in
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
Loss: no auto-CI on PRs — but there are no PRs now, and the batch test
runner covers the suite locally.

**Why no `/schedule` Anthropic routines?**
Decided 2026-05-25: `/schedule` bills per-token, separate from the Max
plan. At the time, `claude -p` headless on Max was flat-fee under the
weekly cap. (Post-2026-06-15 headless is metered too — the answer now is
local control + the interactive-mode lever, not just price.)

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

- ~~**Multi-game bootstrap**~~ — **SHIPPED (2026-06-15)**: `tick.sh`
  iterates the `games:` registry; per-game state is namespaced
  (`state/<slug>/`, `logs/<slug>/`, `.worktrees/<slug>/`), with a
  `global.max_total_dev_workers` ceiling. Onboard new games via
  `/spraxel-launch`.
- ~~**Token-usage backpressure**~~ — **SHIPPED**: the `daily_run_cap`
  brake auto-pauses a runaway day, `sonnet_cap.py` handles the Sonnet cap,
  and the crew-health monitor surfaces silent failures.
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
gh pr list / pr checkout    # no PRs — the ship loop merges directly to master
gh run list / run watch     # no Actions — local launchd + claude -p instead
gh workflow run ...         # no workflows
gh pr edit --add-label X    # no labels driving anything
```

Anthropic `/schedule` routines (PM, Designer, Triager, Concierge, Janitor,
Blogger, Asset Librarian, Keepalive :17/:47) — delete them in claude.ai →
Settings → Scheduled tasks; they billed per token, separate from your Max
plan.

## Files-of-truth (where to look for X)

| What | Where |
|------|-------|
| Today's CEO routine | `~/GameProjects/<game>/.factory/local/MORNING.md` (or `/spraxel-inbox`) |
| What's in flight / queued | `~/GameProjects/<game>/WORK.md` |
| What's been shipped | git log + WORK.md `## Finished since last release` + `WORK_v*.md` archives |
| Escalations waiting on you | `~/GameProjects/<game>/.factory/escalations.md` (+ `ESC ·` ballots in `.factory/local/TRIAGE.md`) |
| Shaping questionnaires | `~/GameProjects/<game>/.factory/local/TRIAGE.md` |
| Last test run | `~/GameProjects/<game>/.factory/local-tests-status.json` |
| Reviewer's notes per branch | `~/GameProjects/<game>/.factory/reviews/<branch>.md` |
| Crew health (silent-failure check) | `~/SpraxelAiCompany/state/<slug>/cache/crew-health.txt` |
| Agent run logs | `~/SpraxelAiCompany/logs/<slug>/<agent>/<ts>.log` |
| Daemon ticks | `~/SpraxelAiCompany/logs/tick/<YYYY-MM-DD>.log` |
| Quick "is anything broken?" | `bash ~/SpraxelAiCompany/scripts/health_check.sh` |
| Company config (games registry, crons, models, knobs) | `~/SpraxelAiCompany/COMPANY_CONFIG.yaml` |
| Per-game config overrides | `~/GameProjects/<game>/GAME_CONFIG.yaml` |
| Bootstrap a new game | `/spraxel-launch` (or `bash ~/SpraxelAiCompany/scripts/new_game.sh <dir>`) |
| Pause + preserve in-flight work | `bash ~/SpraxelAiCompany/scripts/interrupt.sh` |
| Resume after a manual change | `bash ~/SpraxelAiCompany/scripts/resume.sh` |
| Game's design tenets (prose-only) | `~/GameProjects/<game>/Philosophy.md` |
| Feature inventory | `~/GameProjects/<game>/Game.md` (INDEX) → `docs/features/<slug>.md` per feature |
| The built-in game editors (Level / **Cutscene** / Story Map) | `~/SpraxelAiCompany/EDITORS.md` — hands-on test guide. Note: the Cutscene Editor **exists** (title screen → CUTSCENE EDITOR); ignore any older doc claiming otherwise (the infiltrators repo's OPERATIONS.md §2 has that error — EDITORS.md calls it out) |
| CEO taste profile (revealed preferences, with receipts) | `~/GameProjects/<game>/TASTE.md` — Designer/Architect required reading; Architect appends new patterns |
| Art commissioning brief (3-wave plan) | `~/GameProjects/<game>/docs/ART_BRIEF.md` |
| Asset licensing ledger (no asset merges without a line) | `~/GameProjects/<game>/ASSETS.md` → `## License ledger` |
| What each shipped item cost | `~/SpraxelAiCompany/state/<slug>/cache/item-costs.tsv` (+ MORNING.md's 💸 line) |
| The delegate-all jam procedure | `~/SpraxelAiCompany/docs/JAM_RUNBOOK.md` |
| WORK.md format spec | `~/SpraxelAiCompany/docs/WORK_MD_FORMAT.md` |
