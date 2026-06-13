#!/usr/bin/env bash
# check_file_sizes.sh — "no god files" gate.
#
# Blocks a diff that GROWS a code file past max_file_lines (configurable via
# schedule.yaml: continuous.max_file_lines). New files over the cap also fail.
# SHRINKING an already-oversized file is always allowed — so an in-progress
# refactor of an existing god file never trips the gate, but adding more code
# to one does. This forces new functionality into new, focused modules.
#
# Usage: check_file_sizes.sh <repo_dir> <branch> [<base=master>] [<cap=1500>]
# Prints one line per violation to stdout and exits 1; exits 0 when clean.
set -uo pipefail
repo="${1:?repo_dir required}"; branch="${2:?branch required}"
base="${3:-master}"; cap="${4:-}"
# Cap defaults to continuous.max_file_lines in schedule.yaml (fallback 1500).
if [ -z "$cap" ]; then
  _sched="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/schedule.yaml"
  cap=$(grep -E '^[[:space:]]+max_file_lines:' "$_sched" 2>/dev/null | head -1 | grep -oE '[0-9]+' | head -1)
  cap="${cap:-1500}"
fi
cd "$repo" 2>/dev/null || { echo "check_file_sizes: cannot cd $repo" >&2; exit 0; }

# Only enforce on hand-authored code; skip generated/vendored/data trees.
code_re='\.(gd|gdshader|py|sh)$'
skip_re='(^|/)(addons|\.godot|\.git)/'

violations=()
while IFS= read -r f; do
  [ -z "$f" ] && continue
  echo "$f" | grep -qE "$code_re" || continue
  echo "$f" | grep -qE "$skip_re" && continue
  [ -f "$f" ] || continue                                   # deleted — fine
  new=$(wc -l < "$f" 2>/dev/null | tr -d ' '); new=${new:-0}
  [ "$new" -le "$cap" ] && continue                         # under cap — fine
  old=$(git show "$base:$f" 2>/dev/null | wc -l | tr -d ' '); old=${old:-0}
  if [ "$new" -gt "$old" ]; then                            # grew past cap (new file: old=0)
    violations+=("$f: $new lines (cap $cap; was $old) — split into smaller modules")
  fi
done < <(git diff --name-only "$base...$branch" 2>/dev/null)

if [ "${#violations[@]}" -gt 0 ]; then
  printf '%s\n' "${violations[@]}"
  exit 1
fi
exit 0
