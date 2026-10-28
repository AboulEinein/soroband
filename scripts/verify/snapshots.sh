#!/bin/zsh
# Renders each view with fixed data and compares it with its baseline in tests/snapshots/.
# A failing view's image is written to $TMPDIR/soroband-snapshots/.
#
# Usage: scripts/verify/snapshots.sh [--record]
#   --record: write new baselines instead; look at each one before committing it.
set -euo pipefail

root=${0:A:h:h:h}
[[ ${1:-} == --record ]] && export TEST_RUNNER_SOROBAND_RECORD_SNAPSHOTS=1

[[ -d $root/build/SorobandCore.xcframework ]] || $root/scripts/build-core.sh $(uname -m)
xcodebuild -project $root/app/Soroband.xcodeproj -scheme Soroband \
  -derivedDataPath $root/build/DerivedData -destination "platform=macOS,arch=$(uname -m)" test -only-testing:SorobandTests/SnapshotTests
