#!/bin/zsh
# Builds the Debug app for this Mac, launches it, waits until it answers
# `soroband debug state --json`, and prints its PID. A Debug app it finds running is
# stopped first.
set -euo pipefail

root=${0:A:h:h:h}
soroband=$root/core/target/debug/soroband
app=$root/build/DerivedData/Build/Products/Debug/Soroband.app

$root/scripts/build-core.sh $(uname -m) >/dev/null
cargo build --quiet --manifest-path $root/core/Cargo.toml -p soroband-cli

if state=$($soroband debug state --json 2>/dev/null); then
  old=$(print -r -- $state | plutil -extract pid raw -o - -)
  kill $old
  while kill -0 $old 2>/dev/null; do sleep 0.2; done
fi

xcodebuild -quiet -project $root/app/Soroband.xcodeproj -scheme Soroband -configuration Debug -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath $root/build/DerivedData build
open -g $app

for _ in {1..30}; do
  if state=$($soroband debug state --json 2>/dev/null); then
    print -r -- $state | plutil -extract pid raw -o - -
    exit 0
  fi
done
print -u2 "run-app.sh: the app did not answer within 90 s"
exit 1
