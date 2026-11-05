#!/bin/zsh
# Runs a command while holding this Mac's measurement lock, so that only one CPU, memory or
# traffic measurement runs at a time across worktrees and agents. Waits up to 2 hours for the lock.
#
# Usage: scripts/verify/measure-lock.sh <label> <command> [args...]
#   label: who holds the lock, shown to anyone waiting for it
lock=/tmp/soroband-measure.lock
label=$1; shift
for i in {1..720}; do
  if mkdir $lock 2>/dev/null; then
    print -r -- "$label pid $$ since $(date +%H:%M:%S)" > $lock/owner
    trap 'rm -rf $lock' EXIT INT TERM
    "$@"; exit $?
  fi
  (( i == 1 )) && print -u2 "measure-lock: waiting for $(cat $lock/owner 2>/dev/null)"
  sleep 10
done
print -u2 "measure-lock: timed out"; exit 75
