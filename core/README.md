# core

Rust workspace:

- `soroband-core`: the meter engine (kernel network statistics client, app attribution, interface reconciliation) and storage (SQLite). Built as a static library for the app, with its C API in `src/ffi.rs`.
- `soroband-cli`: the `soroband` command, for live usage and queries over the stored history. `soroband debug …` exists in debug builds only.

```sh
cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
../scripts/build-core.sh          # universal static library and header as build/SorobandCore.xcframework
../scripts/build-core.sh arm64    # this Mac only
```

`build-core.sh` generates `soroband_core.h` with cbindgen; if `cbindgen` is not on `PATH` it installs a pinned version into `core/target/tools`. A universal build needs the `x86_64-apple-darwin` standard library, which rustup provides (`rustup target add x86_64-apple-darwin`); Homebrew's `rust` has only the host's.

The engine design and its measurements are in [`docs/design.md`](../docs/design.md#meter-engine); the prototype it is ported from is [`prototypes/meter-probe`](../prototypes/meter-probe).
