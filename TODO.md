# Spraxel framework — planned upgrades

Items that are deliberately deferred from Phase 1, with the trigger that should
prompt the upgrade. Each entry is one work item; we add (or remove) items as
the framework matures.

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

The full vision the CEO articulated: agents merge their own PRs, PM
decides what belongs in each release, creates release branches/tags,
writes release notes, moves WORK.md dashed lines on release-cut.
Build this in three stages so trust accumulates with each.

### Stage 1 — `merge.yml` (auto-merge clean PRs)
Add a workflow that watches for `reviewed:clean` (Phase 1.x) or
`reviewed:clean AND playtest:pass` (Phase 2+) and runs
`gh pr merge --auto --squash` on the PR. Squash-merge keeps `master`
linear and gives PM one commit per feature for clean release notes.
~15 lines of YAML; trigger on `pull_request` `labeled` events.

Risk control: don't auto-merge anything labeled `priority:p0` (treat
critical work as human-gated even when reviewed clean). Configurable
in Philosophy.md as a label-exclusion list.

### Stage 2 — Release scope via labels (no milestones needed)
The milestone-tools gap (no `mcp__github__create_milestone`) doesn't
block release management. Use labels instead:
- PM tags each merged PR with `release:v0.<N>` per the biweekly cadence.
- `gh api repos/.../tags` and `gh release create` ARE callable via the
  MCP GitHub server (verified by probe routine).
- Release notes generated by listing PRs with `release:v0.<N>` label.

Re-enable section 5 of `agents/spraxel-pm.md` against this label-based
release model (replace "milestone" references with "release label").

### Stage 3 — PM release-day automation
On the cadence day (Philosophy `cadence.release`):
1. PM identifies merged PRs since last release tag.
2. Labels them all `release:v0.<N>` (next version number).
3. Cuts a `release/v0.<N>` branch from current master.
4. Tags + creates the GH Release with auto-generated notes from
   labeled PRs (`gh release create v0.<N> --generate-notes`).
5. Runs `sync_work_md.py --release-cut v0.<N>` (new mode TBD) to
   move WORK.md's middle-section items above the top dashed line
   into the "shipped" section.
6. Writes a one-line digest entry to `.factory/inbox/today.md`.

The CEO retains right of veto (revert release, force tag deletion,
etc.) but doesn't have to drive any of it.

### Build `--release-cut` mode into `sync_work_md.py`
Required for Stage 3. New CLI mode: `python sync_work_md.py
--release-cut v0.<N>`. Behavior:
- Verify the tag exists.
- Move items in the middle section (since-last-release) above the top
  dashed line into the "shipped" section.
- Annotate moved items with the release version: `- v0.4: <title> (#N)`.
- Leave the middle section empty for the new cycle.
- Commit + push.

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
