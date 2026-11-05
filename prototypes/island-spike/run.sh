#!/bin/zsh
# Builds the spike and measures each mode in interleaved runs, one JSON line each, holding the
# measurement lock. Usage: prototypes/island-spike/run.sh [runs] [cycles] [rest seconds]
set -euo pipefail
cd ${0:A:h}
swift build -c release -q
exec ../../scripts/verify/measure-lock.py "island-spike" zsh -c "
  for run in {1..${1:-3}}; do
    for mode in none appkit swiftui; do .build/release/IslandSpike \$mode ${2:-5} ${3:-120}; done
  done"
