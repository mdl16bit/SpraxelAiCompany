---
name: spraxel-develop
description: Interactive developer loop (force_interactive_developers mode) — run the Spraxel DEVELOPER role from this session instead of a headless `claude -p` worker, building WORK.md items one by one (claim → build → independent review → squash-merge → ship → push). `/spraxel-develop N` builds N then stops; `/spraxel-develop` builds to the batch cap, then parks and self-resumes on a CEO poke (non-bot commit, checkin, or saving TRIAGE.md). Dev on Sonnet, review on Haiku, via the Agent tool (subscription-side). Use when the user types /spraxel-develop (optionally with a count) or says "build the queue", "ship the next N", "keep building".
---

# Spraxel — interactive developer (`/spraxel-develop [N]`)

You ARE the dev loop: behave like `agents/spraxel-developer.md` + the merge wrapper
(`continuous_dev.sh`), but driven from this session so it bills to the subscription, not metered
`claude -p`. **Never prompt the CEO mid-run** — on ambiguity, escalate via the helper and move on.
Assumes bypass-permissions mode.

Scripts live in `~/SpraxelAiCompany/scripts/` (abbreviated below): `interactive_dev_step.sh`
(the helper — lock/merge/ship), `spx_config.py`, `sonnet_cap.py`, `workmd.py`. Specs:
`agents/spraxel-developer.md`, `agents/spraxel-reviewer.md`. Heartbeat: `.cache/interactive-dev-active`.

## 0. Preflight
1. **Pick the project** (multi-game). `SLUG=$(spx_config.py current --game "<named>")`
   if the CEO named one, else `SLUG=$(spx_config.py current)`. Priority: explicit >
   folder you're in > last used > sole enabled. If `current` exits non-zero it's
   ambiguous (candidates on stderr) → **ask the CEO**, set SLUG. Then
   `spx_config.py set-current "$SLUG"` and `GAME=$(spx_config.py game-dir "$SLUG")`.
   **Pass `--game "$SLUG"` to every helper/config call below.**
2. **Mode gate**: if `spx_config.py get continuous.force_interactive_developers --game "$SLUG"`
   is not true → STOP and tell the CEO to enable it first (else you race the headless pool).
3. **Params + MODE**:
   - `target = get continuous.target_per_batch --game "$SLUG"`; `delegate_all = get policy.delegate_all --game "$SLUG"`.
   - **Arg N** (`/spraxel-develop 3`) → **ONE-SHOT**: `cap=N`, build then STOP (no park; honors N even under delegate_all).
   - **No arg** → **CONTINUOUS**: `cap=target`, build to cap then PARK + auto-resume on a poke.
     **delegate_all → uncapped** (`cap=∞`; only a dry queue ends an epoch; runs until the CEO stops or `.paused`).
   - Models: dev=**sonnet**, review=**haiku**. If `sonnet_cap.py is-capped` exits 0 → use **opus** for dev subagents. Re-check each item (the flag can flip mid-run).
4. **Heartbeat**: `touch .cache/interactive-dev-active` — re-touch each build iteration; remove at the end (§4).
5. `interactive_dev_step.sh release-claims --game "$SLUG"` — clears orphan `[wip:0]` from an interrupted item.
6. CONTINUOUS only: `reset-signal --game "$SLUG"` (counter→0) so epoch 1 builds a full cap.
7. delegate_all only: `workmd.py auto-clear-gates "$GAME/WORK.md"` (makes gated items buildable); re-run each CONTINUOUS epoch.
8. Init `shipped=0, escalated=0, retried=0`.

## 1. Build loop — per item (a–e) until STOP
**STOP when:** ONE-SHOT → shipped `cap` OR queue dry;
CONTINUOUS → `interactive_dev_step.sh cap-status --game "$SLUG"` shows `shipped >= cap` OR queue dry
(delegate_all: ignore the cap test — only a dry queue ends the epoch). Use the **shared** `cap-status`
(not a local count) so a poke's reset frees the next epoch.

a. **Claim**: `interactive_dev_step.sh claim-one --game "$SLUG"`. `EMPTY` → dry, stop (cap NOT hit).
   Else parse JSON `title, details, branch, worktree, is_test_failure, test_ref` (re-read fresh each item — crew agents may edit WORK.md between items).

b. **Develop** — fresh dev subagent (Agent tool, `model: sonnet`, or opus if capped). A fresh
   subagent per item = clean context:
   *"Follow `agents/spraxel-developer.md` exactly. Implement ONLY this item — Title `<title>`,
   Details `<details>`. Work in worktree `<worktree>` on `<branch>` with incremental commits; do NOT
   merge/push/touch WORK.md (canonical `$GAME/WORK.md` is read-only). If `[bug]`, add a regression
   test under `test/unit/`. End with `COMMIT_SUBJECT: <subject>` + short body, and list any asset gap
   as `MANUAL: [<art|sfx|writing|level|tuning>] <desc>` (don't edit WORK.md — I persist them
   post-merge). If genuinely ambiguous, say so instead of guessing."*
   - **delegate_all**: append *"No CEO — emit NO `MANUAL:` lines; ship working PLACEHOLDERS noted in
     the body; never flag ambiguity, decide and record the assumption."*
   - Dev flags ambiguity → (e) escalate. **Sonnet-cap**: if a sonnet dev subagent dies on a usage
     limit (or empty), `sonnet_cap.py set` then re-dispatch the SAME item on **opus** (stay until `is-capped` clears).

