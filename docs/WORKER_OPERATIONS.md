# Worker operations — git/worktree gotchas & recovery

Operational learnings for the `continuous_dev.sh` worker pool. These are failure
modes that cost real debugging time; the fixes are in-tree but the *why* lives
here so the next setup (or the next game) doesn't re-learn them the hard way.

The worker model in one paragraph: `tick.sh` (launchd, every 60 s) spawns up to
`continuous.dev_concurrency` workers. Each worker owns a git **worktree** under
`~/SpraxelAiCompany/.worktrees/worker-N/` linked to the active game repo
(`schedule.yaml: game_dir`). Between items a worktree sits at **detached HEAD on
`origin/master`**; to take an item it claims via `workmd.py claim` (tags it
`[wip:N]`), branches, codes, and the wrapper squash-merges to master. The
canonical `WORK.md` is the one in `game_dir` (NOT the worktree copy) — only ever
mutate it via `workmd.py`, and every mutation must be committed + pushed under
`.locks/master-push.lockdir` or a worker's `reset --hard origin/master` will wipe it.

---

## 1. LFS-tracked vendored binaries can wedge `clean_slate` (the worktree death-loop)

**Symptom.** A worker shows idle on the dashboard but never claims anything; its
per-worker log (`logs/continuous/<date>-wN.log`) repeats:

```
continuous: clean_slate FAILED at iter start — abort   (×3)
continuous: 3 consecutive failures — backing off 30 min
```

It loops forever: 3 failures → 30-min `fail_backoff` → wake → 3 more → back off.

**Root cause.** `clean_slate()` resets the worktree to `origin/master` before each
item. If a tracked file is perpetually "not uptodate" — e.g. a **Git-LFS-tracked
font** (`addons/gut/fonts/*.ttf`) whose smudge/clean round-trip doesn't match the
stored object — then a tree-switching `git checkout <other-commit>` **refuses**
with `error: Entry '…ttf' not uptodate. Cannot merge.`, and **`--force` does NOT
override that**. `git reset --hard <other-commit>` refuses for the same reason.
A worker parked on a stale branch can never switch off it → clean_slate fails
every iteration.

**Fixes (both in tree):**
- `clean_slate()` now detaches in place, then `reset --hard`, and if that still
  can't land it **rebuilds the worktree from scratch** (`_rebuild_worktree`:
  `git worktree remove --force` + `worktree add --detach origin/master`). A
  from-scratch checkout into a clean dir cannot be blocked by a dirty file, so a
  wedged worktree can no longer death-loop a worker.
- The deeper prevention: **don't LFS-track tiny vendored addon binaries.** The
  template `.gitattributes` excludes `addons/**` from LFS for exactly this reason.

**Manual recovery** (if a worktree is already wedged):
```bash
GAME=~/GameProjects/<game>; WT=~/SpraxelAiCompany/.worktrees/worker-N
git -C "$GAME" worktree remove --force "$WT"
git -C "$GAME" worktree add --detach "$WT" origin/master
```

---

## 2. "Idle (no item claimed)" — death-loop vs. legitimately-dry queue

Both look identical on the dashboard. Tell them apart by the worker's **sleep
duration** and **log line**:

| Sleep child | Meaning |
|---|---|
| `sleep 1800` | `fail_backoff` brake — something is *failing* (see §1). **Investigate.** |
| `sleep 300` / `sleep 30` | Healthy idle — `claim` returned no eligible items. Nothing wrong. |

```bash
w=$(pgrep -f "continuous_dev.sh --worker-id N"); pgrep -P "$w" | xargs ps -o command= -p
tail -3 logs/continuous/<date>-wN.log
```

A *legitimately dry* queue is normal: most `## Todo` items are CEO-gated
(`[manual]`, `[future]`, `[needs-ceo]`, `[idea]`, `[concern]`, `[epic]` parents,
epic subtasks blocked behind an earlier sibling). Only `[feature]`/`[game-feature]`/
`[bug]`/`[chore]`/`[test_failure]` are dev-claimable. When those run out, workers
idle until you accept ideas / triage bugs, or the Designer's dry-queue auto-run
refills the pipeline.

---

## 3. Orphaned `[wip:N]` claims

A worker killed mid-item (crash, manual kill, a botched restart) can leave an item
tagged `[wip:N]` with **no live worker on it** — it looks claimed, so no one else
grabs it, and the queue silently shrinks.

**Detect:** every `[wip:N]` should correspond to a worktree currently on the
matching feature branch.
```bash
grep -nE "\[wip:[0-9]\]" $GAME/WORK.md
git -C "$GAME" worktree list | grep worker     # branch per worker
```
If a `[wip:N]` item has no worker on its branch, it's an orphan.

**Reclaim** via the safe wrapper (handles lock + sync + commit + push — §4):
```bash
bash ~/SpraxelAiCompany/scripts/with_master_lock.sh unclaim "[feature] p2 <exact title prefix>"
```
`unclaim` matches by **prefix of the un-wipped title (incl. the `[tag] pN` prefix)**,
not substring. Because the item's feature branch is on origin and the claim path
uses **deterministic branch names**, a fresh re-claim resumes the saved work
rather than rebuilding. (At worker *startup* this is automatic via `release-wip`;
the manual path above is for when the worker is still running.)

---

## 4. Mutate the canonical `WORK.md` only via `with_master_lock.sh`

`workmd.py` is the only writer (FileLock-serialised), but a *bare*
`workmd.py <mutate>` is **unsafe**: it edits `game_dir/WORK.md` locally without
committing, and the next worker's `reset --hard origin/master` (run before every
claim/merge) silently eats it. Every operator mutation must be **lock → sync →
mutate → commit → push, all in ONE live process**. Don't hand-roll that — use
the wrapper:
```bash
bash ~/SpraxelAiCompany/scripts/with_master_lock.sh promote "Some idea title" --detail "amendment…"
bash ~/SpraxelAiCompany/scripts/with_master_lock.sh drop    "Some idea to reject"
bash ~/SpraxelAiCompany/scripts/with_master_lock.sh resume  "Escalated item to retry"
bash ~/SpraxelAiCompany/scripts/with_master_lock.sh unclaim "[feature] p2 <orphan title prefix>"
```
It acquires `master-push.lockdir`, syncs `game_dir` to `origin/master`, runs the
`workmd.py` subcommand (canonical path injected automatically), commits + pushes
WORK.md, and releases the lock on exit. `reject.sh` / `amend.sh` hold the same
lock internally, so they're safe too.

⚠️ **The lock only holds within a single live process.** `acquire_lock` stamps
the holder PID; when that process exits, the lock becomes reclaimable (by design
— a dead holder must never deadlock the pool). So you canNOT split
acquire → edit → commit across separate shell invocations: between them a worker
sees a stale (dead-holder) lock, correctly reclaims it, and its `reset --hard`
discards your uncommitted edit. One process, start to finish — which is exactly
what `with_master_lock.sh` guarantees.
