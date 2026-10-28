#!/bin/zsh
# Checks that bytes are booked to the network they used. With the Debug app running
# (scripts/verify/run-app.sh), it switches the app to a simulated Wi-Fi network, downloads a
# known body with curl, switches to a simulated hotspot, downloads another, switches back to the
# real network, and reads each network's apps from the database with `soroband apps`.
# Passes when each simulated network holds its own download and none of the other's: curl's
# bytes on it are at least the body, and less than the body plus half the smaller download
# (1,500,000 bytes). TLS framing, HTTP headers and retransmissions add a few percent over the
# body; how close attribution comes to the body is M1's check (traffic.sh).
# Another curl running on this Mac at the same time adds to curl's bytes and can fail the check.
#
# Usage: scripts/verify/networks.sh
set -euo pipefail

root=${0:A:h:h:h}
soroband=$root/core/target/debug/soroband
# The URL goes to this build: another worktree's Debug app also handles soroband-debug://.
app=$root/build/DerivedData/Build/Products/Debug/Soroband.app
cargo build --quiet --manifest-path $root/core/Cargo.toml -p soroband-cli
run=$(date +%s)
office=office-$run
phone=phone-$run

# A Debug app from another worktree answers `debug state` too; its answer has no network.
state() {
  local s
  for _ in {1..20}; do
    s=$($soroband debug state --json) || return 1
    [[ $(jq -r '.network.id // empty' <<<$s) != "" ]] && { print -r -- $s; return; }
  done
  return 1
}

# Switches the app and waits until the core books to the new network.
switch() {
  open -g -a $app "soroband-debug://simulate-network$1"
  for _ in {1..50}; do
    local s=$(state)
    local id=$(jq .network.id <<<$s) booked=$(jq .today.networkID <<<$s) name=$(jq -r .network.name <<<$s)
    if [[ $id == $booked && ( -z $2 || $name == $2 ) ]]; then
      print "Booking to network $id ($name, $(jq -r .network.kind <<<$s))"
      return
    fi
    sleep 0.2
  done
  print -u2 "networks.sh: the app did not switch to ${2:-the real network}"
  exit 1
}

download() {
  local size=$(/usr/bin/curl -sS -o /dev/null -w '%{size_download}' "https://speed.cloudflare.com/__down?bytes=$1")
  print "curl downloaded $size bytes"
  (( size == $1 )) || { print -u2 "networks.sh: expected a $1-byte body"; exit 1; }
}

curl_rx() {
  # By name: curl often exits before the engine looks up its path, leaving only its name.
  $soroband apps --network $1 --json | jq '[.apps[] | select(.name == "curl") | .rx] | add // 0'
}

state >/dev/null || { print -u2 "networks.sh: start the Debug app first: scripts/verify/run-app.sh"; exit 1; }
real=$(state | jq -r .network.name)
switch "?id=$office" $office
download 5000000
switch "?id=$phone&kind=hotspot" $phone
download 3000000
switch "" $real

failed=0
check() {
  local network=$1 body=$2 rx=$(curl_rx $1)
  printf '%-18s curl %9d bytes for a %d-byte body (%+.2f%%)\n' $network $rx $body $(( (rx - body) * 100.0 / body ))
  (( rx >= body && rx < body + 1500000 )) || { print "FAIL: $network does not hold its own download alone"; failed=1; }
}
check $office 5000000
check $phone 3000000
kind=$($soroband today --json | jq -r --arg n $phone '.networks[] | select(.name == $n) | .kind')
print "$phone kind: $kind"
[[ $kind == hotspot ]] || { print "FAIL: $phone is not a hotspot"; failed=1; }
(( failed )) || print "PASS"
exit $failed
