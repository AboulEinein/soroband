#!/bin/zsh
# Checks that scripts/install.sh never replaces an installed Soroband without being asked: it runs
# a copy of the script pointed at a fake installed app and a missing build, so nothing is built or
# installed, and checks where each run stops.
set -euo pipefail

root=${0:A:h:h:h}
tmp=$(mktemp -d)
trap 'rm -rf $tmp' EXIT
mkdir -p $tmp/scripts $tmp/Soroband.app
sed -e "s|^app=/Applications/Soroband.app\$|app=$tmp/Soroband.app|" -e "s|^root=.*|root=$tmp/missing|" \
  -e "s|^lock=.*|lock=$tmp/install.lock|" \
  $root/scripts/install.sh > $tmp/scripts/install.sh
grep -qxF "app=$tmp/Soroband.app" $tmp/scripts/install.sh || { print -u2 "install-guard.sh: install.sh no longer sets app="; exit 1; }

fails=0
check() {  # check <name> <answer typed in a terminal, or "" for none> <expected output> <arguments…>
  local name=$1 answer=$2 expected=$3; shift 3
  local out code=0
  if [[ -n $answer ]]; then
    # The answer waits for the prompt: `script` passes on the end of its input as soon as it reads it.
    out=$( { sleep 2; print $answer; sleep 1; } | script -q /dev/null zsh $tmp/scripts/install.sh "$@" 2>&1) || code=$?
  else
    out=$(zsh $tmp/scripts/install.sh "$@" </dev/null 2>&1) || code=$?
  fi
  if (( code != 0 )) && [[ $out == *$expected* && -d $tmp/Soroband.app ]]; then
    print "ok    $name"
  else
    print "FAIL  $name (exit $code): $out"
    fails=1
  fi
}

check "no terminal: stops before building" "" "already installed"
check "terminal, n: stops before building" n "nothing was changed"
check "terminal, y: goes on to the build" y "missing/scripts/build.sh"
check "--replace: goes on to the build" "" "missing/scripts/build.sh" --replace
check "unknown option: prints the usage" "" "usage: scripts/install.sh" --bogus

# A second run while one holds the lock stops before anything else.
zmodload zsh/system
: >> $tmp/install.lock
zsystem flock -f held $tmp/install.lock
check "another install running: stops" "" "another scripts/install.sh is running" --replace
zsystem flock -u $held
exit $fails
