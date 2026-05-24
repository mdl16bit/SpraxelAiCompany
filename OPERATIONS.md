# Operations — CEO handbook

How to drive the Spraxel factory day-to-day. Companion to [`README.md`](README.md) (which is the public pitch) and [`TODO.md`](TODO.md) (deferred work).

---

## Mental model

You are the CEO. You don't write code, run CI, or push commits. You **dictate**, **tick checkboxes**, and **eyeball merges**. A roster of agents owns the rest. State lives in **GitHub Issues** (canonical) and in `WORK.md` (a human-friendly mirror). Issue **#5** on `mdl16bit/infiltrators` is the **Factory Daily Log** — a perpetual dashboard where every bot posts updates. Open that on your phone first thing in the morning and you'll see everything.

---

## Release cadence + ship-in labels

The factory targets a **biweekly Monday release**. PM is the only agent that
plans which issue goes in which release, using `ship-in:v0.<N>` labels:

- **`ship-in:v0.1`** (current) — issues PM plans to land in this sprint.
- **`ship-in:v0.2`** — next sprint's batch (PM looks one ahead).
- **`ship-in:v0.3`** — two sprints out (PM looks two ahead).
- Unlabeled — backlog tail; PM will plan into a future bucket on later runs.

PM fills each bucket up to `Philosophy.dev.velocity_issues_per_release`
(default 4) using priority + bug-first + area-grouped sort. Developers
only fire on `ship-in:v0.<current>` issues. `auto-merge.yml`'s chain
respects the same rule — when a PR merges, the next-up Developer spawns
only on a current-bucket issue.

When you merge `release:v0.<N>` PRs (post-fact label applied at merge
time), they accumulate toward the next release tag. **On Monday**, you
cut the tag yourself (MCP server lacks `create_release`):

```bash
cd ~/GameProjects/infiltrators
gh release create v0.<N> --generate-notes
python3 ~/SpraxelAiCompany/scripts/sync_work_md.py --repo-dir . --release-cut v0.<N> --apply
git add WORK.md && git commit -m "release: v0.<N>" && git push
```

Next PM run sees the new tag, rolls any unfinished `ship-in:v0.<N>`
forward to `ship-in:v0.<N+1>`, and tops up the new current bucket from
the planned-future buckets.

Two distinct labels — keep them straight:
- `ship-in:v0.<N>` — **forward-plan** intent (applied to open issues by PM)
- `release:v0.<N>` — **post-fact** record (applied to merged PRs by auto-merge.yml)

## The agent roster

| Agent | Type | Model | Cadence | What it does |
|---|---|---|---|---|
| **Producer** | Crew, interactive | Opus | on `/spraxel-producer` | Turns your dictation / WORK.md prose into clean GH Issues with acceptance criteria. The only agent you talk to directly. |
| **PM** | Crew, scheduled | Sonnet | daily 07:00 PT | GUPP (un-stick stuck claims), spawns Developers up to velocity cap, posts daily summary on issue #5. |
| **Developer** | Worker, on-demand | Sonnet | fires on `status:ready` label | Implements one issue end-to-end: code, tests, scenarios, Game.md update, opens PR. One per issue, no memory across runs. |
| **Reviewer** | Worker, on PR | Haiku | fires on PR open | Reads diff, labels `reviewed:clean` or `reviewed:blocking`, posts findings. |
| **Tests** | Workflow, on PR | n/a | fires on PR open | Runs GUT + every `scripts/scenarios/*.gd` headlessly; labels `tests:pass` or `tests:fail`; on fail, posts 🐛 summary to issue #5. |
| **Auto-merge** | Workflow, on PR label | n/a | fires when 2 labels land | Squash-merges if both `reviewed:clean` + `tests:pass` + no veto labels; applies `release:v0.<N>` label; chains in the next issue. |
| **Concierge** | Crew, scheduled | Haiku | daily 06:00 PT | Rewrites issue #5 body with today's digest (pending merges, intake counts, Designer batches, anomalies). |
| **Playtester** | Workflow, scheduled | n/a | nightly 02:00 PT | Re-runs scenarios on master; posts 🐛 comments on issue #5 if anything fails. |
| **Triager** | Crew, scheduled | Haiku | daily 05:00 PT | Dedupes the previous 24h of 🐛 comments on issue #5 into one tickable bug batch. |
| **Janitor** | Crew, scheduled | Haiku | weekly Sun 02:00 PT | Closes 30-day-stale issues, deletes merged branches (when MCP allows), reports WORK.md ↔ Issues drift. |
| **Designer** | Crew, scheduled | Sonnet | weekly Fri 07:00 PT | Proposes 4-6 new feature ideas as a tickable batch on issue #5. |
| **Blogger** | Crew, scheduled | Sonnet | weekly Sat 10:00 PT | Drafts a markdown devlog post from the week's merged PRs; opens a PR. |
| **Asset Librarian** | Crew, scheduled | Haiku | monthly 1st 08:00 PT | Scans `assets/` for orphans, broken refs, license gaps. |

