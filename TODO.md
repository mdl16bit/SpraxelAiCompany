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

### Still open
- **PM cannot create or attach milestones in the cloud sandbox.** Run 1
  + run 2 both reported that the `gh` CLI is not installed in the CCR
  environment and that the GitHub MCP tools available to PM don't
  include `create_milestone` or `set_milestone_on_issue`. Until this is
  resolved, PM tags `status:ready` correctly but **cannot milestone an
  issue** — the CEO has to either create + attach milestones manually
  via local `gh` or the GitHub web UI. Investigation needed:
  1. Confirm what tools PM actually has (next time we run PM, instruct
     it to emit `command -v gh; ls /tmp; mcp__list-tools` so we see
     ground truth).
  2. If `gh` truly isn't there, add an explicit install step
     (`apt-get install gh` or `curl ...`) at the start of the PM
     prompt, or vendor a small Python script that uses `urllib.request`
     to hit the GitHub REST API (`POST /repos/{owner}/{repo}/milestones`)
     with the `$GH_TOKEN` env var that the CCR sandbox already has.
  3. Validate that PM's milestone-create + milestone-attach steps now
     work end-to-end.

## When we hit the first real PR that needs reviewing
- **Upgrade `review.yml` from option (a) to option (b).** Currently the
  Reviewer workflow posts an `@claude` mention on PR open and relies on the
  installed Claude GitHub App to respond using the comment's prompt as
  guidance. This works but is generic. The upgrade: switch to
  `anthropics/claude-code-action@v1` with `ANTHROPIC_API_KEY` in repo
  secrets and the Reviewer agent definition baked into the action's prompt.
  Gives reliable, dedicated Reviewer behavior every time and labels PRs
  consistently (`reviewed:clean` / `reviewed:findings` / `reviewed:blocking`).

## When we start spawning Developers via GH Actions
- **Add `developer.yml` workflow.** Currently PM in Phase 1 just adds the
  `status:ready` label + a comment on top-priority issues. Real spawning
  needs a workflow triggered via `gh workflow run developer.yml -f issue=<N>`
  that checks out the repo, runs the Developer agent via the Anthropic
  action, opens a PR. PM's agent definition already references this
  conditional ("if developer.yml exists, spawn via workflow"); the upgrade
  is to actually create the workflow.

## When SpraxelAiCompany grows or stabilizes enough
- **De-vendor `sync_work_md.py`.** Currently the script is vendored at
  `infiltrators/.factory/scripts/sync_work_md.py` with a header note
  reminding us to refresh on framework updates. Options to remove the
  vendoring:
  - Make SpraxelAiCompany public — then `git clone` in workflows works
    without auth.
  - Or publish it as a small Python package on PyPI and `pip install` in CI.
  - Or use a fine-grained cross-repo deploy key / GH App with read access
    to SpraxelAiCompany.

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
