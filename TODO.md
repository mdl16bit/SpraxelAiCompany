# Spraxel framework — planned upgrades

Items that are deliberately deferred from Phase 1, with the trigger that should
prompt the upgrade. Each entry is one work item; we add (or remove) items as
the framework matures.

## MCP GitHub server — missing tools (blocks several features)

The MCP GitHub server exposed inside scheduled CCR sandboxes is missing
endpoints that we'd otherwise use. Probe results from
`infiltrators/.factory/probe-pm-tools.md` (2026-05-23). Each gap drives
a specific deferred feature. Re-evaluate quarterly or when Anthropic
announces MCP additions.

| Missing tool | Blocks | Workaround |
|---|---|---|
| `mcp__github__create_milestone` / `update_milestone` / attach-to-issue | PM milestone work; release scoping by milestone | PM uses priority labels + velocity cap instead; CEO sets milestones manually if needed (rare) |
| `mcp__github__create_release` | Autonomous release-day tagging | CEO runs `gh release create v0.X --generate-notes` locally on cadence day |
| `mcp__github__delete_branch` | Janitor stale-branch cleanup | Janitor flags branches for CEO to delete via GitHub UI or local `git push --delete` |
| `mcp__github__run_workflow` (uncertain — needs reprobe) | PM triggering `release.yml` shim | Track separately; if present, build release shim |

Re-enable conditions:
- Anthropic ships the missing tool → enable the feature in the relevant
  agent definition, push the prompt change to the live routine, remove
  the entry from this table.
- Or: we build a custom MCP server backed by GH REST API with a fine-
  grained PAT injected via routine config (significant effort; only
  pursue if 2+ blockers persist past Q3 2026).

## CRITICAL: Developer #2 bypassed PR flow, pushed direct to master (2026-05-24 02:18 UTC)

Developer agent (run 26349350909, claude-code-action@v1) was triggered
on issue #3 (HideBox). Instead of creating a feature branch and opening
a PR, it pushed **directly to master** as commit `46e0b8e`. That code
was therefore:
- Never reviewed (review.yml only fires on PRs)
- Never tested (test.yml only fires on PRs)
- Closed the source issue when Developer #3 later saw the files exist

The `branch_prefix: "feat/"` action input did NOT prevent this. The
action's checkout step puts the runner on `master`, and unless Claude
explicitly creates a feature branch first, commits end up on master.

### Immediate mitigation (shipped this session)
- developer.yml prompt now has a "CRITICAL: never push to master"
  section at the top of the action's prompt — explicit instructions to
  `git checkout -b feat/issue-<N>-...` as the FIRST action on any
  commit-producing run, and explicit "fireable offense" framing.
- show_full_output: true so future direct-push attempts are visible.

### Real fix: GitHub branch protection on master
Currently mitigation relies on Claude following instructions. The
durable fix is branch-protection rules that physically reject any
push to master that didn't come through a PR.

Recommended rule set (CEO sets via
https://github.com/mdl16bit/infiltrators/settings/branches):
- Require a pull request before merging (1 approval not required;
  PM agent will be the merger)
- Require status checks to pass: `Tests`, `Reviewer`
- Disallow force pushes
- Disallow branch deletions
- Allow administrators to bypass (CEO emergency)

### Open design question
With strict branch protection, PM's own state writes (today.md,
memory/pm.md) will be rejected too, because PM also pushes directly
to master. Options:
1. PM commits its state via auto-merge-PRs (overhead but safe).
2. PM writes state to a separate non-protected branch (`factory-state`).
3. PM uses a different storage layer (GH Issues / Discussions /
   Gist).
4. Accept the trade-off: PM stays bypass-eligible (still risky).

Pick before enabling protection. Probably (2) for cleanliness.

### The commit 46e0b8e itself
Currently being tested on master via workflow_dispatch on test.yml.
If it passes: leave it. If it fails: revert.

---

## Defects found during PR #4 (hide-box) full-autopilot smoke test (2026-05-24 02:00 UTC)

The first PR driven through the new auto-merge pipeline (issue #3
HideBox) surfaced FOUR real defects in the test + review infrastructure.
All fixable; next session priority.

### 1. test.yml needs an editor-import step
The Developer's `hide_box.gd` script declared `class_name HideBox` and
the matching scenario at `scripts/scenarios/hide_box.gd` did
`box as HideBox`. Godot's class-cache only registers `class_name`
during an editor import; the bare `godot --headless` in test.yml does
NOT refresh that cache for new files. Result: scenario fails to parse,
"ERROR: Could not find type 'HideBox'."

Same root cause: GUT failed silently with `Missing class_names: [GutErrorTracker, ...]`.

**Fix:** add one step to test.yml BEFORE running tests:
```yaml
- name: Refresh class cache (editor import)
  run: godot --editor --headless --quit-after 30 || true
```
This runs Godot's editor briefly which populates the class cache, then
exits. GUT classes and any new game class_names get registered.

