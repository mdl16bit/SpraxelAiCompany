---
name: spraxel-inbox
description: CEO morning routine — open MORNING.md (written at 06:00 PT by the Morning Briefer), walk the time-boxed sections (play-test → decide → bug triage → escalations → dictation). Use when the user types /spraxel-inbox or /inbox or says "check my inbox", "morning digest", "what needs my attention".
---

# Spraxel — Morning routine

This skill walks the CEO through `MORNING.md` at the active game repo. It's
**read-mostly** — you'll edit WORK.md inline when promoting Designer ideas
or making quick triage decisions, but most of the work is play-testing the
features that shipped overnight and deciding what's next.

## What to do

0. **Signal the continuous loop** that the CEO is interacting:
   ```bash
   bash ~/SpraxelAiCompany/scripts/checkin.sh
   ```
   This resets the ship-counter to 0, so the loop starts shipping the next
   batch of 10 as soon as the CEO finishes the routine.

1. **Open** `~/GameProjects/<game>/MORNING.md` (default game: infiltrators).
   If it doesn't exist, the Morning Briefer hasn't run yet — check
   `~/SpraxelAiCompany/logs/morning-briefer/<latest>.log`.

2. **Walk the sections in order**:

   - **Overnight result**: glance at the commit range. If any feature looks
     surprising, `git show <sha>` to see the diff.

   - **▶ Play-test (20 min)**: for each of the 10 features, run the
     listed `godot --demo-feature=<slug>` command. Verify the
     "Look for" line. Mark mentally as ✓ or ✗ — fixes for ✗ become
     items the CEO can dictate at the end.

   - **▶ Decide (5 min)**: open WORK.md. For each Designer idea
     (lines tagged `[idea]`): **delete the line** to reject, or **remove
     just the `[idea]` tag** to promote. PM's reorder summary is
     informational — usually no action needed.

   - **▶ Bugs (5 min)**: look at Triager's new `[bug]` items. Bump priority
     of anything urgent (`p1` → `p0` by editing the line). Delete duplicates
     of bugs you've already fixed.

   - **▶ Escalations (3 min)**: read `.factory/escalations.md`. For each
     entry: either resurrect the item (paste back into WORK.md ## Todo
     with clarifying details that address the Developer's blocker) or
     leave it dead (don't do anything — the item stays out of rotation).

3. **▶ Dictation (5 min, optional)**: if you have new ideas from
   play-testing, drop them as bare prose into
   `~/GameProjects/<game>/.factory/inbox/raw.md` and run `/spraxel-producer`
   to convert them to clean WORK.md items.

## Time box

The whole routine is ~38 min. **If you're over 45 min, stop**. The
overnight loop runs every night — there's no need to perfect anything in
one sitting. Half-done is fine; the rest will be in tomorrow's digest.

## What NOT to do

- **Don't edit `.factory/escalations.md`** — it's append-only history.
- **Don't manually move items between WORK.md sections** — the overnight
  loop and Janitor handle that. Editing the file structurally is fine
  (CEO can do anything), but appending/deleting in `## Todo` is the
  normal workflow.
- **Don't touch GitHub Issues** — there aren't any in this workflow.

## Quick commands

| What | Command |
|---|---|
| Open MORNING.md | `cat ~/GameProjects/infiltrators/MORNING.md` |
| Launch a feature | `cd ~/GameProjects/infiltrators && godot --demo-feature=<slug>` |
| See last overnight log | `ls -t ~/SpraxelAiCompany/logs/overnight/ \| head -1` |
| See last morning-briefer log | `ls -t ~/SpraxelAiCompany/logs/morning-briefer/ \| head -1` |
| Drain dictation now | `/spraxel-producer` (interactive in Claude Code) |
| Pause the system | `touch ~/SpraxelAiCompany/.paused` |
| Resume | `rm ~/SpraxelAiCompany/.paused` |
| Daemon status | `bash ~/SpraxelAiCompany/scripts/install_daemon.sh status` |
