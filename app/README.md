# app

The SwiftUI menu bar app (`LSUIElement`, no Dock icon). It links the Rust core from `core/` as `build/SorobandCore.xcframework`, which `scripts/build-core.sh` produces; build the core before opening `Soroband.xcodeproj` in Xcode.

| Path | Contents |
| --- | --- |
| `Soroband/` | App sources. The groups are synchronized with the folders, so new files need no project edit. |
| `Soroband/Debug/` | Debug-only commands for agents: the `soroband-debug://` URL scheme and the answer to `soroband debug state --json`. |
| `SorobandTests/` | Swift Testing: the bridge to the core, and snapshot tests against `tests/snapshots/`. |
| `Config/Debug-Info.plist` | Info.plist keys for Debug builds only (the `soroband-debug` URL scheme). |

Debug builds use the bundle identifier `io.github.abouleinein.soroband.debug`, so they run next to an installed Release build.

Debug URL commands (`open "soroband-debug://<command>"`):

| Command | Effect |
| --- | --- |
| `quit` | Quits the Debug app. |
| `capture-status-item` | Renders the menu bar item to `~/Library/Caches/io.github.abouleinein.soroband.debug/status-item.png`, for when the item is hidden behind the notch. |

The design it implements is in [`docs/design.md`](../docs/design.md) and [`prototypes/ui-spike`](../prototypes/ui-spike); how to run and observe it is in [`docs/verification.md`](../docs/verification.md#running-the-app).
