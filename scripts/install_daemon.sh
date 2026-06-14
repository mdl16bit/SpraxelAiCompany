#!/usr/bin/env bash
# install_daemon.sh — install the always-on Spraxel tick daemon.
#
# Drops ~/Library/LaunchAgents/com.spraxel.tick.plist which fires tick.sh
# every 60s. tick.sh reads schedule.yaml and dispatches due agents.
#
# Usage:
#   ./scripts/install_daemon.sh         # install + start
#   ./scripts/install_daemon.sh stop    # stop + uninstall
#   ./scripts/install_daemon.sh status  # show launchctl state + recent ticks
#   ./scripts/install_daemon.sh restart # uninstall then install
#
# Also runs install_local_tests.sh if local-tests daemon isn't already loaded.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TICK_SCRIPT="$REPO_DIR/scripts/tick.sh"
PLIST_PATH="$HOME/Library/LaunchAgents/com.spraxel.tick.plist"
LABEL="com.spraxel.tick"
INTERVAL=$(python3 "$REPO_DIR/scripts/spx_config.py" get tick.interval_secs 2>/dev/null); INTERVAL=${INTERVAL:-60}   # seconds — tick cadence (tick.interval_secs)

action="${1:-install}"

ensure_executable() {
  chmod +x "$REPO_DIR/scripts/tick.sh" \
           "$REPO_DIR/scripts/run_agent.sh" \
           "$REPO_DIR/scripts/cron_match.py" 2>/dev/null || true
  # overnight_dev.sh might not exist yet (Phase 4)
  [ -f "$REPO_DIR/scripts/overnight_dev.sh" ] && chmod +x "$REPO_DIR/scripts/overnight_dev.sh"
}

write_plist() {
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
    <string>$TICK_SCRIPT</string>
  </array>
  <key>StartInterval</key>
  <integer>$INTERVAL</integer>
  <key>RunAtLoad</key>
  <true/>
  <!-- CRITICAL: tick.sh exits every 60s after spawning the long-lived
       continuous_dev workers as nohup'd background children. Without this,
       launchd kills tick.sh's entire process group on exit — taking the
       just-spawned workers with it (they die in <1s, before acquiring a
       lock or writing a trace). The workers only survived when tick ran
       from an interactive shell. This was the root cause of the recurring
       "launchd ticks but nothing ships" failure (diagnosed 2026-05-28). -->
  <key>AbandonProcessGroup</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/spraxel-tick.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/spraxel-tick.err.log</string>
  <key>WorkingDirectory</key>
  <string>$REPO_DIR</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOME</key>
    <string>$HOME</string>
    <!-- USER and LOGNAME are required for claude CLI to reach the macOS
         keychain. Without them claude silently exits with "Not logged in"
         and produces a 0-byte agent log. -->
    <key>USER</key>
    <string>$USER</string>
    <key>LOGNAME</key>
    <string>$USER</string>
  </dict>
</dict>
</plist>
EOF
}

case "$action" in
  install)
    ensure_executable
    write_plist
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    launchctl load "$PLIST_PATH"
    echo "Installed: $PLIST_PATH"
    echo "Tick every ${INTERVAL}s. First tick: ~now (RunAtLoad=true)."
    echo "Logs:"
    echo "  $REPO_DIR/logs/tick/<YYYY-MM-DD>.log      — per-tick summary"
    echo "  /tmp/spraxel-tick.out.log                  — stdout"
    echo "  /tmp/spraxel-tick.err.log                  — stderr"
    echo
    echo "Pause:   touch $REPO_DIR/.paused"
    echo "Resume:  rm    $REPO_DIR/.paused"
    echo
    echo "Verify:"
    echo "  launchctl list | grep $LABEL"
    echo "  tail -f $REPO_DIR/logs/tick/\$(date +%Y-%m-%d).log"
    echo
    # Also install local tests if they aren't there.
    if ! launchctl list 2>/dev/null | grep -q com.spraxel.localtests; then
      echo "Local-tests daemon not running."
      template_install="$REPO_DIR/template/scripts/install_local_tests.sh"
      if [ -x "$template_install" ]; then
        echo "Run this in the game repo to enable 30-min local tests:"
        echo "  cd ~/GameProjects/infiltrators && bash scripts/install_local_tests.sh"
      fi
    fi
    ;;
  stop|uninstall)
    if [ -f "$PLIST_PATH" ]; then
      launchctl unload "$PLIST_PATH" 2>/dev/null || true
      rm -f "$PLIST_PATH"
      echo "Uninstalled: $PLIST_PATH"
    else
      echo "Not installed."
    fi
    ;;
  restart)
    "$0" stop
    "$0" install
    ;;
  status)
    if launchctl list 2>/dev/null | grep -q "$LABEL"; then
      echo "Running:"
      launchctl list | grep "$LABEL"
    else
      echo "Not running."
    fi
    today_log="$REPO_DIR/logs/tick/$(date +%Y-%m-%d).log"
    if [ -f "$today_log" ]; then
      echo
      echo "Last 5 ticks ($today_log):"
      tail -5 "$today_log"
    fi
    if [ -e "$REPO_DIR/.paused" ]; then
      echo
      echo "⏸  PAUSED — rm $REPO_DIR/.paused to resume"
    fi
    ;;
  *)
    echo "usage: $0 [install|stop|status|restart]"
    exit 1
    ;;
esac