c. **Independent review** — a SEPARATE subagent (Agent tool, `model: haiku`), independent of (b):
   *"Follow `agents/spraxel-reviewer.md`. Review `git -C <worktree> diff master...HEAD` plus
   `bash scripts/check_file_sizes.sh <worktree> HEAD master`. Item `<title>`. Verdict `clean` or
   `blocking` (list each `[block]` as file:line + fix)."*

d. **Review loop**: if `blocking`, re-dispatch the dev subagent with the findings (same worktree/branch),
   then re-review. Up to **2** fix rounds; still blocking → (e) with mode `retry`.

e. **Finish or fail**:
   - **clean** → `interactive_dev_step.sh finish-one "<branch>" "<title>" --subject "<COMMIT_SUBJECT>" --game "$SLUG"`.
     - `SHIPPED:` (rc 0) → for EACH `MANUAL:` the dev named, persist it (finish-one discards branch
       WORK.md edits, so do it here): `interactive_dev_step.sh append-manual "[manual] [<kind>] <desc>" --detail "Spawned by: <title>" --game "$SLUG"`.
       Then, unless (`is_test_failure` AND `get continuous.cap_excludes_test_fixes --game "$SLUG"` is true):
       `interactive_dev_step.sh bump-cap --game "$SLUG"` and `shipped+=1`. `continue`.
     - rc 2 (Game.md gate) / rc 1 (merge conflict / push fail) → `fail-one … retry`, `retried+=1`, `continue`.
   - **still blocking / merge failure** → `interactive_dev_step.sh fail-one "<branch>" "<title>" retry --detail "<reason>" --game "$SLUG"`, `retried+=1`, `continue`.
   - **ambiguity / CEO decision** → `interactive_dev_step.sh fail-one "<branch>" "<title>" escalate --detail "<what & why>" --game "$SLUG"`, `escalated+=1`, `continue`.
     **delegate_all**: use `retry` not `escalate` (no CEO); the poison-pill brake auto-`[cold]`s after `continuous.retry_escalate_threshold` attempts.

## 2. Post-batch test sweep (only when the cap was HIT)
Skip on a dry-queue stop, or if a sweep is in flight (`.cache/test-runner-active` or `…/test-runner-pending` present). CONTINUOUS fires this once per epoch, before PARK.
1. `th = get test_runner.interactive_sweep_after_hours --game "$SLUG"`; if 0/empty → skip.
2. `hours = (.cache/engine-uptime-since-test.json → seconds) / 3600`.
3. If `hours >= th`: `touch .cache/test-runner-pending` then
   `nohup bash ~/SpraxelAiCompany/scripts/test_runner.sh --game "$SLUG" >> ~/SpraxelAiCompany/logs/test_runner/$(date +%F).log 2>&1 &`.
   It runs the suite, files failures as `[test_failure]` items (built next run), and resets the uptime counter.

## 3. CONTINUOUS — PARK + auto-resume  (ONE-SHOT skips → §4)
When an epoch hits the cap (or the queue went dry) and §2 has fired, PARK:
1. Call **ScheduleWakeup** (`delaySeconds: 90`, `reason` "parked at cap") with a `prompt` that
   re-enters this resume logic — **bake the resolved SLUG in literally** (fresh re-entry; the
   variable is out of scope on wake): *"[/spraxel-develop CONTINUOUS auto-wake] Parked on project
   `<SLUG>`. Run `interactive_dev_step.sh poked --game <SLUG>`. Exit 0 → run `release-claims --game <SLUG>`
   then `reset-signal --game <SLUG>`, then resume §1 on `<SLUG>`. Exit 1 → ScheduleWakeup ~90s with
   this same prompt and end the turn."* Then tell the CEO: *"Parked (`<cap-status>`); I'll resume on a
   poke, or interrupt me to stop."* **End the turn.**
2. **On wake**: re-resolve SLUG from the baked-in name; `release-claims --game "$SLUG"`; then
   `interactive_dev_step.sh poked --game "$SLUG"` → exit 0: `reset-signal --game "$SLUG"`, go to §1
   (fresh epoch); exit 1: re-PARK (step 1).
3. **Stop**: if the CEO interrupts (Esc / a message) and says stop → schedule no further wake-up, go to §4.
> If ScheduleWakeup is unavailable: just end the turn with the poke-to-resume message and resume when the CEO next pokes + messages (same `poked`/`reset-signal` checks) — only the idle auto-wake is lost.

## 4. Stop + report
1. `rm -f .cache/interactive-dev-active`; schedule no further wake-up.
2. Report shipped/retried/escalated, what remains, and whether a sweep was kicked off (its `[test_failure]` items build next run). Stop.

## Invariants
- Lock discipline lives in the helper (`claim-one`/`finish-one`/`fail-one` take `master-push.lockdir`); never hand-roll pushes to the game master. If `claim-one` prints `lost push race`, just call it again.
- You're the SOLE dev (the mode guarantees no headless devs) — no claim races. `.paused` pauses crew agents, not this skill (you may run it while the dashboard shows PAUSED).
- `poked` = a non-bot master commit OR `checkin.sh` OR a TRIAGE.md save; the loop's own `*-bot@spraxel.ai` ship commits never count. Every counted ship calls `bump-cap`, so "Cap counter X/N" matches headless.
