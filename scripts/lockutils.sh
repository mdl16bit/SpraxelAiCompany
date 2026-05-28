#!/usr/bin/env bash
# lockutils.sh — PID-aware lockdir primitives.
#
# Source this from bash scripts that need mutual exclusion via a lockdir.
# Every acquired lock writes the holder's PID into `<lockdir>/holder.pid`
# so any other process (waiter, janitor, tick.sh) can verify whether the
# holder is alive without guessing process names.
#
# History (2026-05-27): the system used plain `mkdir lockdir` + EXIT-trap
# rmdir. Two failure modes broke the 3-worker setup:
#   1. SIGKILL bypasses the EXIT trap → lockdir orphans, blocking every
#      future waiter for the 30-min stale-sweep window.
#   2. tick.sh tried to sweep stale lockdirs by pgrep'ing the name out of
#      the lockdir basename (`run_agent.sh <agent_name>`) but the name
#      didn't match the actual cmdline for worker-suffixed locks
#      (`developer-worker-1.lockdir` vs `run_agent.sh developer`). Also
#      `master-push.lockdir` never matches any process — it's a critical
#      section, not an agent. Result: tick.sh sometimes ripped held locks
#      out from under live git operations.
#
# This module replaces both: holder.pid is the source of truth; aliveness
# is checked via `kill -0 PID`.

# Acquire a PID-aware lock. Blocks until acquired or max_wait_seconds
# expires. Sets an EXIT trap on the calling shell to release the lock
# automatically.
#
# Usage:  acquire_lock <lockdir_path> [max_wait_seconds=300] [poll_interval=1]
# Return: 0 on success, 1 on timeout, 2 on argv error
#
# Self-heals: if the existing lockdir's holder.pid names a dead process,
# the orphan is swept and retry happens immediately (no sleep).
acquire_lock() {
  local lock="$1"
  local max_wait="${2:-300}"
  local poll="${3:-1}"
  if [ -z "$lock" ]; then
    echo "acquire_lock: missing lockdir argument" >&2
    return 2
  fi
  local pid_file="$lock/holder.pid"
  local wait_start
  wait_start=$(date +%s)
  while true; do
    if mkdir "$lock" 2>/dev/null; then
      # Stamp the PID of the actual shell that called us. BASHPID is
      # the current subshell's real PID — using $$ would always report
      # the top-level script PID, even when acquire_lock is called from
      # inside a subshell `(...)`. If a subshell dies abnormally while
      # holding the lock, $$ would still be alive (the parent), so
      # tick.sh and the next waiter would (incorrectly) believe the
      # lock is held. BASHPID correctly tracks the subshell, so death
      # is detected.
      echo "${BASHPID:-$$}" > "$pid_file"
      return 0
    fi
    # mkdir failed — someone has the lock. Is the holder alive?
    local holder_pid
    holder_pid=$(cat "$pid_file" 2>/dev/null)
    if [ -n "$holder_pid" ] && [ "$holder_pid" -gt 0 ] 2>/dev/null; then
      if ! kill -0 "$holder_pid" 2>/dev/null; then
        # Dead holder — sweep and retry immediately.
        rm -f "$pid_file" 2>/dev/null
        rmdir "$lock" 2>/dev/null
        continue
      fi
    elif [ -d "$lock" ]; then
      # No PID file but lockdir exists. Could be a microsecond race
      # (holder won mkdir, hasn't yet written PID) — typically resolves
      # within the next poll. But if the lockdir is OLD with no PID
      # file, the holder got SIGKILL'd in that microsecond window —
      # sweep as orphan.
      local lock_age
      lock_age=$(( $(date +%s) - $(stat -f%m "$lock" 2>/dev/null || echo 0) ))
      if [ "$lock_age" -gt 30 ]; then
        rmdir "$lock" 2>/dev/null
        continue
      fi
    fi
    sleep "$poll"
    if [ "$(( $(date +%s) - wait_start ))" -gt "$max_wait" ]; then
      return 1
    fi
  done
}

# Release a PID-aware lock. Removes holder.pid first (so rmdir on the
# now-empty lockdir succeeds). Safe to call when the lock isn't held —
# it's a no-op in that case.
release_lock() {
  local lock="$1"
  [ -z "$lock" ] && return 2
  rm -f "$lock/holder.pid" 2>/dev/null
  rmdir "$lock" 2>/dev/null
  return 0
}

# Returns 0 if the lock's named holder is alive, 1 if dead or no holder,
# 2 if the lockdir doesn't exist at all. Used by tick.sh's stale-sweep.
lock_holder_alive() {
  local lock="$1"
  [ -d "$lock" ] || return 2
  local pid_file="$lock/holder.pid"
  local holder_pid
  holder_pid=$(cat "$pid_file" 2>/dev/null)
  if [ -z "$holder_pid" ] || ! [ "$holder_pid" -gt 0 ] 2>/dev/null; then
    return 1
  fi
  if kill -0 "$holder_pid" 2>/dev/null; then
    return 0
  fi
  return 1
}

# Recursively kill a process and ALL its descendants, leaves first.
#
# The dev-watchdog and wrapper-cleanup paths used `pkill -KILL -P $pid`,
# which only reaches DIRECT children. The dev process tree is deep:
#   run_agent.sh → claude → zsh -c (tool shell) → run_local_tests.sh → godot
# Killing only run_agent's direct child (claude) orphaned the zsh / test
# script / godot — they kept running, held the test lock, and piled up
# (observed: 6+ orphan run_local_tests.sh after a few hours, one stuck
# holding the lock for 18 min while ALIVE — invisible to the dead-PID
# self-heal). kill_tree walks the whole tree so nothing survives.
kill_tree() {
  local pid="$1"
  local sig="${2:-KILL}"
  local child
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    kill_tree "$child" "$sig"
  done
  kill -"$sig" "$pid" 2>/dev/null
}
