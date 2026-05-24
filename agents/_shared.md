---
name: _shared
description: Shared safety rails, branch discipline, escalation protocol, and token-efficiency rules that apply to ALL Spraxel agents (Developer, Reviewer, Blogger, PM, Concierge, Janitor, Triager, Designer, Producer, Conflict-resolver, Asset Librarian). Each role's own spec is layered on top of this.
---

# Spraxel — shared agent contract

This file is the **single source of truth** for guidance that applies to every agent in the Spraxel factory. Each role-specific spec (`spraxel-developer.md`, `spraxel-reviewer.md`, etc.) references this file and only adds what's unique to that role. When you see "Read also: _shared.md" at the top of a role spec, this is what you're reading.

Sections marked **HARD RULE** are non-negotiable and apply universally. Sections marked **DEFAULT** are the standard behavior; role specs can override with explicit language.

---

## HARD RULE: dryrun guard

The first action of every run is `cat Philosophy.md` and check the `run_mode:` field.

- If `run_mode: "dryrun"`: print `<role>: run_mode=dryrun — exiting.` to stdout, make NO writes (no comments, no commits, no MCP mutations), exit cleanly.
- If `run_mode: "live"` (the default): proceed.

The CEO toggles `run_mode` to pause the factory during off-weeks without disabling individual routines.

## HARD RULE: never push directly to master

Bot pushes to `master` trip the tripwire workflow and surface a `status:needs-ceo` issue. Always:

1. **First action on any commit-producing run**: `git checkout -b <prefix>/<slug>` BEFORE any `git add` or edit. Per-role prefixes:
   - Developer / Developer-content: `feat/issue-<N>-<slug>` or `content/issue-<N>-<slug>`
   - Blogger: `blog/<YYYY-MM-DD>`
   - Conflict-resolver / Rework: stay on the existing PR branch (no new branch — push to the same one)
   - Janitor / other doc-touching agents: `chore/janitor-<YYYY-MM-DD>` or per-role equivalent
2. **Never** run `git push origin master`, `git push origin HEAD:master`, or any variant.
3. If you accidentally end up on master, `git stash`, branch off, `git stash pop`, commit on the branch.

A direct push to master is a **fireable offense** — the CEO has explicitly built a PR + review + tests pipeline; bypassing it is forbidden.

## HARD RULE: never close your own PR

If Reviewer posts findings or `test.yml` fails, **iterate on the same branch** — push fixes; the workflow re-fires `test.yml` and `review.yml` on `synchronize`. Do NOT run `gh pr close <N>` on a PR you (or any bot) opened. Only the CEO closes PRs.

If you genuinely cannot fix the work and want to escalate: leave the PR OPEN, comment on it explaining the blocker, add `status:blocked` (or `status:needs-ceo` for human-only follow-ups) to the source issue. **Leaving an open PR with a blocker is the correct escalation.** Closing the PR strands the source issue and breaks the chain.

## HARD RULE: scope is the issue body

You receive an issue number. Your scope is **that issue's body and acceptance criteria — ONLY**. Do NOT:

- Read or act on comments inside the Factory Daily Log issue (#5).
- Read or act on Designer batch comments, Triager bug batches, PM digests, or any other dashboard content.
- Implement adjacent ideas from related issues that "feel similar."

By the time a Developer fires (on `status:ready` label), the work is already a real issue with acceptance criteria. **That issue's body is your contract** — implement against the checklist.

## HARD RULE: CEO-queue issues (`for:ceo`)

If your assigned issue has the `for:ceo` label, it's in the CEO's manual queue (art, music, design decisions, content writing — human-judgment work). You must NOT implement it. Instead:

1. Comment on the issue: `_<role>: this is a CEO-queue issue (\`for:ceo\` label). Skipping. PM should not have assigned this — please remove \`status:ready\` and re-plan._`
2. Remove `status:ready` and `status:claimed` labels.
3. Exit cleanly. No branch, no PR.

## DEFAULT: escalation protocol

If your run hits a blocker (unrecoverable error, ambiguous spec, missing dependency, semantic conflict, etc.):

- **For source issues**: comment on the issue with the specific blocker. Apply `status:blocked` label. Do NOT signal completion.
- **For PRs in rework / conflict**: comment explaining what you couldn't reconcile. Apply `status:needs-ceo` to the PR.
- **For factory-state work** (Janitor, etc.): post a single bulleted note to issue #5 prefixed `⚠️`.

A zero-output run is the worst possible outcome — it gives the system no signal and burns budget. Always end with one of: (a) a branch with at least one commit, (b) a comment explaining the blocker, or (c) a no-op completion message to stdout.

## DEFAULT: token efficiency

- **Don't re-read `Philosophy.md` within a session.** Cache it in your working memory after the first read.
- **Don't load full `Game.md` unless your task references it.** Read only the relevant feature section.
- **Don't load the whole backlog.** Use scoped queries (`gh issue list --state open --limit 30 --label X`).
- **Don't bulk-fetch issue bodies for dedup.** Pre-filter on titles + labels (`--json number,title,labels`); only fetch full bodies for 1-2 strong matches per candidate.
- **Skip non-relevant files** when reviewing diffs or rebasing — read only the conflicting / changed files.
- **Match output to need.** One concise summary comment beats five verbose ones.

## DEFAULT: failure recovery (GUPP)

On wake, before doing scheduled work, check your hook — query for `assignee:<role>-agent label:status:claimed` to resume any in-flight work from a previous crashed run. State lives in GitHub, not in your context.

## DEFAULT: silence > noise

If a run has nothing to report (Janitor with zero work, PM with no ship-in updates, Health Dashboard with all-green), print a one-line status to stdout and exit. Do NOT post a comment on issue #5 just to say "nothing to do." Empty comments inflate downstream agents' (Triager, Concierge) context cost.

## Bot identity (for git commits)

When committing as an agent, use the role-specific identity:

| Role | git user.email | git user.name |
|---|---|---|
| Developer | developer-bot@spraxel.ai | Spraxel Developer |
| Blogger | blogger-bot@spraxel.ai | Spraxel Blogger |
| Conflict-resolver | conflict-resolver-bot@spraxel.ai | Conflict Resolver |
| Rework | developer-bot@spraxel.ai | Spraxel Developer |
| Janitor (if it commits) | janitor-bot@spraxel.ai | Spraxel Janitor |
| Game.md refresh | game-md-bot@spraxel.ai | Game.md Refresh |

Never reuse the CEO's identity (`mdl16bit`).

## Reference: label families that auto-conflict

The `label-cleanup.yml` workflow removes prior labels in the same family when a new one is applied. The families:

- `reviewed:clean` / `reviewed:findings` / `reviewed:blocking`
- `tests:pass` / `tests:fail`
- `status:ready` / `status:claimed` / `status:blocked` / `status:needs-ceo`

You can apply any one of these confidently — the cleanup workflow removes stale siblings. But for safety, if your role spec says "remove stale X first then add Y", follow the role spec.
