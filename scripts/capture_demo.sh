#!/usr/bin/env bash
# capture_demo.sh — record a deterministic video of a Godot --demo-feature
# run using Godot's built-in Movie Maker (--write-movie).
#
# Captures the engine's framebuffer directly (not screen pixels), so:
#   - No Screen Recording permission needed
#   - No Accessibility / AppleScript permission needed
#   - No foreground-app contamination (anything else on your screen
#     is invisible to the recording — only Godot's render output ends
#     up in the .avi)
#   - Deterministic frame timing (--fixed-fps + --quit-after): exactly
#     `duration * fps` frames, independent of system load
#
# Still requires Mac to be awake + a visible Godot window: Movie Maker
# refuses to record without a real renderer (--headless segfaults). The
# window WILL pop up briefly during recording. There's no way around
# that with Godot 4.6.1 as far as we can tell.
#
# Pipeline:
#   1. Launch Godot windowed with --write-movie → produces raw .avi
#      (very large — ~20 MB/sec at 30fps, 1080p).
#   2. ffmpeg encodes .avi → H.264 .mp4 (compact, web-friendly).
#   3. ffmpeg extracts a still .png at the 3s mark.
#   4. Delete the raw .avi (no value once .mp4 + .png exist).
#
# Usage:
#   capture_demo.sh <slug> [--duration 10] [--fps 30] [--out PATH-NO-EXT]
#
# Output:
#   <out>.mp4   H.264 encoded video
#   <out>.png   Still extracted at 3s (or 1s if duration < 4)
#   <out>.log   Godot + ffmpeg stdout/stderr for debugging
#
# Exit codes:
#   0  — success (.mp4 + .png produced, frame count looks healthy)
#   1  — Godot couldn't open a window / Movie Maker failed
#   2  — bad args
#   3  — ffmpeg not on PATH (skipped — `brew install ffmpeg`)
#   4  — game_dir or godot binary unresolvable
#   5  — capture ran but recording is suspiciously short (scenario
#        likely a test-style script that auto-quits — falls through to
#        recipe.md for hand-recording)

set -o pipefail

if [ $# -lt 1 ]; then
  echo "usage: $0 <slug> [--duration SECS] [--fps FPS] [--out PATH-WITHOUT-EXT]" >&2
  exit 2
fi

SLUG="$1"; shift
DURATION=10
FPS=30
OUT_BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --duration) DURATION="$2"; shift 2 ;;
    --fps)      FPS="$2"; shift 2 ;;
    --out)      OUT_BASE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# ffmpeg gate. Without it, the raw .avi is a huge useless artifact.
# Cleaner to skip auto-capture entirely; the demo-creator agent's
# recipe.md fallback covers the day. Hint at install command.
if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "[capture] SKIPPED — ffmpeg not on PATH. Install: brew install ffmpeg" >&2
  exit 3
fi

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
[ -z "$GAME_DIR" ] && { echo "[capture] game_dir not resolvable from $SCHEDULE" >&2; exit 4; }

# Resolve the Godot binary via the config loader (dev.godot_binary now lives in
# GAME_CONFIG.yaml, deep-merged over COMPANY_CONFIG.yaml).
GODOT=$(python3 ~/SpraxelAiCompany/scripts/spx_config.py get dev.godot_binary 2>/dev/null)
[ -x "$GODOT" ] || { echo "[capture] Godot binary not found at '$GODOT'" >&2; exit 4; }

# Default output dir if not given.
if [ -z "$OUT_BASE" ]; then
  OUT_BASE="$GAME_DIR/.factory/demos/$(date +%Y-%m-%d)/$SLUG"
fi
mkdir -p "$(dirname "$OUT_BASE")"

# Pad quit-after by 2s so Godot finishes flushing the last frames.
QUIT_AFTER=$((DURATION + 2))
AVI="$OUT_BASE.avi"

echo "[capture] slug=$SLUG, duration=${DURATION}s @ ${FPS}fps, out=$OUT_BASE.{mp4,png}"
echo "[capture] launching Godot --write-movie ($QUIT_AFTER s engine time)..."

"$GODOT" --write-movie "$AVI" --fixed-fps "$FPS" --quit-after "$QUIT_AFTER" \
  --path "$GAME_DIR" -- --demo-feature="$SLUG" \
  > "$OUT_BASE.log" 2>&1
GODOT_RC=$?

if [ $GODOT_RC -ne 0 ]; then
  echo "[capture] Godot exited rc=$GODOT_RC — see $OUT_BASE.log" >&2
fi
if [ ! -f "$AVI" ]; then
  echo "[capture] FAILED — no .avi produced (Godot couldn't open a window?)" >&2
  exit 1
fi

echo "[capture] raw avi: $(du -h "$AVI" | cut -f1) — encoding..."

# Encode .avi → H.264 .mp4 (small, web-friendly). yuv420p is the most
# universal pixel format; -an strips audio (there's none in --write-movie).
ffmpeg -y -i "$AVI" -c:v libx264 -preset fast -crf 23 -pix_fmt yuv420p -an \
  "$OUT_BASE.mp4" >>"$OUT_BASE.log" 2>&1
ENC_RC=$?

# Extract still at 3s (or 1s if the duration is shorter than 4).
STILL_AT=3
[ "$DURATION" -lt 4 ] && STILL_AT=1
ffmpeg -y -i "$OUT_BASE.mp4" -ss "$STILL_AT" -frames:v 1 "$OUT_BASE.png" \
  >>"$OUT_BASE.log" 2>&1

if [ $ENC_RC -ne 0 ] || [ ! -f "$OUT_BASE.mp4" ]; then
  echo "[capture] FAILED — ffmpeg encode rc=$ENC_RC, see $OUT_BASE.log" >&2
  exit 1
fi

# Raw .avi is huge and now redundant — toss it.
rm -f "$AVI"

# Detect suspiciously short recordings — usually means the scenario script
# called get_tree().quit() shortly after _ready (typical for assertion-style
# scenarios that were authored as acceptance tests, not visual demos).
FRAME_COUNT=$(grep -oE '^[0-9]+ frames at' "$OUT_BASE.log" 2>/dev/null | grep -oE '^[0-9]+' | head -1)
FRAME_COUNT="${FRAME_COUNT:-0}"
MIN_USEFUL_FRAMES=$((DURATION * FPS / 3))   # at least 1/3 of expected frames
if [ "$FRAME_COUNT" -lt "$MIN_USEFUL_FRAMES" ]; then
  echo "[capture] ⚠️  WARN — only $FRAME_COUNT frames recorded (expected ~$((DURATION * FPS)))" >&2
  echo "[capture]    The scenario for '$SLUG' likely quits early (test-style script)." >&2
  echo "[capture]    The .mp4 is technically valid but visually empty. Hand-record" >&2
  echo "[capture]    via recipe.md for a usable clip." >&2
  echo "[capture] done — $(du -h "$OUT_BASE.mp4" | cut -f1) mp4 (${FRAME_COUNT} frames, ⚠️ very short)"
  exit 5   # special code: capture ran but output isn't useful
fi

echo "[capture] done — $(du -h "$OUT_BASE.mp4" | cut -f1) mp4, $(du -h "$OUT_BASE.png" 2>/dev/null | cut -f1 || echo '?') png (${FRAME_COUNT} frames)"
