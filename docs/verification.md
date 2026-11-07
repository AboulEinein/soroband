# Verification

Every milestone proves its work three ways: **tests**, a **run of the real app**, and **evidence** in the pull request. Work without evidence is not done, however sure the reasoning.

## Tests

Each test guards a behavior that a user or the performance budget depends on, and goes red when that behavior breaks.

- **Independent expected values.** Expected numbers come from outside the code under test: recorded kernel messages whose totals were checked against the interface counter, the known size of a download, an example worked out by hand in the test's comment.
- **Tautological tests are rejected in review.** A test is tautological when it:
  - asserts that a mock returns what it was configured to return;
  - computes its expected value with the function under test, or a copy of it;
  - asserts a constant or a default against a literal copy of itself;
  - accepts a snapshot image nobody looked at;
  - has no assertion that can fail.
- **Prove the tests bite.**
  - Rust: run `cargo mutants` on the engine and storage modules. Every surviving mutant in parsing, accounting, bucketing or settings is killed by a new test or explained in the PR.
  - Bug fixes: write the test first and show it red before the fix.
- **Swift:** logic lives in plain types (moment queue, network registry, settings sync, formatting) and is tested with Swift Testing. Views are verified by rendered images (below), not by asserting on view structure.
- **Names state the behavior:** `closed_flow_final_bytes_are_counted`, `peek_ignores_pointer_beside_the_notch`.

## Before pushing

