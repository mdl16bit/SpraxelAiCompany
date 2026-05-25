#!/usr/bin/env bash
# install_local_tests.sh — install/uninstall the local-tests launchd cron.
#
# Installs ~/Library/LaunchAgents/com.spraxel.localtests.plist firing
# run_local_tests.sh every 30 minutes while your Mac is awake. Wakes the
# Mac if it's been asleep more than 30 min and you're plugged in.
#
# Usage:
#   ./scripts/install_local_tests.sh        # install + start
#   ./scripts/install_local_tests.sh stop   # stop + uninstall
#   ./scripts/install_local_tests.sh status # show launchctl state
#
# Idempotent: re-running install is safe.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_DIR/scripts/run_local_tests.sh"
PLIST_PATH="$HOME/Library/LaunchAgents/com.spraxel.localtests.plist"
LABEL="com.spraxel.localtests"
INTERVAL=1800   # seconds = 30 min

action="${1:-install}"

case "$action" in
  install)
    if [ ! -x "$SCRIPT" ]; then
      echo "ERROR: $SCRIPT not found or not executable"
      exit 1
    fi
    mkdir -p "$(dirname "$PLIST_PATH")"
    cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$SCRIPT</string>
  </array>
  <key>StartInterval</key>
  <integer>$INTERVAL</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/spraxel-localtests.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/spraxel-localtests.err.log</string>
  <key>WorkingDirectory</key>
  <string>$REPO_DIR</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
</dict>
</plist>
EOF
    # Reload if already loaded
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    launchctl load "$PLIST_PATH"
    echo "Installed: $PLIST_PATH"
    echo "Will run every $((INTERVAL / 60)) minutes (next: ~immediately, RunAtLoad=true)"
    echo "Logs: /tmp/spraxel-localtests.out.log and /tmp/spraxel-localtests.err.log"
    echo
    echo "Verify:"
    echo "  launchctl list | grep $LABEL"
    echo "  tail -f /tmp/spraxel-localtests.out.log"
    ;;
  stop|uninstall)
    if [ -f "$PLIST_PATH" ]; then
      launchctl unload "$PLIST_PATH" 2>/dev/null || true
      rm -f "$PLIST_PATH"
      echo "Uninstalled."
    else
      echo "Not installed."
    fi
    ;;
  status)
    if launchctl list | grep -q "$LABEL"; then
      echo "Running:"
      launchctl list | grep "$LABEL"
      echo
      echo "Last status:"
      [ -f "$REPO_DIR/.factory/local-tests-status.json" ] && cat "$REPO_DIR/.factory/local-tests-status.json" || echo "  (no status file yet)"
    else
      echo "Not running."
    fi
    ;;
  *)
    echo "usage: $0 [install|stop|status]"
    exit 1
    ;;
esac