PT timezone shifts twice a year; cron is fixed in UTC, so PDT (summer) and PST (winter) differ by an hour from these listed times.

---

## A day in the system (autonomous baseline)

```
02:00 PT  Sunday-only: Janitor cleans entropy + drift
02:00 PT  Playtester re-runs scenarios on master headlessly
05:00 PT  Triager batches yesterday's failures into one tickable comment
06:00 PT  Concierge rewrites issue #5 body with the morning digest
07:00 PT  PM fills the velocity cap (spawns N Developers on top backlog)
~07:30    Developers open PRs in parallel
~07:35    Reviewer + Tests labels land
~07:40    Auto-merge merges any clean PR + status:ready's the next issue
…         Chain repeats until backlog drains or cap is full
Fri 07    Designer drops a 4-6 idea batch on issue #5
Sat 10    Blogger PRs the week's devlog draft
1st 08    Asset Librarian dumps the monthly assets inventory
```

You do not need your Mac on for any of this. Everything runs in Anthropic CCR sandboxes (`/schedule` routines) or GitHub-hosted runners.

---

## What you do (3 touchpoints/day)

### Morning — open issue #5 on your phone

- Read the Concierge digest (the issue body).
- If there's a **Designer batch** comment, tick one of `accept` / `reject` / `amend` per idea. (Reply `Amend #<N>: <new text>` for amends.)
- If there's a **Triager bug batch** comment, tick `real` / `not-a-bug` / `wontfix`.
- That's it. Producer drains your ticks on its next run.

### Whenever you have ideas — dictate or type

- **Phone dictation**: drop transcripts as `.txt` files into `.factory/inbox/dictation/`. Producer eats them next run.
- **Direct edits to `WORK.md`**: add lines to the bottom (todo) section. On push, `sync.yml` queues them into `pending-intake.md`.
- **In a Claude Code session**: just type `/spraxel-producer` and start talking.

### End-of-day — run Producer

- `/spraxel-producer` in any Claude Code session.
- Producer shows you a numbered batch of cleaned-up issue drafts. You reply `all` or `2 needs repro, 5 not now`. Issues get created. Done.

---

## Skills + slash commands

| Command | What it does |
|---|---|
| `/spraxel-producer` (or `/producer`) | Drain dictation, WORK.md intake, Designer/Triager checked batches → polished GH Issues. The only skill you invoke regularly. |
| `/schedule` | Manage `/schedule` routines (the cloud-scheduled agents). Use to list / update / fire a routine on-demand. See "Manual overrides" below. |

When you say `/something`, Claude Code matches against the available skills list. The Spraxel skill is `skills/spraxel-producer/SKILL.md` — symlinked into `~/.claude/skills/`.

---

## Manual overrides

### Fire a scheduled agent immediately

Use `/schedule` → choose **Run now** → pick the routine. Or in chat: ask "fire the PM routine now." The routine list lives at https://claude.ai/code/routines.

### Spawn a Developer on a specific issue right now

