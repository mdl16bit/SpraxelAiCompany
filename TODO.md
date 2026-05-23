# Spraxel framework — planned upgrades

Items that are deliberately deferred from Phase 1, with the trigger that should
prompt the upgrade. Each entry is one work item; we add (or remove) items as
the framework matures.

## Defects found during Step 1.13 / 1.14 smoke tests (2026-05-23)

### Fixed in 73ed4de + routine update
- **PM didn't append to `.factory/inbox/today.md`.** Now required on every
  working run; only zero-work runs exit without commit. PM v2 runs are
  now appending correctly.
- **PM was silent about its own limitations.** Now logs the milestone
  blocker explicitly in `pm.md` and `today.md`. Behavior verified.

### Probe results (2026-05-23 probe routine `trig_013XKhRC4dz5KoLiFTrsjSvV`)
Full report committed at `infiltrators/.factory/probe-pm-tools.md`. Summary:

- **No `gh` CLI installed** in the CCR sandbox.
- **No `GITHUB_TOKEN` env var** exposed.
- **MCP GitHub server IS authenticated** (`mcp__github__get_me` works
  as `mdl16bit`) and exposes ~50 endpoints: issues r/w, PR r/w/review,
  commits, search, labels, branches.
- **MCP GitHub server does NOT expose milestone endpoints.** Not
  create, not list, not attach. This is the root cause of PM run
  1 + 2 failing to milestone — and there's no workaround inside the
  sandbox short of installing `gh` AND getting a token, neither of
  which the sandbox supports.
- `python3`, `curl`, `jq`, `git`, `node` are all present.

### Decision: PM skips milestone work in Phase 1
Until Anthropic adds milestone tools to the GitHub MCP (or we find a
secure way to inject a GH PAT into the routine), PM should NOT attempt
milestone create/attach. Section 3 of the PM prompt is shortened to a
single line: "milestone work is a CEO-manual step until tooling
catches up; do not attempt." Release-day work in section 5 is also
disabled until milestones work end-to-end.

Action: edit `agents/spraxel-pm.md` to remove milestone logic, push the
updated prompt to the live routine. (Tracked under "Fixed" once
landed.)

### Re-enable milestone work when one of these lands
- Anthropic adds `mcp__github__create_milestone` / `update_milestone` /
  `delete_milestone` tools to the GitHub MCP server.
- Or: we build our own MCP server that exposes milestone CRUD against
  the GitHub REST API, with a PAT injected via routine config.
- Or: the routine config grows an env-var injection mechanism that
  lets us pass a fine-grained PAT for milestones only.

## ~~When we hit the first real PR that needs reviewing~~ Done 2026-05-23
- ~~Upgrade `review.yml` from option (a) to option (b).~~ Shipped. Both
  `review.yml` and `developer.yml` now use `anthropics/claude-code-action@v1`
  with `ANTHROPIC_API_KEY` in repo secrets. Reviewer runs Haiku; Developer
  runs Sonnet. The action handles branch management (prefix `feat/`) and
  the workflow's final step opens a PR from the action's `branch_name`
  output if one doesn't exist yet.

## When we start spawning Developers via GH Actions
- ~~**Add `developer.yml` workflow.**~~ Done in c11eccc (option (a) with
  `@claude` mention). Upgrade to option (b) is tracked above.

## When the framework grows past one game repo
- **Move per-repo workflows to reusable workflows.** Currently each game
  repo gets its own `.github/workflows/{review,sync,developer}.yml` from
  `new_game.sh`. To update those across N game repos, we'd touch each.
  GitHub's reusable-workflows feature lets the framework host the real
  workflow file and game repos call it via a tiny shim:

      # infiltrators/.github/workflows/developer.yml (shim)
      on:
        issues:
          types: [labeled]
      jobs:
        spawn:
          uses: mdl16bit/SpraxelAiCompany/.github/workflows/developer-reusable.yml@main
          if: github.event.label.name == 'status:ready'
          secrets: inherit

  Same pattern fixes review.yml and sync.yml. Migration: add reusable
  versions in SpraxelAiCompany/.github/workflows/, replace per-game
  workflow contents with shims, update new_game.sh to write shims.

## When SpraxelAiCompany grows or stabilizes enough
- **De-vendor `sync_work_md.py`.** SpraxelAiCompany is **public** (CEO
  decision 2026-05-23), so the cross-repo blocker is gone. The sync
  workflow on each game repo can switch from `python3
  .factory/scripts/sync_work_md.py` to `git clone --depth=1
  https://github.com/mdl16bit/SpraxelAiCompany /tmp/spraxel-framework &&
  python3 /tmp/spraxel-framework/scripts/sync_work_md.py`. After that,
  refreshing the script across N game repos is a no-op (each next
  workflow run picks up the new version automatically). Pinning to a
  specific tag would be even safer once we tag releases.

## When release-day automation lands
- **Build `--release-cut` mode into `sync_work_md.py`.** PM's release-day
  logic mentions this is TODO. The mode should: shift WORK.md's bottom
  dashed-line down past the "since last release" section's items (moving
  them into the top "shipped" section), then leave the middle section
  empty for the new release cycle to populate.

## When we have observed stuck-work patterns
- **Add a Witness agent.** Yegge's "supervisor that watches for stuck
  work" was deliberately cut from Phase 1 as premature. Revisit if we
  observe a recurring class of stuck items that PM's GUPP doesn't catch.

## Token-efficiency follow-ups
- **Switch to prompt caching for scheduled agents.** PM and Concierge
  routines currently embed their full agent definitions inline in the
  scheduled prompt (~1500 tokens each, every run). When the Anthropic
  remote-agent API exposes prompt caching with > 5-minute TTL for
  scheduled jobs, refactor to a stable cached prefix + a small dynamic
  suffix per run.
- **Move from embedded agent defs to dynamic fetch.** Same root cause: the
  routine prompts duplicate the agent definition file in
  `agents/spraxel-pm.md` / `agents/spraxel-concierge.md`. When the routine
  prompts grow stale (i.e. when we edit the framework agent files), we
  have to update the routines too. Two cleaner options:
  - Make SpraxelAiCompany public; the routine prompt becomes
    "Read https://raw.githubusercontent.com/.../agents/spraxel-pm.md and
    follow it."
  - Add SpraxelAiCompany as a second `source` in the routine's
    `session_context.sources` (if the API supports multi-source clones).
