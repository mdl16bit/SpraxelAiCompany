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
for f in Philosophy.md INSPIRATIONS.md GAME_CONFIG.yaml Game.md WORK.md .gitignore .gitattributes CLAUDE.md; do
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
paths = [target / fname for fname in ("Philosophy.md", "GAME_CONFIG.yaml", "Game.md", "WORK.md")]
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

cat <<EOF

done. next steps to wire this game into the multi-game Spraxel system
(the /spraxel-launch skill walks all of this interactively — preferred):

  1. Edit $TARGET/GAME_CONFIG.yaml
     - Fill in identity.pitch, identity.must_include, identity.must_not_include.
     - Set dev.godot_binary to the absolute path of your Godot binary.
     - (run_mode lives in ~/SpraxelAiCompany/COMPANY_CONFIG.yaml as policy.run_mode;
       a game may override any COMPANY_CONFIG key here — it deep-merges on top.)
     Then edit $TARGET/Philosophy.md — prose-only design narrative (no config).

  2. Edit $TARGET/Game.md — it is an INDEX; feature blocks live one-per-file
     in $TARGET/docs/features/<slug>.md (see the contract inside Game.md).

  3. Edit $TARGET/WORK.md with the roadmap (2026-07 layout: Up-and-coming work /
     Finished since last release / Next work / archive footer).
     Format spec: ~/SpraxelAiCompany/docs/WORK_MD_FORMAT.md

  4. REGISTER the game in the multi-game registry (games run CONCURRENTLY —
     you are adding, not replacing):
       \$EDITOR ~/SpraxelAiCompany/COMPANY_CONFIG.yaml
       # under games:, add:
       #   <slug>:
       #     dir: $TARGET
       #     enabled: true

  5. Install the daemon if this machine doesn't run it yet (idempotent):
       bash ~/SpraxelAiCompany/scripts/install_daemon.sh

  6. Install the GUT test framework into THIS repo (the templated test runner
     calls res://addons/gut — without it EVERY unit test errors):
       cd $TARGET && git clone --depth 1 https://github.com/bitwes/Gut /tmp/gut \
         && rm -rf addons/gut && mkdir -p addons && mv /tmp/gut/addons/gut addons/gut \
         && rm -rf /tmp/gut
       # (or install via Godot editor: AssetLib > "Gut"). Do NOT put addons/ in
       # Git LFS — .gitattributes excludes it on purpose (LFS-tracked GUT fonts
       # wedge worktree checkouts). See docs/WORKER_OPERATIONS.md §1.

  7. Verify the daemon sees it:
       launchctl list | grep com.spraxel
       python3 ~/SpraxelAiCompany/scripts/spx_config.py games

  8. (Optional) Generate a first MORNING.md:
       bash ~/SpraxelAiCompany/scripts/run_agent.sh morning-briefer --game <slug>

For a fully-autonomous jam launch: ~/SpraxelAiCompany/docs/JAM_RUNBOOK.md.
For day-to-day operation: ~/SpraxelAiCompany/OPERATIONS.md (Part II covers
zero-to-running; Part V covers adding games).
EOF