Add the `status:ready` label to the issue. `developer.yml` fires on label-add. The Developer agent claims the issue (adds `status:claimed`), opens a feature branch, ships a PR. Example:

```bash
gh issue edit <N> --repo mdl16bit/infiltrators --add-label status:ready
```

### Force a re-run of an existing PR's tests / reviewer

- Tests: `gh workflow run test.yml -F pr_number=<N>` (workflow_dispatch) or push a tiny commit to the branch.
- Reviewer: push to the branch (it re-fires on `synchronize`).

### Pause everything (`run_mode: dryrun`)

Edit `Philosophy.md`:

```yaml
run_mode: "dryrun"   # was "live"
```

Push. On the next firing of **any** scheduled `/schedule` agent (PM, Concierge, Janitor, Triager, Designer, Asset Librarian), the agent reads Philosophy first, sees `dryrun`, and exits with a one-line `"would have done X"` log without making any MCP calls, comments, or commits. Flip back to `"live"` when you're ready to resume.

This pauses the **agent** layer (Sonnet/Haiku spend). It does NOT yet pause the **workflow** layer (`developer.yml`, `review.yml`, `test.yml`, `playtest.yml`, `blogger.yml`, `auto-merge.yml`, `sync.yml`) — those fire on PR/push/issue events you control indirectly. For a full pause, also stop creating issues + disable the GH App, or set the routines to `enabled: false` via `/schedule`. Tracked in TODO.md as a follow-up.

Nuclear option: revoke the OAuth token in claude.ai settings — bots immediately can't push.

### Cut a release

Currently CEO-manual (MCP server lacks `create_release`):

```bash
cd ~/GameProjects/infiltrators
gh release create v0.<N> --generate-notes
python3 ~/SpraxelAiCompany/scripts/sync_work_md.py --repo-dir . --release-cut v0.<N> --apply
git add WORK.md && git commit -m "release: v0.<N>" && git push
```

After that, `auto-merge.yml` will label future merges as `release:v0.<N+1>`.

### Override a stuck PR

- Tests failing but you know the failure is a flake: `gh pr edit <N> --add-label tests:pass` (auto-merge will fire). Better: re-run tests.
- Reviewer blocked but you want to merge anyway: `gh pr edit <N> --add-label reviewed:clean --remove-label reviewed:blocking`.
- Don't want auto-merge to touch a PR: `gh pr edit <N> --add-label do-not-merge`.

### Delete a merged branch (Janitor can't yet)

```bash
git push origin --delete feat/issue-N-foo
```

---

## Common workflows

### "I dictated some ideas, what now?"

1. Drop the transcript in `.factory/inbox/dictation/<YYYY-MM-DD-walk>.txt`. (Or paste into WORK.md.)
2. Run `/spraxel-producer` in a Claude Code session.
3. Producer reads the dictation, drafts a numbered issue batch, asks you to confirm. Say `all` or pick numbers to amend.
4. Issues are created with `acceptance criteria` checkboxes. PM picks them up on its next 07:00 run (or you fire PM now via `/schedule` → Run now).

### "Designer dropped 5 ideas overnight — how do I accept them?"

1. On issue #5, scroll to the most recent `💡 **Designer (...)**` comment.
2. Per idea, tick exactly one of the 3 boxes (`accept` / `reject` / `amend`).
3. For amends: reply on the issue with a comment starting `Amend #<N>: <new text>`.
4. Run `/spraxel-producer`. It reads the ticked batch, creates issues for accepts, and marks the batch processed via an HTML comment so it's never reprocessed.

### "PR is failing tests, what do I do?"

If you want the system to handle it:
- Test.yml has already posted a 🐛 summary on issue #5. Triager will batch it tomorrow. You'll see it as a tickable bug. Tick `real` → next `/spraxel-producer` run creates a bug issue → PM picks it up.

If you want to short-circuit:
- Close the PR with `gh pr close <N>` + comment explaining.
- Comment on the source issue with what went wrong + relevant context (file paths, error excerpts).
- Remove `status:claimed` from the source issue (`gh issue edit <N> --remove-label status:claimed`). PM re-spawns a Developer on its next run.

