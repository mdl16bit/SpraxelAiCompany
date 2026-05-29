#!/usr/bin/env bash
# Mark overnight play-test features as DONE for today, so they drop off the
# dashboard's "CEO action items" and the /spraxel-inbox board.
#
# Tracker: <game>/.factory/local/playtested.json  — CEO-local, gitignored,
# keyed by today's date. It auto-resets each day: yesterday's checkmarks do
# NOT carry over, so a fresh overnight batch always shows up clean.
#
# Usage:
#   playtested.sh <substr>   mark play-test feature(s) whose title OR slug
#                            matches <substr> (case-insensitive) as tested
#   playtested.sh all        mark every current play-test feature tested
#   playtested.sh '*'        same as 'all' (QUOTE the * so the shell doesn't
#                            expand it to filenames; bare * won't work)
#   playtested.sh --list     show what's tested vs still pending today
#   playtested.sh --reset    clear today's tested list (start the day over)
set -euo pipefail

SPRAXEL="$HOME/SpraxelAiCompany"
SC="$SPRAXEL/schedule.yaml"
GAME=$(python3 -c "import re,os;m=re.search(r'game_dir:\s*(\S+)',open(os.path.expanduser('$SC')).read());print(os.path.expanduser(m.group(1)))")

if [ $# -lt 1 ]; then
  echo "usage: playtested.sh <substr> | all | '*' | --list | --reset" >&2
  exit 2
fi

GAME_DIR="$GAME" SPRAXEL_SCRIPTS="$SPRAXEL/scripts" python3 - "$@" <<'PY'
import os, sys, json
from datetime import datetime
sys.path.insert(0, os.environ["SPRAXEL_SCRIPTS"])
import dashboard as D
from pathlib import Path

game = Path(os.environ["GAME_DIR"])
arg = sys.argv[1]
today = datetime.now(D.TZ).strftime("%Y-%m-%d")
tracker = game / D.PLAYTESTED_FILE

# Current raw play-test list (what the dashboard/inbox would show).
texts = D.playtest_texts(game, limit=50)
pairs = [(D._playtest_key(t), t) for t in texts]

def load_today():
    if tracker.exists():
        try:
            d = json.loads(tracker.read_text())
            if d.get("date") == today:
                return set(d.get("slugs", []))
        except Exception:
            pass
    return set()

def save(slugs):
    tracker.parent.mkdir(parents=True, exist_ok=True)
    tracker.write_text(json.dumps({"date": today, "slugs": sorted(slugs)}, indent=2))

if arg == "--reset":
    save(set())
    print(f"Reset — 0 features marked tested for {today}.")
    sys.exit(0)

tested = load_today()

if arg == "--list":
    print(f"Play-test status for {today}:")
    if not pairs:
        print("  (no play-test features today — nothing to verify)")
    for key, t in pairs:
        mark = "✓ tested" if key in tested else "· pending"
        print(f"  [{mark}] {t}   ({key})")
    sys.exit(0)

# Mark mode: 'all'/'*' or a substring match against title OR slug-key.
if arg in ("all", "*"):
    matched = [(k, t) for k, t in pairs]
else:
    q = arg.lower()
    matched = [(k, t) for k, t in pairs if q in t.lower() or q in k.lower()]

if not matched:
    print(f"No play-test feature matches '{arg}'. Run --list to see them.", file=sys.stderr)
    sys.exit(1)

for k, _ in matched:
    tested.add(k)
save(tested)

print(f"Marked {len(matched)} feature(s) tested for {today}:")
for _, t in matched:
    print(f"  ✓ {t}")
remaining = [t for k, t in pairs if k not in tested]
print(f"{len(remaining)} play-test item(s) still pending. (--list to review, --reset to undo)")
PY
