---
name: spraxel-develop
description: Interactive developer loop for force_interactive_developers mode. Runs the Spraxel DEVELOPER role from this interactive session instead of a headless `claude -p` worker — building WORK.md items one-by-one (claim → build → independent review → squash-merge → ship → push). TWO MODES — `/spraxel-develop N` builds exactly N items then stops (one-shot); `/spraxel-develop` with NO number builds up to the batch cap, then PARKS and self-resumes whenever the CEO pokes the system (a non-bot commit, a checkin, or saving TRIAGE.md), looping until told to stop. Dev work runs on Sonnet, review on Haiku, both via the Agent tool (subscription-side, not metered). Use when the user types /spraxel-develop (optionally with a count) or says "build the queue", "develop the work items", "ship the next N", "keep building".
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
2. **Resolve params + MODE**:
   - `game_dir` = `spx_config get game_dir` (expand a leading `~`).
   - `target` = `spx_config get continuous.target_per_batch` (5) — the cap size.
   - **MODE** (the whole behavior split):
     - A **number was passed** (`/spraxel-develop 3`) → **ONE-SHOT** mode. `cap = that number`.
       Build `cap` items, then STOP. No parking, no auto-resume.
     - **No arg** (`/spraxel-develop`) → **CONTINUOUS** mode. `cap = target`. Build up to the cap,
       then PARK and self-resume on a CEO poke — looping until the CEO stops it.
   - Dev model = **sonnet** (`models.developer`); reviewer model = **haiku** (`models.reviewer`).
3. **Heartbeat ON**: `touch ~/SpraxelAiCompany/.cache/interactive-dev-active`. Re-touch it at the
   top of every BUILD iteration (the dashboard reads its freshness for "develop: executing").
   Always remove it when the run ends (§4).
4. **Clear stale claims**: `bash ~/SpraxelAiCompany/scripts/interactive_dev_step.sh release-claims`
   — releases any orphan `[wip:0]` left by a previously interrupted item (e.g. you pressed Esc
   mid-build) so it becomes eligible again and nothing is stranded.
5. **CONTINUOUS mode only — fresh start**:
   `bash ~/SpraxelAiCompany/scripts/interactive_dev_step.sh reset-signal` (counter→0, watermark→
   current master) so the first epoch builds a full `cap`. (ONE-SHOT mode: skip this — it builds
   exactly its N regardless of the counter.)
6. Initialize `shipped=0`, `escalated=0`, `retried=0`.

## 1. Build the batch — repeat the per-item steps (a–e) until the STOP condition

Re-`touch` the heartbeat marker at the start of each iteration. **STOP building the current batch when:**
- **ONE-SHOT**: you have shipped `cap` items, OR the queue is dry (`claim-one` → `EMPTY`). Then do
  §2 (sweep, if cap hit) and §4 (stop) — you're done.
- **CONTINUOUS**: `interactive_dev_step.sh cap-status` shows `shipped >= cap` (cap hit), OR the
  queue is dry. Then do §2 (sweep, if cap hit) and §3 (PARK).

Use the **shared** counter (`cap-status`) for the CONTINUOUS stop test — NOT a local count — so
that a poke's counter-reset is exactly what lets the next epoch run. In ONE-SHOT mode, count the
items you shipped this run.

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
   > short body. **If the feature introduces any asset gap (a new entity/pickup needing real
   > art, a new audible event needing real SFX, new copy needing writing, a new level, or
   > tuning), list each as an explicit `MANUAL: [<art|sfx|writing|level|tuning>] <short desc>`
   > line in your handoff** — do NOT edit WORK.md; I persist them after the merge. If the item
   > is genuinely ambiguous or needs a CEO decision, say so clearly instead of guessing."
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
     - Prints `SHIPPED: …` (rc 0) → first, **persist any `[manual]` asset follow-ups the
       dev reported** in its handoff (the dev must NOT edit WORK.md; finish-one discards any
       branch WORK.md change, so these would otherwise be lost). For EACH follow-up the dev
       named (e.g. "needs a real sprite for the new pickup"), run:
       ```
       bash ~/SpraxelAiCompany/scripts/interactive_dev_step.sh append-manual "[manual] [<art|sfx|writing|level|tuning>] <short desc>" --detail "Spawned by: <item title>"
       ```
       Then update the cap counter the SAME way the headless worker does. If the item counts
       toward the cap — i.e. NOT (`is_test_failure` true AND `spx_config get
       continuous.cap_excludes_test_fixes` true) — increment BOTH your local `shipped` AND the
       **shared** cap counter so the dashboard "Cap counter X/N" reflects interactive ships
       identically to headless ones:
       ```
       bash ~/SpraxelAiCompany/scripts/interactive_dev_step.sh bump-cap
       ```
       (A `[test_failure]` fix under `cap_excludes_test_fixes` counts toward neither — same
       exclusion the headless main loop applies.) `continue`.
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