### "I want to start fresh on a feature the Developer half-built"

- Close the PR (don't delete the branch — it's reference for the next attempt).
- Remove `status:claimed` from the source issue.
- Add a comment on the issue with what you want different.
- PM re-picks it up. Tell Developer in the comment to read previous branch / what to avoid.

### "Pull a PR locally to test before merging"

The system auto-merges clean PRs (`auto-merge.yml` fires when both `tests:pass` and `reviewed:clean` labels land). To intervene and test something yourself first:

```bash
# 1. Block auto-merge temporarily
gh pr edit <N> --repo mdl16bit/infiltrators --add-label do-not-merge

# 2. Check out the PR locally
cd ~/GameProjects/infiltrators
gh pr checkout <N>      # creates/switches to a local branch tracking the PR

# 3. Run the game windowed and play through it
/Users/skinnyluigi/Downloads/Godot.app/Contents/MacOS/Godot --path .

# 3a. Or run the specific feature's debug hook
/Users/skinnyluigi/Downloads/Godot.app/Contents/MacOS/Godot --path . -- --demo-feature=<slug>

# 3b. Or run the headless scenario test directly
godot --headless --path . -- --demo-feature=<slug> --trace-file=/tmp/t.jsonl --quit-after=10

# 3c. Or run the full GUT unit suite
godot --headless --path . -s res://addons/gut/gut_cmdln.gd -gdir=res://test/unit -ginclude_subdirs -gexit

# 4a. If it works — un-block, let auto-merge take over
gh pr edit <N> --remove-label do-not-merge
# (or merge manually): gh pr merge <N> --squash --delete-branch

# 4b. If it doesn't work — leave do-not-merge on, comment the issue with
#     what failed, close the PR, remove status:claimed from the source issue.
gh pr close <N> --comment "Tests pass but X is wrong — see issue #M"
gh issue edit <source-issue> --remove-label status:claimed

# 5. Return to master
git checkout master
git pull
```

`gh pr checkout` handles fork-PRs and detached-head cases cleanly. The `do-not-merge` label is recognized by `auto-merge.yml` as a veto so the chain won't merge while you're testing.

### "I want to disable an agent temporarily"

`/schedule` → List → pick the routine → Update → set `enabled: false`. Re-enable when you want it back.

### "Something is wrong with an agent — how do I debug?"

