#!/bin/zsh
# Builds the core, the soroband command and the Release app from a clean clone.
#
# Usage: scripts/build.sh [--host]
#   --host: build for this Mac's architecture only (no universal binary, so no rustup needed)
# Output: build/DerivedData/Build/Products/Release/Soroband.app and core/target/release/soroband
set -euo pipefail

root=${0:A:h:h}
archs=(arm64 x86_64)
[[ ${1:-} == --host ]] && archs=($(uname -m))

$root/scripts/build-core.sh $archs
cargo build --release --manifest-path $root/core/Cargo.toml -p soroband-cli
xcodebuild -quiet -project $root/app/Soroband.xcodeproj -scheme Soroband -configuration Release \
  -derivedDataPath $root/build/DerivedData -destination generic/platform=macOS ARCHS="$archs" ONLY_ACTIVE_ARCH=NO build

print "Built $root/build/DerivedData/Build/Products/Release/Soroband.app"
print "Built $root/core/target/release/soroband"
