#!/usr/bin/env bash
# notify.sh — macOS Notification Center ping for monitoring alerts.
#
# The pull-based files (MORNING.md, escalations.md, crew-health.txt) remain the
# canonical record; this is the push-based "look now" signal they were missing —
# the 2026-06-24→07-08 outage sat invisible for 2 weeks because every alert
# landed in a file the CEO had to open. Callers: run_agent.sh (fatal gate,
# compliance miss) and tick.sh (crew-health, daily caps, prolonged pause).
#
# Usage: notify.sh "<title>" "<message>"
# Disable with policy.notifications.enabled: false in COMPANY_CONFIG.yaml.
# ALWAYS exits 0 — alerting must never break the caller.

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

enabled=$(python3 "$REPO_DIR/scripts/spx_config.py" get policy.notifications.enabled 2>/dev/null)
case "$enabled" in
  false|False) exit 0 ;;
esac

title="${1:-Spraxel}"
msg="${2:-}"
# Escape backslashes then double quotes for the AppleScript string literal.
t=${title//\\/\\\\}; t=${t//\"/\\\"}
m=${msg//\\/\\\\};   m=${m//\"/\\\"}
osascript -e "display notification \"$m\" with title \"$t\" sound name \"Basso\"" >/dev/null 2>&1 || true
exit 0
