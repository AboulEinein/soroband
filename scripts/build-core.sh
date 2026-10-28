#!/bin/zsh
# Builds soroband-core as a static library with its C header and packages both as
# build/SorobandCore.xcframework, which the Xcode project links.
#
# Usage: scripts/build-core.sh [arch...]
#   arch: arm64, x86_64 (default: both, giving a universal library)
set -euo pipefail

root=${0:A:h:h}
build=$root/build
cbindgen_version=0.29.4
archs=("$@")
(( $# )) || archs=(arm64 x86_64)

# Rust stamps its objects with this, so the linker does not warn when the app targets macOS 14.
export MACOSX_DEPLOYMENT_TARGET=14.0

triple_for() {
  case $1 in
    arm64) print aarch64-apple-darwin ;;
    x86_64) print x86_64-apple-darwin ;;
    *) print -u2 "build-core.sh: unknown arch '$1' (use arm64 or x86_64)"; exit 2 ;;
  esac
}

sysroot=$(rustc --print sysroot)
for arch in $archs; do
  triple=$(triple_for $arch)
  if [[ ! -d $sysroot/lib/rustlib/$triple ]]; then
    if command -v rustup >/dev/null; then
      rustup target add $triple
    else
      print -u2 "build-core.sh: the Rust standard library for $triple is not installed."
      print -u2 "Install Rust with rustup (https://rustup.rs) to build a universal library,"
      print -u2 "or build for this Mac only: scripts/build-core.sh $(uname -m)"
      exit 1
    fi
  fi
done

cbindgen=$(command -v cbindgen || true)
if [[ -z $cbindgen ]]; then
  tools=$root/core/target/tools
  cbindgen=$tools/bin/cbindgen
  if [[ ! -x $cbindgen ]] || [[ $($cbindgen --version) != "cbindgen $cbindgen_version" ]]; then
    print "Installing cbindgen $cbindgen_version into core/target/tools"
    cargo install cbindgen --version $cbindgen_version --locked --root $tools --quiet
  fi
fi

libs=()
for arch in $archs; do
  triple=$(triple_for $arch)
  cargo build --manifest-path $root/core/Cargo.toml -p soroband-core --release --target $triple
  libs+=($root/core/target/$triple/release/libsoroband_core.a)
done

rm -rf $build/core $build/SorobandCore.xcframework
mkdir -p $build/core/include/SorobandCore
lipo -create $libs -output $build/core/libsoroband_core.a

$cbindgen --quiet --config $root/core/crates/soroband-core/cbindgen.toml \
  --output $build/core/include/SorobandCore/soroband_core.h $root/core/crates/soroband-core
cat > $build/core/include/SorobandCore/module.modulemap <<'MODULEMAP'
module SorobandCore {
    header "soroband_core.h"
    export *
}
MODULEMAP

xcodebuild -create-xcframework \
  -library $build/core/libsoroband_core.a -headers $build/core/include \
  -output $build/SorobandCore.xcframework >/dev/null
print "Built $build/SorobandCore.xcframework ($(lipo -archs $build/core/libsoroband_core.a))"
