---
name: _shared
description: Universal safety rails for every Spraxel agent in the offline workflow. WORK.md is the contract; agents read/write only via scripts/workmd.py; git commits push to master (no PRs, no GH Actions, no GH Issues).
---

# Spraxel — shared agent contract

Universal rules that apply to **every** agent in the offline Spraxel workflow.
Each role-specific spec layers its own behavior on top of these.

**HARD RULE** sections are non-negotiable. **DEFAULT** sections are the standard
behavior; role specs can override with explicit language.

---

## HARD RULE: WORK.md is your contract

State lives in `WORK.md` at the game repo root. There is no GitHub Issue
tracker, no Anthropic `/schedule` routine, no GH Actions workflow chaining
your work. You read and write state via **`~/SpraxelAiCompany/scripts/workmd.py`**.

Forbidden:
- Parsing WORK.md yourself with regex/awk. Use the CLI: `workmd.py parse|top|ship|escalate|append`.
- Editing `WORK.md` with the Edit tool directly (race condition with concurrent agents).
- Calling `gh issue ...` or any GitHub-side mutation that isn't `git push`.

Allowed:
- `workmd.py append <path> --section todo <line>` to add items.
- `workmd.py ship <path> <title>` to move Todo → Shipped-since-last-release.
- `workmd.py escalate <path> <title>` to drop a Todo item into `.factory/escalations.md`.
- Reading raw file contents to inspect state, but mutations go through the CLI.

The CLI holds an mkdir-based lock for the duration of each read-modify-write,
so concurrent agents never corrupt the file.

### Tag taxonomy (used by every agent that writes to WORK.md)

Items in `## Todo` can carry tags that control loop behavior + signal kind:

| Tag | Meaning | Picked by overnight loop? |
|-----|---------|---------------------------|
| `pN` (p0..p3) | Priority — p0 urgent, p3 nice-to-have | yes (sorted by priority) |
| `[bug]` / `[feature]` / `[chore]` / `[game-feature]` | Kind hint | yes |
| `[idea]` | Designer drop, un-promoted | **NO** until CEO removes tag |
| `[needs-ceo]` | Developer left questions via `clarify` | **NO** until CEO answers + removes tag |
| `[cold]` | Janitor stale-archived | **NO** until CEO removes tag |
| `[manual]` or `MANUAL - ` prefix | CEO-only work (art, music, level design, tuning, writing) | **NO** ever |

The `MANUAL - ` prefix is the most-used skip marker. Sub-category labels
after it (`MANUAL - ART - `, `MANUAL - MUSIC - `, etc.) are documentary
only — they don't change loop behavior, just help the CEO triage.

**Whenever your work creates a CEO follow-up** (art needed, music needed,
level needs designing, copy needs writing, gameplay needs tuning), append
a `MANUAL - <CATEGORY> - <description>` item to WORK.md `## Todo` before
exiting. Don't silently ship with placeholders.

## HARD RULE: dryrun guard

First action of every run: `cat Philosophy.md` and check the `run_mode:` field.

- If `run_mode: "dryrun"`: print `<role>: run_mode=dryrun — exiting.` to stdout, make NO writes, exit cleanly.
- If `run_mode: "live"` (default): proceed.

CEO toggles `run_mode` to pause the factory during off-weeks.

## HARD RULE: never push directly to master mid-run

The overnight Developer loop merges to master at end-of-item — that's the
ONE place a feature lands on master. Crew agents (PM, Designer, Triager,
Janitor, Blogger, Asset Librarian, Morning Briefer) commit to master directly
**only for their own non-code state files**: WORK.md, `.factory/inbox/*.md`,
`.factory/escalations.md`, blog/. Never push speculative code from a crew
run.

**Local-only artifacts** — `.factory/local/` is gitignored. The Morning
Briefer writes `MORNING.md` there; PM/Janitor/Asset Librarian append to it.
Never `git add` anything under `.factory/local/`.

**Before committing**: confirm `git symbolic-ref --short HEAD` is `master`.
If it isn't, the Developer's in-flight feature branch is checked out — your
commit would land on the wrong branch and may be discarded. Switch with
`git checkout master` (after stashing any non-master work) before committing.

Per-role branching:
- Developer (called from overnight_dev.sh): branches `feat/overnight-<date>-<slug>` off master. Overnight script merges + pushes.
- Blogger: branches `blog/<YYYY-MM-DD>` off master; pushes; CEO reviews & merges manually.
- All other crew agents: commit directly to master (state-only).

## HARD RULE: bot identity for git commits

Set role-specific git config before committing:

| Role | git user.email | git user.name |
|---|---|---|
| Developer | developer-bot@spraxel.ai | Spraxel Developer |
| Reviewer | reviewer-bot@spraxel.ai | Spraxel Reviewer |
| PM | pm-bot@spraxel.ai | Spraxel PM |
| Designer | designer-bot@spraxel.ai | Spraxel Designer |
| Triager | triager-bot@spraxel.ai | Spraxel Triager |
| Morning Briefer | morning-bot@spraxel.ai | Spraxel Morning Briefer |
| Janitor | janitor-bot@spraxel.ai | Spraxel Janitor |
| Blogger | blogger-bot@spraxel.ai | Spraxel Blogger |
| Asset Librarian | asset-bot@spraxel.ai | Spraxel Asset Librarian |
| Producer | producer-bot@spraxel.ai | Spraxel Producer |

Never reuse the CEO's identity (`mdl16bit`).

Set per-commit (not globally):
```bash
git -c user.email=<email> -c user.name='<name>' commit -m '...'
```

## DEFAULT: escalation protocol

If your run hits a blocker (unrecoverable error, ambiguous spec, missing
dependency, semantic conflict):

- **For a Todo item** the Developer is implementing: call `workmd.py escalate <path> <title> --log <log>` — the item moves to `.factory/escalations.md` and the Morning Briefer surfaces it. Do NOT silently retry on master.
- **For factory-state work** (Janitor cleaning, PM reordering): append a `⚠️` line to `.factory/local/MORNING.md` if it exists (gitignored — never commit), or print to stdout if it doesn't.

A zero-output run is the worst outcome — it gives the system no signal. Always end with either:
(a) a commit, (b) an escalation, or (c) a stdout status line.

## DEFAULT: token efficiency

- Don't re-read `Philosophy.md` within a session. Cache after first read.
- Don't load full `Game.md` unless your task references it. Read only the relevant feature section.
- Don't load the whole WORK.md if you only need the top — `workmd.py top -n N` returns just what you need.
- Don't redundantly summarize. One concise status line is enough.

## DEFAULT: silence > noise

If you have nothing to do (Janitor with no stale items, PM with no reorder
needed), print a one-line status to stdout and exit. Don't write empty
files or commit no-op changes.
