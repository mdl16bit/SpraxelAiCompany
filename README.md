# Spraxel AI Company

A meta-framework that turns a Claude Max subscription into a small, autonomous gamedev studio.

You — the **CEO** — keep the human-only work: art, music, storyline, finetuning, gameplay design, ideation, playtesting. A roster of Claude agents handles code, planning, code review, bug triage, devlog blogging, asset hygiene, and demo capture. Each game repo adopts the framework by copying a `.factory/` directory and the standard files (`Philosophy.md`, `Game.md`, `WORK.md`).

**First target game:** [`infiltrators`](https://github.com/mdl16bit/infiltrators) — a 2D stealth/heist in Godot 4.6.1 (Lost Vikings × Gunpoint, 8 thieves, plan-mode slow-mo).

## How a day works

You don't keep a Claude Code window open. You touch the system 2-3 times a day; the rest runs in Anthropic's cloud (`/schedule` remote agents) or on GitHub-hosted runners (Actions).

```
05:00 PT   Triager        — batches Playtester failures from overnight into one comment
06:00 PT   Concierge      — morning digest on the Factory Daily Log issue
07:00 PT   PM             — fills the velocity cap: tags top N backlog issues status:ready
                            → developer.yml fires → Developers open PRs in parallel
On PR open Reviewer       — Haiku-tier code review, labels reviewed:clean or reviewed:blocking
On PR open Tests          — Godot --headless runs GUT + scenarios, labels tests:pass/fail
On 2 labels Auto-merge    — squash-merges, applies release:v0.X label, status:ready's next issue
                            → next Developer fires → chain continues
02:00 PT   Playtester     — nightly: re-runs the scenario catalog headless, files failures
Fri 07:00  Designer       — proposes 4-6 ideas in a tickable batch for the CEO
Sun 02:00  Janitor        — closes stale, compacts memory, reports cost
1st 08:00  Asset Librarian — orphan-file + license scan
```

The CEO interactive touchpoints: `/producer` to drain dictation/notes into clean issues (morning + after playtests + before bed), checkbox-tick on Designer/Triager batches in the Factory Daily Log, and `gh release create v0.X --generate-notes` on cadence days (until the MCP server exposes release tools).

## Layout

```
SpraxelAiCompany/
├── agents/          # Claude Code subagent definitions (symlinked to ~/.claude/agents/)
├── skills/          # User-invocable skills (symlinked to ~/.claude/skills/)
│   └── spraxel-producer/
├── scripts/
│   ├── sync_work_md.py   # WORK.md ↔ GH Issues bidirectional sync
│   ├── new_game.sh        # apply the framework to a target game repo
│   └── ...
├── template/        # files copied into a game repo on bootstrap
│   ├── Philosophy.md.template
│   ├── Game.md.template
│   ├── WORK.md.template
│   └── .factory/, .github/workflows/
└── docs/
```

Each adopted game repo gains:

```
infiltrators/
├── Philosophy.md         # identity, must_include, must_not_include, cadences, budgets
├── Game.md               # canonical feature/controls catalog
├── WORK.md               # three-section text view of GH Issues
├── .factory/             # per-game agent state, scenarios, artifacts
└── .github/workflows/    # developer.yml, review.yml, test.yml, playtest.yml,
                          # blogger.yml, sync.yml, auto-merge.yml, tripwire.yml
```

## Design principles

- **Token efficiency is a first-class concern.** Haiku for routine agents (Reviewer, Triager, Janitor), Sonnet for judgment work, Opus reserved for the Producer's interactive sessions. Each agent loads only what it needs — Philosophy + the specific issue body + its memory file, never full WORK.md.
- **State lives in Git and GitHub Issues, not in agent memory.** Sessions crash; PRs and issues survive. Agents resume on the next wake by querying current state. (Yegge's NDI principle, adapted for GH.)
- **One PR per issue, one feature per `--demo-feature=<slug>`.** The Developer agent's molecule includes adding a debug boot path so Playtester can drive the feature headlessly later.
- **Never push to master from a bot.** Branch protection isn't available on free private repos, so the guard rail is layered: prompt-level "never push to master" rules + a `tripwire.yml` workflow that pings the Factory Daily Log if a bot push slips through.
- **CEO is the ideation source, not the bottleneck.** Designer exists to *complement* the CEO's stream of ideas, not replace it. Weekly batch of 4-6 ideas with checkbox accept/reject/amend.

## Current state — Phase 3 (creative loop)

| Phase | Status | What shipped |
|---|---|---|
| Phase 0 — Godot headless validation | ✅ | DebugBoot + Tracer, `--demo-feature=<slug>` works |
| Phase 1 — Spine | ✅ | Producer, PM, Developer, Reviewer, Concierge, sync script, daily routines |
| Phase 1.x — Merge orchestration | ✅ | PM auto-merge + release labeling; OAuth (Max-billed); GUT 9.6.0; state-in-issue model |
| Phase 2 — Quality + autonomy | ✅ | Playtester workflow, Triager, Janitor |
| Phase 3 — Creative loop | 🟡 | Blogger ✅, Designer ✅, Asset Librarian ✅, Demo Creator (stub) |
| Continuous flow | ✅ | `auto-merge.yml` chains merge → next-issue-spawn without daily-cadence wait |

Open items: see [`TODO.md`](TODO.md). MCP server gaps (no `create_milestone`, no `create_release`, no `delete_branch`) drive most deferred work.

## Operating the factory

The day-to-day CEO handbook is [`OPERATIONS.md`](OPERATIONS.md) — agent roster, cadence, skills, manual overrides, common workflows, tests, file map, gotchas, and a current plan-vs-shipped status.

## Heavy influences

- **Steve Yegge's "Gas Town"** — GUPP (work-on-hook), molecules, patrol loops, pet/cattle agent split, NDI (state in Git). We borrow the vocabulary and most of the discipline; we drop the merge queue (single dev) and the supervisor (premature).
- **The author's existing `infiltrators` repo** — Godot 4.6.1, GDScript, autoload-heavy, dictation-friendly notes. The framework was designed around the real grain of one developer's workflow.

## License

TBD. Code is currently public so scheduled remote agents can fetch agent definitions at runtime; a permissive OSS license (MIT / Apache 2.0) will land before the first stranger contribution.
