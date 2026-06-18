---
name: spraxel-develop
description: Interactive developer loop (force_interactive_developers mode) — run the Spraxel DEVELOPER role from this session instead of a headless `claude -p` worker, building WORK.md items one by one (claim → build → independent review → squash-merge → ship → push). `/spraxel-develop N` builds N then stops; `/spraxel-develop` builds to the batch cap, then parks and self-resumes on a CEO poke (non-bot commit, checkin, or saving TRIAGE.md). Dev on Sonnet, review on Haiku, via the Agent tool (subscription-side). Use when the user types /spraxel-develop (optionally with a count) or says "build the queue", "ship the next N", "keep building".
---

# Spraxel — interactive developer (`/spraxel-develop [N]`)

You ARE the dev loop: behave like `agents/spraxel-developer.md` + the merge wrapper
(`continuous_dev.sh`), but driven from this session so it bills to the subscription, not metered
`claude -p`. **Run FULLY AUTONOMOUSLY — NEVER stop to ask the CEO anything** (asking stalls the loop
overnight): on ambiguity escalate via the helper and move on; never pause to ask whether to
continue/proceed/stop. A run ends ONLY on a CEO interrupt (Esc/message) or, in CONTINUOUS mode, the
§3 park-and-self-resume. Assumes bypass-permissions mode.

Scripts live in `~/SpraxelAiCompany/scripts/` (abbreviated below): `interactive_dev_step.sh`
(the helper — lock/merge/ship), `spx_config.py`, `sonnet_cap.py`, `workmd.py`. Specs:
`agents/spraxel-developer.md`, `agents/spraxel-reviewer.md`. Heartbeat + sweep + all per-game state are handled by `interactive_dev_step.sh` subcommands (namespaced via gctx) — never hardcode `.cache/` paths.

## 0. Preflight
1. **Pick the project** (multi-game). `SLUG=$(spx_config.py current --game "<named>")`
   if the CEO named one, else `SLUG=$(spx_config.py current)`. Priority: explicit >
   folder you're in > last used > sole enabled. If `current` exits non-zero it's
   ambiguous → **ask the CEO**, set SLUG. Then
   `spx_config.py set-current "$SLUG"` and `GAME=$(spx_config.py game-dir "$SLUG")`.
   **Pass `--game "$SLUG"` to every helper/config call below.**
2. **Mode gate**: if `spx_config.py get continuous.force_interactive_developers --game "$SLUG"`
   is not true → STOP and tell the CEO to enable it first.
3. **Params + MODE**:
   - `target = get continuous.target_per_batch --game "$SLUG"`; `delegate_all = get policy.delegate_all --game "$SLUG"`.
   - **Arg N** (`/spraxel-develop 3`) → **ONE-SHOT**: `cap=N`, build then STOP (no park; honors N even under delegate_all).
   - **No arg** → **CONTINUOUS**: `cap=target`, build to cap then PARK + auto-resume on a poke.
     **delegate_all → uncapped** (`cap=∞`; only a dry queue ends an epoch; runs until the CEO stops or `.paused`).
   - Models: dev=**sonnet**, review=**haiku**. If `sonnet_cap.py is-capped` exits 0 → use **opus** for dev subagents. Re-check each item (the flag can flip mid-run).
4. **Heartbeat**: `interactive_dev_step.sh heartbeat on --game "$SLUG"` — re-run each build iteration (drives the dashboard's "develop: executing" + Current items); `heartbeat off` at the end (§4).
5. `interactive_dev_step.sh release-claims --game "$SLUG"` — clears orphan `[wip:0]` from an interrupted item.
6. CONTINUOUS only: `reset-signal --game "$SLUG"` (counter→0) so epoch 1 builds a full cap.
7. delegate_all only: `workmd.py auto-clear-gates "$GAME/WORK.md"` (makes gated items buildable); re-run each CONTINUOUS epoch.
8. Init `shipped=0, escalated=0, retried=0`.

## 1. Build loop — per item (a–e) until STOP
**STOP when:** ONE-SHOT → shipped `cap` or queue dry; CONTINUOUS → `cap-status --game "$SLUG"` shows
`shipped >= cap` or queue dry (delegate_all: only a dry queue ends the epoch). Use the shared
`cap-status`, not a local count, so a poke's reset frees the next epoch.

a. **Claim**: `interactive_dev_step.sh claim-one --game "$SLUG"`. `EMPTY` → dry, stop (cap NOT hit).
   Else parse JSON `title, details, branch, worktree, is_test_failure, test_ref` fresh each iteration.

a2. **Destructive gate — NEVER ask the CEO.** If the item deletes/deprecates/removes/folds/consolidates
   existing code or features (not purely additive), do NOT build it: `interactive_dev_step.sh fail-one
   "<branch>" "<title>" escalate --detail "deferred: destructive — CEO sign-off"` then `continue` (tags
   `[needs-ceo]`, so claim skips it + gates its epic). Build ADDITIVE items only.

b. **Develop** — fresh dev subagent per item (Agent tool, `model: sonnet`, or opus if capped):
   *"Follow `agents/spraxel-developer.md`. Implement ONLY this item (Title/Details). Work ONLY inside
   `<worktree>` on `<branch>`, incremental commits. **WORK.md is OFF-LIMITS: never edit, append to, or
   run `workmd.py` against ANY WORK.md — not the copy in `<worktree>`, and NOT the canonical
   `$GAME/WORK.md` you might find via `git worktree list` — for ANY reason, even if your own self-check
   or the developer spec mentions filing MANUAL/asset-gap items. WORK.md is owned SOLELY by the loop
   driver, who persists your MANUAL lines post-merge.** Do NOT merge, push, switch the canonical
   checkout's branch, or run your own reviewer/merge step — just build on the branch in the worktree.
   `[bug]` → add a `test/unit/` regression test. End with `COMMIT_SUBJECT: <subject>` + body + any
   `MANUAL: [<art|sfx|writing|level|tuning>] <desc>` lines (these lines ARE how follow-ups reach
   WORK.md — I file them; you must not). If ambiguous, say so."*
   - **delegate_all**: append *"No CEO — no `MANUAL:` lines; ship working PLACEHOLDERS (note in body);
     never flag ambiguity, decide + record it."*
   - Dev flags ambiguity → (e) escalate. **Sonnet-cap**: if a sonnet dev subagent dies on a usage
     limit (or empty), `sonnet_cap.py set` then re-dispatch the SAME item on **opus** (stay until `is-capped` clears).

b2. **WORK.md sanity guard (run after the dev settles, before review).** If a dev ignored the rule and
   left the canonical WORK.md dirty, discard it so it can't confuse the reviewer or leak into the ship:
   `git -C "$GAME" checkout -- WORK.md 2>/dev/null || true`. The dev's `MANUAL:` lines (from its final
   message) are the source of truth — you persist them in (e) via `append-manual`. This is
   belt-and-suspenders: `claim-one`/`finish-one`/`append-manual` each `reset --hard origin/master`
   under the master-push lock, so a stray write is auto-healed regardless — but discarding it here keeps
   the review honest.

