#!/bin/zsh
# Renders the spike's windows to docs/mockups/*.png.
set -euo pipefail
cd "${0:A:h}"
swift build -c debug
out=../../docs/mockups
list=$(mktemp)
SOROBAND_SNAPSHOT=$list .build/debug/Soroband &
pid=$!
until [[ -s $list ]]; do perl -e 'select(undef,undef,undef,0.3)'; done
perl -e 'select(undef,undef,undef,2)'
while read -r name id || [[ -n $name ]]; do screencapture -x -o -l $id $out/$name.png; done < $list
kill $pid
rm $list
