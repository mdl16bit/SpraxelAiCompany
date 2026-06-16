#!/usr/bin/env bash
# install_skills.sh — expose this repo's skills to Claude Code.
#
# Claude Code discovers skills under ~/.claude/skills/ (user skills) and
# .claude/skills/ (project skills) — NOT this repo's top-level skills/ directory.
# So each skill here must be symlinked into ~/.claude/skills/ to be invocable as a
# slash command. (This was done by hand per-skill, which is how spraxel-develop and
# spraxel-launch ended up missing — they were never linked. This script makes it
# reliable.)
#
# Idempotent: re-run any time you add or rename a skill. Symlinks (not copies) so
# edits to the repo skill are reflected immediately — a stale REAL-dir copy in
# ~/.claude/skills/ silently shadows your repo edits, so this replaces those too.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_DIR/skills"
DST="$HOME/.claude/skills"
mkdir -p "$DST"

linked=0
for d in "$SRC"/*/; do
  [ -f "${d}SKILL.md" ] || continue          # only dirs that are real skills
  name="$(basename "$d")"
  target="${d%/}"
  link="$DST/$name"
  if [ -L "$link" ]; then
    [ "$(readlink "$link")" = "$target" ] && { echo "  = $name (ok)"; continue; }
    rm -f "$link"                             # repoint a wrong symlink
  elif [ -e "$link" ]; then                   # stale real dir/file shadowing the repo
    bak="/tmp/spraxel-skill-stale-$name-$(date +%s)"
    mv "$link" "$bak"
    echo "  ~ $name (backed up stale copy → $bak)"
  fi
  ln -s "$target" "$link"
  echo "  + $name → $target"
  linked=$((linked + 1))
done

echo "done ($linked linked/updated). Restart Claude Code (or let it re-index) to pick up changes."
