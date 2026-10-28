# app

The SwiftUI menu bar app (`LSUIElement`, no Dock icon). It links the Rust core from `core/` as `build/SorobandCore.xcframework`, which `scripts/build-core.sh` produces; build the core before opening `Soroband.xcodeproj` in Xcode.

| Path | Contents |
| --- | --- |
| `Soroband/` | App sources. The groups are synchronized with the folders, so new files need no project edit. |
| `Soroband/Debug/` | Debug-only commands for agents: the `soroband-debug://` URL scheme and the answer to `soroband debug state --json`. |
| `SorobandTests/` | Swift Testing: the bridge to the core, network identity, the menu bar and popover view models, launch at login, onboarding, and snapshot tests against `tests/snapshots/`. |
| `Config/Debug-Info.plist` | Info.plist keys for Debug builds only (the `soroband-debug` URL scheme). |

Debug builds use the bundle identifier `io.github.abouleinein.soroband.debug`, so they run next to an installed Release build.

Debug URL commands (`open "soroband-debug://<command>"`):

| Command | Effect |
| --- | --- |
| `quit` | Quits the Debug app. |
| `open-popover?tab=networks&all=1` | Opens the popover on a tab (`apps` unless given); `all=1` turns on the Apps tab's All networks toggle. |
| `close-popover` | Closes the popover. |
| `open-settings?tab=networks` | Opens Settings on a tab (`general` unless given). |
| `close-settings` | Closes Settings. |
| `open-onboarding` | Opens the first-run window that asks for the Location permission. |
| `capture-status-item` | Renders the menu bar item to `~/Library/Caches/io.github.abouleinein.soroband.debug/status-item.png`, for when the item is hidden behind the notch. |
| `capture-window?number=<n>` | Renders window `n` (a number from `soroband debug state`) as the app draws it to `window.png` in the same directory, for a window `screencapture` cannot see. |
| `simulate-network?id=office&kind=hotspot` | Books usage to a made-up network named `office` (`kind` is `wifi`, `ethernet` or `hotspot`; default `wifi`), as if the Mac had joined it. `simulate-network` alone goes back to the real network. |
| `update-network?name=Desk&kind=ethernet` | Renames the current network and sets its kind, as a user would. |

Debug builds of other worktrees also handle `soroband-debug://`, and `open "soroband-debug://…"` may launch one of them. Send the URL to this build: `open -g -a "$PWD/build/DerivedData/Build/Products/Debug/Soroband.app" "soroband-debug://…"`. To capture the popover or Settings with `screencapture`, leave out `-g`: macOS does not let an app sent to the background bring itself forward, and a window behind others is not drawn.

The app keeps its usage database (`usage.sqlite`) and `settings.json` in `~/Library/Application Support/Soroband`; Debug builds use `Soroband Debug` next to it.

The design it implements is in [`docs/design.md`](../docs/design.md) and [`prototypes/ui-spike`](../prototypes/ui-spike); how to run and observe it is in [`docs/verification.md`](../docs/verification.md#running-the-app).