## 2. Post-batch full-test sweep (when the cap was HIT — both modes)

Run this when the batch stopped because the **cap was hit** (ONE-SHOT: shipped `cap`; CONTINUOUS:
`cap-status` shows `shipped >= cap`) — NOT if the queue went dry. And only if no sweep is already
in flight (`~/SpraxelAiCompany/.cache/test-runner-active` and `…/test-runner-pending` both absent).
In CONTINUOUS mode this fires once per epoch, right before you PARK (§3).

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

## 3. CONTINUOUS mode — PARK, then poll for a CEO poke and resume

**ONE-SHOT mode skips this entirely → go straight to §4 and stop.**

When a CONTINUOUS epoch hits the cap (or the queue went dry) and §2 has fired, you PARK and let
the session self-resume on a poke:

1. **Schedule a wake-up and END THE TURN** (so control returns to the CEO and the loop self-resumes):
   - Call **ScheduleWakeup** with `delaySeconds: 90`, a short `reason` (e.g. "parked at cap —
     polling for a CEO poke"), and a `prompt` that re-enters THIS resume logic, e.g.:
     > "[/spraxel-develop CONTINUOUS — auto-wake] You are mid-run, parked at the cap. Run
     > `bash ~/SpraxelAiCompany/scripts/interactive_dev_step.sh poked`. If it exits 0 (a CEO
     > poke — it prints the reason), run `interactive_dev_step.sh release-claims` then
     > `reset-signal`, then resume building the next batch (§1). If it exits 1, ScheduleWakeup
     > again (~90s) with this same prompt and end the turn."
   - Then tell the CEO: "Parked at the cap (`<cap-status>`). I'll resume automatically when you
     poke the system — a non-bot commit on master, a `checkin.sh`, or **saving TRIAGE.md** — or
     interrupt me (Esc / a message) to stop or redirect." End the turn.
2. **On wake** (the prompt above fires): `release-claims`, then `interactive_dev_step.sh poked`:
   - **exit 0** (poked) → `reset-signal`, then go to §1 and build the next batch (a fresh epoch).
   - **exit 1** (no poke) → re-PARK (step 1 again: ScheduleWakeup ~90s, end the turn).
3. **Stopping**: the CEO interrupts (Esc while building, or a message any time) and tells you to
   stop. When that happens, do NOT schedule another wake-up — go to §4.

> If `ScheduleWakeup` isn't available in this context, fall back to: PARK by ending the turn with
> the same "poke to resume" message, and resume when the CEO next pokes + messages you (run the
> same `poked` / `reset-signal` checks on re-entry). The behavior is identical; only the
> auto-wake-while-idle is lost.

## 4. Stop + report

(ONE-SHOT mode lands here after its batch. CONTINUOUS mode lands here only when the CEO stops it.)

1. **Heartbeat OFF**: `rm -f ~/SpraxelAiCompany/.cache/interactive-dev-active`. Do NOT schedule
   any further wake-up.
2. Report to the CEO: how many shipped / retried / escalated this run, what (if anything) remains,
   and whether a full-test sweep was kicked off (and that any `[test_failure]` items it files will
   be built on the next run/epoch). Then stop.

## Notes / invariants

- **Lock discipline is in the helper** — `claim-one`/`finish-one`/`fail-one` each take the
  shared `master-push.lockdir` briefly so you never lose a concurrent crew WORK.md push.
  Don't hand-roll git pushes to the game master from here; always go through the helper.
- **One developer only**: the mode (tick.sh + continuous_dev.sh) guarantees no headless
  dev runs, so you're the sole claimant — no claim races.
- **`.paused` is separate**: it pauses crew agents, not this manually-run skill. You may
  run /spraxel-develop while the system shows PAUSED (the dashboard shows both states).
- If `claim-one` ever prints `lost push race`, just call it again — a crew push won the race.
- **Interrupting (CONTINUOUS mode)**: the CEO presses **Esc** to interrupt mid-build, or just
  types while you're parked between epochs. Either way, handle their request (stop, talk to the
  producer, dictate a fix, etc.). If they Esc'd mid-item, the next `release-claims` (run at the
  top of every batch + on every wake) clears the orphaned `[wip:0]` so nothing is stranded.
- **Resume pokes**: `poked` returns true on a non-bot commit on master, a `checkin.sh` touch, OR
  a TRIAGE.md save. The interactive-dev bot commits use `*-bot@spraxel.ai`, so the loop's own
  ship commits never count as a poke (they won't falsely reset the counter).
- **Cap parity**: every counted ship calls `bump-cap`, so the dashboard "Cap counter X/N" and the
  CONTINUOUS stop test (`cap-status`) reflect interactive ships exactly like headless ones.
