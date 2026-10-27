#!/bin/zsh
# Builds the Debug app for this Mac, launches it, waits until it answers
# `soroband debug state --json`, and prints its PID. This worktree's Debug app is stopped
# first if it is running; Debug builds of other worktrees are left alone.
set -euo pipefail

root=${0:A:h:h:h}
soroband=$root/core/target/debug/soroband
app=$root/build/DerivedData/Build/Products/Debug/Soroband.app

$root/scripts/build-core.sh $(uname -m) >/dev/null
cargo build --quiet --manifest-path $root/core/Cargo.toml -p soroband-cli

# Every running Debug app answers `debug state`, so find this build's process by its path.
own() { pgrep -f "^$app/Contents/MacOS/Soroband" || true }
for old in $(own); do
  kill $old
  while kill -0 $old 2>/dev/null; do sleep 0.2; done
done

xcodebuild -quiet -project $root/app/Soroband.xcodeproj -scheme Soroband -configuration Debug -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath $root/build/DerivedData build
open -g $app

for _ in {1..30}; do
  pid=$(own)
  if [[ -n $pid ]] && state=$($soroband debug state --json 2>/dev/null) &&
     [[ $(print -r -- $state | plutil -extract pid raw -o - -) == $pid ]]; then
    print -r -- $pid
    exit 0
  fi
  sleep 1
done
print -u2 "run-app.sh: the app did not answer within 90 s"
exit 1
