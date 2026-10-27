# core

Rust workspace:

- `soroband-core`: the meter engine (kernel network statistics client, app attribution, interface reconciliation), storage (SQLite, `store`), the app's metering loop (`ledger`, `service`) and settings (`settings`). Built as a static library for the app, with its C API in `src/ffi.rs`.
- `soroband-cli`: the `soroband` command: `today`, `apps --network`, `config`, and `live`. `soroband debug …` exists in debug builds only. Debug builds read the Debug app's data directory (`~/Library/Application Support/Soroband Debug`), release builds the installed app's; `SOROBAND_DATA_DIR` overrides both.

```sh
cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
../scripts/build-core.sh          # universal static library and header as build/SorobandCore.xcframework
../scripts/build-core.sh arm64    # this Mac only
```

The engine is `soroband-core`'s `meter` module. `soroband live` shows what it counts; `soroband live --for 60 --record <file>` records a session with the kernel as a test fixture (descriptors scrubbed to the fields the engine reads; app paths, process names and interface totals are still real, so anonymize them before committing, as `docs/handover.md` describes), and `tests/replay.rs` replays the recordings in `crates/soroband-core/tests/fixtures`.

`build-core.sh` generates `soroband_core.h` with cbindgen; if `cbindgen` is not on `PATH` it installs a pinned version into `core/target/tools`. A universal build needs the `x86_64-apple-darwin` standard library, which rustup provides (`rustup target add x86_64-apple-darwin`); Homebrew's `rust` has only the host's.

`cargo run --release --example db-growth -- [days] [apps an hour] [networks a day]` measures how much the usage database grows per day.

The engine design and its measurements are in [`docs/design.md`](../docs/design.md#meter-engine); the prototype it is ported from is [`prototypes/meter-probe`](../prototypes/meter-probe).
