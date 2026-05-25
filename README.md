# Spraxel AI Company

A meta-framework that turns a Claude Max subscription into a small, autonomous
gamedev studio — running **entirely on your Mac**.

You — the **CEO** — keep the human-only work: art, music, storyline, gameplay
design, dictation, playtesting. A roster of Claude agents handles code,
planning, code review, bug triage, devlog drafting, and asset hygiene.

**First target game:** [`infiltrators`](https://github.com/mdl16bit/infiltrators) —
a 2D stealth/heist in Godot 4.6.1 (Lost Vikings × Gunpoint, 8 thieves,
plan-mode slow-mo).

## How a day works

You don't keep a Claude Code window open. **Everything runs locally**:

- A single **launchd daemon** (`com.spraxel.tick`) ticks every 60 seconds.
- The tick script reads `schedule.yaml` and dispatches whichever agents are due.
- Each agent fires as **`claude -p` headless** on your Claude Max plan
  (flat-fee, no marginal cost per run).
- The agents read and write **`WORK.md`** (the single source of truth) — no
  GitHub Issues, no GitHub Actions, no Anthropic `/schedule` routines.
- Code commits push to GitHub (free, unlimited) for backup and visibility.

```
─ Overnight ─────────────────────────────────────────────────────
23:00 PT   overnight_dev.sh  — loop ships up to 10 features
                              picks top of WORK.md ## Todo
                              branch → claude -p developer → tests → reviewer → merge → push
                              hard stop at 06:00 PT

─ Morning ───────────────────────────────────────────────────────
05:00 PT   triager           — overnight test failures → [bug] items in WORK.md
06:00 PT   morning-briefer   — writes MORNING.md (10 things to play-test today)
07:00 PT   pm                — reorders top of ## Todo

─ Weekly ────────────────────────────────────────────────────────
Fri 07:00  designer          — drops 4-6 [idea] items in WORK.md ## Todo
Sat 10:00  blogger           — drafts blog/<YYYY-MM-DD>.md from week's commits
Sun 02:00  janitor           — cold-archives stale items, prunes branches+logs
1st 08:00  asset-librarian   — monthly scan of assets/
```

## Layout

```
SpraxelAiCompany/
├── schedule.yaml            ← the single dial for all cadences
├── scripts/
│   ├── tick.sh              ← launchd fires this every minute
│   ├── run_agent.sh         ← invokes one agent via `claude -p`
│   ├── overnight_dev.sh     ← the 10-features-or-06:00 loop
│   ├── workmd.py            ← WORK.md parser/writer
│   ├── cron_match.py        ← evaluates cron expressions
│   ├── slugify.py           ← title → branch slug
│   ├── install_daemon.sh    ← drops the launchd plist
│   ├── new_game.sh          ← bootstraps a new game repo into the framework
│   ├── generate_release_notes.py
│   └── generate_game_md_inventory.py
├── agents/
│   ├── _shared.md           ← universal rules
│   └── spraxel-*.md         ← per-role specs (developer, reviewer, pm, ...)
├── skills/
│   ├── spraxel-inbox/       ← CEO morning routine skill
│   └── spraxel-producer/    ← dictation → WORK.md skill
├── docs/
│   └── WORK_MD_FORMAT.md    ← the WORK.md schema spec
├── template/                ← copied into each new game repo
│   ├── Philosophy.md
│   ├── Game.md
│   ├── WORK.md
│   └── scripts/
│       ├── install_local_tests.sh
│       └── run_local_tests.sh
└── logs/                    ← per-agent run logs
    ├── tick/<YYYY-MM-DD>.log
    ├── overnight/<YYYY-MM-DD>/<slug>.log
    └── <agent>/<ts>.log
```

## Design principles

- **Token efficiency over headcount**. Haiku for cheap roles, Sonnet only
  where reasoning matters (Developer, Designer, Blogger). Crew agents
  read scoped slices of WORK.md, not the whole file.
- **WORK.md is the contract.** Agents read/write only via `scripts/workmd.py`.
  No agent owns the file's structure.
- **Fail loudly.** A blocked Developer escalates to `.factory/escalations.md`;
  the morning briefer surfaces it.
- **Pausable.** `touch ~/SpraxelAiCompany/.paused` halts all agent dispatch;
  remove the file to resume. The overnight loop checks the flag at the top
  of every iteration.

## Operating handbook

See [`OPERATIONS.md`](OPERATIONS.md) for the daily CEO routine, manual
overrides, and troubleshooting.
