# JAM_RUNBOOK.md — the delegate-all 48h game jam

The experiment: launch a brand-new tiny game as a SECOND registered game with
`policy.delegate_all: true` and let the factory run **fully unsupervised** for
~48 hours — designer ideas auto-accepted, architect self-answers, devs decide
instead of asking, placeholders instead of `[manual]` items. You learn what
your company builds when nobody steers, you stress-test every autonomy gate,
and win or lose it's the best devlog post you'll ever write.

**Decisions already made (CEO, 2026-07-09):** budget **~$50-100 total**;
**the Designer picks the concept unsupervised** (WORK.md starts empty; the
dry-queue trigger fires the Designer, and in delegate mode its ideas are
auto-accepted straight into shaping).

**Cost model:** the jam runs HEADLESS (`claude -p`) = metered API billing.
A headless sonnet dev run costs very roughly $0.30-0.80; crew runs less.
`daily_run_cap: 120` runs/day ≈ $40-70/day worst case → the ~$50-100 two-day
envelope. The cap AUTO-PAUSES the whole system when hit (`.paused` with an
explanatory note inside) — that's the leash. Watch actuals on day 1 via the
`item-costs.tsv` ledger + `token_usage` dashboard figures and loosen/tighten.

---

## Pre-flight — CEO manual steps (all of these are YOURS)

1. **Pick the weekend.** The Mac must stay awake ~48h. Either
   `caffeinate -dims &` in a terminal you leave open, or (better)
   `sudo pmset repeat wakeorpoweron MTWRFSU 19:00:00` + Energy Saver
   "prevent sleep." A sleeping Mac pauses the jam (catch_up will replay crew
   slots, but dev throughput dies).
2. **Verify git auth won't stall** (the locked-keychain failure mode):
   `gh auth setup-git` once, then confirm `cd ~/GameProjects/infiltrators &&
   git fetch` works without a prompt after a lock/unlock cycle.
3. **Create the jam repo's GitHub remote** (or decide local-only: skip pushes
   by leaving `origin` unset — the loop tolerates it but you lose the offsite
   copy). `gh repo create <jamname> --private --clone` into `~/GameProjects/`.
4. **Confirm the budget line** in the GAME_CONFIG below (`daily_run_cap`).
5. **Decide Infiltrators' posture during the jam**: leave
   `force_interactive_developers: true` for infiltrators (its headless devs
   stay off; crew agents still run and count toward the daily cap — that's
   ~10-15 runs/day of headroom to leave in the cap).

## Launch (operator/Claude does this with you present — ~15 min)

1. Run **`/spraxel-launch`** in an interactive session. Answer the interview
   minimally: name the jam (e.g. `jam-2026-08`), engine Godot, and say
   "delegate-all jam per JAM_RUNBOOK — skip Philosophy interview." Leave
   Philosophy.md's scaffold: one line only — *"48h jam. Designer's choice.
   Small, playable, finished beats ambitious."* (In delegate mode the
   Designer treats an open Philosophy as license, which is the experiment.)
2. **GAME_CONFIG.yaml for the jam repo** — the complete delegate block:
   ```yaml
   identity:
     name: "<jamname>"
     pitch: "48h delegate-all jam — designer's choice"
     must_include: []
     must_not_include: []
   policy:
     delegate_all: true
     budgets:
       daily_run_cap: 120          # THE leash — auto-pauses everything at 120 runs/day
   continuous:
     force_interactive_developers: false   # headless devs ON for this game
     dev_concurrency: 2            # 2 workers is plenty for a jam-sized repo
     target_per_batch: 999         # uncapped anyway in delegate mode
     retry_escalate_threshold: 3   # abandon stuck items fast ([cold], no CEO gate)
   agents:
     designer: { cron: "0 */4 * * *" }   # every 4h — keep the idea queue fed
   ```
3. **Registry**: add the jam to `COMPANY_CONFIG.yaml games:` with
   `enabled: true` (infiltrators stays enabled — the global
   `max_total_dev_workers: 4` pool is shared; interactive-mode infiltrators
   uses none of it).
4. **Seed nothing.** WORK.md stays empty — the designer's dry-queue trigger
   is the starting gun.
5. **Start the clock**: `rm ~/SpraxelAiCompany/.paused`. Note the time; the
   jam "ends" when YOU re-pause, ~48h later.

## During (optional peeking — it runs without you)

- `/spraxel-report` — what's running, what shipped.
- `tail -f ~/SpraxelAiCompany/logs/tick/$(date +%F).log` — dispatch heartbeat.
- Spend check: `python3 ~/SpraxelAiCompany/scripts/item_cost.py --since <launch-epoch> --pool api_credit`
  and `cat ~/SpraxelAiCompany/state/<jamname>/cache/item-costs.tsv`.
- Kill switch, any time: `touch ~/SpraxelAiCompany/.paused`.
- If the daily cap trips early, the system self-pauses — read the note inside
  `.paused`, decide whether to raise the cap, `rm .paused` to resume.

## After

1. `touch ~/SpraxelAiCompany/.paused`, then flip the jam's GAME_CONFIG to
   `enabled: false` in the registry (or keep it running — your call).
2. Play what it made. Export a build if it boots.
3. The devlog writes itself: the blogger has release notes, ship reports,
   and item-costs.tsv gives you the "this game cost $X" headline number.
4. Post-mortem the gates: check `[cold]`-shelved items (the poison-pill
   brake), reviewer block rate, and whether placeholders actually shipped —
   that's the autonomy-hardening feedback for the next jam.
