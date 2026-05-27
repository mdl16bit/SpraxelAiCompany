---
identity:
  name: "{{GAME_NAME}}"
  pitch: "TODO — one-sentence elevator pitch"
  must_include:
    - "TODO"
  must_not_include:
    - "TODO"

cadence:
  release: "biweekly mondays"
  pm: "daily 06:00; release sweep on release day"
  concierge: "daily 05:00"
  janitor: "sunday 02:00"           # phase 2
  playtester: "on PR open; nightly 02:00"   # phase 2
  designer: "daily 04:00"           # phase 3
  blogger: "saturday 10:00"         # phase 3
  demo_creator: "wed+sat 03:00"     # phase 3

budgets:
  monthly_usd_hard_cap: 250
  by_agent_percent:
    producer: 30
    developer: 35
    pm: 5
    reviewer: 3
    concierge: 3
    playtester: 10                  # phase 2
    janitor: 2                      # phase 2
    designer: 10                    # phase 3
    blogger: 3                      # phase 3
    demo_creator: 2                 # phase 3
  model_assignments:
    producer: sonnet
    developer: sonnet
    pm: sonnet
    reviewer: haiku
    concierge: haiku
    playtester: sonnet              # phase 2
    triager: haiku                  # phase 2
    janitor: haiku                  # phase 2
    designer: sonnet                # phase 3
    blogger: sonnet                 # phase 3

ceo:
  do_not_disturb: ["00:00-07:30"]
  approval_required_for:
    - "bulk issue creation (>5)"
    - "release cut"
    - "playtester-found bugs (validate real-vs-not before issue creation)"
    - "designer ideas (accept/reject/amend per idea)"
  default_to_yes_after_hours: 24
  headless_mode_default: false

blog:
  voice: "TODO — casual dev-log, first-person, ~1000 words"
  template: "blog/templates/devlog.md"
  publish_target: "github-pages-hugo"

dev:
  language: "TODO"
  engine: "TODO"
  velocity_issues_per_release: 6   # max parallel issues in flight; 6 is the validated sweet spot (1 stuck PR doesn't starve the queue). CEO dials up/down per pace tolerance.
  style_guide: ".factory/style.md"
  branching: "trunk-based; feature branches off main; PR for everything"
  required_for_done:
    - "tests pass"
    - "new test added covering the change"
    - "debug hook --demo-feature=<slug> works"
    - "Game.md updated for new/changed features"
    - "Reviewer pass green"

# Per-agent CEO-tunable thresholds. All optional with defaults shown; the
# agents read these at runtime and fall back to defaults if absent.

# Janitor (weekly maintenance) thresholds.
janitor:
  # Untouched Todo items get [cold] retag after this many days. Higher
  # = items linger longer in the active queue. Lower = aggressive archive
  # (less queue noise, but more "wait I wanted that" moments).
  cold_threshold_days:    30
  # Delete agent log files older than this many days. Higher = more
  # disk used; lower = harder to debug yesterday's issue.
  log_retention_days:     60

# Morning briefer (daily MORNING.md author) preferences.
morning_briefer:
  # How many features to surface for play-test in the ▶ Play-test section.
  # Higher = more thorough, longer routine. Lower = faster mornings.
  playtest_count:         10

# Dashboard display preferences (read by scripts/dashboard.py).
dashboard:
  # How many most-recent shipped commits to show in "Last N shipped".
  recent_ships:           20
  # How many items in "Next N CEO action items" (urgency-ordered).
  ceo_actions:            10

run_mode: "live"   # "dryrun" = log what each agent would do, spend no tokens
---

# Project philosophy

TODO: one-paragraph elevator pitch. What is the game, what is the tone,
what is the signature mechanic.

TODO: what we are NOT making. List 3-5 things explicitly. These become
the `must_not_include` enforcement that Producer + Designer respect.
