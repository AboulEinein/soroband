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

## Running the app

An agent drives and observes the real app without a mouse. The pieces below are built in M0 and grow with each milestone.

| Tool | What it does |
| --- | --- |
| `scripts/verify/run-app.sh` | Builds Debug, launches the app, waits until it reports ready, prints the PID. |
| Debug URL scheme `soroband-debug://` (Debug builds only) | `open-popover`, `open-history?range=month`, `open-settings?tab=island`, `fire-moment?kind=dataHog`, `simulate-network?id=office`. Trigger with `open -g -a <this build's Soroband.app> "soroband-debug://open-popover"`; never leave out `-g` (see the handover's Gotchas). |
| `soroband debug state --json` | What the running app shows: current network, menu bar text, open windows with their window numbers, island state, engine health. |
| `soroband debug history --json` | What the History process shows: range, network, totals, open time from the click, its windows. `open-history` (with `range`, `network`, `date`, `app`, `hover`) starts a History process from the menu bar app, replacing an open one; `close-history` quits it; `export-history` writes its CSV to `~/Library/Caches/io.github.abouleinein.soroband.debug/history.csv`. Open the popover first to time the standby path a click takes. A Debug app launched with `open -g --env SOROBAND_DATA_DIR=<dir> -a <this build's Soroband.app>` and its History process use that data directory, for a synthetic year from `cargo run --release --example history-year -- <dir>`. |
| `screencapture -x -o -l <windowNumber> out.png` | Captures one window; window numbers come from `soroband debug state`. Menu bar and notch: `screencapture -x -R <rect>`. Read every capture and compare it with `docs/mockups/`. |
| `scripts/verify/snapshots.sh` | Renders each view with fixed fake data to PNG and diffs against `tests/snapshots/`. A changed baseline is accepted only after looking at it; the PR says what changed and why. |
| `scripts/verify/networks.sh` | With the Debug app running, switches it to a simulated Wi‑Fi network and a simulated hotspot with a known `curl` download on each, and checks with `soroband apps --network` that each network holds its own download. |
| `scripts/verify/traffic.sh` | Downloads a known size (20 MB from `speed.cloudflare.com`) and checks the attribution in `soroband live --json` or `soroband today --json`. |
| `scripts/verify/budget.sh <minutes>` | Samples the running app's CPU (`ps`) and memory footprint (`footprint`); exits non-zero over budget. |
| `scripts/verify/install-guard.sh` | Runs a copy of `scripts/install.sh` against a fake installed app and checks it stops before building unless it gets `--replace` or a yes in a terminal. Runs in CI. |

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
| M1 | Replay of recorded kernel messages: chunked polls, continuation, baselines, closed flows, layout guard, local filter, helper and delegated attribution; `cargo mutants` | `traffic.sh`: 20 MB within 1% of the body plus the kernel's duplicate bytes; 60 s sum under load within 10% of the interface counter; judged only on runs with duplicates under 1% of the body, at least 3 passing; `budget.sh 10` | Test and mutant results, measured attribution and budget numbers |
| M2 | Bucketing across hour, day and reset-hour boundaries; flush and restart against a temporary database; settings schema, `config set` and change notification; `cargo mutants` | `networks.sh` (`simulate-network` switches with known downloads); `soroband today --json` before and after an app restart; `soroband config set` changes the running app | `debug state` output before and after; user checklist for a real hotspot switch |
| M3 | Popover and menu bar view models; display modes; launch-at-login state | `open-popover` and `open-settings` captures; `budget.sh 10` | Captures next to the mockups; budget numbers; start of the daily-use week |
| M4 | SQL aggregates against a fixture database with hand-checked totals | `open-history` for each range; open time from the app's log; memory open and after close | Captures, timing, memory numbers |
| M5 | Moment queue (priority, duration, hover keeps open); hover hit-test against the island outline; trigger thresholds | `fire-moment` for each kind, captured on the real notch; a large `traffic.sh` download fires the large-transfer moment; `budget.sh 10` with the island on | Captures of every moment, `debug state` showing real-traffic triggers, budget numbers |
| M6 | Snapshots unchanged by any view that is redrawn with less SwiftUI | `budget.sh 10` after the popover, Settings and History have each opened and closed, in each menu bar mode; History opened on a synthetic year in a Release build | Memory at launch and after each window, CPU per menu bar mode, Release open times and History's memory while open |
| M7 | Release workflow dry run | DMG installed under a second macOS user account; a fresh agent follows the README install prompt | Release run link, install transcript, Location re-prompt result as written in the release notes |
