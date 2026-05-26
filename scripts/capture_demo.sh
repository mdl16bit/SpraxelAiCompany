#!/usr/bin/env bash
# capture_demo.sh — record a short video + still of a Godot --demo-feature run.
#
# macOS-only. Uses screencapture to record the screen region around the
# Godot window. The window must be visible (Mac awake, screen unlocked).
#
# Usage:
#   capture_demo.sh <slug> [--duration 10] [--out .factory/demos/<date>/<slug>]
#
# Output:
#   <out>.mov   — H.264 video, --duration seconds
#   <out>.png   — still grabbed 3s into the run
#   <out>.log   — Godot stdout for debugging

set -o pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <slug> [--duration SECS] [--out PATH-WITHOUT-EXT]" >&2
  exit 2
fi

SLUG="$1"; shift
DURATION=10
OUT_BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --duration) DURATION="$2"; shift 2 ;;
    --out)      OUT_BASE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Resolve game_dir from the framework's schedule.yaml.
SCHEDULE=~/SpraxelAiCompany/schedule.yaml
GAME_DIR=$(python3 - "$SCHEDULE" <<'PY'
import sys, os, re
with open(sys.argv[1]) as f:
    for line in f:
        m = re.match(r"\s*game_dir:\s*(\S+)", line)
        if m:
            print(os.path.expanduser(m.group(1))); break
PY
)
[ -z "$GAME_DIR" ] && { echo "game_dir not resolvable from $SCHEDULE" >&2; exit 1; }

GODOT=$(python3 -c "
import yaml, re
text = open('$GAME_DIR/Philosophy.md').read()
fm = re.search(r'^---\n(.*?)\n---', text, re.DOTALL).group(1)
data = yaml.safe_load(fm)
print(data.get('dev', {}).get('godot_binary', ''))
")
[ -x "$GODOT" ] || { echo "Godot binary not found at '$GODOT'" >&2; exit 1; }

# Default output dir if not given.
if [ -z "$OUT_BASE" ]; then
  OUT_BASE="$GAME_DIR/.factory/demos/$(date +%Y-%m-%d)/$SLUG"
fi
mkdir -p "$(dirname "$OUT_BASE")"

echo "[capture] slug=$SLUG, duration=${DURATION}s, out=$OUT_BASE"

# Launch Godot windowed.
"$GODOT" --path "$GAME_DIR" -- --demo-feature="$SLUG" --quit-after=$((DURATION + 5)) \
  > "$OUT_BASE.log" 2>&1 &
GODOT_PID=$!
echo "[capture] godot PID $GODOT_PID — waiting 1.5s for window..."
sleep 1.5

# Detect the Godot window's bounds via AppleScript.  Godot's process name is
# "Godot" on macOS by default.  Returns "x,y,w,h" or empty if not found.
BOUNDS=$(osascript <<'APPLESCRIPT' 2>/dev/null
tell application "System Events"
  set godotProc to first process whose name contains "Godot"
  set w to first window of godotProc
  set p to position of w
  set s to size of w
  return (item 1 of p as text) & "," & (item 2 of p as text) & "," & (item 1 of s as text) & "," & (item 2 of s as text)
end tell
APPLESCRIPT
)

if [ -z "$BOUNDS" ]; then
  echo "[capture] ERROR: couldn't find Godot window. Capturing full screen instead." >&2
  REGION=""   # screencapture without -R captures whole screen
else
  REGION="-R${BOUNDS}"
  echo "[capture] window bounds: $BOUNDS"
fi

# Take a still 3s in (background; doesn't block).
(
  sleep 3
  screencapture -t png $REGION "$OUT_BASE.png" 2>/dev/null
  echo "[capture] still saved: $OUT_BASE.png"
) &

# Record video for $DURATION seconds.
# screencapture -V records H.264 video. Output is .mov.
echo "[capture] recording ${DURATION}s..."
screencapture -V "$DURATION" $REGION "$OUT_BASE.mov" 2>/dev/null

# Cleanup: kill Godot if still running.
if kill -0 $GODOT_PID 2>/dev/null; then
  kill -TERM $GODOT_PID 2>/dev/null
  sleep 1
  kill -KILL $GODOT_PID 2>/dev/null
fi

echo "[capture] done — $OUT_BASE.mov + $OUT_BASE.png"

# Quick sanity check.
[ -f "$OUT_BASE.mov" ] && echo "  video: $(ls -lh "$OUT_BASE.mov" | awk '{print $5}')" || echo "  video: MISSING"
[ -f "$OUT_BASE.png" ] && echo "  still: $(ls -lh "$OUT_BASE.png" | awk '{print $5}')" || echo "  still: MISSING"
