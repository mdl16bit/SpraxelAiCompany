---
name: spraxel-develop
description: Interactive developer loop for force_interactive_developers mode. Runs the Spraxel DEVELOPER role from this interactive session instead of a headless `claude -p` worker — building WORK.md items one-by-one (claim → build → independent review → squash-merge → ship → push), up to the batch cap, then stopping. Dev work runs on Sonnet, review on Haiku, both via the Agent tool (subscription-side, not metered). Use when the user types /spraxel-develop (optionally with a count, e.g. `/spraxel-develop 3`) or says "build the queue", "develop the work items", "ship the next N".
---

# Spraxel — interactive developer (`/spraxel-develop [N]`)

You ARE the developer loop now. Behave EXACTLY like the headless developer
(`agents/spraxel-developer.md`) + the wrapper (`continuous_dev.sh`) that merges
its work — but driven from this interactive session so the dev work bills against
the subscription, not metered `claude -p`. **Never prompt the CEO** during the
run: on any ambiguity, escalate via the helper and move on (same contract as the
headless dev). This skill assumes the session is in **bypass-permissions mode**.

Paths (absolute):
- Helper (lock/merge/ship mechanics): `~/SpraxelAiCompany/scripts/interactive_dev_step.sh`
- Config loader: `~/SpraxelAiCompany/scripts/spx_config.py`
- Dev spec: `~/SpraxelAiCompany/agents/spraxel-developer.md`
- Reviewer spec: `~/SpraxelAiCompany/agents/spraxel-reviewer.md`
- Heartbeat marker: `~/SpraxelAiCompany/.cache/interactive-dev-active`

## 0. Preflight

