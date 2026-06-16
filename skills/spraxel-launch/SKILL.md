---
name: spraxel-launch
description: Onboard a NEW project/game into SpraxelAiCompany — interview the CEO to fill Philosophy/INSPIRATIONS/config, scaffold the repo via new_game.sh, register it in the multi-game `games:` registry ALONGSIDE existing games (never replacing them), wire up tests/daemon, and optionally seed starter work via an inline designer→architect pass. Engine-agnostic (Godot game, web game, app, or anything). Use when the user types /spraxel-launch or says "start a new project", "onboard a new game", "set up a new Spraxel project", "add a new game to the company".
---

# Spraxel — Launch (new-project onboarding)

Guided, interactive setup for a brand-new project. The Spraxel *framework* is now
multi-game: adding a project **registers it alongside** the existing ones (it does
NOT switch away from infiltrators or any running game). One daemon iterates all
enabled games; per-game state is namespaced automatically.

**Baby-walk the CEO.** Label every step **"I'll do this"** (you run it) vs
**"you do this"** (system-level / their call), give exact commands and the expected
output, and confirm before anything outward-facing or hard to reverse (registry
edits, git init, pushes). Don't invent design content — interview, or let the CEO
type it.

## What you (Claude) should do

### Step 0 — Pre-flight (I'll do this)
- Confirm the framework root: `~/SpraxelAiCompany`. Read `scripts/new_game.sh`
  (the scaffolder) and `template/` (what gets copied) so you describe accurately.
- List existing games so the CEO sees what's already there:
  `python3 ~/SpraxelAiCompany/scripts/spx_config.py games`

### Step 1 — Interview (gather the essentials)
Ask in ONE tight batch (use **AskUserQuestion** for the structured choices below;
free-text for prose). Don't gauntlet — 1 pass, then proceed.
- **Name** (display) + **slug** (short, kebab-case; default = slug of the name).
- **Target directory** (default `~/GameProjects/<slug>`).
- **One-sentence pitch.**
- **must_include** (2–4 things this project IS) / **must_not_include** (3–5 things
  it is NOT — these become the Producer/Designer guardrails).
- **Kind & stack** (engine-agnostic — assume nothing): Godot game? web game? mobile/
  desktop app? CLI? other? Capture `language`, `engine`/framework, the **run command**,
  and the **test command**.
- **Philosophy/INSPIRATIONS**: offer a choice — *"I can interview you to draft them,
  or scaffold blank files for you to type into."*
- **Cadence** (optional): release rhythm (default "biweekly"), or leave the template default.
- **CEO github login** (optional, for `--ceo`).

