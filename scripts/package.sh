#!/bin/zsh
# Builds a universal (arm64 + x86_64) Release of Soroband, signs it ad hoc and packages it as
# build/Soroband.dmg, with its SHA-256 checksum in build/Soroband.dmg.sha256. The release
# workflow (.github/workflows/release.yml) runs it on a version tag; it runs the same on a Mac.
#
# Usage: scripts/package.sh
# The DMG holds Soroband.app, with the soroband command in Soroband.app/Contents/Helpers, and a
# link to /Applications. Needs rustup, for the x86_64-apple-darwin standard library.
set -euo pipefail

root=${0:A:h:h}
build=$root/build
stage=$build/dmg
app=$stage/Soroband.app
cli=$app/Contents/Helpers/soroband

$root/scripts/build.sh

# The soroband command, universal like the app. Rust stamps its objects with this, so the command
# runs on the same macOS versions as the app.
export MACOSX_DEPLOYMENT_TARGET=14.0
clis=()
for triple in aarch64-apple-darwin x86_64-apple-darwin; do
  cargo build --release --manifest-path $root/core/Cargo.toml -p soroband-cli --target $triple
  clis+=($root/core/target/$triple/release/soroband)
done

rm -rf $stage $build/Soroband.dmg $build/Soroband.dmg.sha256
mkdir -p $stage
ditto $build/DerivedData/Build/Products/Release/Soroband.app $app
mkdir -p ${cli:h}
lipo -create $clis -output $cli

# Nested code first, then the app, whose signature seals it.
codesign --force --sign - $cli
codesign --force --sign - $app
codesign --verify --deep --strict $app
# One arch per -verify_arch: Xcode 27's lipo takes a second one for a file name.
for binary in $app/Contents/MacOS/Soroband $cli; do
  for arch in arm64 x86_64; do
    lipo $binary -verify_arch $arch || { print -u2 "package.sh: $binary has no $arch"; exit 1; }
  done
done

ln -s /Applications $stage/Applications
hdiutil create -quiet -volname Soroband -srcfolder $stage -format UDZO -fs HFS+ $build/Soroband.dmg
(cd $build && shasum -a 256 Soroband.dmg > Soroband.dmg.sha256)

print "Built $build/Soroband.dmg ($($app/Contents/Helpers/soroband version))"
print "SHA-256: $(cut -d' ' -f1 $build/Soroband.dmg.sha256)"
