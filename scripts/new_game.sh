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
for f in Philosophy.md Game.md WORK.md; do
    copy_if_missing "$TEMPLATE_DIR/$f" "$TARGET/$f"
done

# .factory/ structure
for d in memory inbox inbox/dictation inbox/decisions inbox/playtest artifacts; do
    mkdir -p "$TARGET/.factory/$d"
    [ -e "$TARGET/.factory/$d/.gitkeep" ] || touch "$TARGET/.factory/$d/.gitkeep"
done

# Local test runner — installable launchd job (every 30 min while Mac awake).
mkdir -p "$TARGET/scripts"
copy_if_missing "$TEMPLATE_DIR/scripts/install_local_tests.sh" "$TARGET/scripts/install_local_tests.sh"
copy_if_missing "$TEMPLATE_DIR/scripts/run_local_tests.sh" "$TARGET/scripts/run_local_tests.sh"
chmod +x "$TARGET/scripts/install_local_tests.sh" "$TARGET/scripts/run_local_tests.sh" 2>/dev/null || true

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

done. next steps:
  1. Edit $TARGET/Philosophy.md with the project pitch + constraints
  2. Edit $TARGET/Game.md with current features + controls
  3. Edit $TARGET/WORK.md with the roadmap (3 sections, 2 dashed lines)
  4. Seed GH Issues from WORK.md:
       python3 $FRAMEWORK_DIR/scripts/sync_work_md.py --repo-dir $TARGET --seed --apply

  5. Set up GitHub Actions secret CLAUDE_CODE_OAUTH_TOKEN:
       gh secret set CLAUDE_CODE_OAUTH_TOKEN --repo <owner>/<repo>
     (Use 'claude /login' to obtain a token if needed.)

  6. Open the "Factory Daily Log" pinned issue (#5 ideally):
       gh issue create --title "Factory Daily Log" --body "Pinned daily ops log." --repo <owner>/<repo>
       gh issue pin <issue-number>

  7. Set up the Anthropic /schedule CCR routine to drive keepalive
     reliably (GH cron is throttled for active repos):

       In a Claude Code session, run:  /schedule
       Choose: create
       Name: <Game> Keepalive trigger (hourly)
       Cron: 17 * * * *   (hourly at :17 past)
       Model: claude-haiku-4-5-20251001
       Repo source: github.com/<owner>/<repo>
       Prompt: copy from docs/ccr-keepalive-routine.md

     This routine posts a "KEEPALIVE-TICK" comment on the Factory Daily Log
     issue every hour, which fires keepalive.yml via issue_comment event.
     Bypasses GH cron's "fairness throttling" for noisy repos.
EOF
