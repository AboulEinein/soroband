# Plan

Roadmap from prototypes to the first public release. Each milestone is one branch and one pull request, merged into `main` after review. The ledger is the single record of progress: update it when a milestone changes state.

## Ledger

| ID | Milestone | Phase | Status | PR |
| --- | --- | --- | --- | --- |
| P0 | Research and prototypes | 0 | done | – |
| M0 | Repository foundation | 1 | blocked (hand checklist: menu bar item on screen, Location across a rebuild) | [#3](https://github.com/AboulEinein/soroband/pull/3) |
| M1 | Meter engine | 1 | done | [#4](https://github.com/AboulEinein/soroband/pull/4) |
| M2 | Network identity and storage | 1 | blocked (hand checklist: Location, real hotspot switch, Wi‑Fi without its name) | [#5](https://github.com/AboulEinein/soroband/pull/5) |
| M3 | Menu bar and popover (first dogfood build) | 1 | blocked (hand checklist and daily-use week) | [#6](https://github.com/AboulEinein/soroband/pull/6) |
| M4 | History window | 2 | blocked (hand checklist; user decision on History's open with no UI process running, 363–423 ms against the 300 ms criterion, since M6a) | [#13](https://github.com/AboulEinein/soroband/pull/13) |
| M5 | Dynamic Island moments | 2 | blocked (hand checklist: peek, look and feel, the hog's buttons, notifications, full screen, a real hotspot, the Island pane) | [#50](https://github.com/AboulEinein/soroband/pull/50) |
| M6 | Memory and performance | 3 | blocked (M6a hand checklist) | [#35](https://github.com/AboulEinein/soroband/pull/35), [#36](https://github.com/AboulEinein/soroband/pull/36), [#37](https://github.com/AboulEinein/soroband/pull/37) |
| M7 | Release v0.1.0 | 3 | blocked (hand checklist: second-account install, a fresh agent's install by each route, Location after an update; then the v0.1.0 tag, with the user's approval) | [#54](https://github.com/AboulEinein/soroband/pull/54) |
| M8 | Resource meter engine and storage | 4 | planned | – |
| M9 | Resources in the popover, History and the menu bar | 4 | planned | – |
| M10 | Resource moments | 4 | planned | – |

M0–M6 are merged to `main`. A milestone with a hand checklist stays `blocked` until the user has run it; the checklists are in [`handover.md`](handover.md#next-action).

Statuses: `planned`, `in progress`, `in review`, `done`, `blocked (<reason>)`.

## Phases

1. **Foundation and first features (M0–M3).** Ends with a build you run every day: real per-app, per-network counting, stored forever, shown in the menu bar and popover.
2. **History and island (M4–M5).** M4 and M5 touch separate parts of the app and can run in parallel once M3 is merged.
3. **Performance and release (M6–M7).** The menu bar app back within its budget after every window, then a release workflow with a DMG and an install prompt for agents.
4. **Resource meter (M8–M10).** CPU, memory, disk and energy per app beside the internet bytes, with history, then their views, then their moments. M8 runs first; M9 and M10 can run in parallel once it is merged.

## Milestones

Every milestone ends on its exit criteria. A milestone is `done` only when each criterion is checked with evidence in the PR description, as [`verification.md`](verification.md) describes for that milestone.

A milestone states outcomes and how each is tested: what it delivers, its exit criteria, and the evidence that checks them. The mechanism (the algorithm, the data layout, how a check is computed) and the design of a view are the milestone's to choose, and its PR states and tests them.

### M0: Repository foundation

Deliverables:
- `core/`: Cargo workspace with `soroband-core` (library) and `soroband-cli` (binary), `rustfmt` and `clippy` settings.
- Bridge: `soroband-core` builds as a universal (arm64 + x86_64) static library with a generated C header (`cbindgen`), packaged as an XCFramework by `scripts/build-core.sh`.
- `app/`: Xcode project for a menu-bar-only app (`LSUIElement`) that links the core and shows a string returned by Rust in the menu bar.
- `scripts/build.sh`: builds core and app from a clean clone.
- `scripts/install.sh`: builds a release, signs it, installs `Soroband.app` into `/Applications` and the `soroband` command into `~/.local/bin`, and launches the app. Idempotent, so the same script updates an existing install. An ad-hoc signature changes with every build, so the script signs with a stable self-signed certificate it creates in its own keychain; `--adhoc` signs ad hoc. Check whether the Location permission survives a rebuild with each signature.
- `docs/agents/install.md`: the install prompt for coding agents: check requirements (macOS 14+, Xcode, Rust), run the script, verify the app is running, walk the user through the Location permission.
- `.github/workflows/ci.yml`: `cargo fmt --check`, `cargo clippy -D warnings`, `cargo test`, and an unsigned `xcodebuild` build on a macOS runner.
- Verification harness from [`verification.md`](verification.md#running-the-app): `scripts/verify/run-app.sh`, `scripts/verify/budget.sh`, the `soroband-debug://` URL scheme and `soroband debug state --json` (Debug builds only), and the snapshot test setup with its first baseline.

Exit criteria:
- A clean clone builds with one command.
- A coding agent given only `docs/agents/install.md` installs and launches the app on this Mac.
- CI is green on the PR.
- The menu bar shows the string from Rust.

### M1: Meter engine

Deliverables:
- Kernel statistics client in `soroband-core`, ported from `prototypes/meter-probe`: chunked polls with continuation, full-poll baselines, final updates for closed flows, kernel-side interface filter, per-flow `IS_LOCAL` filter.
- Layout guard: a table of known descriptor sizes per provider and macOS version; unknown sizes switch the engine to interface-only totals and report it.
- Process attribution: `proc_pidpath` to `.app` bundle, helper processes rolled up to their app, effective pid credited for delegated traffic, daemons grouped as "macOS & Services".
- Interface counters via the interface MIB's 64-bit statistics (`IFDATA_GENERAL`) for reconciliation.
- Recorded kernel message fixtures with replay tests.
- `soroband live`: per-app internet bytes every N seconds.

Exit criteria:
- A known 20 MB download is attributed to its process: curl's received bytes are within 1% of the body size plus the duplicate bytes the kernel reports for that flow (`nstat_rxduplicatebytes`).
- The sum over all apps is within 10% of the interface counter over 60 s under load (the `traffic.sh` download). The gap over an idle minute is measured and reported, not judged.
- Network-quality cutoff for the two criteria above: a `traffic.sh` run is judged only if the kernel-reported duplicate bytes for curl's flow are under 1% of the body (200,000 bytes for the 20 MB file), no other curl ran in the window, and the download finished within 45 s. Other runs are recorded in the PR but not judged. At least 3 judged runs must pass.
- Idle cost measured over 10 min: CPU ≤ 0.1%, memory ≤ 5 MB. Numbers recorded in `docs/design.md`.

### M2: Network identity and storage

Deliverables:
- App side: `NWPathMonitor`, CoreWLAN network name (with the Location permission request), gateway MAC for Ethernet, hotspot detection from `isExpensive`, a network registry with stable IDs and user-editable names and types.
- On a network change the app tells the core, which polls immediately and closes the current bucket.
- Core: SQLite (system library, WAL), one row per (hour, network, app); flush every minute, on network change and on quit; daily reset hour.
- `soroband today` and `soroband apps --network <name>`, reading the app's database, each with `--json`.
- Settings owned by the core: one schema (key, type, default, description) stored in `~/Library/Application Support/Soroband/settings.json`. `soroband config list | get <key> | set <key> <value>` edits it and posts a Darwin notification the app listens for, so changes apply live. `docs/agents/configure.md` tells agents how to use it.

Exit criteria:
- Switching between Wi‑Fi and a hotspot books bytes to the right network (scripted manual test, steps in the PR).
- Data survives a restart.
- `soroband config set` changes a setting in the running app without a restart.
- Database growth per day measured and recorded.

### M3: Menu bar and popover (first dogfood build)

Deliverables:
- Menu bar item: network icon and today's total on the current network; other menu bar layouts in Settings.
- Popover as in `prototypes/ui-spike`: current network card, Apps and Networks tabs, footer.
- Settings: General and Networks tabs. Launch at login (`SMAppService`). First-run onboarding for the Location permission.
- Engine self-check, as in [`design.md`](design.md#meter-engine): the raw gap between the interfaces and the app sum always shows as "Other / overhead"; "degraded" shows only after two consecutive 10-minute windows with at least 10 MB on the interfaces and a gap over ~15%, or at once when the apps sum to more than the interfaces by about 2%.

Exit criteria:
- Memory footprint ≤ 25 MB with the popover closed; CPU ≤ 0.1% idle over 10 min.
- You run it daily for a week; issues found go into the ledger as follow-ups.

### M4: History window

Deliverables:
- The history window from the prototype: ranges, stat tiles, stacked chart with hover, apps with network split, share by network, heatmap.
- Aggregation in SQL; no raw rows in memory. CSV export.

Exit criteria:
- Opens in under 300 ms with a year of synthetic data.
- Memory ≤ 60 MB while open, back under 30 MB after closing. Met by History's own process, which quits when its window closes and leaves nothing in the menu bar app; the menu bar app's own residue after the popover is M6's.

### M5: Dynamic Island moments

Deliverables:
- Island panel with notch geometry, the seamless and keep-menu-bar-clear styles, hover tested against the island's outline.
- Moment queue with priorities and durations.
- Triggers from real events: network joined and left, hotspot meter, peek on hover, data hog, background activity (frontmost app from `NSWorkspace`), large transfer.
- Island settings tab, notification fallback, full-screen detection, display choice, "Pause until off hotspot".

Exit criteria:
- Each moment fires from real traffic in a scripted test (for example, a large `curl` download fires the large-transfer moment).
- No CPU cost while no moment is showing.

Decided for M5 (2026-11-05):
- The island runs in the menu bar process, drawn with AppKit and Core Animation (the user's choice of four, measured in `prototypes/island-spike`, 3 interleaved runs each). An AppKit agent with a status item grew from 10.9–11.2 MB to 14.9–15.5 MB after 30 moments with the island in Core Animation (5.5–5.7 MB with the SwiftUI prototype's view), at 0.001% CPU at rest in both and about 50 ms of CPU a moment (200 ms in SwiftUI). The UI process would have run all day with the island on (42–57 MB more, its linger numbers in M6c) or started for each moment (0.5–0.8 s late); a third process for the island alone measured about 16.7 MB. The look is the prototype's: screenshots differ in under 0.15% of pixels, and recordings of the opening match frame by frame from the third frame on.
- Measured on the built island (Debug, the menu bar process): idle CPU over 10 minutes, interleaved rounds on the reviewed build, 0.058% and 0.043% with the island on and at rest, against 0.078% and 0.043% with the island and its notifications off, so exit criterion 2 is met (with the island off and its notifications on, 0.108% in one round and 0.046% in the next: noise from the Mac's traffic, the engine doing a subset of the island-on work); memory 14.4–14.8 MB at launch with the island off, 15.2–16.8 MB on, 18.2–18.4 MB after every moment and a peek (fresh launches, three runs, `vmmap`). `scripts/verify/moments.sh` fires every moment but the recap from real events (exit criterion 1).
- "Network joined" reports the last 7 days rather than the calendar week, so a Monday join is not empty.
- The daily recap fires at the reset hour only, so the scripted test (`scripts/verify/moments.sh`) leaves it to the core's test, which ends a day under the real engine on a recorded session.

Review experiment: M5's first review compares the blind reviewer with CodeRabbit on one commit, to find what the `pr-review` skill misses or gets wrong. Its files stay outside the repository, in `~/soroband-review-benchmark/m5/`. It changes `review.md`'s loop only here:
- **Round 1 is not posted.** It runs `pr-review` with `--no-story --no-github-comments` and saves its full report to `round-1-blind.md`, with the commit it reviewed. The lead answers each finding in `round-1-answers.md` (the fix commit, or the evidence for leaving it). Round 2's brief names those two files for the re-review; from round 2 the loop runs as `review.md` describes.
- **CodeRabbit reviews round 1's commit** before any fix is pushed: on the draft with `@coderabbitai full review` (if it skips the draft, mark it ready for the review and back to draft with `gh pr ready --undo`). Its review, inline comments and review-body findings are saved to `round-1-coderabbit.md`. Neither reviewer sees the other's findings before its report is saved. Its findings go through `review.md`'s CodeRabbit steps and into `coderabbit-findings.md` as usual, and their fixes go into round 2.
- **The comparison** goes in `comparison.md`: one row per distinct finding across both reviewers, with file and line, severity, category, which reviewer raised it, and the lead's verdict (valid, not valid, duplicate). Then per reviewer: valid findings, findings not valid, valid findings only it raised, and its time to review. It ends with proposals for the `pr-review` skill, which lives outside this repository and changes only with the user's approval. The PR's retro links nothing from it; the final report gives the user the comparison's summary.

### M6: Memory and performance

Deliverables:
- The menu bar app returns to its launch footprint after its windows close. Measured in M4: 18 MB at launch, 36 MB after Settings has opened and closed, 37–45 MB after the popover.
- Idle CPU measured in every menu bar layout, including a live speed: under the budget, or for a live speed under its accepted ceiling.
- History's open time and memory measured in a Release-optimized build (Release configuration with the DEBUG condition, Debug data directory), next to M4's Debug numbers.

Stages, one PR each (the user chose "split + hover prewarm" on 2026-11-03, then the linger without the prewarm on 2026-11-04):
- M6a: the popover, Settings and History move into the UI process, started at the first click, which quits 10 minutes after its last window closes; the menu bar process keeps the menu bar item and the engine.
- M6b: the menu bar process drops SwiftUI and draws the menu bar item itself.
- M6c: the closing measurements: idle CPU in every menu bar layout, History in a Release-optimized build, and the final table against `main` before M6 (cc87d1c).

Decided for M6a (2026-11-03, [#35](https://github.com/AboulEinein/soroband/pull/35)):
- History stays in the UI process with the popover and Settings. With History open after them the UI process reaches 74.3 MB, over design.md's "History window open ≤ 60 MB" row, which the menu bar process meets; one process costs less in total and loads the frameworks once, and it quits 10 minutes after its last window.
- The menu bar process ends about 1 MB above its launch footprint after every window (18.2 to 19.1 MB, 19.3 MB at rest once the UI process quit, Debug; 1.4 MB in an earlier run), not within 0.5 MB: pages touched during the first popover's live polls, with no growth in live heap and none on later openings. Accepted as measured.
- `budget.sh 10` in each menu bar layout (today's total, with a live speed, icon only) and History on a synthetic year in a Release-optimized build (Release configuration with the DEBUG condition, Debug data directory) are M6c's evidence, not M6a's: M6b replaces the menu bar process, so they are measured once, after it. M6a measures the default layout in Debug.

Decided for M6b (2026-11-04):
- One binary. The menu bar process runs AppKit alone (`main.swift`) and the UI process runs the SwiftUI app: the menu bar process measured 14.3–14.5 MB at launch against `main`'s 18.6–18.7 MB (Debug). S2's AppKit-only agent measured 14.2 MB with SwiftUI and Charts linked but unused and 13.9 MB without them, so a separate executable for the menu bar process would save about 0.3 MB, for a second target sharing the menu bar process's files and two executables to start and match; not taken.
- The menu bar process still grows after the popover, Settings and History: 1.2–1.4 MB, against 0.7–1.1 MB on `main` in the same two runs, almost all of it heap fragmentation from the popover's live polls (M6a's accepted residue); the live heap grows 0.25 MB in both.

Decided for M6c (2026-11-04):
- M6c measures and changes no code. The CPU levers that keep the look shipped earlier: the menu bar process's own renderer (M6b, [#36](https://github.com/AboulEinein/soroband/pull/36)) and coalesced settings-changed notifications ([#34](https://github.com/AboulEinein/soroband/pull/34)). The one left, a 10 s live-speed refresh, changes the readout, and the user ruled out changes to the look (2026-11-03).
- Layouts with a live speed are an exception to the 0.1% idle CPU budget, accepted up to 0.32% (measured 0.27–0.30%; 0.32–0.37% before M6); every other layout meets it.

Exit criteria:
- With no window open, after the popover, Settings and History have each opened and closed, the menu bar app is ≤ 25 MB.
- Idle CPU ≤ 0.1% over 10 minutes in each menu bar layout, except a layout with a live speed, accepted up to 0.32% (measured 0.27–0.30%) (2026-11-04).

Measured in M6c (memory and CPU in Debug, each beside `main` before M6, cc87d1c, in the same run; History also in a Release-optimized build, as its line says):
- Criterion 1 is met: the menu bar process 15.7–15.9 MB after the popover, Settings and History have each opened and closed and at rest once the UI process quit (cc87d1c: 47.1–47.5 MB), 14.3–14.5 MB at launch (two runs, `vmmap`).
- Criterion 2 is met, with the exception the user accepted for a live speed (2026-11-04): today's total 0.071%, icon only 0.041%, download 0.068%, upload 0.058%, download and upload stacked 0.061%, labeled 0.065% and inline 0.078%; live download 0.270%, live upload 0.265% and both 0.304% (cc87d1c: 0.318%, 0.341% and 0.369%). A live speed redraws the item whenever its whole KB/s changes, at most every poll (`design.md`, Menu bar label).
- History in a Release-optimized build opens in 151–211 ms within a running UI process and 363–416 ms with none (Year), as in Debug (149–211 and 373–423 ms); the UI process holds 55.2–56.1 MB with History open. With no UI process running, History is over M4's 300 ms exit criterion, as it has been since M6a (417 ms); the user has not decided whether that is accepted.
- The hand checklist (M6a's, run on `main`) needs the user.

### M7: Release v0.1.0

Deliverables:
- A GitHub Actions release workflow on a version tag: CI checks, then a universal (arm64 + x86_64) ad-hoc signed build packaged as `Soroband.dmg` (app plus `soroband` command), attached to a GitHub release with notes and a SHA-256 checksum.
- `docs/agents/install.md` covers both routes: download the DMG, verify the checksum, copy to `/Applications`, clear the quarantine flag with the user's consent (`xattr -dr com.apple.quarantine`), link the `soroband` command; or build from source with `scripts/install.sh`. Update path: `soroband update` downloads and installs the newest release the same way.
- README screenshots from the real app, `CHANGELOG.md`.

Exit criteria:
- On a second Mac user account, the DMG installs after one Open Anyway approval and the app runs.
- A coding agent following the README's install prompt ends with Soroband running, by either route.
- Whether macOS asks for Location permission again after an update is tested and written in the release notes.

### M8: Resource meter engine and storage

Soroband meters each app's CPU, memory, disk and energy beside its internet bytes, keeps them as long as the bytes, and keeps a minute-by-minute record of the busiest apps. Measured in `prototypes/sysmon-probe` (2026-11-08, M2 Max, 1131 processes): one coalition read per app gives its CPU time, memory footprint, disk bytes and energy, counts processes that already exited, and reads apps run as root without privilege; read on every 5 s poll it costs 0.072% CPU, read once a minute and whenever the gauges show load 0.014%, leaving out mapping each coalition to an app (about 0.25 ms a pass). On the same Mac, Stats used 3.3–4.0% CPU and 99–131 MB, Vorssaint 3.4.2 1.3% and 23 MB (its monitors on, its notch off).

Deliverables:
- **System gauges** on every engine poll, with no new thread or timer: CPU busy share (`host_statistics`, `HOST_CPU_LOAD_INFO`), memory used, compressed and swapped and the memory pressure level (`host_statistics64`, `HOST_VM_INFO64`, `kern.memorystatus_vm_pressure_level`), and free space on each local volume (`statfs`), read once a minute.
- **The resource read.** `proc_listcoalitions` and `coalition_info_resource_usage` once a minute, and on every poll while the CPU is over 50% busy or memory is under pressure. Each app's resources are credited under the same name as its bytes, named the way flows are (the outermost `.app`, "macOS & Services", or a command-line tool). A coalition holding processes of several apps (a terminal and the commands it runs share one) is split among them, so each command keeps its own usage; how the split treats a process that exits between reads is M8's to measure, and the PR states what such a process loses and to whom. The counters: CPU time, CPU time billed to it by daemons working for it, disk bytes read and written and energy; the gauges: memory footprint. GPU energy is left out: no per-process counter can check it, and the probe read it as zero for every app, since the compositing is billed to WindowServer.
- **A guard and a fallback.** Both calls are exported by `libsystem_kernel` but absent from the public SDK, as the statistics socket is. The engine looks them up at launch and checks the layout against `proc_pid_rusage` reads of the same processes, at launch and at intervals M8 sets. A coalition also counts processes that exited and processes the user cannot read, and a footprint changes between reads, so the check allows for each of these; it must still fail on a layout that moves or swaps any stored field, so it judges a field only on coalitions where that field's value differs from the others', and a layout it cannot verify that way counts as failed. When the lookup or the check fails, the engine reads the user's own processes with `proc_pid_rusage` instead and says so in `soroband debug state`; the rows it stores while falling back are marked, and `soroband top` and `apps` say when their numbers come from the fallback, which leaves out other users' and root processes. How the app shows it is M9's to design. In the probe, Cursor and Chrome, with 4 and 1 exited processes, read 3.1% and 1.2% above their live processes' CPU, and every listed footprint matched exactly.
- **Storage** (a schema version, one-way like the others): per (hour, app) the counters and the average and peak footprint, with daily sums written in the same transaction; per minute the system gauges and the five busiest apps by CPU, by footprint and by disk bytes written, kept 7 days by default (`resource_minutes_days`); measured growth per day in the PR.
- **`soroband`** gains `system` (the gauges now), `top` (the busiest apps now, by any resource) and `apps --by cpu|memory|disk|energy` over any range.
- `GLOSSARY.md`: the new terms (coalition, resource read, system gauges, footprint, and whatever the milestone names).

Exit criteria:
- Replay of recorded coalition reads: exited processes' CPU counted, coalitions folded into apps, a shared coalition split among its apps; the guard passes on recorded correct reads (exited and unreadable processes, a footprint that changed between reads) and fails on the same reads with each stored field moved or swapped, and the fallback takes over; `cargo mutants` on the new modules.
- A scripted load from one shell (`yes > /dev/null`, a `dd` writing 1 GB, an allocation that stays resident), with each command running over 90 s, shows in `soroband top` and in the stored hour against its known CPU time, bytes and footprint, within 5%, each under its own command's name.
- Idle CPU of the menu bar process over 10 minutes with the resource meter on (its guard and split included), beside a build without it in the same session: no more than 0.02% higher, and within the 0.1% budget in the default layout. Memory with no window open ≤ 25 MB.

Hand checklist: the energy counters against `sudo powermetrics` over the same minutes (the probe could not check them without root); if they disagree by more than 20%, energy is stored but not shown. On a Mac whose kernel leaves the energy counters at zero (Intel Macs may), energy is shown as unavailable, not as zero.

### M9: Resources in the popover, History and the menu bar

Deliverables:
- Resources wherever internet bytes are shown: the popover, History on every range and per app, and the menu bar's readings.
- A view of what was busy at a past minute, within the minute record M8 keeps ("what slowed my Mac at 3 pm").
- Settings for which resources are metered and how long the minute record is kept.

Each view's design is picked by the user from mockups before it is built, as the popover's and History's were. The design settles how the resource fallback (M8) is shown.

Exit criteria:
- Captures of each new view next to the mockup the user picked.
- History's open times and memory within M4's criteria with the resources on a synthetic year.
- Idle CPU in each new menu bar reading over 10 minutes, beside `main` in the same session: within the 0.1% budget. Each redraw costs about 18 ms of the main thread, so a reading that changes on every poll is measured before it is offered.

### M10: Resource moments

Deliverables:
- Island moments that fire on a change in an app's or the Mac's resources rather than on a fixed number. The candidates: an app holding a full core for minutes, an app's memory growing for hours (a leak), memory pressure, the start-up disk filling at its recent rate, an app writing heavily.
- The moments, their thresholds and actions, and how they sit with the existing moments (alerts, the ignored apps, notifications with the island off), are designed with the user at the start of M10, from these candidates and the data M8 stores.

Exit criteria:
- Each moment fires from a scripted load (`moments.sh` extended), and none fires on a recorded idle day.
- No CPU cost while no moment is showing, measured as in M5.

Decided for M8–M10 (2026-11-08): the user asked for CPU, memory and disk monitoring "to create the best monitoring app available with a significant margin". What sets it apart, from the competitor research (2026-11-08): per-app history kept as long as the internet bytes (Stats keeps 24 hours of totals, iStat Menus 28 days of totals, Vorssaint about 4 minutes, in memory), moments that fire on change, helpers counted with their app, and a cost one to two orders of magnitude below. Out of scope: temperatures, fans and anything needing SMC reads or a privileged helper.

## Later

Data caps and alerts, per-domain usage (DNS correlation), desktop widget, CSV and JSON export of any range, localization.

## How the work runs

- **One milestone per session.** Start each session with the prompt below. A fresh session per milestone keeps context small; the handover carries what matters across.
- **Orchestrator plus agents inside a session.** The session lead plans the milestone, does the coupled work itself, and spawns agents only for independent tracks (for example, in M4 the chart views and the SQL queries), for the blind reviewer of each round, for the direct review of comment or wording fixes, and for an advisor agent on a review judgment or reassessment.
- **Parallel sessions only after M3.** M0–M3 change shared interfaces (the bridge, the schema), so they run in order. M4 and M5 can run as two sessions in separate worktrees.

Estimated sessions: M0 1, M1 1–2, M2 1, M3 1–2, M4 1, M5 2, M6 1, M7 1, M8 2, M9 2, M10 1, so about 15 sessions. Calendar time depends mostly on review turnaround and the M3 daily-use week.

### Unattended runs

Milestones can run overnight as a chain, one fresh thread per milestone, started by a conductor thread that writes no code.

- **Stacked branches.** Nothing is merged without the user, so each milestone branches from the previous milestone's branch and opens its PR against it: `m<n>-<name>` from the branch of milestone n−1, or from `main` once that milestone has merged; the first from `main`. The user merges them in order; before merging a PR, the next PR is retargeted to `main` (`gh pr edit <n> --base main`), so deleting the merged branch cannot close it.
- **When the chain continues.** The next milestone starts only if the previous one ended `in review`, or `blocked` solely on a hand-run checklist (a permission prompt, a real hotspot, the daily-use week). Anything else stops the chain: a decision needed, repeated failures, red CI.
- **The conductor checks the review judgment.** Each milestone thread runs its own review loop as [`review.md`](review.md#rounds) describes, then CodeRabbit's review ([`review.md`](review.md#coderabbit)). When a thread stops, the conductor checks its review record against that loop and may send work back to the same thread. It asks the user only when the way forward needs a decision.
- **Hand-run checklists** collect in each PR and in the handover; the user runs them in the morning, in milestone order.

### When a session stops

A session stops in exactly one of two states, and never starts the next milestone.

- **In review.** Every exit criterion is checked with evidence in an open PR, CI is green, and the review in [`review.md`](review.md), the blind loop and then CodeRabbit's review, has ended with nothing left to act on. The ledger says `in review`.
- **Blocked.** The work needs a person (a permission prompt, a real hotspot, a decision), the same problem has failed three fixes, the work outgrows the milestone, or a review reassessment needs a decision (see [`review.md`](review.md#reassess-instead-of-another-round)), or CodeRabbit did not review (see [`review.md`](review.md#coderabbit)). The ledger says `blocked (<reason>)` and the handover lists exactly what is needed.

In both cases, update **Current state** and **Next action** in the handover, and add any new gotcha, before the final report. The user merges the PR; the next session marks the milestone `done` after checking the merge, or, for a milestone with a hand checklist, once the user has run it.

### Session prompt

Paste this into a new session, with the milestone ID and branch filled in:

```text
Run milestone M4 of Soroband on branch m4-history, created from main, with its PR against main.

Before anything else, read docs/checklist.md and follow it for every change and every push; then read docs/handover.md and the milestone in docs/plan.md. docs/verification.md and docs/review.md are the reference the checklist links to.

Deliver everything listed for the milestone in plan.md, with the evidence verification.md asks for this milestone. Review it as docs/review.md describes, with any change the milestone's section makes to the loop (M5's review experiment). Stop as plan.md's "When a session stops" says, with the ledger and the handover updated.

Report: the PR link, each exit criterion with its evidence, any checklist I need to run by hand, and anything blocked with what you need from me.
```
