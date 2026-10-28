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
  $root/scripts/install.sh > $tmp/scripts/install.sh
grep -qxF "app=$tmp/Soroband.app" $tmp/scripts/install.sh || { print -u2 "install-guard.sh: install.sh no longer sets app="; exit 1; }

fails=0
check() {  # check <name> <expected output> <arguments…>
  local name=$1 expected=$2; shift 2
  local out code=0
  out=$(zsh $tmp/scripts/install.sh "$@" </dev/null 2>&1) || code=$?
  if (( code != 0 )) && [[ $out == *$expected* && -d $tmp/Soroband.app ]]; then
    print "ok    $name"
  else
    print "FAIL  $name (exit $code): $out"
    fails=1
  fi
}

check "no terminal: stops before building" "already installed" 
check "--replace: goes on to the build" "missing/scripts/build.sh" --replace
check "unknown option: prints the usage" "usage: scripts/install.sh" --bogus
exit $fails
