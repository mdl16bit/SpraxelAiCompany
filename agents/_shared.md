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
- `workmd.py clarify <path> <title> --question ...` to tag `[needs-ceo]`
  and surface dev questions to the CEO.
- `workmd.py retry <path> <title>` (wrapper-only) to bounce a failed dev
  branch back into the queue. Crew agents do NOT call this — only
  continuous_dev.sh does.
- Reading raw file contents to inspect state, but mutations go through
  the CLI.

**HARD RULE: items in WORK.md are never deleted by agents.** The only
acceptable lifecycle endpoints are:
  - `ship` (Todo → Shipped-since-last-release; the item is preserved
    under the Shipped header)
  - CEO manual edit (the CEO can delete an item line by hand, but no
    agent or script should)
  - Janitor `[cold]` retag (stale archive — the item stays in Todo
    tagged `[cold]`, never deleted)

If an attempt fails (tests, reviewer, merge conflict), the item stays
in Todo tagged `[retry]` with the failure feedback in details — it does
NOT get dropped, and the CEO does NOT get escalated.

The CLI holds an mkdir-based lock for the duration of each read-modify-write,
so concurrent agents never corrupt the file.

### Tag taxonomy (used by every agent that writes to WORK.md)

Items in `## Todo` can carry tags that control loop behavior + signal kind:

| Tag | Meaning | Picked by overnight loop? |
|-----|---------|---------------------------|
| `pN` (p0..p3) | Priority — p0 urgent, p3 nice-to-have | yes (sorted by priority) |
| `[bug]` / `[feature]` / `[chore]` / `[game-feature]` | Kind hint | yes |
| `[idea]` | Designer drop, un-promoted | **NO** until CEO promotes (→ `[untriaged]`, into shaping) |
| `[untriaged]` | New feature-type item awaiting the Architect's first pass (fast-pass or questionnaire). Set by producer / designer-promote / manual CEO add. | **NO** until the Architect finalizes/fast-passes |
| `[untriaged-proposal-active]` | Architect wrote a shaping questionnaire; Q&A is in `.factory/local/TRIAGE.md` (keyed by the item's `triage-id` detail). | **NO** until the Architect finalizes the spec |
| `[needs-ceo]` | Developer left questions via `clarify` | **NO** until CEO answers + removes tag |
| `[cold]` | Janitor stale-archived | **NO** until CEO removes tag |
| `[manual]` or `MANUAL - ` prefix | CEO-only work (art, music, level design, tuning, writing) | **NO** ever |
| `[future]` or `FUTURE - ` prefix | Roadmap item not ready to schedule | **NO** until CEO promotes |
| `[concern]` | Designer/Producer advisory commentary | **NO** until CEO triages |
| `[escalated]` | Needs real CEO judgment (design/PM gameplay-ruiner, paid-asset block, story decision). RARE — never set automatically; only by triager/designer/PM/CEO manually. Wrapper regenerates `.factory/escalations.md` from these every iter. | **NO** until CEO retags as `[resume]` |
| `[resume]` | CEO triaged an `[escalated]` item; wrapper picks up the saved branch | yes (high priority) |
| `[retry]` | Wrapper auto-set after tests/reviewer/merge failed on prior dev attempt. Next dev fire resumes from saved branch with failure feedback in details. **Not a CEO action** — silently retried. | yes (high priority) |
| `[epic]` | Parent of a decomposed feature (Architect-created via `shape-epic`). Display + completion tracker only. Auto-ships once its last child ships. | **NO** ever (devs never build the parent) |

**Subtasks (epics).** A complex feature can be split into a parent `[epic]` item
plus child subtask items that share an `epic-id: E-xxxx` detail and are ordered
by a `seq: N` detail. Each child is a NORMAL item (full `[wip]`/ship/`[retry]`/
branch lifecycle). A child is eligible only once every lower-`seq` sibling has
shipped (left `## Todo`) — strictly sequential, so each builds on the prior one's
merged code, and with parallel workers at most one subtask of a feature is in
flight at a time. Items with no `epic-id` are shipped whole, exactly as before.

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
| Architect | architect-bot@spraxel.ai | Spraxel Architect |

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

## DEFAULT: leave a dated report when you finish

As your LAST step, write ONE short report of what you did + any news the CEO
should know, by piping markdown bullets to `report.sh`:

```bash
printf '%s\n' \
  "- <concrete change / news bullet>" \
  "- <another>" \
  | bash ~/SpraxelAiCompany/scripts/report.sh <your-role>
```

`<your-role>` is your `schedule.yaml` agent name (pm, designer, architect,
triager, playtester, janitor, blogger, asset_librarian, producer, demo_creator).
Keep it **scannable bullets of concrete changes** — "decomposed 4 features into
epics (8 subtasks)", "added 3 [bug] candidates", "reordered Todo: moved X above
Y" — not prose, not a re-dump of your whole run. The **Morning Briefer reads
every report written since the last briefing and distills them into MORNING.md's
"📰 News" section** — this is how your work reaches the CEO, so make it count.

It writes to `.factory/local/reports/` (gitignored, CEO-local; the Janitor
prunes old ones) — so reporting is NOT a commit and never needs a push.

Exceptions:
- **Developer + Reviewer do NOT report** — they run per-item under
  `continuous_dev.sh`, which writes one ship report per shipped item for them.
- **The Morning Briefer does NOT report** — it's the consumer of reports.
- Nothing to do? A one-line "nothing to do" report is fine, or skip it.

## DEFAULT: silence > noise

If you have nothing to do (Janitor with no stale items, PM with no reorder
needed), print a one-line status to stdout and exit. Don't write empty
files or commit no-op changes.
