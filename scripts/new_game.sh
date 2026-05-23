#!/usr/bin/env bash
# new_game.sh — apply the Spraxel framework template to a game repo.
#
# Usage:
#   scripts/new_game.sh <target-dir> [--name "Display Name"]
#
# Idempotent: refuses to clobber an existing .factory/ directory.
# Skips top-level files (Philosophy.md, Game.md, WORK.md) that already exist.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_DIR="$FRAMEWORK_DIR/template"

if [ $# -lt 1 ]; then
    echo "usage: $0 <target-dir> [--name \"Display Name\"]" >&2
    exit 1
fi

TARGET="$1"
shift
NAME=""
while [ $# -gt 0 ]; do
    case "$1" in
        --name) NAME="$2"; shift 2 ;;
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
for f in Philosophy.md Game.md WORK.md; do
    copy_if_missing "$TEMPLATE_DIR/$f" "$TARGET/$f"
done

# .factory/ structure
for d in memory inbox inbox/dictation inbox/decisions inbox/playtest artifacts; do
    mkdir -p "$TARGET/.factory/$d"
    [ -e "$TARGET/.factory/$d/.gitkeep" ] || touch "$TARGET/.factory/$d/.gitkeep"
done

# .github/ structure
mkdir -p "$TARGET/.github/workflows"
mkdir -p "$TARGET/.github/ISSUE_TEMPLATE"
[ -e "$TARGET/.github/workflows/.gitkeep" ] || touch "$TARGET/.github/workflows/.gitkeep"
for f in feature.md bug.md; do
    copy_if_missing "$TEMPLATE_DIR/.github/ISSUE_TEMPLATE/$f" "$TARGET/.github/ISSUE_TEMPLATE/$f"
done

# Name substitution in the just-copied top-level files
if [ -n "$NAME" ]; then
    python3 - "$NAME" "$TARGET" <<'PY'
import sys, pathlib
name = sys.argv[1]
target = pathlib.Path(sys.argv[2])
for fname in ("Philosophy.md", "Game.md", "WORK.md"):
    f = target / fname
    if not f.exists():
        continue
    text = f.read_text()
    new = text.replace("{{GAME_NAME}}", name)
    if new != text:
        f.write_text(new)
PY
fi

cat <<EOF

done. next steps:
  1. Edit $TARGET/Philosophy.md with the project pitch + constraints
  2. Edit $TARGET/Game.md with current features + controls
  3. Edit $TARGET/WORK.md with the roadmap (3 sections, 2 dashed lines)
  4. Seed GH Issues from WORK.md:
       python3 $FRAMEWORK_DIR/scripts/sync_work_md.py --repo-dir $TARGET --seed --apply
EOF
