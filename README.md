# Spraxel AI Company

A meta-framework that turns a Claude Max subscription into a small, autonomous
gamedev studio — running **entirely on your Mac**.

You — the **CEO** — keep the human-only work: art, music, storyline, gameplay
design, dictation, playtesting. A roster of Claude agents handles code,
planning, code review, bug triage, devlog drafting, and asset hygiene.

## How a day works

You don't keep a Claude Code window open. **Everything runs locally**:

- A single **launchd daemon** (`com.spraxel.tick`) ticks every 60 seconds.
- The tick script reads `schedule.yaml` and dispatches whichever crew agents
  are due, and keeps the continuous Developer loop alive.
- Each crew agent fires as **`claude -p` headless** — **metered API-credit
  spend since 2026-06-15** (kept cheap: Haiku-heavy roles + byte-capped
  prompts + the daily run/$ caps). Development itself runs subscription-side
  via the interactive `/spraxel-develop` loop when
  `continuous.force_interactive_developers` is on.
- The agents read and write **`WORK.md`** (the single source of truth) — no
  GitHub Issues, no GitHub Actions, no Anthropic `/schedule` routines.
- Code commits push to GitHub (free, unlimited) for backup and visibility.

```
─ Continuous loop (always on) ──────────────────────────────────
ANY TIME   continuous_dev.sh  — long-running Developer loop
                               picks top of WORK.md ## Todo (skips [idea]/
                               [cold]/[manual]/[future]/[escalated]/
                               [needs-ceo]/[concern]/[untriaged]/
                               [untriaged-proposal-active]/[epic]; picks up
                               [resume]). Epic subtasks are claimed strictly
                               in seq order (next one only after the prior ships)
                               branch → claude -p developer (NO tests) →
                               reviewer → squash-merge → push
                               sleeps when cap hit (target_per_batch since
                               last CEO signal); resumes on any non-bot
                               commit or `bash scripts/checkin.sh`

─ Testing (batch test runner — NOT a cron) ─────────────────────
TRIGGERED  test_runner.sh     — devs run NO tests; this runs the WHOLE
                               suite serially (no CPU contention) and files
                               each failure as a [test_failure] item at the
                               top of WORK.md. Dispatched by tick.sh when the
                               ship cap maxes out + workers drain, or after
                               test_runner.force_after_engine_hours (100h) of
                               engine on-time. Runs EXCLUSIVELY (no new workers
                               spawn; existing ones finish + idle). A worker
                               fixing a [test_failure] re-runs only that one
                               named test as its merge gate. (Replaces the old
                               com.spraxel.localtests 30-min daemon.)

─ Daily crew agents (times America/Los_Angeles — the live dial is
  COMPANY_CONFIG.yaml `agents:`; these can drift, that file can't) ─
03:00      playtester        — actively plays the game; writes bug
                               candidates to .factory/inbox/playtest-findings.md
04:00      triager           — consolidates playtest + test failures into
                               [bug] items in WORK.md
05:00      morning-briefer   — writes .factory/local/MORNING.md (gitignored;
                               CEO-only file — the morning routine entry). Leads
                               with a 📰 News digest distilled from every agent's
                               dated report since the last briefing.
05:30      demo-creator      — writes .factory/demos/<date>/recipe.md
                               (always) + best-effort Godot --write-movie
                               capture (when Mac is awake)
06:00      pm                — reorders top of ## Todo; biweekly Monday
                               release-cut (auto-tags v0.N, generates notes)
06:30,     architect         — shapes [untriaged] feature work into buildable
21:00 +                        specs: fast-pass concrete items, or write a
reactive                       /plan-style questionnaire to .factory/local/
                               TRIAGE.md; on your answers, finalize the spec OR
                               decompose into an [epic] + sequential subtasks.
                               Also wakes within ~60s when you add untriaged
                               work or save TRIAGE.md answers.

─ Weekly ───────────────────────────────────────────────────────
Tue+Fri 04:30  designer      — drops 4-6 [idea] items + 0-3 [concern] items;
(+ daily                       audits implemented + planned work vs Philosophy.md
 when dry)                     and escalates any conflict to the CEO
                               in WORK.md (the [concern]s flag game-wide
                               issues — feature bloat, philosophical drift).
                               ALSO auto-runs on other days when the
                               buildable queue is dry (devs out of work).
Tue+Fri 06:45  blogger       — release-gated devlog: drafts blog/content/posts/
                               draft-<date>-<slug>.md when a release was cut (or
                               14d + 3 player-facing commits); pushes
                               blog/<date> branch for CEO humanization
Sun 01:00      janitor       — cold-archives stale Todo items, prunes
                               merged branches + 60+-day logs, sweeps
                               orphan escalated branches
1st of month   asset-librarian — scans assets/ for orphans + license gaps

─ On-demand CEO slash-commands ─────────────────────────────────
/spraxel-inbox    — morning routine (walk MORNING.md sections)
/spraxel-producer — convert dictation + raw.md into WORK.md items
                    (Producer flags ⚠️ concerns on questionable ideas
                    but always appends as CEO requested — advisory only)
/spraxel-report   — immediate status snapshot: now / last 24 h / last
                    week / next 20 scheduled events
/spraxel-develop  — interactive dev loop (subscription-side): claim →
                    build → review → squash-merge → ship, item by item
/spraxel-launch   — onboard a NEW game into the games: registry

─ Always-on dashboard (optional, no tokens) ────────────────────
python3 ~/SpraxelAiCompany/scripts/dashboard.py
  — leave running in a corner terminal. Auto-refreshes every 5 s.
    Compact glanceable view: status, wrapper PID + uptime, cap
    counter, current item, today's ships/escalations, next 10
    scheduled fires (PT), next 10 CEO action items (needs-ceo /
    escalated / triage questionnaires / play-test / bug / idea /
    manual / dictation backlog — color-coded by urgency), last 20
    shipped (sha + age + subject), last log line.
    Stdlib-only Python — no Claude calls.
```

