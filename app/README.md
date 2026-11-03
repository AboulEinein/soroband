# app

The SwiftUI menu bar app (`LSUIElement`, no Dock icon). It links the Rust core from `core/` as `build/SorobandCore.xcframework`, which `scripts/build-core.sh` produces; build the core before opening `Soroband.xcodeproj` in Xcode.

| Path | Contents |
| --- | --- |
| `Soroband/` | App sources. The groups are synchronized with the folders, so new files need no project edit. |
| `Soroband/Debug/` | Debug-only commands for agents: the `soroband-debug://` URL scheme and the answers to `soroband debug state --json` and `soroband debug history --json`. |
| `SorobandTests/` | Swift Testing: the bridge to the core, network identity, the menu bar, popover and History view models, the UI process (its requests, launch, linger and the popover toggle), the History options, launch at login, onboarding, and snapshot tests against `tests/snapshots/`. |
| `Config/Debug-Info.plist` | Info.plist keys for Debug builds only (the `soroband-debug` URL scheme). |

Debug builds use the bundle identifier `io.github.abouleinein.soroband.debug`, so they run next to an installed Release build.

The menu bar process holds the menu bar item and the engine, and never a window. The popover, Settings, History and the Welcome window run in the UI process, a second instance of the same app started with `--ui` by the menu bar process (`Soroband/UIProcess.swift`, its side in `Soroband/UIHost.swift`): it starts when the pointer enters the menu bar item or at the first click, gets the engine's numbers from the menu bar process over its standard input, and quits 60 s after its last window closes, or with the menu bar process. A Debug build started with `SOROBAND_DATA_DIR` set (`open -g --env SOROBAND_DATA_DIR=<dir> -a <app>`) uses that data directory, and so does its UI process.

Debug URL commands (`open -g -a <this build's Soroband.app> "soroband-debug://<command>"`):

| Command | Effect |
| --- | --- |
| `quit` | Quits the Debug app, and its UI process with it. |
| `open-popover?tab=networks&all=1` | Opens the popover on a tab (`apps` unless given); `all=1` turns on the Apps tab's All networks toggle. |
| `close-popover` | Closes the popover. |
| `open-settings?tab=networks` | Opens Settings on a tab (`general` unless given). |
| `close-settings` | Closes Settings. |
| `open-history?range=year&network=2&date=2026-10-15&app=<app id>&hover=2026-10-18T09:00` | Opens History in the UI process, replacing an open one: `range` is `day`, `week`, `month` (default), `year` or `all`; `network` an id (every network unless given); `date` a day in the period; `app` and `hover` expand an app and hold the chart's hover, for captures. With no UI process running it starts one, as a cold open. |
| `close-history` | Closes History. |
| `export-history` | History exports what it shows to `history.csv` in `~/Library/Caches/io.github.abouleinein.soroband.debug`. |
| `open-onboarding` | Opens the first-run window that asks for the Location permission. |
| `hover?inside=1` | Acts as the pointer entering the menu bar item (`inside=0`: leaving it): entering starts the UI process in standby, and while the pointer is inside it does not quit. |
| `quit-ui` | Quits the UI process, so the next window opens cold. |
| `capture-status-item` | Renders the menu bar item to `~/Library/Caches/io.github.abouleinein.soroband.debug/status-item.png`, for when the item is hidden behind the notch. |
| `capture-window?number=<n>` | Renders window `n` (a number from `soroband debug state`, of either process) as the app draws it to `window.png` in the same directory, for a window `screencapture` cannot see. |
| `simulate-network?id=office&kind=hotspot` | Books usage to a made-up network named `office` (`kind` is `wifi`, `ethernet` or `hotspot`; default `wifi`), as if the Mac had joined it. `simulate-network` alone goes back to the real network. |
| `update-network?name=Desk&kind=ethernet` | Renames the current network and sets its kind, as a user would. |

Debug builds of other worktrees also handle `soroband-debug://`, and `open "soroband-debug://…"` may launch one of them. Send the URL to this build: `open -g -a "$PWD/build/DerivedData/Build/Products/Debug/Soroband.app" "soroband-debug://…"`. Always pass `-g`: without it macOS brings Soroband to the front and it takes the keyboard from whatever the user is typing in. With `-g` the popover and windows still open and `screencapture -l` captures them.

The app keeps its usage database (`usage.sqlite`) and `settings.json` in `~/Library/Application Support/Soroband`; Debug builds use `Soroband Debug` next to it.

The design it implements is in [`docs/design.md`](../docs/design.md) and [`prototypes/ui-spike`](../prototypes/ui-spike); how to run and observe it is in [`docs/verification.md`](../docs/verification.md#running-the-app).
