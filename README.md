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
- Each agent fires as **`claude -p` headless** on your Claude Max plan
  (flat-fee, no marginal cost per run).
- The agents read and write **`WORK.md`** (the single source of truth) — no
  GitHub Issues, no GitHub Actions, no Anthropic `/schedule` routines.
- Code commits push to GitHub (free, unlimited) for backup and visibility.

```
─ Continuous loop (always on) ──────────────────────────────────
ANY TIME   continuous_dev.sh  — long-running Developer loop
                               picks top of WORK.md ## Todo (skips [idea]/
                               [cold]/[manual]/[future]/[escalated]/
                               [needs-ceo]/[concern]; picks up [resume])
                               branch → claude -p developer → tests →
                               reviewer → squash-merge → push
                               sleeps when cap hit (target_per_batch since
                               last CEO signal); resumes on any non-bot
                               commit or `bash scripts/checkin.sh`

─ Daily crew agents (all times America/Los_Angeles) ────────────
04:00      playtester        — actively plays the game; writes bug
                               candidates to .factory/inbox/playtest-findings.md
05:00      triager           — consolidates playtest + test failures into
                               [bug] items in WORK.md
06:00      morning-briefer   — writes .factory/local/MORNING.md (gitignored;
                               CEO-only file — the morning routine entry)
06:30      demo-creator      — writes .factory/demos/<date>/recipe.md
                               (always) + best-effort Godot --write-movie
                               capture (when Mac is awake)
07:00      pm                — reorders top of ## Todo; biweekly Monday
                               release-cut (auto-tags v0.N, generates notes)

─ Weekly ───────────────────────────────────────────────────────
Tue+Fri 07:00  designer      — drops 4-6 [idea] items + 0-3 [concern] items
                               in WORK.md (the [concern]s flag game-wide
                               issues — feature bloat, philosophical drift)
Sat 10:00      blogger       — drafts blog/content/posts/draft-<date>-<slug>.md
                               from the week's feat: commits; pushes
                               blog/<date> branch for CEO humanization
Sun 02:00      janitor       — cold-archives stale Todo items, prunes
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

─ Always-on dashboard (optional, no tokens) ────────────────────
python3 ~/SpraxelAiCompany/scripts/dashboard.py
  — leave running in a corner terminal. Auto-refreshes every 5 s.
    Compact glanceable view: status, wrapper PID + uptime, cap
    counter, current item, today's ships/escalations, next 10
    scheduled fires (PT), next 10 CEO action items (needs-ceo /
    escalated / concern / idea / dictation backlog — color-coded by
    urgency), last 20 shipped (sha + age + subject), last log line.
    Stdlib-only Python — no Claude calls.
```

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
│   │                          promote|drop|bump|clarify|release-cut)
│   ├── cron_match.py        ← 5-field cron expression evaluator
│   ├── slugify.py           ← title → kebab-case branch slug
│   ├── install_daemon.sh    ← drops `com.spraxel.tick.plist` into
│   │                          ~/Library/LaunchAgents/
│   ├── new_game.sh          ← bootstraps a new game repo into the framework
│   ├── checkin.sh           ← explicit CEO signal (touches .cache/ceo-checkin.ts);
│   │                          resets the ship-counter
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
│   └── spraxel-*.md         ← 12 role specs:
│                              developer, reviewer, pm, designer, triager,
│                              playtester, morning-briefer, demo-creator,
│                              blogger, janitor, asset-librarian, producer
├── skills/                  ← CEO slash-commands
│   │                          (also hardlinked to ~/.claude/skills/)
│   ├── spraxel-inbox/       ← /inbox — morning routine
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

- **Token efficiency over headcount**. Haiku for cheap roles (PM, Triager,
  Reviewer, Janitor, Morning Briefer, Asset Librarian); Sonnet only where
  reasoning matters (Developer, Designer, Blogger, Playtester, Demo Creator,
  Producer). Crew agents read scoped slices of WORK.md, not the whole file.
- **WORK.md is the contract.** Agents read/write only via `scripts/workmd.py`.
  No agent owns the file's structure.
- **Tags are the language.** `[bug]`/`[feature]`/`[game-feature]`/`[chore]`
  for kinds; `[idea]`/`[cold]`/`[manual]`/`[needs-ceo]`/`[future]`/
  `[escalated]`/`[resume]`/`[concern]` for state. The wrapper skips all
  the state tags except `[resume]` (which is the dev's "pick this back
  up" signal).
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
