#!/usr/bin/env bash
# new_game.sh — apply the Spraxel framework template to a game repo.
#
# Usage:
#   scripts/new_game.sh <target-dir> [--name "Display Name"] [--ceo <github-login>]
#
# Idempotent: refuses to clobber an existing .factory/ directory.
# Skips top-level files (Philosophy.md, Game.md, WORK.md) that already exist.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_DIR="$FRAMEWORK_DIR/template"

if [ $# -lt 1 ]; then
    echo "usage: $0 <target-dir> [--name \"Display Name\"] [--ceo <github-login>]" >&2
    exit 1
fi

TARGET="$1"
shift
NAME=""
CEO=""
while [ $# -gt 0 ]; do
    case "$1" in
        --name) NAME="$2"; shift 2 ;;
        --ceo) CEO="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [ ! -d "$TARGET" ]; then
    echo "error: target dir does not exist: $TARGET" >&2
    exit 1
fi

if [ -d "$TARGET/.factory" ]; then
    echo "error: $TARGET already has a .factory/ directory; refusing to overwrite" >&2
    exit 2
fi

if [ -z "$NAME" ]; then
    NAME="$(basename "$TARGET")"
fi

echo "applying framework to: $TARGET"
echo "  game name: $NAME"

copy_if_missing() {
    local src="$1"
    local dst="$2"
    if [ -e "$dst" ]; then
        echo "  SKIP $dst (already exists)"
    else
        mkdir -p "$(dirname "$dst")"
        cp "$src" "$dst"
        echo "  +    $dst"
    fi
}

# Top-level stub files (skipped if they already exist)
for f in Philosophy.md Game.md WORK.md .gitignore; do
    copy_if_missing "$TEMPLATE_DIR/$f" "$TARGET/$f"
done

# .factory/ structure
for d in memory inbox inbox/dictation inbox/decisions inbox/playtest artifacts; do
    mkdir -p "$TARGET/.factory/$d"
    [ -e "$TARGET/.factory/$d/.gitkeep" ] || touch "$TARGET/.factory/$d/.gitkeep"
done

# Test + scenario scaffolding (Developer agent expects these to exist).
for d in test/unit scripts/scenarios; do
    mkdir -p "$TARGET/$d"
    [ -e "$TARGET/$d/.gitkeep" ] || touch "$TARGET/$d/.gitkeep"
done

# Local test runner + unit test runner — installable launchd job (every 30 min
# while Mac awake) plus a fast on-demand GUT runner.
mkdir -p "$TARGET/scripts"
copy_if_missing "$TEMPLATE_DIR/scripts/install_local_tests.sh" "$TARGET/scripts/install_local_tests.sh"
copy_if_missing "$TEMPLATE_DIR/scripts/run_local_tests.sh"   "$TARGET/scripts/run_local_tests.sh"
copy_if_missing "$TEMPLATE_DIR/scripts/run_unit_tests.sh"    "$TARGET/scripts/run_unit_tests.sh"
chmod +x "$TARGET/scripts/install_local_tests.sh" \
         "$TARGET/scripts/run_local_tests.sh" \
         "$TARGET/scripts/run_unit_tests.sh" 2>/dev/null || true

# Placeholder substitution: {{GAME_NAME}}, {{CEO_LOGIN}}.
python3 - "$NAME" "${CEO:-}" "$TARGET" <<'PY'
import sys, pathlib
name, ceo, target_str = sys.argv[1], sys.argv[2], sys.argv[3]
target = pathlib.Path(target_str)
paths = [target / fname for fname in ("Philosophy.md", "Game.md", "WORK.md")]
substitutions = {}
if name: substitutions["{{GAME_NAME}}"] = name
if ceo:  substitutions["{{CEO_LOGIN}}"] = ceo
for f in paths:
    if not f.exists(): continue
    text = f.read_text()
    orig = text
    for k, v in substitutions.items():
        text = text.replace(k, v)
    if text != orig:
        f.write_text(text)
        print(f"  templated {f.relative_to(target)}")
PY

# Note: this game becomes the active game for the Spraxel daemon only if you
# update ~/SpraxelAiCompany/schedule.yaml `game_dir:` to point here.
echo ""
echo "ℹ️  To make this game the active target for the Spraxel daemon, edit:"
echo "      ~/SpraxelAiCompany/schedule.yaml"
echo "    and set: game_dir: $TARGET"
echo "    (only one game can be the active target at a time.)"

cat <<EOF

done. next steps to wire this game into the offline Spraxel system:

  1. Edit $TARGET/Philosophy.md
     - Fill in the project pitch, must_include, must_not_include lists.
     - Set dev.godot_binary to the absolute path of your Godot binary.
     - Confirm run_mode is "live" (set to "dryrun" to pause all agents).

  2. Edit $TARGET/Game.md with current features + controls.

  3. Edit $TARGET/WORK.md with the roadmap (3 sections, 2 dashed lines).
     Format spec: ~/SpraxelAiCompany/docs/WORK_MD_FORMAT.md

  4. Point the Spraxel daemon at this game:
       \$EDITOR ~/SpraxelAiCompany/schedule.yaml
       # change: game_dir: $TARGET

  5. Install the daemon (idempotent — safe to re-run):
       bash ~/SpraxelAiCompany/scripts/install_daemon.sh

  6. Install the local-tests cron in THIS repo:
       cd $TARGET && bash scripts/install_local_tests.sh

  7. Verify both are loaded:
       launchctl list | grep com.spraxel

  8. (Optional) Open MORNING.md by running the morning-briefer once:
       bash ~/SpraxelAiCompany/scripts/run_agent.sh morning-briefer

For day-to-day operation, see ~/SpraxelAiCompany/OPERATIONS.md.
EOF
