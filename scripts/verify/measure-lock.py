#!/usr/bin/env python3
"""Runs a command while holding this Mac's measurement lock, so that only one CPU, memory,
traffic or timing measurement runs at a time across worktrees and agents.

Usage: scripts/verify/measure-lock.py <label> <command> [args...]
  label: who holds the lock, shown to anyone waiting for it

The lock is a flock(2) on ~/Library/Caches/soroband-measure.lock. This process takes it,
then execs the command, so the command itself holds it until it exits, however it exits,
and a killed holder leaves no stale lock. Waits up to 2 hours (exit 75).
"""
import fcntl
import os
import sys
import time

LOCK = os.path.expanduser("~/Library/Caches/soroband-measure.lock")
WAIT_SECONDS = 2 * 60 * 60

if len(sys.argv) < 3:
    sys.exit(__doc__)
label, command = sys.argv[1], sys.argv[2:]

fd = os.open(LOCK, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
deadline = time.monotonic() + WAIT_SECONDS
waiting = False
while True:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        break
    except BlockingIOError:
        if not waiting:
            with open(LOCK) as owner:
                print(f"measure-lock: waiting for {owner.read().strip()}", file=sys.stderr)
            waiting = True
        if time.monotonic() > deadline:
            print("measure-lock: timed out", file=sys.stderr)
            sys.exit(75)
        time.sleep(10)

os.ftruncate(fd, 0)
os.write(fd, f"{label} pid {os.getpid()} since {time.strftime('%H:%M:%S')}\n".encode())
os.set_inheritable(fd, True)
os.execvp(command[0], command)
