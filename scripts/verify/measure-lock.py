#!/usr/bin/env python3
"""Runs a command while holding this Mac's measurement lock, so that only one CPU, memory,
traffic or timing measurement runs at a time across worktrees and agents.

Usage: scripts/verify/measure-lock.py <label> <command> [args...]
  label: who holds the lock, shown to anyone waiting for it

The lock is a flock(2) on ~/Library/Caches/soroband-measure.lock, held by this process and
not inherited by the command. INT, TERM and HUP go on to the command, and the lock is
released when the command exits, so a killed holder leaves no stale lock. Exits with the
command's status. Waits up to 2 hours (exit 75).
"""
import fcntl
import os
import signal
import subprocess
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
child = subprocess.Popen(command)
for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(sig, lambda signum, _: child.send_signal(signum))
returncode = child.wait()
sys.exit(128 - returncode if returncode < 0 else returncode)
