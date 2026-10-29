#!/bin/zsh
# Runs CI's checks before a push, for this Mac's architecture in Debug, plus the snapshots CI
# skips. CI also builds a universal Release app; a failure only there shows in CI. Exits at the
# first failure.
#
# Usage: scripts/verify/prepush.sh
# CI builds the app with the Xcode named in docs/verification.md; a build that passes here on
# another Xcode can still fail there, so this warns when the major versions differ.
set -euo pipefail
cd "${0:A:h}/../.."

expected=$(sed -n 's/^CI builds with Xcode \([0-9][0-9]*\).*/\1/p' docs/verification.md | head -1)
local_major=$(xcodebuild -version | sed -n 's/^Xcode \([0-9][0-9]*\).*/\1/p')
if [[ -z $expected ]]; then
  print -u2 "prepush: docs/verification.md no longer says \"CI builds with Xcode N\"; restore that sentence."
  exit 1
fi
if [[ $local_major != "$expected" ]]; then
  print -u2 "prepush: warning: this Mac builds with Xcode $local_major, CI with Xcode $expected; wait for CI before a review round."
fi

print "== records"
scripts/verify/records-lint.py
print "== core"
(
  cd core
  cargo fmt --all --check
  cargo clippy --workspace --all-targets -- -D warnings
  # Release-only code (`cfg(not(debug_assertions))`) compiles only here.
  cargo clippy --workspace --all-targets --release -- -D warnings
  cargo test --workspace -q
)
print "== swift-format"
xcrun swift-format lint --strict --recursive app
print "== install guard"
scripts/verify/install-guard.sh
print "== app (with snapshots)"
scripts/build-core.sh arm64 >/dev/null
xcodebuild -project app/Soroband.xcodeproj -scheme Soroband -derivedDataPath build/DerivedData test -quiet
print "prepush: all checks passed"
