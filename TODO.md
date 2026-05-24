# Spraxel framework — open TODOs

What's still unfinished, organized by status. Items get removed from this file when they ship.

## Active — unblocked, working on

(empty — most recent active item shipped 2026-05-24)

## Blocked on external dependencies

### MCP GitHub server is missing tools

Probe results from `infiltrators/.factory/probe-pm-tools.md` (2026-05-23). Each gap drives a deferred feature. Re-evaluate quarterly or when Anthropic announces MCP additions.

| Missing tool | Blocks | Workaround in place |
|---|---|---|
| `mcp__github__create_milestone` / `update_milestone` / attach-to-issue | PM milestone work | PM v9 uses `ship-in:v0.<N>` labels (equivalent expressiveness) |
| `mcp__github__create_release` | PM autonomous release tagging | `release-cut.yml` workflow (autonomous biweekly Monday + manual) — workflows can call the release API even though MCP can't |
| `mcp__github__delete_branch` | Janitor stale-branch cleanup | Janitor flags for CEO; CEO runs `git push origin --delete <branch>` |

Re-enable conditions: Anthropic ships the missing tool → enable in the agent file → next routine run picks it up (dynamic-fetch, see below). No routine config update needed.

### Branch protection on master

Requires GitHub Pro on free private repos. CEO opted out — mitigation is layered: prompt-level "never push to master" rules in agent prompts + `tripwire.yml` workflow alerts on `claude[bot]` direct pushes. Upgrade when CEO decides Pro is worth the cost.

### Hugo publish pipeline

Waiting on CEO webspace decision. Blogger drafts to `blog/content/posts/draft-*.md`; the publish workflow targeting the chosen host hasn't been built. Tracks the user's "actually I might switch webspace" call.

## Deferred until trigger condition

### Reusable workflows across N game repos

Currently each game repo gets its own copies of `developer.yml`, `review.yml`, `sync.yml`, etc. via `new_game.sh`. When a 2nd game adopts the framework, GitHub's reusable-workflows feature lets the framework host the actual workflow YAML and game repos call it via a tiny shim:

```yaml
# infiltrators/.github/workflows/developer.yml (shim)
on:
  issues:
    types: [labeled]
jobs:
  spawn:
    uses: mdl16bit/SpraxelAiCompany/.github/workflows/developer-reusable.yml@main
    if: github.event.label.name == 'status:ready'
    secrets: inherit
```

Trigger: 2nd game adopts the framework. Then migrate `developer.yml`, `review.yml`, `sync.yml`, `auto-merge.yml` (the multi-game ones).

### Witness / supervisor agent

Yegge's "supervisor that watches for stuck work" was deliberately cut from Phase 1 as premature. Revisit if a recurring class of stuck items emerges that PM v9's GUPP + the closed-PR-aware unstick logic doesn't catch. PM v9 already catches: PR-self-close (immediate), no-PR-after-24h (24h delay).

## Closed/decided — not implementing

### Prompt caching for scheduled agents

Anthropic prompt-cache TTL is 5 minutes (1h extended is beta). `/schedule` routines fire on hour+ cadence (PM daily, others daily/weekly/monthly). The cache window never hits between routine fires. Per-fire cost is already low (~$0.05-0.20 depending on agent + model). Not worth the implementation effort. Revisit if Anthropic ships persistent (24h+) cache for scheduled agents.

### Absolute $ tracking for agent spend

CEO is on Claude Max (flat plan) — absolute dollars aren't useful. `costs.yaml` tracks per-agent activity as relative % (workflows × per-fire weight). CEO sees "where my Max budget is going" without dollar conversion.
