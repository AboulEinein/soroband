#!/bin/zsh
# Runs a command and, if it is still running after a time limit, prints the stacks of this
# checkout's test host and of xctest with `sample`, then stops the command and exits 124. CI runs
# the app tests under it, so a hung test run ends with the stacks that name what blocks it.
#
# Usage: scripts/verify/watchdog.sh <seconds> <command> [argument...]
set -uo pipefail
cd "${0:A:h}/../.."

if (( $# < 2 )) || [[ $1 != <-> ]]; then
  print -u2 "usage: scripts/verify/watchdog.sh <seconds> <command> [argument...]"
  exit 2
fi
limit=$1
shift

# Swift concurrency runs one thread per CPU; a test that blocks them all hangs the run.
print "watchdog: ${limit} s limit, $(sysctl -n hw.ncpu) CPUs"
"$@" &
command_pid=$!
start=$SECONDS
while kill -0 $command_pid 2>/dev/null; do
  if (( SECONDS - start >= limit )); then
    print "watchdog: still running after ${limit} s; sampling the test processes"
    # The Debug test host is this checkout's Soroband.app; another checkout's builds are left alone.
    hosts=(${(f)"$(pgrep -f "^$PWD/build/DerivedData/.*/Soroband\.app/Contents/MacOS/Soroband( |$)")"})
    runners=(${(f)"$(pgrep -x xctest)"})
    for pid in $hosts $runners; do
      print "== sample of $pid: $(ps -o command= -p $pid)"
      sample $pid 5 -file /dev/stdout 2>&1
    done
    kill $command_pid $hosts 2>/dev/null
    # A process that ignores the stop is killed after 10 s, so the watchdog always returns.
    for _ in {1..10}; do
      kill -0 $command_pid $hosts 2>/dev/null || break
      sleep 1
    done
    kill -KILL $command_pid $hosts 2>/dev/null
    wait $command_pid
    exit 124
  fi
  sleep 1
done
wait $command_pid