CI builds with Xcode 26 (the newest on GitHub's `macos-latest` runners), while the app is developed with Xcode 27. An older Swift rejects some code a newer one accepts, so a local pass does not prove CI's: CI is the authority, and no review round starts before it passes (`review.md`).

- **`scripts/verify/prepush.sh`** before every push: CI's checks for this Mac's architecture in Debug (records lint, Rust format, clippy in Debug and Release, Rust tests, swift-format, the install guard, the app's tests) plus the snapshots CI skips. CI's universal Release build, and its build and tests of the core on the `rust-version` `core/Cargo.toml` declares, run only in CI. It warns when this Mac's Xcode major differs from CI's.
- **Check what the change reaches,** as a reviewer will (`REVIEW.md`):
  - every input that crosses a boundary (a C function, a `soroband` argument, a setting, a debug URL) has a test at its limits and one past them;
  - every function that can receive a state or value the change adds (an empty display, a new setting value, a picked color) has its guards read against it, and a test for the new input;
  - a copy held elsewhere (the UI process's snapshot, a cache, a drawn image) is updated or its staleness is stated.
- **Fix every path into the state.** A fix to state that several paths reach (a queue's bookkeeping, a loop's exit, a cache) lists those paths and tests each, not only the one the finding names: in #9 and #50 each path-by-path fix drew the next round's finding.
- **Docs from evidence.** A number, a claim of "within budget" or "passes", or a rule restated from another doc, is copied from its source when written, not recalled.

## Running the app

An agent drives and observes the real app mostly without the pointer; `clicktime.swift` and `cliclick` click it for real, with Accessibility permission. The pieces below are built in M0 and grow with each milestone.

| Tool | What it does |
| --- | --- |
| `scripts/verify/run-app.sh` | Builds Debug, launches the app, waits until it reports ready, prints the menu bar process's PID. |
| Debug URL scheme `soroband-debug://` (Debug builds only) | `open-popover`, `open-history?range=month`, `open-settings?tab=island`, `fire-moment?kind=hog` (sample numbers, for captures), `hover-island?at=notch` (the pointer on the notch for the island's hit test, without moving it), `simulate-network?id=office`. Trigger with `open -g -a <this build's Soroband.app> "soroband-debug://open-popover"`; never leave out `-g` (see the handover's Gotchas). |
| `soroband debug state --json` | What the running app shows: current network, menu bar text, the menu bar process's windows, engine health, the island (`island`: what it shows, the waiting moments, its panels, and the latest moments with their source, `engine`, `hover` or `debug`, and whether each transfer moment is its end), and under `uiProcess` the UI process while it runs: its pid, whether the popover, Settings (`settingsTab`), History and the Welcome window are open, the popover's last open time from the click to its window on screen, as its occlusion state turning visible reports it (`popoverOpenMilliseconds`), whether it is lingering, and its windows with their window numbers. `popoverShown` and `settingsTab` are repeated at the top. |
| `soroband debug history --json` | What History shows, answered by the UI process: range, network, totals, open time from the click, the UI process's windows. `open-history` (with `range`, `network`, `date`, `app`, `hover`) opens History in the UI process, replacing an open one, and starts the UI process when none runs; `close-history` closes it; `export-history` writes its CSV to `~/Library/Caches/io.github.abouleinein.soroband.debug/history.csv`. A Debug app launched with `open -g --env SOROBAND_DATA_DIR=<dir> -a <this build's Soroband.app>` and its UI process use that data directory, for a synthetic year from `cargo run --release --example history-year -- <dir>`. |
| `quit-ui` | Debug URL command that quits the UI process, as the end of the linger does, to time a popover opened cold (no UI process) against one opened warm (within the linger). The time a user sees is from the click to the popover's window on screen: a timer that posts the click and polls `CGWindowListCopyWindowInfo` for the popover's window (near the top of a screen, wider than 300 pt) measures it from outside. The UI process runs the same executable as the menu bar process with `--ui`: match the menu bar process with `pgrep -f "^<app>/Contents/MacOS/Soroband$"`. |
| `screencapture -x -o -l <windowNumber> out.png` | Captures one window; window numbers come from `soroband debug state`. Menu bar and notch: `screencapture -x -R <rect>`. Read every capture and compare it with `docs/mockups/`. |
| `scripts/verify/snapshots.sh` | Renders each view with fixed fake data to PNG and diffs against `tests/snapshots/`. A changed baseline is accepted only after looking at it; the PR says what changed and why. |
| `scripts/verify/networks.sh` | With the Debug app running, switches it to a simulated Wi‑Fi network and a simulated hotspot with a known `curl` download on each, and checks with `soroband apps --network` that each network holds its own download. |
| `scripts/verify/moments.sh` | With the Debug app running, fires every moment but the daily recap from real events (simulated network switches, two 30 MB `curl` downloads, the pointer resting on the notch through the island's own hit test) and checks each in `soroband debug state`'s `island.recent`, from the engine or the hover. The recap fires at the reset hour only; a core test covers it. Moves real bytes: run it under `measure-lock.py`. |
| `scripts/verify/traffic.sh` | Downloads a known size (20 MB from `speed.cloudflare.com`) and checks the attribution in `soroband live --json`. A run with another curl in the window, or a download that does not finish within 45 s, is reported, not judged (exit 3). |
| `scripts/verify/budget.sh <minutes>` | Samples the running app's CPU (`ps`) and memory footprint (`footprint`); exits non-zero over budget. |
| `scripts/verify/measure-lock.py <label> <command>` | Runs a measurement while holding this Mac's measurement lock (a `flock` on `~/Library/Caches/soroband-measure.lock`, released when the command exits), waiting up to 2 hours for it, so that measurements from different worktrees and agents of this macOS user run one at a time. Every CPU, memory, traffic or timing measurement runs through it. |
| `scripts/verify/clicktime.swift` | Clicks the real pointer on the menu bar item and prints the milliseconds until the popover's window is on screen: the open time the user sees. Build with `swiftc -O scripts/verify/clicktime.swift -o /tmp/clicktime`; run as `/tmp/clicktime <x> <y> <menu bar pid>` with the item's centre from `soroband debug state` (`Item-0`); it finds the popover whether the UI process already runs (warm) or the click starts it (cold), exits 1 when no popover shows within 3 s, and exits 2 without clicking when the popover is already open. Needs Accessibility permission. Compare builds in paired, interleaved runs in one session (`docs/review.md`). |
| `scripts/verify/install-guard.sh` | Runs a copy of `scripts/install.sh` against a fake installed app and checks it stops before building with no terminal, with a no typed in a terminal (through `script`), and while another install holds the lock, and goes on with a yes or `--replace`. Runs in CI. |

## What needs a person

Agents cannot answer system permission prompts or physically switch networks. These are batched into short checklists the user runs at a review gate:

- The Location permission prompt, and Open Anyway for a downloaded build, once per Mac.
- Joining a real hotspot (M2, M5).
- How hover and clicks feel on the notch and popover. If the user grants Accessibility permission to the app running the agent (System Settings › Privacy & Security › Accessibility), the agent can move and click the pointer with `cliclick` and test this itself.
- The M3 week of daily use.

A milestone that needs one of these stops with the checklist in the PR and the handover, rather than guessing.

## Per milestone

| Milestone | Tests | Run the app | Evidence in the PR |
| --- | --- | --- | --- |
| M0 | Bridge returns the core's version, compared with `Cargo.toml` | `run-app.sh`; the menu bar shows the string from Rust; `budget.sh 5` on the empty app | Menu bar capture, budget numbers, green CI, transcript of a fresh agent following `docs/agents/install.md` |
| M1 | Replay of recorded kernel messages: chunked polls, continuation, baselines, closed flows, layout guard, local filter, helper and delegated attribution; `cargo mutants` | `traffic.sh`: 20 MB within 1% of the body plus the kernel's duplicate bytes; 60 s sum under load within 10% of the interface counter; judged only on runs with duplicates under 1% of the body, no other curl in the window and the download finished within 45 s, at least 3 passing; `budget.sh 10` on the app; `MEMORY_BUDGET_MB=5 scripts/verify/budget.sh 10 <pid of soroband live>` on the engine | Test and mutant results, measured attribution and budget numbers |
| M2 | Bucketing across hour, day and reset-hour boundaries; flush and restart against a temporary database; settings schema, `config set` and change notification; `cargo mutants` | `networks.sh` (`simulate-network` switches with known downloads); `soroband today --json` before and after an app restart; `soroband config set` changes the running app | `debug state` output before and after; user checklist for a real hotspot switch |
| M3 | Popover and menu bar view models; menu bar layouts; launch-at-login state | `open-popover` and `open-settings` captures; `budget.sh 10` | Captures next to the mockups; budget numbers; start of the daily-use week |
| M4 | SQL aggregates against a fixture database with hand-checked totals | `open-history` for each range; open time from the app's log; memory open and after close | Captures, timing, memory numbers |
| M5 | Moment queue (priority, duration, hover keeps open); hover hit-test against the island outline; trigger thresholds in the core (`moments.rs`), with the session receipt and the recap | `fire-moment` for each kind, captured on the real notch; `moments.sh` fires each moment from real events; `budget.sh 10` on the menu bar process with the island at rest, beside the island off, interleaved; its memory after every moment | Captures of every moment, `debug state` showing real-traffic triggers, budget numbers |
| M6 | Snapshots unchanged by any view that is redrawn with less SwiftUI; the UI process's decisions as plain types: the request queue while it launches, the popover toggle, the linger run by the menu bar process, a restart after a crash or a failed write (a script stands in for the UI process) | Memory of the menu bar process at launch and after the popover, Settings and History have each opened and closed (`vmmap --summary`); the UI process while each is open; popover open time, click to window on screen, cold (`quit-ui` first) and warm (within the linger); `budget.sh 10` on the menu bar process in each menu bar layout (today's total, each single reading, both live speeds, icon only, and a two-reading layout in each style), each beside a build from before the change in the same 10 minutes (with a live speed it exits non-zero, over the 0.1% it checks; that layout is judged against its accepted ceiling of 0.32% in `plan.md`, M6); History opened on a synthetic year in a Release-optimized build (the Release configuration with the DEBUG condition, the Debug bundle identifier and `Config/Debug-Info.plist`, `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`: a Release build reads the installed app's data directory, and the core is built for arm64 only); captures of the popover's tabs, each Settings pane and History before and after a change that moves a window to another process | Memory at launch and after each window, the UI process's memory and open times, CPU per menu bar layout, Release open times and History's memory while open, the captures side by side; a hand checklist for a real click, click-outside, focus and ⌘, |
| M7 | Release workflow dry run | DMG installed under a second macOS user account; a fresh agent follows the README install prompt | Release run link, install transcript, Location re-prompt result as written in the release notes |
| M8 | Replay of recorded coalition reads: exited processes, folding into apps, a coalition split across apps, the guard (an inconclusive footprint included) and the fallback; storage of counters and gauges across hour and day boundaries and the minute record's expiry; `cargo mutants` | A scripted load from one shell with known CPU time, bytes written and footprint, checked under each command's name in `soroband top` and the stored hour; `budget.sh 10` on the menu bar process with the resource meter on, beside a build without it, interleaved; its memory with no window open (`vmmap --summary`); growth per day | Replay and mutant results, the load's numbers against its known values, CPU and memory numbers, growth; the energy hand checklist |
| M9 | View models for the picker, the System card and the minute view; the new menu bar readings' redraw steps | Captures of each view; History on a synthetic year with resources; `budget.sh 10` in each new menu bar reading beside `main` | Captures next to the picked mockup, open times and memory, CPU per reading |
| M10 | Each detector against recorded resource series: fires on the change, stays quiet on a recorded idle day, a dismissed moment fires again only when worse, an ignored app raises none | `moments.sh` fires each resource moment from a scripted load; `budget.sh 10` with the moments at rest | Captures of every moment, `debug state` showing the triggers, budget numbers |
