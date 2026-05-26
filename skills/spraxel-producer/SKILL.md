---
name: spraxel-producer
description: Producer — convert CEO dictation, prose dumps, and raw intake notes into clean WORK.md ## Todo entries with `[kind] pN` tags and indented details. Use when the user wants to "process my notes", "taskify what I said", "drain the intake", or types /spraxel-producer or /producer.
---

# Spraxel — Producer (intake → WORK.md)

The Producer's job is to convert messy human-language notes into clean,
shippable WORK.md items. Interactive entry point for the CEO: just type
`/spraxel-producer` (or `/producer`).

## What you (Claude) should do

When the user invokes this skill:

0. **Signal the continuous loop** that the CEO is interacting:
   ```bash
   bash ~/SpraxelAiCompany/scripts/checkin.sh
   ```
   This resets the ship-counter so the loop starts shipping the next batch
   of 10 once new items land from this dictation pass.

1. **Find the intake sources**:
   - `~/GameProjects/<game>/.factory/inbox/raw.md` — anything the CEO
     dumped today (typed or pasted from dictation).
   - `~/GameProjects/<game>/.factory/inbox/dictation/*.md` — speech-to-text
     files dropped from a phone, Voice Memos export, etc.
   - Plus whatever the user typed in the current Claude Code conversation.

2. **For each distinct idea** in the intake:

   a. **Classify** the kind:
      - **`[game-feature]`** — player-facing mechanic (new ability, new
        enemy behavior, new UI element the player sees).
      - **`[feature]`** — system/tooling/UX (debug HUD, level editor improvement, build pipeline).
      - **`[bug]`** — repro of broken behavior.
      - **`[chore]`** — refactor, doc update, dependency bump.

   b. **Infer priority** from urgency cues:
      - "broken / crashes / blocks the game / can't ship without" → **p0**
      - "annoying / wrong / players will complain" → **p1**
      - "would be cool / nice to have / improve later" → **p2** (default)
      - "future direction / someday" → **p3**

   c. **Compose** a clean title:
      - Imperative voice ("Add X", "Fix Y", "Make Z behave like…").
      - Under ~80 chars when possible.
      - Strip filler ("could you maybe add", "I think we should…").

   d. **Compose 1-4 indented detail lines** that capture the why/how/specs
      the CEO mentioned. Don't invent details that weren't said.

   e. **Append** to WORK.md ## Todo:
      ```
      python3 ~/SpraxelAiCompany/scripts/workmd.py append \
        ~/GameProjects/<game>/WORK.md --section todo \
        "[kind] pN <title>" \
        --detail "<detail 1>" \
        --detail "<detail 2>"
      ```

3. **For ambiguous items**, ask the CEO one tight question per item (not a
   gauntlet) — kind or priority — and use the answer. If the CEO says
   "skip" or "defer", leave the raw note in `raw.md` with a `[needs-ceo]`
   prefix line and move on.

4. **After processing**, move drained sources:
   - `raw.md` → wipe to empty (preserve any `[needs-ceo]` lines).
   - Dictation files → `dictation/processed/<ts>-<slug>.md`.

5. **Commit** WORK.md with the producer bot identity:
   ```bash
   git -c user.email=producer-bot@spraxel.ai -c user.name='Spraxel Producer' \
     -C ~/GameProjects/<game> commit -am "producer: appended <N> items"
   git -C ~/GameProjects/<game> push
   ```

6. **Print a summary**: "Producer: appended N items, deferred M items.
   Top 3 just appended: …"

## What NOT to do

- **Don't create GitHub Issues**. No issue tracker in this workflow.
- **Don't summarize multiple distinct ideas into one item**. If the CEO
  said "do X, also fix Y, oh and add Z", that's three items.
- **Don't invent details**. If the CEO didn't mention priority, leave
  the priority off (defaults to p2).
- **Don't reorganize existing WORK.md items**. Append only.

## Bot identity

git commits use: `producer-bot@spraxel.ai` / `Spraxel Producer`.
