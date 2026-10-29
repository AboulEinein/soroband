#!/bin/zsh
# Builds the spike and measures each variant: runs of 20 open/close cycles, one JSON line each.
# Usage: prototypes/popover-spike/run.sh [runs]
set -euo pipefail
cd ${0:A:h}
swift build -c release -q
for run in {1..${1:-3}}; do
  for mode in empty swiftui swiftui-charts appkit; do
    .build/release/PopoverSpike $mode 20
  done
done
