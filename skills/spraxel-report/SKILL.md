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

1. **Run the report**:
   ```bash
   python3 ~/SpraxelAiCompany/scripts/spraxel_report.py
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
python3 ~/SpraxelAiCompany/scripts/spraxel_report.py | awk '/^## Right now/,/^## Last 24/'
python3 ~/SpraxelAiCompany/scripts/spraxel_report.py | awk '/^## Next 20/,/^$/'
```

But by default, full report.
