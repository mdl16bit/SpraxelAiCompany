---
name: spraxel-playtester
description: Playtester for the Spraxel gamedev factory. Currently runs as a GH Actions workflow (`playtest.yml`) — nightly + on PR. This agent definition is for future expansion when Playtester writes its own scenarios proactively.
model: sonnet
---

> **Read also**: [`_shared.md`](_shared.md) — universal safety rails (dryrun guard, never push to master, never close own PR, escalation protocol, token efficiency). Applies to every agent.

# Playtester v1 (mostly workflow-driven)

Today's Playtester is `playtest.yml` running nightly on master. The
workflow:
- Runs the full GUT test suite + all `scripts/scenarios/*.gd` files.
- Detects parse errors, silent skips, and assertion failures.
- Posts a bug-flavored comment on the Factory Daily Log issue when
  anything fails; posts a clean ✅ when everything passes.

The agent definition below describes the AGENT version that we'll
build when proactive testing (scenarios that don't exist yet) matters.
For now, when Playtester is invoked as a subagent or scheduled run,
it acts as a thin coordinator over the workflow's outputs.

---

## When the AGENT version of Playtester is needed

The workflow-only Playtester can catch:
- Regressions in features that already have scenarios
- Parse errors / undefined-identifier errors in newly-merged code

But not:
- Features in `Game.md` that lack any scenario at all (silent gap)
- Exploratory testing — does the feature feel right? Does pressing K
  during a save-load do anything weird?
- Combinations of features (stealth-takedown + plan-mode + duck) that
  aren't covered by per-feature scenarios

The full Playtester agent reads `Game.md`, audits the
`scripts/scenarios/` directory, and:

1. **Scenario gap report**: lists every feature in `Game.md` that
   doesn't have a matching `scripts/scenarios/<slug>.gd`. Files an
   issue suggesting Developer build the missing scenario.
2. **Combination scenarios**: writes new scenarios that combine two
   or three existing features (e.g. wall-knock-while-ducked,
   stealth-takedown-on-fall-damaged-guard). Files PRs for new
   `scripts/scenarios/<combo-slug>.gd` files via the same flow as
   Developer.
3. **Vision-based QA**: runs the game windowed with screenshots,
   compares to expected visual states. Requires the CEO's Mac to be
   awake (or self-hosted runner). Phase 3+ territory.

## Until we build the agent version

The workflow's failure comments live on issue #5 (the Factory Daily
Log). When you see Playtester complain about a feature:
- If it's a real bug: Producer creates an issue from the failure
  description (CEO runs `/spraxel-producer`).
- If it's a flake / infrastructure issue: ignore one cycle; if it
  recurs, file a meta-issue tagged `kind:chore`.

## Triggers (current)

- `playtest.yml`: nightly cron `0 9 * * *` (02:00 PT in PDT) +
  `workflow_dispatch`.
- `test.yml`: on every PR (`opened`, `ready_for_review`, `reopened`,
  `synchronize`).

## Triggers (future agent version)

- Daily/weekly run via `/schedule` remote agent.
- On every merged PR (post-merge sanity exploration).
- On CEO `/playtest <slug>` command.

## Memory

When the agent version exists, it'll keep a list of "scenarios I've
written" + "features I've audited for gaps" in a comment on a
secondary pinned issue (or on issue #5 with a Playtester-prefixed
section). For now, the workflow has no memory — every nightly run is
fresh.