1. **Mode gate** — read `continuous.force_interactive_developers`:
   `python3 ~/SpraxelAiCompany/scripts/spx_config.py get continuous.force_interactive_developers`
   (the loader prints `True`/`False`, capitalized — treat case-insensitively).
   If it is NOT true, STOP immediately and tell the CEO: "force_interactive_developers
   is false — headless devs are live; enable the mode (set it true in COMPANY_CONFIG or
   the game's GAME_CONFIG) before running /spraxel-develop, or you'll race the headless
   pool." Do not proceed.
2. **Resolve params**:
   - `game_dir` = `spx_config get game_dir` (expand a leading `~`).
   - `N` = the numeric arg to the skill if given, else `spx_config get continuous.target_per_batch` (5).
   - Dev model = **sonnet** (`models.developer`); reviewer model = **haiku** (`models.reviewer`).
3. **Heartbeat ON**: `touch ~/SpraxelAiCompany/.cache/interactive-dev-active`. You will
   re-touch it at the top of every iteration (the dashboard reads its freshness to show
   "develop: executing"). Always remove it on exit (step 4 / on stop).
4. Initialize `shipped=0`, `escalated=0`, `retried=0`.

## 1. Build loop — repeat while `shipped < N`

Re-`touch` the heartbeat marker at the start of each iteration.

a. **Claim** the next item (syncs master, claims under the master-push lock, pushes the
   `[wip:0]` tag):
   ```
   bash ~/SpraxelAiCompany/scripts/interactive_dev_step.sh claim-one
   ```
   - Output `EMPTY` → the queue is dry. Stop the loop (go to step 3); note the cap was NOT hit.
   - Otherwise parse the JSON: `title`, `details`, `branch`, `worktree`, `is_test_failure`,
     `test_ref`. Always re-read this fresh each iteration — a crew agent may have changed
     WORK.md between items.

b. **Develop** — dispatch a fresh **dev subagent via the Agent tool** (`model: sonnet`):
   > "You are the Spraxel developer. Read and follow `~/SpraxelAiCompany/agents/spraxel-developer.md`
   > EXACTLY. Implement THIS item only:
   > Title: `<title>`
   > Details:
   > `<details>`
   > Work inside the git worktree `<worktree>` on branch `<branch>` (already checked out).
   > Make incremental commits there. Do NOT merge, do NOT push, do NOT touch WORK.md.
   > The canonical WORK.md is `<game_dir>/WORK.md` (read-only for you). If this is a
   > `[bug]`, you MUST add a never-again regression test under `test/unit/` (per the spec).
   > When done, print a final line `COMMIT_SUBJECT: <conventional-commit subject>` and a
   > short body. If the item is genuinely ambiguous or needs a CEO decision, say so clearly
   > instead of guessing."
   - A fresh subagent per item is the per-item "clear context" (matches the headless
     fresh-`claude -p` model).
   - If the dev subagent reports the item is ambiguous / needs CEO → go to (e) escalate.

c. **Independent review** — dispatch a SEPARATE **reviewer subagent via the Agent tool**
   (`model: haiku`):
   > "You are the Spraxel reviewer. Read and follow `~/SpraxelAiCompany/agents/spraxel-reviewer.md`
   > EXACTLY. Review the diff `git diff master...HEAD` inside the worktree `<worktree>`
   > (run `git -C <worktree> diff master...HEAD`). Also run
   > `bash ~/SpraxelAiCompany/scripts/check_file_sizes.sh <worktree> HEAD master`.
   > The item is `<title>`. Return a verdict: `clean` or `blocking`, and for `blocking`
   > list each `[block]` finding with file:line and what to fix."
   - Use a separate subagent (NOT yourself) so the review is independent of the code you
     just wrote.

d. **Review loop**: if `blocking`, dispatch the dev subagent again with the findings to
   fix (in the same worktree/branch), then re-review. Allow up to **2** fix rounds. If it
   is still blocking after that → (e) with mode `retry`.

e. **Finish or fail**:
   - **Clean** → merge + ship + push under the lock:
     ```
     bash ~/SpraxelAiCompany/scripts/interactive_dev_step.sh finish-one "<branch>" "<title>" --subject "<COMMIT_SUBJECT from the dev>"
     ```
     - Prints `SHIPPED: …` (rc 0) → increment `shipped` UNLESS (`is_test_failure` is true AND
       `spx_config get continuous.cap_excludes_test_fixes` is true) — then it does NOT count
       toward the cap (mirror headless). `continue`.
     - rc 2 (Game.md gate) or rc 1 (merge conflict/push fail) → treat as a blocking failure:
       run `fail-one … retry` (below), `retried += 1`, `continue`.
   - **Still blocking / merge failure** → bounce to the queue as `[retry]`:
     ```
     bash ~/SpraxelAiCompany/scripts/interactive_dev_step.sh fail-one "<branch>" "<title>" retry --detail "<one-line reason: reviewer blocks or merge conflict>"
     ```
     `retried += 1`, `continue`.
   - **Genuine ambiguity / needs a CEO decision** → escalate and move on (NEVER ask the CEO inline):
     ```
     bash ~/SpraxelAiCompany/scripts/interactive_dev_step.sh fail-one "<branch>" "<title>" escalate --detail "<what decision is needed and why>"
     ```
     `escalated += 1`, `continue`.

## 2. Post-batch full-test sweep (only when the cap was HIT)

Run this ONLY if the loop stopped because `shipped == N` (a full batch) — NOT if the queue
went dry. And only if no sweep is already in flight (`~/SpraxelAiCompany/.cache/test-runner-active`
and `…/test-runner-pending` both absent).

1. Threshold = `spx_config get test_runner.interactive_sweep_after_hours` (merged; infiltrators=48).
   If it is `0` or empty → skip the sweep.
2. Engine-active hours since the last full test run:
   read `~/SpraxelAiCompany/.cache/engine-uptime-since-test.json` → `seconds / 3600`.
3. If `hours >= threshold`: kick off the same batch runner the system uses (fire-and-forget):
   ```
   touch ~/SpraxelAiCompany/.cache/test-runner-pending
   nohup bash ~/SpraxelAiCompany/scripts/test_runner.sh >> ~/SpraxelAiCompany/logs/test_runner/$(date +%Y-%m-%d).log 2>&1 &
   ```
   It runs the whole suite, files any failures as `[test_failure]` items, and resets the
   uptime counter on completion. Those `[test_failure]` items are built by the NEXT
   `/spraxel-develop` run.

## 3. Stop + report

1. **Heartbeat OFF**: `rm -f ~/SpraxelAiCompany/.cache/interactive-dev-active`.
2. Report to the CEO: how many shipped / retried / escalated, what (if anything) remains,
   and whether a full-test sweep was kicked off (and that any `[test_failure]` items it
   files will be built next run). Then stop and wait — do not loop further.

## Notes / invariants

- **Lock discipline is in the helper** — `claim-one`/`finish-one`/`fail-one` each take the
  shared `master-push.lockdir` briefly so you never lose a concurrent crew WORK.md push.
  Don't hand-roll git pushes to the game master from here; always go through the helper.
- **One developer only**: the mode (tick.sh + continuous_dev.sh) guarantees no headless
  dev runs, so you're the sole claimant — no claim races.
- **`.paused` is separate**: it pauses crew agents, not this manually-run skill. You may
  run /spraxel-develop while the system shows PAUSED (the dashboard shows both states).
- If `claim-one` ever prints `lost push race`, just call it again — a crew push won the race.
