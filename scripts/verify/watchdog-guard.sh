#!/bin/zsh
# Checks scripts/verify/watchdog.sh, which decides whether CI's app tests pass: it runs a copy of
# the script in a scratch checkout with a stand-in test host, and checks each exit status and that
# nothing it started is left running.
set -uo pipefail

root=${0:A:h:h:h}
# The resolved path: the watchdog matches the host by the path its own location resolves to.
tmp=${$(mktemp -d):A}
trap 'kill $(jobs -p) 2>/dev/null; rm -rf $tmp' EXIT
mkdir -p $tmp/scripts/verify $tmp/build/DerivedData/Build/Products/Debug/Soroband.app/Contents/MacOS
cp $root/scripts/verify/watchdog.sh $tmp/scripts/verify/
watchdog=$tmp/scripts/verify/watchdog.sh
# A stand-in test host that waits until stopped; a compiled binary, as the watchdog finds the host
# by its executable's path.
host=$tmp/build/DerivedData/Build/Products/Debug/Soroband.app/Contents/MacOS/Soroband
print '#include <unistd.h>\nint main(void) { for (;;) pause(); }' | cc -x c -o $host -

fails=0
check() {  # check <name> <expected exit> <watchdog arguments…>
  local name=$1 expected=$2; shift 2
  local code=0
  zsh $watchdog "$@" >/dev/null 2>&1 || code=$?
  if (( code == expected )); then print "ok    $name"; else print "FAIL  $name (exit $code, expected $expected)"; fails=1; fi
}
gone() {  # gone <name>: nothing this run started is left (every command line names its scratch path)
  local left=(${(f)"$(pgrep -f $tmp)"})
  if (( $#left )); then print "FAIL  $1: left running"; fails=1; kill -KILL $left; else print "ok    $1"; fi
}

check "a passing command passes" 0 5 true
check "a failing command fails with its status" 1 5 false
check "a command past the limit stops with 124" 124 1 sleep 31
check "a limit that is not a number prints the usage" 2 x true

# A command that ignores the stop is killed after the grace.
check "a command that ignores the stop is killed" 124 1 zsh -c "trap '' TERM; while true; do sleep 1; done; : $tmp"
gone "nothing is left after a command that ignores the stop"

# The grace lasts until every stopped process has exited: the host quits at once on the stop,
# the command takes 3 s to clean up.
$host &
check "a command that cleans up within the grace stops with 124" 124 1 \
  zsh -c "trap 'sleep 3; touch $tmp/cleaned; exit 1' TERM; while true; do sleep 1; done"
if [[ -e $tmp/cleaned ]]; then print "ok    the command finishes its cleanup though the host quit first"
else print "FAIL  the command was killed before its cleanup, when the host quit"; fails=1; fi
gone "nothing is left of the stand-in host"

# A watchdog that is stopped stops its command.
zsh $watchdog 60 zsh -c "sleep 60; : $tmp" >/dev/null 2>&1 &
sleep 2
kill $!
wait $! 2>/dev/null
sleep 1
gone "a stopped watchdog leaves no command running"

exit $fails