### Step 2 — Scaffold the repo (I'll do this)
- Create the dir if needed; if it should be a git repo and isn't one, `git init`
  (confirm first — that's a real action on their filesystem).
- Run the scaffolder (copies `template/` → substitutes `{{GAME_NAME}}`/`{{CEO_LOGIN}}`,
  creates `.factory/`, `test/`, test-runner stubs):
  ```bash
  bash ~/SpraxelAiCompany/scripts/new_game.sh "<dir>" --name "<name>" [--ceo "<login>"]
  ```
- Show what landed (`ls` the new dir). new_game.sh refuses to clobber an existing
  `.factory/` — if it skips files, say so.

### Step 3 — Fill the scaffold from the interview (I'll do this)
Replace the `TODO:` markers using the interview answers:
- **GAME_CONFIG.yaml** — `identity.name/pitch/must_include/must_not_include`;
  `dev.language/engine`, run/test commands, `style_guide`. The template is
  Godot-centric: for a **non-Godot** project, set `dev.*` to the real stack, and
  REMOVE or rewrite the Godot-specific bits (`godot_binary`, `main_scene`, the
  GUT-based `template/scripts/run_*tests.sh`, `scripts/scenarios/*.gd`) — replace the
  test runner with the project's real one, or leave a clear `TODO:` if unknown.
- **Philosophy.md** — prose pitch + an explicit "what we are NOT making" list (from
  the interview, or leave the scaffold for the CEO if they chose to type it).
- **INSPIRATIONS.md** — optional; fill from the interview or leave the blank template.
- **Game.md / CLAUDE.md** — seed what's known (controls, engine setup, conventions);
  leave `TODO:` for the rest. Keep CLAUDE.md accurate — agents read it every run.
- **WORK.md** — leave the fresh 3-section skeleton (Step 6 can seed `## Todo`).

### Step 4 — Register in the games registry (you confirm; I'll apply)
This is the step that makes the project live. Edit `~/SpraxelAiCompany/COMPANY_CONFIG.yaml`
`games:` map to ADD the new project (do NOT touch existing entries):
```yaml
games:
  infiltrators: { dir: ~/GameProjects/infiltrators, enabled: true }
  <slug>:
    dir: <dir>
    enabled: true
```
- Show the exact diff and confirm before writing.
- Verify: `python3 ~/SpraxelAiCompany/scripts/spx_config.py games` lists the new game,
  and `python3 ~/SpraxelAiCompany/scripts/spx_config.py paths <slug>` shows its
  namespaced state dirs.
- The running daemon picks it up on the next tick (≤60s) — no restart needed. Note
  the global dev-worker ceiling (`global.max_total_dev_workers`) is shared across all
  games; mention it if the CEO expects the new game to run workers immediately.

### Step 5 — Tests / daemon wiring (baby-walk; mostly "you do this")
Tailor to the stack from Step 1:
- **Godot**: walk the CEO through (a) setting `dev.godot_binary` to their absolute
  Godot path, (b) installing GUT into the new repo, (c) `cd <dir> && bash
  scripts/install_local_tests.sh` for the 30-min local-test cron. Give exact commands;
  these are "you do this" (system-level).
- **Other stacks**: point `dev.test`/run commands at the real tooling; skip GUT. If a
  local-test cron makes sense, adapt `template/scripts/install_local_tests.sh`.
- The crew agents (designer/architect/pm/…) already run for every enabled game on the
  shared cron — nothing to install for those.

### Step 6 — Optional: seed starter work (interactive designer→architect)
Offer: *"Want me to seed N starter items? I'll run a designer→architect pass right
here (subscription-side, not metered)."* If yes:
- **As the Designer**: read `~/SpraxelAiCompany/agents/spraxel-designer.md`, the new
  `Philosophy.md` + `INSPIRATIONS.md`, and propose **N ranked ideas** that fit the
  pitch + `must_include`/`must_not_include`. (Use the **Agent tool** for the heavy
  thinking if you want parallelism — it stays subscription-side, unlike headless
  `claude -p`.)
- **As the Architect**: read `~/SpraxelAiCompany/agents/spraxel-architect.md` and shape
  each idea into a concrete, buildable spec (what/why/size/acceptance), decomposing
  big ones into an `[epic]` + subtasks.
- Append them to the new project's WORK.md with the canonical tool + game flag:
  ```bash
  python3 ~/SpraxelAiCompany/scripts/workmd.py append "<dir>/WORK.md" --section todo \
    "[untriaged] [game-feature] pN <title>" --detail "what: …" --detail "why: …"
  ```
- Record the new project as the current one so later skills default to it:
  `python3 ~/SpraxelAiCompany/scripts/spx_config.py set-current "<slug>"`

### Step 7 — Wrap up
- Summarize: project registered, files filled, tests wired (or what the CEO still
  needs to do), N items seeded.
- Offer next: `/spraxel-develop <slug>` to start building, or `/spraxel-report` to see
  it on the (per-project) dashboard.
- Commit only if the CEO asks: the new repo (its own git), and the `COMPANY_CONFIG.yaml`
  `games:` edit in the framework repo.

## What NOT to do
- **Never replace or disable an existing game.** Registration is additive.
- **Don't run system-level installs** (GUT, launchd crons, git init) without the CEO —
  present them as "you do this" with exact commands, or confirm first.
- **Don't invent Philosophy/INSPIRATIONS content.** Interview or let the CEO type it.
- **Don't use headless `claude -p`** for seeding — do it inline (subscription-side).

## Notes
- Scaffolder: `~/SpraxelAiCompany/scripts/new_game.sh`; template: `~/SpraxelAiCompany/template/`.
- Registry + layout: `scripts/spx_config.py` (`games`, `paths <slug>`, `set-current`).
- Multi-game internals (namespacing, worker ceiling) are automatic — see the framework
  docs; this skill only needs the registry entry.