## New work gets shaped before it's built

Developers never build a vague one-liner. Every new feature item enters the queue
tagged **`[untriaged]`** and is invisible to the loop until the **Architect** agent
(Opus) turns it into a concrete spec — like Claude `/plan` mode, but file-based:

1. **Intake.** The Architect reads each `[untriaged]` item. If it's already clear it
   **fast-passes** it (tag removed → buildable). If it's ambiguous it writes a short
   questionnaire into **one** CEO-facing file, `.factory/local/TRIAGE.md`, and re-tags
   the item `[untriaged-proposal-active]`.
2. **You answer.** Open `TRIAGE.md`, type your answer after each `▶`, and **save** —
   that's the whole hand-back, nothing to submit. The tick daemon wakes the Architect
   within ~60 s (and it also runs at 09:00 & 21:00 PT).
3. **Finalize or decompose.** With your answers the Architect either writes the spec
   into the item and removes the gate (now buildable), or — for a big feature —
   **decomposes** it into a parent `[epic]` plus a sequence of subtask items. Subtasks
   ship strictly in order (each builds on the prior one's merged code), and the parent
   auto-ships once the last subtask lands. If it needs more, it asks a follow-up round
   (up to 5).

Where `[untriaged]` comes from: the Producer tags new feature items; accepting a
Designer `[idea]` (`promote`) converts it to `[untriaged]`; you tag your own hand-adds.
**Bugs and `MANUAL` items skip shaping entirely.** Full walkthrough + FAQ in
[`OPERATIONS.md`](OPERATIONS.md) ("The shaping loop").

## Layout

```
SpraxelAiCompany/
├── schedule.yaml            ← single dial for crew cadences + continuous-loop config
├── scripts/
│   ├── tick.sh              ← launchd fires this every 60 s; dispatches due
│   │                          agents, spawns continuous_dev.sh, sweeps
│   │                          orphan agent lockdirs
│   ├── run_agent.sh         ← invokes one agent via `claude -p`. Sets
│   │                          SPRAXEL_AGENT_RUN=1 (gates the SessionStart
│   │                          hook); branch guard ensures crew commits
│   │                          never land on dev's feat branch
│   ├── continuous_dev.sh    ← always-on Developer loop; clean-slate at iter
│   │                          start; preserves failed branches on origin
│   │                          for [resume]
│   ├── workmd.py            ← WORK.md parser + CLI
│   │                          (parse|top|append|ship|escalate|resume|
│   │                          promote|drop|bump|clarify|release-cut|
│   │                          shape-list|shape-start|shape-detail|
│   │                          shape-finalize|shape-pass|shape-epic|
│   │                          reconcile-epics)
│   ├── cron_match.py        ← 5-field cron expression evaluator
│   ├── slugify.py           ← title → kebab-case branch slug
│   ├── install_daemon.sh    ← drops `com.spraxel.tick.plist` into
│   │                          ~/Library/LaunchAgents/
│   ├── new_game.sh          ← bootstraps a new game repo into the framework
│   ├── checkin.sh           ← explicit CEO signal (touches .cache/ceo-checkin.ts);
│   │                          resets the ship-counter
│   ├── report.sh            ← agents pipe a dated activity report here at end of
│   │                          run → .factory/local/reports/; Morning Briefer
│   │                          distills them into MORNING.md's 📰 News section
│   ├── amend.sh             ← CEO refines a shipped feature → [amend] item
│   │                          (master untouched; dev modifies in place next run)
│   ├── reject.sh            ← CEO reverts a shipped feature → [reject] item
│   │                          (git revert + WORK.md re-queue)
│   ├── interrupt.sh         ← pause + stash + kill the agent tree
│   ├── resume.sh            ← restore from interrupt (paired with above)
│   ├── capture_demo.sh      ← Godot --write-movie + ffmpeg pipeline; outputs
│   │                          .mp4 + .png; no Screen-Recording permissions needed
│   ├── health_check.sh      ← scan today's logs for known error patterns
│   ├── spraxel_report.py    ← status snapshot generator (powers /spraxel-report)
│   ├── token_report.sh      ← per-agent invocation count vs budget
│   ├── backfill_escalations.py ← one-shot migration: pre-redesign
│   │                          escalations.md entries → richer per-block format
│   ├── generate_release_notes.py
│   └── generate_game_md_inventory.py
├── agents/
│   ├── _shared.md           ← universal rules (paused-check, branch-guard,
│   │                          tag conventions, escalation flow)
│   └── spraxel-*.md         ← 13 role specs:
│                              developer, reviewer, pm, designer, architect,
│                              triager, playtester, morning-briefer,
│                              demo-creator, blogger, janitor, asset-librarian,
│                              producer
├── skills/                  ← CEO slash-commands (symlinked into
│   │                          ~/.claude/skills/ by scripts/install_skills.sh)
│   ├── spraxel-develop/     ← /spraxel-develop — interactive dev loop
│   ├── spraxel-inbox/       ← /inbox — morning routine
│   ├── spraxel-launch/      ← /spraxel-launch — onboard a new game
│   ├── spraxel-producer/    ← /producer — dictation → WORK.md
│   └── spraxel-report/      ← /report — immediate status snapshot
├── docs/
│   └── WORK_MD_FORMAT.md    ← WORK.md schema spec
├── template/                ← copied into each new game repo by new_game.sh
│   ├── Philosophy.md
│   ├── Game.md
│   ├── WORK.md
│   ├── .gitignore           ← includes .factory/local/, .factory/reviews/,
│   │                          .factory/local-test-logs/
│   └── scripts/
│       ├── install_local_tests.sh
│       └── run_local_tests.sh
└── logs/
    ├── tick/<YYYY-MM-DD>.log
    ├── continuous/<YYYY-MM-DD>.log    ← wrapper-level log
    ├── continuous/<YYYY-MM-DD>/<slug>.log  ← per-item attempt trail
    └── <agent>/<ts>.log               ← per-agent claude invocation log
```

## Design principles

- **Token efficiency over headcount**. Haiku for cheap, well-scaffolded roles
  (Reviewer, Triager, Janitor, Asset Librarian); Sonnet where reasoning
  matters (Developer, Designer, PM, Morning Briefer, Blogger, Playtester,
  Demo Creator, Producer); Opus only for the Architect. The live assignment
  is `COMPANY_CONFIG.models` — that file wins over this prose. Crew agents
  read scoped slices of WORK.md, not the whole file.
- **WORK.md is the contract.** Agents read/write only via `scripts/workmd.py`.
  No agent owns the file's structure.
- **Tags are the language.** `[bug]`/`[feature]`/`[game-feature]`/`[chore]`
  for kinds; `[idea]`/`[cold]`/`[manual]`/`[needs-ceo]`/`[future]`/
  `[escalated]`/`[resume]`/`[concern]`/`[untriaged]`/
  `[untriaged-proposal-active]`/`[epic]` for state. The wrapper skips all
  the state tags except `[resume]` (the dev's "pick this back up" signal);
  epic subtasks are gated until their predecessor ships.
- **Shape before build.** New feature work is born `[untriaged]` and can't be
  built until the Architect agent turns it into a concrete spec (via a
  `.factory/local/TRIAGE.md` questionnaire you answer, or an auto fast-pass).
  Big features get decomposed into a parent `[epic]` + sequential subtasks so a
  developer ships one focused chunk at a time. Bugs + `MANUAL` items skip it.
- **Fail loudly, preserve work.** A blocked Developer escalates: item
  stays in WORK.md tagged `[escalated]`, feature branch pushed to origin,
  rich failure summary appended to `.factory/escalations.md`. Master is
  never touched by a failed attempt.
- **Pausable.** `touch ~/SpraxelAiCompany/.paused` halts all agent
  dispatch; remove the file to resume. The continuous loop checks the
  flag at the top of every iteration; tick.sh exits early when paused.
- **Advisory, not gatekeeping.** Producer + Designer can flag concerns on
  CEO ideas (cliché / complexity / balance / drift) but never block them.
  CEO has final authority on every item.

## Operating handbook

See [`OPERATIONS.md`](OPERATIONS.md) for the daily CEO routine, manual
overrides, tag reference, and troubleshooting.
