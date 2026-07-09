#!/usr/bin/env bash
# publish_itch.sh — export the game headlessly and push builds to itch.io.
#
#   publish_itch.sh [--game <slug>] [--version vX.Y] [--dry-run]
#
# Reads per-game config (GAME_CONFIG.yaml → loader):
#   publish.itch_target    e.g. "spraxel/infiltrators"  (REQUIRED to push)
#   publish.itch_presets   comma list of export presets → channel names
#                          (default "macos-playtest,windows-playtest";
#                           channel = text before the first "-", so
#                           macos-playtest → channel "macos")
#
# The first push auto-creates the itch project as a HIDDEN DRAFT — set its
# visibility (Restricted + password for the private playtest channel) once in
# the itch dashboard. One-time CEO auth: `butler login`.
#
# Called by the PM's release-cut step (spraxel-pm.md) with --version v0.N;
# safe to run by hand anytime. Exit codes: 0 ok; 2 config/tooling missing;
# 1 export or push failed.
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPX="$REPO_DIR/scripts/spx_config.py"

game_arg="" version="" dry=""
while [ $# -gt 0 ]; do
  case "$1" in
    --game)    game_arg="${2:-}"; shift 2 ;;
    --version) version="${2:-}"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    *) echo "publish_itch: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

if [ -n "$game_arg" ]; then . "$REPO_DIR/scripts/gctx.sh" --game "$game_arg"; else . "$REPO_DIR/scripts/gctx.sh"; fi

BUTLER=$(command -v butler || echo "$HOME/bin/butler")
[ -x "$BUTLER" ] || { echo "publish_itch: butler not installed (see OPERATIONS.md → itch channel)"; exit 2; }
GODOT=$(python3 "$SPX" get dev.godot_binary --game "$GAME_SLUG" 2>/dev/null)
[ -x "$GODOT" ] || { echo "publish_itch: godot binary not found ($GODOT)"; exit 2; }
TARGET=$(python3 "$SPX" get publish.itch_target --game "$GAME_SLUG" 2>/dev/null)
[ -n "$TARGET" ] || { echo "publish_itch: publish.itch_target not set in GAME_CONFIG.yaml — skipping (not an error for unpublished games)"; exit 0; }
PRESETS=$(python3 "$SPX" get publish.itch_presets --default "macos-playtest,windows-playtest" --game "$GAME_SLUG" 2>/dev/null)
[ -f "$GAME_DIR/export_presets.cfg" ] || { echo "publish_itch: no export_presets.cfg in $GAME_DIR"; exit 2; }

# Not logged in? Fail with the exact fix (skipped on --dry-run, which never pushes).
if [ -z "$dry" ] && ! "$BUTLER" whoami >/dev/null 2>&1 </dev/null; then
  echo "publish_itch: butler is not logged in — CEO one-time step: run \`butler login\`" >&2
  exit 2
fi

[ -n "$version" ] || version="manual-$(date +%Y%m%d-%H%M)"
cd "$GAME_DIR" || exit 2
rc=0
IFS=',' read -ra plist <<< "$PRESETS"
for preset in "${plist[@]}"; do
  preset=$(echo "$preset" | xargs)
  channel="${preset%%-*}"
  case "$preset" in
    windows*) out="build/windows/$GAME_SLUG.exe"; push_path="build/windows" ;;
    *)        out="build/$GAME_SLUG-$channel.zip"; push_path="$out" ;;
  esac
  mkdir -p "$(dirname "$out")"
  echo "publish_itch: exporting '$preset' → $out"
  if ! "$GODOT" --headless --path . --export-release "$preset" "$out" >/tmp/publish-export-$channel.log 2>&1; then
    echo "publish_itch: EXPORT FAILED for $preset (see /tmp/publish-export-$channel.log)" >&2
    rc=1; continue
  fi
  [ -s "$out" ] || { echo "publish_itch: export produced no file for $preset" >&2; rc=1; continue; }
  if [ -n "$dry" ]; then
    echo "publish_itch: [dry-run] would push $push_path → $TARGET:$channel --userversion $version"
    continue
  fi
  echo "publish_itch: pushing → $TARGET:$channel ($version)"
  if ! "$BUTLER" push "$push_path" "$TARGET:$channel" --userversion "$version" >/tmp/publish-push-$channel.log 2>&1; then
    echo "publish_itch: PUSH FAILED for $channel (see /tmp/publish-push-$channel.log)" >&2
    rc=1
  fi
done

if [ "$rc" -eq 0 ] && [ -z "$dry" ]; then
  echo "publish_itch: ✅ $TARGET updated ($version) — https://$( echo "$TARGET" | cut -d/ -f1 ).itch.io/$(echo "$TARGET" | cut -d/ -f2)"
  printf '%s\n' "- Pushed $version builds to itch ($TARGET: ${PRESETS})" \
    | bash "$REPO_DIR/scripts/report.sh" pm --game "$GAME_SLUG" >/dev/null 2>&1 || true
fi
exit "$rc"
