#!/usr/bin/env bash
# report.sh — append a dated agent activity report.
#
# Every agent calls this ONCE at the end of its run with a short markdown
# summary of what it did + anything the CEO should know ("the news"). The
# Morning Briefer reads all reports written since the last briefing and
# distills them into MORNING.md's "News since your last briefing" section.
#
# Usage:   <body on stdin> | report.sh <agent-name>
#   e.g.   printf '...' | bash ~/SpraxelAiCompany/scripts/report.sh architect
#
# Writes <game>/.factory/local/reports/<YYYY-MM-DD-HHMMSS>-<agent>.md
# (.factory/local/ is gitignored — CEO-local, never committed; the Janitor
# prunes old report files). Reports go to the CANONICAL game repo path (resolved
# from schedule.yaml), NOT the caller's cwd — crew agents run in worktrees whose
# .factory/local/ is separate, so a cwd-relative write wouldn't be seen by the
# Briefer (which reads the main checkout).
set -uo pipefail

agent="${1:-}"
if [ -z "$agent" ]; then
  echo "report.sh: usage: <body on stdin> | report.sh <agent-name>" >&2
  exit 2
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEDULE="$REPO_DIR/schedule.yaml"
game=$(python3 - "$SCHEDULE" <<'PY'
import sys, os, re
m = re.search(r"game_dir:\s*(\S+)", open(sys.argv[1]).read())
print(os.path.expanduser(m.group(1)) if m else "")
PY
)
if [ -z "$game" ] || [ ! -d "$game" ]; then
  echo "report.sh: could not resolve game_dir from $SCHEDULE" >&2
  exit 1
fi

dir="$game/.factory/local/reports"
mkdir -p "$dir"
f="$dir/$(date '+%Y-%m-%d-%H%M%S')-${agent}.md"
{
  echo "# ${agent} · $(date '+%Y-%m-%d %H:%M %Z')"
  echo
  cat
} > "$f"
echo "report: wrote $f"
