#!/bin/zsh
# Renders the spike's windows to docs/mockups/*.png.
set -euo pipefail
cd "${0:A:h}"
swift build -c debug
out=../../docs/mockups
mkdir -p $out
list=$(mktemp)
SOROBAND_SNAPSHOT=$list .build/debug/Soroband &
pid=$!
trap 'kill $pid 2>/dev/null || true; rm -f $list' EXIT
until [[ -s $list ]]; do
  kill -0 $pid 2>/dev/null || { echo "Soroband exited before writing its window list" >&2; exit 1; }
  perl -e 'select(undef,undef,undef,0.3)'
done
perl -e 'select(undef,undef,undef,2)'
while read -r name id || [[ -n $name ]]; do screencapture -x -o -l $id $out/$name.png; done < $list
