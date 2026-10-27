#!/bin/zsh
# Checks the meter engine against a known download and the interface counters. While
# `soroband live` runs for 60 s, curl downloads a body of known size from speed.cloudflare.com.
# Passes when:
#   - curl's received bytes are within 1% of the body size plus the duplicate bytes the kernel
#     reports for its flow (`nstat_rxduplicatebytes`): retransmitted bytes crossed the interface,
#     so they are usage; TLS framing and HTTP headers add a little more;
#   - the sum over all apps is within 10% of what crossed the internet interfaces. The download
#     puts the window under load; the gap is judged only under load (docs/plan.md, M1).
# A run is judged only on a good network: the kernel reports duplicate bytes under 1% of the body
# for curl's flow. Over that, the results are printed but not judged (docs/plan.md, M1).
# Another curl running on this Mac at the same time adds to curl's bytes and fails the first check.
#
# Usage: scripts/verify/traffic.sh [bytes]   (default 20000000)
# Exit status: 0 judged and passed, 1 failed, 3 reported only (network over the cutoff).
set -euo pipefail

root=${0:A:h:h:h}
bytes=${1:-20000000}
window=60

cargo build --quiet --release --manifest-path $root/core/Cargo.toml -p soroband-cli
soroband=$root/core/target/release/soroband
out=$(mktemp -t soroband-traffic)
$soroband live --json --interval 5 --for $window >$out &
live=$!
trap 'kill $live 2>/dev/null || true; rm -f $out' EXIT

sleep 8
# The system curl, because the attribution check below looks for its path.
size=$(/usr/bin/curl -sS -o /dev/null -w '%{size_download}' "https://speed.cloudflare.com/__down?bytes=$bytes")
print "curl downloaded $size bytes"
(( size == bytes )) || { print -u2 "traffic.sh: expected a $bytes-byte body"; exit 1; }
wait $live

last=$(tail -1 $out)
mode=$(jq -r .mode <<<$last)
curl_rx=$(jq '[.apps[] | select(.id == "/usr/bin/curl") | .rx] | add // 0' <<<$last)
curl_duplicate=$(jq '[.apps[] | select(.id == "/usr/bin/curl") | .rx_duplicate] | add // 0' <<<$last)
apps=$(jq '.total.rx + .total.tx' <<<$last)
interfaces=$(jq '.interfaces.rx + .interfaces.tx' <<<$last)

expected=$(( bytes + curl_duplicate ))
attribution=$(( (curl_rx - expected) * 100.0 / expected ))
against_body=$(( (curl_rx - bytes) * 100.0 / bytes ))
reconciliation=$(( (apps - interfaces) * 100.0 / interfaces ))
printf 'Mode:            %s\n' $mode
printf 'curl received:   %d bytes for a %d-byte body (%+.2f%% against the body alone)\n' $curl_rx $bytes $against_body
cutoff=$(( bytes / 100 ))
judged=$(( curl_duplicate < cutoff ))
printf 'Duplicates:      %d bytes reported by the kernel for curl'"'"'s flow (cutoff %d)\n' $curl_duplicate $cutoff
printf 'Attribution:     %d against body + duplicates %d (%+.2f%%, limit 1%%)\n' $curl_rx $expected $attribution
printf 'All apps:        %d bytes; interfaces %d bytes over %d s (%+.2f%%, limit 10%%)\n' $apps $interfaces $window $reconciliation
print "Top apps:"
jq -r '.apps[:8][] | "  \(.name)\t\(.rx) down\t\(.tx) up"' <<<$last

failed=0
[[ $mode == per_app ]] || { print "FAIL: the engine is not counting per app"; exit 1; }
if (( ! judged )); then
  print "NOT JUDGED: duplicates over 1% of the body; results reported only"
  exit 3
fi
print "Judged:          yes (duplicates under 1% of the body)"
(( ${attribution#-} <= 1 )) || { print "FAIL: curl's bytes are off body + duplicates by more than 1%"; failed=1; }
(( ${reconciliation#-} <= 10 )) || { print "FAIL: the app sum is off the interface counter by more than 10%"; failed=1; }
(( failed )) || print "PASS"
exit $failed
