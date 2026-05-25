#!/usr/bin/env bash
# run_unit_tests.sh — fast GUT unit test runner.
#
# Runs ONLY the GUT unit tests under test/unit/* — no acceptance scenarios,
# no class-cache refresh, no notifications. Use this when iterating on tests
# and you want a quick green/red signal.
#
# For the full pre-commit test gate (cache refresh + GUT + acceptance scenarios
# + status JSON + macOS notifications), use scripts/run_local_tests.sh.
#
# Usage:
#   ./scripts/run_unit_tests.sh                       # all tests
#   ./scripts/run_unit_tests.sh test_block_ability    # single file (matches prefix)
#   ./scripts/run_unit_tests.sh -gtest=res://test/unit/test_block_ability.gd:test_take_damage_frontal_blocked

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

GODOT=$(python3 -c "
import yaml, re
text = open('Philosophy.md').read()
fm = re.search(r'^---\n(.*?)\n---', text, re.DOTALL).group(1)
data = yaml.safe_load(fm)
print(data.get('dev', {}).get('godot_binary', ''))
")
if [ -z "$GODOT" ] || [ ! -x "$GODOT" ]; then
  echo "[unit-tests] ERROR: Godot binary not found at '$GODOT' (set dev.godot_binary in Philosophy.md)"
  exit 2
fi

GUT_ARGS=( -gdir=res://test/unit -ginclude_subdirs -gexit )

if [ $# -gt 0 ]; then
  arg="$1"
  if [[ "$arg" == -* ]]; then
    # Pass-through: caller supplied a -gtest=... / -gselect=... etc.
    GUT_ARGS=( "$@" -gexit )
  else
    # Convenience: bare prefix runs just that test file.
    GUT_ARGS=( "-gtest=res://test/unit/${arg%.gd}.gd" -gexit )
  fi
fi

"$GODOT" --headless --path . -s res://addons/gut/gut_cmdln.gd "${GUT_ARGS[@]}"
