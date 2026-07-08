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

0a. **Select the target project** (the framework is multi-game now). Resolve WHICH
   project's intake you're draining before touching any files. Priority: an explicit
   project named in the CEO's message/args > the folder you're currently in > the last
   project used > the sole enabled project; if it's genuinely ambiguous, ask.
   ```bash
   # If the CEO named a project, pass it; otherwise let the resolver decide.
   SLUG=$(python3 ~/SpraxelAiCompany/scripts/spx_config.py current --game "<named>") \
     || SLUG=$(python3 ~/SpraxelAiCompany/scripts/spx_config.py current)
   ```
   - If `current` exits non-zero, it was **ambiguous** and printed the candidate slugs
     on stderr. **Ask the CEO which project**, then set `SLUG` to their answer.
   - Record last-used and resolve the project dir (every game path below builds from `$GAME`):
     ```bash
     python3 ~/SpraxelAiCompany/scripts/spx_config.py set-current "$SLUG"
     GAME=$(python3 ~/SpraxelAiCompany/scripts/spx_config.py game-dir "$SLUG")
     ```

0. **Signal the continuous loop** that the CEO is interacting:
   ```bash
   bash ~/SpraxelAiCompany/scripts/checkin.sh --game "$SLUG"
   ```
   This resets the ship-counter so the loop starts shipping the next batch
   of 10 once new items land from this dictation pass.

1. **Find the intake sources** (all under the resolved `$GAME`):
   - `$GAME/.factory/inbox/raw.md` — anything the CEO
     dumped today (typed or pasted from dictation).
   - `$GAME/.factory/inbox/dictation/*.md` — speech-to-text
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

   d2. **Critique gate.** Quietly evaluate the idea against four gates
       before appending. If any genuinely fires, add ONE indented detail
       line per concern, prefixed `⚠️ concern (<gate>):`. The item still
       gets appended as the CEO asked — concerns are advisory text, not
       a veto. Be sparing: most items pass without comment. Cap at 2
       concerns per item.

       Gates:
       - **cliché** — appears in 70%+ of games in the genre obviously?
         (regen health, double jump, sprint button)
       - **complexity** — would take 2+ weeks of focused dev? (network
         co-op, full localization, save-with-branching)
       - **balance** — would this trivialize the game's central tension?
         Cross-check `Philosophy.md`'s core fantasy.
       - **drift** — contradicts an existing feature in Game.md or a
         Philosophy.md design tenet?

       If you flag a concern, ALSO surface it to the CEO inline in your
       summary at step 6 ("Concerns raised on N items").

   e. **Tag `[untriaged]` (the shaping gate).** Every NEW feature-type item
      (`[game-feature]` / `[feature]` / `[chore]`) is born `[untriaged]` so the
      Architect shapes it into a concrete spec before developers build it.
      Prepend `[untriaged]` to the title. **Exceptions — do NOT add `[untriaged]`:**
      - `[bug]` items — bugs are concrete; they keep their normal flow.
      - `[manual] …` items — CEO hand-work, never built by the loop.

   f. **Append** to WORK.md ## Todo:
      ```
      # feature-type → carries [untriaged]:
      python3 ~/SpraxelAiCompany/scripts/workmd.py append \
        "$GAME/WORK.md" --section todo \
        "[untriaged] [kind] pN <title>" \
        --detail "<detail 1>" \
        --detail "⚠️ concern (balance): <one-line reason>"

      # bug or MANUAL → NO [untriaged]:
      python3 ~/SpraxelAiCompany/scripts/workmd.py append \
        "$GAME/WORK.md" --section todo \
        "[bug] pN <title>"
      ```

3. **For ambiguous items**, ask the CEO one tight question per item (not a
   gauntlet) — kind or priority — and use the answer. If the CEO says
   "skip" or "defer", leave the raw note in `raw.md` with a `[needs-ceo]`
   prefix line and move on.

4. **After processing**, move drained sources (all under `$GAME/.factory/inbox/`):
   - `$GAME/.factory/inbox/raw.md` → wipe to empty (preserve any `[needs-ceo]` lines).
   - Dictation files → `$GAME/.factory/inbox/dictation/processed/<ts>-<slug>.md`.

5. **Commit** WORK.md with the producer bot identity — UNDER THE MASTER-PUSH
   LOCK with a rebase, like every other WORK.md writer. A bare `commit` +
   `push` loses items two ways: a concurrent worker's push rejects yours
   (non-fast-forward, silently dropped), or a worker's `reset --hard
   origin/master` eats the uncommitted/unpushed edit — the exact incident the
   designer/triager specs document.
   ```bash
   . ~/SpraxelAiCompany/scripts/lockutils.sh
   LOCK=~/SpraxelAiCompany/state/$SLUG/locks/master-push.lockdir
   if acquire_lock "$LOCK" 60 0.3; then
     git -c user.email=producer-bot@spraxel.ai -c user.name='Spraxel Producer' \
       -C "$GAME" commit -am "producer: appended <N> items" \
     && git -C "$GAME" pull --rebase --quiet origin master \
     && git -C "$GAME" push --quiet origin master
     release_lock "$LOCK"
   fi
   ```
   (`$SLUG` = the game slug from the same `spx_config.py current` resolution
   used above.)

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