- **Last run logs**: claude.ai/code/routines → pick the routine → "Last run" → opens the session transcript.
- **The agent's prompt**: lives in two places — the framework copy at `~/SpraxelAiCompany/agents/spraxel-<role>.md` (the source of truth you edit), and the cloud copy embedded in the routine config (the version that actually runs). To sync them: edit the framework copy, then `/schedule` → Update → paste the new prompt content into the routine's `events[].data.message.content`. This duplication is intentional (and tracked under TODO.md's "dynamic fetch" item).

---

## Tests — yes, `scripts/scenarios/*` are the tests (one of two layers)

Two layers run on every PR via `test.yml`:

### Layer 1 — GUT unit tests at `test/unit/*.gd`

Pure GDScript unit tests using [GUT 9.6.0](https://github.com/bitwes/Gut) (vendored at `addons/gut/`). Run via:

```bash
godot --headless --path . -s res://addons/gut/gut_cmdln.gd \
  -gdir=res://test/unit -ginclude_subdirs -gexit
```

Fast, hermetic, no scene loading. Use for: queue logic, parsers, math, state machines.

### Layer 2 — Acceptance scenarios at `scripts/scenarios/*.gd`

Real-engine integration tests. Each scenario:
1. Instantiates a real character + guard + environment.
2. Runs a sequence of inputs/awaits via the autoload-aware lifecycle.
3. Calls `_assert(...)` for each acceptance bullet.
4. Prints `SCENARIO <slug>: PASS` (or `FAIL`) and quits the engine with the right exit code.

Triggered by:
```bash
godot --headless --path . -- --demo-feature=<slug> --trace-file=/tmp/<slug>.jsonl --quit-after=10
```

The test step in `test.yml` loops over every `.gd` file in `scripts/scenarios/`, runs it, and greps stdout/stderr for `ERROR:`, `Parse error`, `SCENARIO <slug>: FAIL`, or absence of `SCENARIO <slug>: PASS`. Any of those → `tests:fail` label + 🐛 comment on issue #5.

Naming: the slug is the filename with underscores → dashes. `overwatch.gd` → `--demo-feature=overwatch`. `hide_box.gd` → `--demo-feature=hide-box`.

Every Developer-implemented feature ships with **both** layers: a `test/unit/test_<feature>.gd` and a `scripts/scenarios/<feature>.gd`. That's in the Developer molecule.

---

## File map (what lives where)

In `~/SpraxelAiCompany/` (framework, public):

| Path | Purpose |
|---|---|
| `agents/spraxel-*.md` | Agent definitions (source of truth). Symlinked to `~/.claude/agents/`. |
| `skills/spraxel-producer/SKILL.md` | The interactive Producer skill. |
| `scripts/sync_work_md.py` | WORK.md ↔ GH Issues bidirectional sync. Also supports `--seed` and `--release-cut`. |
| `scripts/new_game.sh` | Bootstrap a new game repo with the framework. |
| `template/` | What `new_game.sh` copies in. |
| `TODO.md` | Deferred work + MCP server gaps + post-mortems. |
| `OPERATIONS.md` | This file. |

In `~/GameProjects/infiltrators/` (the game, private):

| Path | Purpose |
|---|---|
| `Philosophy.md` | Identity, must_include/exclude, cadences, model assignments, velocity cap. |
| `Game.md` | Canonical feature/controls catalog. Every feature ships a block here. |
| `WORK.md` | Three-section human-friendly mirror of GH Issues. |
| `.factory/inbox/pending-intake.md` | Sync's queue of WORK.md lines waiting for Producer. |
| `.factory/inbox/dictation/` | Phone-dictated transcripts. Producer drains. |
| `.factory/memory/<role>.md` | Per-agent compacted memory. Janitor maintains. |
| `.github/workflows/*.yml` | CI: developer / review / test / playtest / blogger / sync / tripwire / auto-merge. |
| `scripts/systems/debug_boot.gd` | `--demo-feature=<slug>` autoload entry point. |
| `scripts/systems/tracer.gd` | JSON event emitter (read by Playtester). |
| `scripts/scenarios/*.gd` | Acceptance tests (Layer 2). |
| `test/unit/*.gd` | GUT unit tests (Layer 1). |
| `addons/gut/` | Vendored GUT 9.6.0. |

---

## Gotchas / things to know

- **Bot push to master is forbidden.** `tripwire.yml` will alert on issue #5 if it happens. Branch protection isn't available on free private repos. The guard rail is prompt + tripwire.
- **claude[bot] has admin** on the infiltrators repo (so it can label, comment, merge). If something feels off, you can revoke at https://github.com/settings/installations.
- **Pasting an API key in chat is dangerous.** If you do it accidentally, revoke immediately at https://console.anthropic.com → API Keys, then set the new one via `gh secret set ANTHROPIC_API_KEY --repo mdl16bit/infiltrators` with stdin (no argv).
- **Velocity cap is in `Philosophy.dev.velocity_issues_per_release`** (currently 4). Raise/lower to control parallelism + spend.
- **Cost knob #1 is `model_assignments` in Philosophy.md.** Move a Sonnet agent to Haiku → ~80% cost drop for that agent.
- **MCP server gaps**: no `create_milestone`, no `create_release`, no `delete_branch`. The system works around all three; see TODO.md's gap table.
- **Two prompt copies for scheduled agents**: the framework file at `agents/spraxel-<role>.md` is the source of truth; the cloud routine has a copy embedded in its config. Edit the framework file first, then sync to the routine via `/schedule` → Update. (TODO: dynamic fetch.)
- **`WORK.md` parser is divider-count-sensitive**: 0 dividers → everything is todo; 1 → shipped/todo; 2+ → shipped/current/todo. Put new dictation **below** the last divider so sync queues it.
- **Hard CEO gates** (the system will never act without your tick): bulk issue creation, release cuts, designer-idea acceptance, p0-priority work, bug "real or not" calls.

---

## Where we are vs the plan, today (2026-05-24)

Plan-vs-shipped by phase:

| Phase | Status | Notes |
|---|---|---|
| Phase 0 — Godot headless validation | ✅ | DebugBoot, Tracer, `--demo-feature` work |
| Phase 1 — Spine | ✅ | Producer, PM, Developer, Reviewer, Concierge, sync script, schedules |
| Phase 1.x — Merge orchestration | ✅ | PM v7 fill-the-cap, auto-merge.yml chain, OAuth, GUT, state-in-issue |
| Phase 2 — Quality + autonomy | 🟡 | Playtester ✅, Triager ✅, Janitor ✅. **Scenario coverage is thin** (only `hide_box`, `wall_knock`; plan called for 3-5 covering existing features) |
| Phase 3 — Creative loop | 🟡 | Blogger ✅, Designer ✅, Asset Librarian ✅, Demo Creator ❌ (issue #11 filed, awaiting Developer) |
| Continuous flow | ✅ | auto-merge chain + PM fill-the-cap |
| Cost tracking | ❌ | costs.yaml + Concierge surfacing — designed, not built |
| Hugo publish | 🟡 | Blogger writes drafts; publish workflow not wired |
| `run_mode: dryrun` honor | ❌ | Philosophy flag exists; no agent reads it |

Plan verification checklist (10 items):

1. Dictation → Issue ✅
2. Issue → PR ✅
3. PR → Reviewer ✅
4. Merge → WORK.md ⚠️ (sync.yml runs on push; not stress-tested with the new auto-merge chain)
5. Morning digest ✅
6. Release cut ⚠️ (CEO-manual until MCP gains `create_release`)
7. Cost cap ❌ (declared in Philosophy, not enforced)
8. Headless Playtester ✅
9. Triager validation ✅
10. Janitor compaction ⚠️ (runs; compaction loop not stress-tested at scale)

---

## What's next

Right now (background, autonomous):

- PM v7 fired at 16:02 UTC → up to 4 Developers spinning up on #6, #7, #8, #9
- Auto-merge will chain in #10, #11 as the first PRs land clean
- Sync workflow fires on the WORK.md push → queues ~75 new dictated lines into `pending-intake.md`

Once that settles (today or tomorrow), in priority order:

1. **Drain `pending-intake.md`** — run `/spraxel-producer`. ~221 lines (146 old + ~75 new) to triage. Producer will dedup against `Game.md` and flag "looks already done" for items the live game already has. You batch-confirm.
2. **Scenario coverage (Step 2.1 of the plan)** — file 3-5 issues for `scripts/scenarios/{stealth_takedown,character_select,plan_mode,save_load,…}.gd`. Lets Playtester actually find regressions instead of running 2 scenarios.
3. **`run_mode: dryrun` honor** — thread through scheduled agent prompts as a guard clause. ~30 min. Saves runaway spend during off weeks.
4. **`costs.yaml` + Concierge surfacing** — Janitor weekly cost report; Concierge embeds in morning digest. Plan called for this; you're flying blind today.
5. **Hugo publish pipeline** — Blogger drafts at `blog/content/posts/draft-*.md`; needs a `gh-pages` deploy workflow. ~1 hour.
6. **Demo Creator screenshot impl** — issue #11 already in the queue; one of today's Developers should land it.

Deferred until trigger conditions are met (see [`TODO.md`](TODO.md) for full list):

- Release-tag automation: blocked on MCP `create_release` tool
- Branch protection: blocked on GitHub Pro pricing
- Reusable workflows: premature until a 2nd game adopts the framework
- Witness/supervisor agent: only if stuck-work patterns emerge
