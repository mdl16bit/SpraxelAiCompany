# CCR keepalive routine — setup

The autopilot relies on a periodic "fire keepalive.yml" trigger. GitHub Actions cron is unreliable for active repos (GH throttles scheduled fires for repos with >100 runs/day under their "fairness across the platform" policy). When that happens, the entire autopilot stops making forward progress until someone manually dispatches keepalive.

The fix: drive keepalive from an Anthropic `/schedule` CCR routine. Runs on Anthropic infra, independent of GH Actions throttling. It posts a marker comment on the Factory Daily Log issue, which fires `keepalive.yml` via the `issue_comment` event (one of GH's events that DOES cascade from a GitHub App token).

## Setup steps (per game repo)

### 1. Pre-requisites

- Target game repo already has the framework applied (`new_game.sh` ran)
- Factory Daily Log issue exists (any number; routine queries by title)
- `CLAUDE_CODE_OAUTH_TOKEN` secret set in the repo
- The `keepalive.yml` workflow file is current (includes `issue_comment` trigger filter for `KEEPALIVE-TICK`)

### 2. Create the routine

In a Claude Code session (any directory works), invoke `/schedule` and follow the prompts:

| Field | Value |
|---|---|
| Action | `create` |
| Name | `Spraxel Keepalive trigger — <Game> (hourly)` |
| Cron | `17 * * * *` (every hour at :17 past — staggered off :00/:30 peak load) |
| Model | `claude-haiku-4-5-20251001` (cheapest; this routine just runs one tool call) |
| Source git repo | `https://github.com/<owner>/<repo>` (the game's repo) |
| Allowed tools | `Bash`, `Read` |
| MCP connections | Google Drive (optional — not used by this routine) |

### 3. Routine prompt

Paste this as the routine's user message:

```markdown
## DRYRUN GUARD

Read `Philosophy.md` from cwd. If `run_mode: "dryrun"`, print `Keepalive trigger: run_mode=dryrun — exiting.` and exit cleanly.

## WHY

GH Actions cron is unreliable for this repo (throttled when run volume is high). This routine posts a marker comment on the Factory Daily Log issue (typically #5) every hour; keepalive.yml's `on: issue_comment` trigger fires when it sees the marker. MCP github comment-writes use a GitHub App token whose events cascade to workflows (unlike GITHUB_TOKEN).

## TASK

Post a comment with the body `KEEPALIVE-TICK <ISO-UTC-timestamp>` on the Factory Daily Log issue of this repo.

The MCP github server here has NO workflow/actions tools (confirmed via probing). It DOES have issue comment tools. Try these names in order — the FIRST that exists is the right one:

1. `mcp__github__add_issue_comment` with args `{owner: "<OWNER>", repo: "<REPO>", issue_number: <ISSUE_NUM>, body: "KEEPALIVE-TICK <timestamp>"}`
2. `mcp__github__create_issue_comment` (same args)
3. `mcp__github__issue_comment_write` (same args)
4. `mcp__github__issue_write` (with `action: "comment"`)

To find the issue number: `mcp__github__search_issues` for "Factory Daily Log in:title state:open" within the repo.

If success: print `Keepalive trigger: posted KEEPALIVE-TICK comment on issue #<N> via <tool> at <UTC-time>` and exit cleanly.

If NONE of those exist: print `Keepalive trigger: no MCP comment-write tool found. Tools with 'comment' or 'issue' in name that DO exist: <list>` and exit non-zero.

If the call errors: print `Keepalive trigger: comment FAILED via <tool>: <error>` and exit non-zero.

## CONSTRAINTS

- Do NOT read other files
- Do NOT use Bash for github operations (no gh CLI / no curl in CCR sandbox)
- Use the MCP tools directly
- Total runtime target: under 30 seconds
- Timestamp: `$(date -u +%Y-%m-%dT%H:%M:%SZ)` format
```

Replace `<OWNER>`, `<REPO>`, `<ISSUE_NUM>` with the game's actual values (or let the routine discover the issue number via search).

### 4. Verify

After creating the routine, run it once manually (the `/schedule` UI has a "run now" button):

```bash
# In the target game repo, check that:
gh issue view <factory-log-issue-number> --json comments --jq '.comments[-1].body'
# Should show: "KEEPALIVE-TICK 2026-..."

gh run list --workflow=keepalive.yml --limit 2
# Should show a fresh `issue_comment`-event run that fired ~5 seconds after the comment
```

## Maintenance

- Janitor weekly sweep deletes `KEEPALIVE-TICK` comments older than 24h, keeping issue #5 tidy.
- If the routine fails (e.g., MCP server upgrade renames a tool), the keepalive.yml's GH cron at `:13,:43` is the backup — may be delayed but eventually fires.
- Cost: ~5K tokens per fire × 24 fires/day × Haiku rate ≈ trivial.

## Trouble-shooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Routine posts comment but keepalive doesn't fire | `keepalive.yml` missing `issue_comment` in `on:` block or the filter doesn't match | Check `keepalive.yml`'s `on:` and the job's `if:` condition includes the marker check |
| Routine errors with "no MCP tool found" | MCP github server changed tool names | Update the prompt's tool-name candidates |
| Comments accumulate but Janitor doesn't sweep | Janitor not running, or sweep not in spec | Check Janitor's spec includes the `KEEPALIVE-TICK` sweep step |
