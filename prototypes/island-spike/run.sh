#!/bin/zsh
# Builds the spike and measures each mode in interleaved runs, one JSON line each, holding the
# measurement lock. Usage: prototypes/island-spike/run.sh [runs] [cycles] [rest seconds]
set -euo pipefail
cd ${0:A:h}
# The build runs under the lock too, so it never takes CPU from another measurement, and a mode
# that fails stops the run.
exec ../../scripts/verify/measure-lock.py "island-spike" zsh -e -c "
  swift build -c release -q
  for run in {1..${1:-3}}; do
    for mode in none appkit swiftui; do .build/release/IslandSpike \$mode ${2:-5} ${3:-120}; done
  done"
