#!/bin/zsh
# Checks that each island moment fires from real events. With the Debug app running
# (scripts/verify/run-app.sh), it turns the island on with low thresholds, then:
#   1. switches to a simulated Wi-Fi network, then to a simulated hotspot: network joined, network
#      left, and the hotspot meter;
#   2. downloads 30 MB with curl, which is never the frontmost app, with the data hog set out of
#      reach: background activity and a large transfer, which ends;
#   3. downloads 30 MB again with the data hog at 15 MB in a minute: the data hog;
#   4. rests the pointer on the notch (`hover-island`, the island's own hit test): peek.
# Each moment must appear in `soroband debug state`'s island.recent from the engine (or, for the
# peek, from the hover) after the step started; the hotspot meter must show once the queue is
# empty. The settings and the network are restored afterwards. The daily recap fires at the reset
# hour only; the core's tests cover it (a_new_day_recaps_the_day_that_ended_once).
#
# It moves real bytes, so it runs under the measurement lock:
#   scripts/verify/measure-lock.py moments scripts/verify/moments.sh
set -euo pipefail
zmodload zsh/datetime  # EPOCHREALTIME

root=${0:A:h:h:h}
soroband=$root/core/target/debug/soroband
# The URL goes to this build: another worktree's Debug app also handles soroband-debug://.
app=$root/build/DerivedData/Build/Products/Debug/Soroband.app
cargo build --quiet --manifest-path $root/core/Cargo.toml -p soroband-cli
run=${EPOCHREALTIME%.*}
pid=$(pgrep -f "^$app/Contents/MacOS/Soroband\$" || true)
[[ -n $pid ]] || { print -u2 "moments.sh: start the Debug app first: scripts/verify/run-app.sh"; exit 1; }

# Every running Debug app answers `debug state`: ask until this build's answers.
state() {
  local s
  for _ in {1..20}; do
    s=$($soroband debug state --json) || return 1
    [[ $(jq .pid <<<$s) == $pid ]] && { print -r -- $s; return; }
  done
  return 1
}

keys=(island island_moments island_hog_mb island_hog_minutes island_background_mb island_transfer_mb
  island_ignored_apps)
typeset -A saved
for key in $keys; do saved[$key]=$($soroband config get $key); done
restore() {
  for key in $keys; do $soroband config set $key $saved[$key] >/dev/null; done
  open -g -a $app "soroband-debug://hover-island"
  open -g -a $app "soroband-debug://simulate-network"
}
trap restore EXIT

set_config() { $soroband config set $1 $2 >/dev/null }
set_config island on
set_config island_moments peek,joined,left,hotspot,hog,background,transfer
set_config island_ignored_apps none
set_config island_hog_minutes 1
set_config island_hog_mb 10000
set_config island_background_mb 10
set_config island_transfer_mb 10
sleep 1

failed=0
# Waits up to $3 seconds for a moment of kind $1 from source $2 at or after Unix time $4.
expect() {
  local kind=$1 source=$2 seconds=$3 since=$4
  for _ in {1..$(( seconds * 2 ))}; do
    if [[ $(state | jq --arg k $kind --arg s $source --argjson t $since \
      '[.island.recent[] | select(.kind == $k and .source == $s and .at >= $t)] | length') -gt 0 ]]; then
      print "PASS $kind ($source)"
      return
    fi
    sleep 0.5
  done
  print "FAIL $kind: no $source moment within $seconds s"
  failed=1
}

switch() {
  open -g -a $app "soroband-debug://simulate-network$1"
  for _ in {1..50}; do
    [[ $(state | jq -r .network.name) == $2 ]] && return
    sleep 0.2
  done
  print -u2 "moments.sh: the app did not switch to $2"
  exit 1
}

download() {
  # A stalled download must not hold the measurement lock: it fails the step instead.
  local size=$(/usr/bin/curl -sS --max-time 90 -o /dev/null -w '%{size_download}' "https://speed.cloudflare.com/__down?bytes=$1" || true)
  print "curl downloaded $size bytes"
}

print "1. Networks"
t=$EPOCHREALTIME
switch "?id=m5-office-$run" m5-office-$run
expect joined engine 15 $t
t=$EPOCHREALTIME
switch "?id=m5-phone-$run&kind=hotspot" m5-phone-$run
expect left engine 15 $t
expect joined engine 15 $t

print "2. Background activity and a large transfer"
# curl's bytes from an earlier run hold its alerts until they leave the one-minute window.
sleep 65
t=$EPOCHREALTIME
download 30000000
expect background engine 20 $t
expect transfer engine 20 $t
# The transfer ends after two quiet polls; its end (`ended` in island.recent) opens it again once the queue reaches it.
for _ in {1..120}; do
  [[ $(state | jq --argjson t $t '[.island.recent[] | select(.kind == "transfer" and .ended and .at >= $t)] | length') -ge 1 ]] && break
  sleep 0.5
done
(( $(state | jq --argjson t $t '[.island.recent[] | select(.kind == "transfer" and .ended and .at >= $t)] | length') >= 1 )) &&
  print "PASS transfer ended" || { print "FAIL transfer: no end"; failed=1; }

print "3. Data hog"
set_config island_hog_mb 15
# Background activity's burst must leave the one-minute window, so the hog sees only this download.
sleep 65
t=$EPOCHREALTIME
download 30000000
expect hog engine 20 $t
# This download is a transfer too: wait for its end, so nothing more arrives during step 4.
for _ in {1..120}; do
  [[ $(state | jq --argjson t $t '[.island.recent[] | select(.kind == "transfer" and .ended and .at >= $t)] | length') -ge 1 ]] && break
  sleep 0.5
done

print "4. Hotspot meter and peek"
# The meter shows once the moments of steps 1 to 3 have each had their turn: about a minute.
for _ in {1..360}; do
  [[ $(state | jq -r .island.showing) == glance ]] && break
  sleep 0.5
done
if [[ $(state | jq -r .island.showing) == glance ]]; then
  print "PASS hotspot meter"
else
  print "FAIL hotspot meter: $(state | jq -c '{network: .network, island: (.island | {showing, waiting})}')"
  failed=1
fi
# The peek opens only on an island at rest or showing the meter: a transfer's end may still come.
for _ in {1..120}; do
  [[ $(state | jq -r .island.showing) == glance ]] && break
  sleep 0.5
done
t=$EPOCHREALTIME
open -g -a $app "soroband-debug://hover-island?at=notch"
expect peek hover 15 $t
(( failed )) && print "island: $(state | jq -c '.island | {showing, waiting, hovering, recent: .recent[-3:]}')"

(( failed )) && exit 1
print "PASS"
