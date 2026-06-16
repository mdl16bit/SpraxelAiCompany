---
name: spraxel-report
description: Immediate status snapshot — what's running RIGHT NOW, what happened in the last 24 hours and last 7 days, and the next 20 scheduled events (with dates and times in Pacific). Use when the user types /spraxel-report or /report or asks "what's going on", "system status", "what's running right now", "what's scheduled", "what shipped recently".
---

# Spraxel — Status report

When the user invokes this skill, run the local report script and pass
its output back verbatim. The script is pure-local + read-only — it
gathers from `schedule.yaml`, `Philosophy.md`, `.cache/`, `git log`, and
tick logs. No Claude tokens needed for the data gathering itself.

## What to do

0. **Select the target project** (the framework is multi-game now). Resolve WHICH
   game this report is for before running anything. Priority: an explicit project
   named in the CEO's message/args > the folder you're currently in > the last
   project used > the sole enabled project; if it's genuinely ambiguous, ask.
   ```bash
   # If the CEO named a project, pass it; otherwise let the resolver decide.
   SLUG=$(python3 ~/SpraxelAiCompany/scripts/spx_config.py current --game "<named>") \
     || SLUG=$(python3 ~/SpraxelAiCompany/scripts/spx_config.py current)
   ```
   - If `current` exits non-zero, it was **ambiguous** and printed the candidate
     slugs on stderr. **Ask the CEO which project**, then set `SLUG` to their answer.
   - Record it as last-used and resolve the project dir (not needed for the report
     itself, but keeps the selection sticky for the next skill):
     ```bash
     python3 ~/SpraxelAiCompany/scripts/spx_config.py set-current "$SLUG"
     GAME=$(python3 ~/SpraxelAiCompany/scripts/spx_config.py game-dir "$SLUG")
     ```

1. **Run the report** for that project (`--game "$SLUG"`):
   ```bash
   python3 ~/SpraxelAiCompany/scripts/spraxel_report.py --game "$SLUG"
   ```

2. **Print the output verbatim**. The script already produces markdown.
   Don't reformat, don't summarize — the CEO wants the facts.

3. **Optionally add a one-line interpretation at the bottom** ONLY if
   something is clearly off:
   - Cap counter at 10/10 and not paused → "loop is sleeping until next CEO signal"
   - Wrapper down but `.paused` missing → "wrapper should be running but isn't — try `bash ~/SpraxelAiCompany/scripts/tick.sh` to kick it"
   - Last-24h ships = 0 and not paused → "system hasn't shipped today — check escalations or item queue"
   - In flight + cap at 9 → "next ship likely fills the batch"

   Stop at one line. If everything looks normal, say nothing extra.

## Sections in the report

- **Right now** — time, paused?, tick daemon loaded?, wrapper alive?,
  in-flight dev session, cap counter, most recent item attempted.
- **Last 24 hours** — ships, escalations, CEO commits, crew agents fired
  (timestamped), top 5 recent feature titles.
- **Last 7 days** — totals, releases cut, top 10 features.
- **Next 20 scheduled events** — sorted ascending, grouped by date,
  with the cron'd time in PT.

## When NOT to run this

- The user is asking about a specific item (e.g. "what happened to
  feature X") — use `git log` / `grep WORK.md` instead.
- The user wants to start work — they want `/spraxel-inbox` (morning
  routine), not a status dump.
- They asked "are we paused?" specifically — just `ls ~/SpraxelAiCompany/.paused`
  and answer.

## Quick variations

If the user asks for "just right now" or "just the schedule", you can
filter the script's output (it's markdown sections):

```bash
python3 ~/SpraxelAiCompany/scripts/spraxel_report.py --game "$SLUG" | awk '/^## Right now/,/^## Last 24/'
python3 ~/SpraxelAiCompany/scripts/spraxel_report.py --game "$SLUG" | awk '/^## Next 20/,/^$/'
```

But by default, full report.