c. **Independent review** — a SEPARATE subagent (Agent tool, `model: haiku`), independent of (b):
   *"Follow `agents/spraxel-reviewer.md`. Review `git -C <worktree> diff master...HEAD` +
   `bash scripts/check_file_sizes.sh <worktree> HEAD master`. Item `<title>`. Verdict `clean`/`blocking`
   (each `[block]` = file:line + fix). **FLOW NOTE — interactive loop: MANUAL/asset-gap follow-ups are
   filed by the loop driver post-merge, NOT by the dev in the branch. Do NOT raise a blocking finding
   for "MANUAL items missing from WORK.md" — that is not a code concern here. Judge ONLY the code
   (correctness, the diff, file-size caps).** WRITE your verdict as the FIRST line of
   `<worktree>/.factory/reviews/<branch>.md` (overwrite) — `VERDICT: clean` or `VERDICT: blocking`,
   then findings — BEFORE you finish, so the verdict is durable on disk."*
   - **Read the verdict from that file**, not just the notification. Notifications can be lost (e.g.
     across a context compaction); the file is the source of truth. If the notification never arrives,
     poll the file — and NEVER infer a stall from file mtime (a stale mtime means *finished long ago*,
     not *hung*); confirm via the verdict file or the agent's transcript tail (`stop_reason: end_turn`).

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
On a cap-hit stop (NOT a dry queue), CONTINUOUS runs this once per epoch before PARK:
`bash ~/SpraxelAiCompany/scripts/interactive_dev_step.sh post-batch-sweep --game "$SLUG"`
The helper fires the full-test runner iff engine on-time ≥ `test_runner.interactive_sweep_after_hours`
and no sweep is already in flight (else it no-ops); failures become `[test_failure]` items built next
run. (All per-game state paths live in the helper — the skill hardcodes none.)

## 3. CONTINUOUS — PARK + auto-resume  (ONE-SHOT skips → §4)
When an epoch hits the cap (or the queue went dry) and §2 has fired, PARK:
1. Call **ScheduleWakeup** (`delaySeconds: 90`, `reason` "parked at cap") with a `prompt` that
   re-enters this resume logic — **bake the resolved SLUG in literally** (out of scope on wake):
   *"[/spraxel-develop CONTINUOUS auto-wake] Parked on project
   `<SLUG>`. Run `interactive_dev_step.sh poked --game <SLUG>`. Exit 0 → run `release-claims --game <SLUG>`
   then `reset-signal --game <SLUG>`, then resume §1 on `<SLUG>`. Exit 1 → ScheduleWakeup ~90s with
   this same prompt and end the turn."* Then tell the CEO: *"Parked (`<cap-status>`); I'll resume on a
   poke, or interrupt me to stop."* **End the turn.**
2. **On wake**: re-resolve SLUG from the baked-in name; `release-claims --game "$SLUG"`; then
   `interactive_dev_step.sh poked --game "$SLUG"` → exit 0: `reset-signal --game "$SLUG"`, go to §1
   (fresh epoch); exit 1: re-PARK (step 1).
3. **Stop**: if the CEO interrupts (Esc / a message) and says stop → schedule no further wake-up, go to §4.
> (No ScheduleWakeup? End the turn with the poke message; resume on the CEO's next poke + message.)

## 4. Stop + report
1. `interactive_dev_step.sh heartbeat off --game "$SLUG"`; schedule no further wake-up.
2. Report shipped/retried/escalated, what remains, and whether a sweep was kicked off. Stop.

## Invariants
- Lock discipline is in the helper (`claim-one`/`finish-one`/`fail-one` take `master-push.lockdir`) — never hand-roll game-master pushes; if `claim-one` says `lost push race`, call it again.
- You're the SOLE dev (mode guarantees no headless devs); `.paused` pauses crew, not this skill.
- `poked` = a non-bot master commit, `checkin.sh`, or a TRIAGE.md save (the loop's own `*-bot@spraxel.ai` commits never count). Every counted ship calls `bump-cap` so "Cap counter X/N" matches headless.