### 2. test.yml's scenario loop is too permissive
The loop relies on `godot --headless ... --quit-after=10` exiting 0
to declare pass. But Godot exits 0 even when a script fails to parse —
the parse error is logged to stderr but doesn't propagate. PR #4 got
labeled `tests:pass` despite the scenario failing to load.

**Fix:** capture the godot stdout+stderr per scenario and grep for
`ERROR:` / `Parse error` / `SCRIPT ERROR`. Also require the scenario
to print its own `SCENARIO <slug>: PASS` line. Stricter:

```bash
output=$(godot --headless --path . -- --demo-feature="$slug" --trace-file="/tmp/$slug.jsonl" --quit-after=10 2>&1)
echo "$output"
if echo "$output" | grep -qE "^(ERROR:|SCRIPT ERROR|Parse error)"; then
  echo "::error::scenario $slug had script errors"
  fail=1
elif ! echo "$output" | grep -q "SCENARIO .* PASS"; then
  echo "::error::scenario $slug did not print PASS"
  fail=1
fi
```

### 3. Reviewer ran but posted nothing
Reviewer Haiku run on PR #4: 17 turns, $0.18, succeeded — but posted
zero comments and added no `reviewed:*` label. Either Haiku decided
there was nothing to say (despite the code having a real parse error
that Reviewer should have caught), OR the action's
"post-buffered-inline-comments" stage saw nothing to post and skipped.

**Fix:** add `show_full_output: true` to review.yml to see what the
agent actually decided. Then tune the prompt: require ONE summary
comment + ONE `reviewed:*` label even on a clean review, never zero
output. Currently the prompt says "End with a single summary comment
... Then label the PR ..." but Haiku may have skipped both as
optimization.

### 4. Developer can ship parse errors
Independent of the test infra: the Developer agent shipped code with
a Parse error and the test infra approved it. With PM's merge step
trusting `tests:pass + reviewed:clean`, broken code would auto-land.

**Fix:** items 1+2+3 above. With all three fixed, broken code can't
get to the merge step.

### Smoke test postmortem
PR #4 closed unmerged with explanation. Branch deleted. Issue #3
reopened, label `status:claimed` removed so the issue is back in the
backlog. Re-attempt after fixes 1+2+3 ship.

---

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

## End-state goal: PM owns merge + release entirely (CEO eyeballs, doesn't gate)

Tracked progress on the three-stage build:

### Stage 1 — auto-merge clean PRs
✅ **Shipped** (in PM v4 → v5, agents/spraxel-pm.md section 4.5). PM
itself is the merge orchestrator — no separate merge.yml needed.
Daily PM run scans for `reviewed:clean + tests:pass` PRs and squash-
merges up to 2 per run. Excludes `priority:p0`. Verified safe (PR #4
was correctly held back when test.yml caught its parse error post-
hardening; PR #4 was closed unmerged).

### Stage 2 — Release scope via labels
✅ **Shipped** (in PM v5). PM determines current release version
from `mcp__github__list_releases` (highest v0.<X> tag → next is
v0.<X+1>; v0.1 if no releases yet) and applies `release:v0.<X+1>`
label to every merged PR. The label is the source of truth for
"what's shipping in this release."

### Stage 3 — PM release-day automation
🟡 **Partial.** The CEO-side pieces are built; the agent-side piece
is blocked.

✅ Built: `sync_work_md.py --release-cut v0.<N> --apply` lifts every
middle-section item into the top "shipped" section with the version
prefix, preserves continuation indents, and empties the middle
section. CEO can run this on cadence day after tagging.

⛔ Blocked: PM cannot autonomously create the release tag. The MCP
GitHub server probe confirmed there's no `mcp__github__create_release`
tool exposed in the cloud sandbox. Same root cause as the milestone
gap. Until either:
- Anthropic adds `create_release` to the MCP, or
- We add a small workflow_dispatch wrapper that PM triggers (the
  workflow runs `gh release create` via the GH App's regular auth),

…the cadence-day workflow is:
1. PM (daily auto) keeps merging + labeling PRs with `release:v0.<N>`
2. CEO on cadence day (Mondays biweekly): runs locally:
     gh release create v0.<N> --generate-notes
     python3 ~/SpraxelAiCompany/scripts/sync_work_md.py --repo-dir . --release-cut v0.<N> --apply
     git add WORK.md && git commit -m 'release: v0.<N>' && git push
3. Next PM run sees the new v0.<N> tag and starts labeling new merges
   with `release:v0.<N+1>`.

### Future: release-tag automation via workflow_dispatch shim

Lowest-effort path to fully autonomous release-day: add a
`release.yml` workflow that PM triggers via
`mcp__github__run_workflow` (if available; otherwise PM creates an
issue tagged `command:cut-release` and a separate scheduled job
watches for it). The workflow runs `gh release create v0.<N>
--generate-notes` + the `--release-cut` Python script + a commit. PM
just needs to invoke it on cadence day. Track this when MCP gains
workflow-trigger capability.

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
