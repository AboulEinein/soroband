#!/bin/zsh
# Repeats the spike's measurements: the cost of one call of each source, then
# 10 minutes of each polling mode side by side, under this Mac's measurement lock.
set -euo pipefail
cd "${0:A:h}"
cargo build --release --quiet
probe=$PWD/target/release/sysmon-probe
lock=${0:A:h}/../../scripts/verify/measure-lock.py
secs=${1:-600}
python3 $lock sysmon-probe zsh -c "
  $probe bench
  for mode in idle gauges scan coal tiered; do $probe run \$mode $secs & done
  wait
"
