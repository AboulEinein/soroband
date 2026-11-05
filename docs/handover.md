# Handover

The state of the project for whoever picks it up next. Read this file, then the ledger in [`plan.md`](plan.md), before starting work. At the end of a session, update **Current state**, **Next action** and the ledger.

## Current state (2026-11-05)

- M0–M4 and M6, the fix in [#14](https://github.com/AboulEinein/soroband/pull/14), the work after the first install ([#17](https://github.com/AboulEinein/soroband/pull/17) to [#21](https://github.com/AboulEinein/soroband/pull/21)) and the CodeRabbit backlog and its follow-ups ([#23](https://github.com/AboulEinein/soroband/pull/23) to [#34](https://github.com/AboulEinein/soroband/pull/34)) are merged to `main`. On `main`: 174 Rust and 130 Swift tests pass and `scripts/verify/prepush.sh` passes. The milestones with a hand checklist stay `blocked` in the ledger until the user has run it.
- M0 (repository foundation): the Rust workspace, the universal XCFramework bridge, the menu bar app showing "Soroband <core version>", the build, install and verification scripts, the agent install guide and CI. Its hand checklist (below) has not been run.
- M1 (meter engine): the engine counts internet bytes per app from the kernel statistics socket; `soroband live` shows it; the app starts it at launch and reports it in `soroband debug state`. Under the network-quality cutoff, 3 judged `traffic.sh` runs passed, all at +0.16% attribution and −6.7% to −7.3% reconciliation; one lossy run over the cutoff reached +1.15%, because the kernel's duplicate counter misses some re-received bytes. Budget: engine 0.033% and 1.8 MB, Debug app 0.096% and 23.0 MB over 10 minutes. The replay fixtures are anonymized (see Decisions).
- M2 (network identity and storage): simulated switches (`scripts/verify/networks.sh`, 6 of 6 runs), the restart check and `config set` on the running app pass, and growth is measured at 27.9 KB a day. Budget: Debug app 0.059% CPU and 19.0 MB over 10 minutes. Its hand checklist (below) has not been run.
- M3 (menu bar and popover): the menu bar item (network icon and today's total, or today on all networks, live speed, or the icon alone), the popover (network card, Apps and Networks tabs, "Other / overhead", footer), Settings (General and Networks), launch at login through `SMAppService`, the first-run Location window, and the engine self-check in `core/crates/soroband-core/src/check.rs`. The menu bar item and popover are AppKit (`NSStatusItem`, `NSPopover`) hosting SwiftUI, so Debug builds open them on command (`open-popover`, `open-settings`). Budget: Debug app 0.096% CPU and 21.0 MB over 10 minutes with the popover closed, on a busy network; 0.055% with the icon alone. Its hand checklist and the daily-use week (exit criterion 2) need the user.
- M4 (History window): History runs in the UI process since M6a (`app/Soroband/UIProcess.swift`), and in M4 ran in a process of its own; every number is aggregated in SQL (`core/crates/soroband-core/src/history.rs`), long ranges read daily sums (`usage_day`, schema version 2); CSV export. On a synthetic year (Debug build): 199–244 ms from the click to the window drawn on every range, with History 50–56 MB while open in its own process; the menu bar app kept nothing of History after it closed. Budget: Debug app 0.074% CPU and 18.0 MB over 10 minutes. The blind loop and CodeRabbit's review ended with nothing left to act on (`docs/review-retros.md`). The user accepted "back under 30 MB after closing" as met, because History leaves nothing in the menu bar app; the app's own residue after the popover is M6's (Memory and performance). Its hand checklist (below) needs the user.
- M6a ([#35](https://github.com/AboulEinein/soroband/pull/35), merged, stage 1 of M6): the popover, Settings, History and the Welcome window run in a UI process, started at the first click and quit 10 minutes after its last window. Measured (Debug, external timer for open times): the menu bar process 18.2 MB at launch, 19.1 MB after every window and 19.3 MB at rest once the UI process quit (`main`: 18.3 and 55.9 MB); idle CPU 0.071% against `main`'s 0.068% in the same 10 minutes; the popover opens in 252–276 ms within the linger (`main`: 245–257 ms) and 508–784 ms after it; the UI process holds 43–65 MB during the linger. The user decided History stays in the UI process although it then reaches 74.3 MB, over the 60 MB History row, and accepted the menu bar process ending about 1 MB above launch (`plan.md`, M6). Its hand checklist (below) needs the user.
- M6b ([#36](https://github.com/AboulEinein/soroband/pull/36), merged, stage 2 of M6): the menu bar process runs AppKit alone (`app/Soroband/main.swift`), and the UI process the SwiftUI app; `MenuBarRenderer` draws the menu bar item straight into its bitmap, the same bytes as `rasterized(itemImage)`, which it drew before (`MenuBarRendererTests`). Measured (Debug, paired with `main`): the menu bar process 14.3–14.5 MB at launch and 15.7 MB after every window (`main`: 18.6–18.7 and 19.4–19.7 MB); idle CPU 0.078% against 0.078% with today's total and 0.283% against 0.326% with a live speed; popover open times as `main`'s.
- M6c ([#37](https://github.com/AboulEinein/soroband/pull/37), merged, stage 3 of M6): the closing measurements, each beside `main` before M6 (cc87d1c) in the same run (Debug unless named). The menu bar process 14.3–14.5 MB at launch and 15.7–15.9 MB after the popover, Settings and History and at rest (cc87d1c: 18.3–18.6 and 47.1–47.5 MB), so exit criterion 1 is met. Idle CPU is under 0.1% in 7 of 10 layouts (from 0.041% with the icon only to 0.078% with download and upload inline; today's total 0.071% against 0.074%) and over it with a live speed, 0.265–0.304% (cc87d1c: 0.318–0.369%), which the user accepted as an exception (2026-11-04), so exit criterion 2 is met with it. The popover opens in 166–275 ms within the linger and 513–809 ms with no UI process, against 244–254 ms on cc87d1c. History in a Release-optimized build opens as in Debug: 151–211 ms within a running UI process, 363–416 ms with none (Year), with the UI process at 55.2–56.1 MB. All numbers are in `design.md`'s budget rows and M6's section of `plan.md`.
- A Debug build's menu bar icon is orange, and `scripts/install.sh` replaces an installed app only after a yes in a terminal or with `--replace`, one run at a time (`scripts/verify/install-guard.sh` in CI).
- CodeRabbit reviewed the whole project in [#15](https://github.com/AboulEinein/soroband/pull/15) (closed, not for merge; see Gotchas). Its findings and those deferred while merging the stack are fixed, in [#23](https://github.com/AboulEinein/soroband/pull/23) to [#29](https://github.com/AboulEinein/soroband/pull/29) and their follow-ups [#30](https://github.com/AboulEinein/soroband/pull/30) to [#34](https://github.com/AboulEinein/soroband/pull/34); each is in `docs/coderabbit-findings.md`.
- [#17](https://github.com/AboulEinein/soroband/pull/17) (user feedback after the first install): Wi‑Fi known by its router takes its name once Location is allowed (re-keyed, or merged into the named network), the popover offers Location access on such a network, and the Welcome window floats at first launch until answered.
- [#18](https://github.com/AboulEinein/soroband/pull/18): the popover and History in the "Warm" direction (`docs/mockups/warm.html`), SwiftUI without Swift Charts in the popover, because `prototypes/popover-spike` measured AppKit about 3 MB lower and Charts about 6 MB higher. Idle CPU 0.093%; the popover's memory residue (+2 MB) is M6's.
- [#19](https://github.com/AboulEinein/soroband/pull/19): Settings is a sidebar window (General, Menu Bar, Networks, About); the menu bar layout is `menu_bar_readings` (up to four, in order), `menu_bar_style` (stacked, labeled, inline) and `menu_bar_scope`, applied as the user changes it. On this Mac (four displays) a live speed costs 0.38% CPU and the default layout 0.129%, both over the 0.1% budget; #18's build measured 0.150% in the same hour, so the default's cost is M6's.
- [#20](https://github.com/AboulEinein/soroband/pull/20): the user picks a network's color in Settings › Networks (`networks.color`, schema version 3, a one-way migration); History rereads the registry with each answer.
- [#21](https://github.com/AboulEinein/soroband/pull/21): `REVIEW.md` (read by the `pr-review` skill), `scripts/verify/prepush.sh`, `scripts/verify/records-lint.py`, CI checking its Xcode against `verification.md`, and review rounds that wait for CI and run on Opus.
- The installed copy in `/Applications` is #18's build, on schema version 2 with `menu_bar_top` and `menu_bar_bottom`. Installing `main` migrates the database to schema version 3, which older builds refuse; afterwards, `soroband config set menu_bar_readings download,upload` keeps the layout the user had.
- The CodeRabbit CLI is installed (`~/.local/bin/coderabbit`, signed in with an agentic API key): `coderabbit review --agent --base <base branch>` reviews a branch locally in a few minutes.
- The app is named Soroband, with the bundle identifier `io.github.abouleinein.soroband` (Debug: `.debug`), data in `~/Library/Application Support/Soroband`, and the `soroband` command.

## Next action

1. **The user's checks.** When the user asks, install `main` (`scripts/install.sh`) and set `menu_bar_readings` as above. The user then runs the hand checklists on `main` (M0, M2, M3, M4 and M6a's, below), checks by eye #17's Location grant, the popover and History on real data (#18) and Settings (#19, #20), and starts the daily-use week (M3, exit criterion 2). Each milestone is marked `done` in the ledger once its checklist has passed; issues go into Follow-ups.
2. **History's cold open.** The user decides about History opening with no UI process running: 363–416 ms in a Release-optimized build and 373–423 ms in Debug, over M4's 300 ms.
3. **M5 (Dynamic Island moments)** starts from `main` in its own worktree when the user says so, and runs the review experiment in its section of `plan.md`. The menu bar process has no SwiftUI and every window lives in the UI process, so M5 first chooses which process the island runs in. CPU and memory measurements on this Mac run one at a time, never beside another agent's, through `scripts/verify/measure-lock.py`.

### M6a hand checklist

The user runs these, on a build of `main` (`scripts/install.sh`, or `scripts/verify/run-app.sh` for a Debug build).

1. **Click.** Click the menu bar item: the popover opens under it; close it and click again within 10 minutes: it opens as fast as before.
2. **Click after the linger.** Quit the UI process (`kill <pid of the --ui process>`, as after 10 idle minutes) and click the item: the popover opens, later than in step 1. Close it, quit the UI process again, and click twice quickly: it opens, and the second click closes it, as on `main`.
3. **Toggle and click-outside.** With the popover open, click the item: it closes and stays closed. Open it and click elsewhere (the desktop, another app's window): it closes. Open it and press Escape: it closes. On `main` too, a click on the empty menu bar leaves it open, and with the item in the menu bar's overflow Soroband never comes to the front, so Escape does not reach it.
4. **Keyboard and focus.** Open the popover: it takes the keyboard (Escape works; Tab moves between its controls), and the app you were typing in gets the keyboard back when it closes. Starting the UI process never takes the keyboard from the app you are typing in. Opened from the overflow it does not take the keyboard, as on `main`.
5. **⌘,.** With the popover or History in front, ⌘, opens Soroband Settings. The gear in the popover opens Settings too; History… opens History in front.
6. **Settings reach the menu bar.** In Settings › Menu Bar pick another reading and style: the menu bar item follows each change at once. Rename a network in Settings › Networks: the popover shows the new name.
7. **The item moves.** With the popover open, change the menu bar item's width (Settings › Menu Bar, add a reading) or plug in or unplug a display: the popover stays under the item. On a Mac with several displays, click the item on each display: the popover opens on that display.
8. **It goes away.** Close every window: about 10 minutes later the `--ui` process is gone. Quit Soroband with the popover's power button: both processes are gone.

### M4 hand checklist

1. **History from the popover.** Click the menu bar item, then History…: the History window opens in front, on this month, and takes the keyboard (agents can only open it in the background).
2. **Ranges and networks by hand.** Click Day, Week, Month, Year, All Time, previous, Today and next; pick a network in the sidebar and All Networks again; hover a bar (tooltip) and a heatmap cell (its value in the card's header); click an app to see its network split.
3. **Export CSV.** Click the export button, save, and open the file: one line per hour, network and app of the range shown.
4. **It goes away.** Close the window: about 10 minutes later this build's UI process is gone (`pgrep -fl -- '--ui'` lists no process from this build's path; an installed or other worktree build may run its own).

### M0 hand checklist

Location access is shown in **Settings › General › Wi‑Fi names**: open Settings with the gear button at the bottom of the popover (click the menu bar item to open the popover). The row reads **Allowed: Wi‑Fi networks show their names** or **Not allowed: Wi‑Fi networks show as “Wi‑Fi”**.

1. **Menu bar item.** Look for the Soroband item in the menu bar: a network icon and today's total on the current network. On this Mac it sits behind the notch; hide or quit another menu bar item to make room, then confirm it shows.
2. **Location permission across a rebuild, ad hoc signature.** From the repository root:
   1. `scripts/install.sh --adhoc`, then open Settings › General › Wi‑Fi names. If it shows **Allow…**, click it, then **Allow** in the macOS prompt. If it shows **Open Location Settings…** (Location was already answered for this build), click it and turn Soroband on in System Settings › Privacy & Security › Location Services. The **Welcome to Soroband** window offers the same button only at a launch where it has never been shown and Location was never answered, which a reinstall on this Mac does not reset. Wi‑Fi names now reads **Allowed**.
   2. `scripts/install.sh --adhoc` again, then open Settings › General. Note whether Wi‑Fi names still reads **Allowed**. Expected: it does not, because an ad hoc designated requirement is the build's cdhash.
3. **Location permission across a rebuild, stable signature.**
   1. `scripts/install.sh`, then allow Location access again with **Allow…** (or **Open Location Settings…**) in Settings › General › Wi‑Fi names (the signature changed, so this one is expected).
   2. `scripts/install.sh` again, then open Settings › General. Expected: Wi‑Fi names still reads **Allowed**. If it does not, the stable signature does not carry the permission and M0's signing approach needs rework.

### M2 hand checklist

1. **Location permission, so Wi‑Fi is named.** `scripts/install.sh`, then allow Location access: **Allow Location Access** in the Welcome to Soroband window, **Allow…** under Show Wi‑Fi names in the popover, or **Allow…** in Settings › General › Wi‑Fi names, then **Allow** in the macOS prompt. Within a few seconds `soroband today` lists the Wi‑Fi under its name, and so does Settings › Networks. The "Wi-Fi" network seen before the permission is gone: its usage is under the Wi‑Fi's name.
2. **Real hotspot switch.** On Wi‑Fi, note `soroband today --json`. Join the iPhone's Personal Hotspot and run `/usr/bin/curl -o /dev/null https://speed.cloudflare.com/__down?bytes=20000000`. Rejoin the Wi‑Fi. Then check:
   - `soroband apps --network "<iPhone's name>" --json` shows curl at about 20,000,000 B.
   - `soroband today --json` lists the iPhone with `"kind": "hotspot"`.
   - The Wi‑Fi's `interfaces.rx` grew by much less than 20 MB.
3. **Wi‑Fi without its name.** With Location off for the app, join a Wi‑Fi network. Within a few seconds `soroband debug state --json` (Debug build) shows a `wifi-router:` key, never `wifi-interface:`; a second such network gets its own key.

### M3 hand checklist

1. **Install the dogfood build.** `scripts/install.sh`. The installed app replaces `/Applications/Soroband.app`; quit any other Soroband first so only one item shows.
2. **Popover by hand.** Click the menu bar item: the popover opens under it; click elsewhere and it closes; open it and click the item again: it closes and stays closed. Switch Apps and Networks, flip All networks, click the gear (Settings opens), and the power button (Soroband quits; reopen it).
3. **Settings by hand.** In Menu Bar, pick readings, reorder them, try each style and Count today on: the menu bar item follows each change, and Revert Changes restores what it showed when the pane opened. In General, set A new day starts at to another hour and back. In Networks, rename a network and press Return, and pick a color: the popover shows the new name and color, and an open History window shows them once another range or network is picked in it.
4. **Launch at login.** Turn on Open at login in Settings › General. System Settings › General › Login Items lists Soroband. Log out and in: Soroband starts. (Debug builds outside `/Applications` report "macOS cannot find this copy", so this needs the installed build.)
5. **First run.** If Location was never answered for the installed app, the Welcome window opens once at launch; Allow Location Access shows the macOS prompt.
6. **⌘,** with the popover or Settings in front opens Soroband Settings, not an empty window.
7. **The week.** Use it daily for a week; write each issue into the ledger's follow-ups.

## Decisions

| Date | Decision |
| --- | --- |
| 2026-10-26 | Distribution outside the Mac App Store, so the app is not sandboxed. |
| 2026-10-26 | Count internet traffic only: physical interfaces (Wi‑Fi, wired, cellular), local destinations excluded. |
| 2026-10-26 | History is kept forever at hourly granularity per (network, app). The daily counter resets at a chosen hour; history is untouched. |
| 2026-10-26 | Menu bar default: today's total on the current network. The menu bar item is always present and is the main element. |
| 2026-10-26 | Measurement through our own client of the kernel statistics socket (`com.apple.network.statistics`), written in Rust. `nettop` and `NetworkStatistics.framework` were measured and rejected (see design.md, Meter engine). |
| 2026-10-26 | Rust core (`soroband-core`) linked into a SwiftUI app as one process; the same core powers a `soroband` CLI. |
| 2026-10-26 | Dynamic Island shows moments only, each switchable; a master switch turns it off for a plain menu bar app. Style is seamless (default) or keep menu bar clear. |
| 2026-10-26 | Data caps and alerts are deferred past v0.1.0. |
| 2026-10-28 | The installed app is the user's daily copy and runs beside agents' Debug builds. A Debug build's menu bar icon is orange and VoiceOver calls it "Soroband Debug"; `scripts/install.sh` replaces an installed app only after a yes in a terminal, or with `--replace` when the user asked for the update. |
| 2026-10-28 | M4's "back under 30 MB after closing" is met by History's own process, which leaves nothing in the menu bar app. The menu bar app's memory after the popover and Settings is M6 (Memory and performance), before the release. |
| 2026-10-28 | The island is off on a fresh install, so the first run is a plain menu bar app; turned on, its default style is seamless. |
| 2026-10-28 | M5's round 1 compares the blind reviewer with CodeRabbit on the same commit, the blind report saved outside the repository instead of posted (`plan.md`, M5). |
| 2026-10-26 | Bundle identifier `io.github.abouleinein.soroband`. Minimum macOS 14 (Sonoma). |
| 2026-10-26 | No paid Apple Developer Program, so builds are ad-hoc signed and never notarized. Building from source on the user's Mac avoids Gatekeeper entirely, because a local build carries no quarantine flag. Homebrew casks are ruled out: since 2026-09-01 Homebrew no longer supports casks that fail Gatekeeper checks. |
| 2026-10-27 | License: MIT. |
| 2026-10-27 | Releases also ship an ad-hoc signed `Soroband.dmg` on GitHub. Without notarization, the first launch needs one Open Anyway approval in System Settings (or an agent clears the quarantine flag with the user's consent). |
| 2026-10-27 | Reviews: a fresh blind reviewer per round using the `pr-review` skill. No PR is handed over with fixes no reviewer has seen; whether another round adds value is judged, not capped, and a reassessment brings in an independent advisor agent unless the root cause is already plain (`docs/review.md`). This overrides the round caps in the user's global instructions, and their rule to stop and ask when a fixed finding returns: that case goes to the reassessment, which asks the user only when the way forward needs a decision. |
| 2026-10-28 | CodeRabbit reviews each PR once the blind loop has ended: PRs open as drafts, which it skips, and are marked ready afterwards. `.coderabbit.yaml` makes it review stacked PRs (any base) and never pause; its docstring-coverage check is off. Every finding goes into `docs/coderabbit-findings.md` with why the blind loop missed it, and a repeated miss becomes a rule (`docs/review.md`). |
| 2026-10-28 | Every PR records each review (reviewer model, findings, the origin of each) and a retro on why it took the rounds it did in `docs/review-retros.md`; an origin that recurs across PRs for the same reason becomes a rule, read at each milestone's end with the CodeRabbit log. |
| 2026-10-28 | Agents driving a Debug build keep Soroband out of the front, because the user works on this Mac while they run it: every `open` of a Debug build or a `soroband-debug://` URL passes `-g`. The popover, Settings, Welcome and History still call `NSApp.activate()`, which macOS grants only when the user has just used Soroband, so a command sent then can take the keyboard (Follow-ups). `scripts/install.sh` opens the installed app in front, because the user asked for it. |
| 2026-11-04 | M6c measures and changes no code: the CPU levers that keep the look shipped in M6b (own menu bar renderer) and #34 (coalesced settings-changed notifications); a 10 s live-speed refresh would change the readout, which the user ruled out on 2026-11-03. Layouts with a live speed are accepted as an exception to the 0.1% idle CPU budget, up to 0.32% (measured 0.27–0.30%; 0.32–0.37% before M6); every other layout meets it. |
| 2026-11-04 | M6a has no pointer prewarm: the UI process starts at the first click and lingers 10 minutes. The tracking area on the status item's button never fires on macOS 27, and a global monitor of pointer moves cost the menu bar process 14% CPU while the pointer moved (about 37 µs a move); the user chose the linger alone over that cost or a standby UI process kept at about 29 MB. |
| 2026-11-03 | M6: "split + hover prewarm". The menu bar process holds no window; the popover, Settings, History and the Welcome window run in one UI process (the same binary), started in standby when the pointer enters the menu bar item and quit 60 s after its last window closes (10 minutes from 2026-11-04, the user's choice after a real-pointer run showed cold opens at 740–800 ms). Look and feel must not change. Three stages: M6a (UI process), M6b (thin agent with no SwiftUI), M6c (closing measurements, see 2026-11-04). |
| 2026-10-28 | History runs in its own process, which quits when its window closes: AppKit, SwiftUI and Charts kept 13–40 MB in the menu bar app's process after the window closed (freed but fragmented; no API returns it). The popover starts it in standby so History opens without a launch to wait for (the user chose this over keeping History in the app and revising the criterion). |
| 2026-10-28 | The usage database keeps daily sums (`usage_day`, schema version 2) beside the hourly buckets, so a long History range reads whole UTC days from it: a year's apps read went from 125 ms to 23 ms, at about 3 KB a day more on disk. A build from before it refuses a version 2 database. |
| 2026-10-28 | History's days, weeks and months follow the calendar (local midnight), not the reset hour; a stored hour belongs to the local day, hour and weekday of its middle. History opens on this month from the popover. |
| 2026-10-27 | `scripts/install.sh` signs with a self-signed "Soroband Local Signing" identity kept in its own keychain (`~/Library/Keychains/soroband-signing.keychain-db`, random password stored in the login keychain), not in the login keychain itself: letting `codesign` use a key without a prompt needs `security set-key-partition-list`, which needs the keychain's password. `--adhoc` keeps the ad hoc route for the Location check. |
| 2026-10-27 | Universal builds need rustup (the `x86_64-apple-darwin` standard library); `scripts/build.sh --host` and `scripts/install.sh` build for this Mac only and work with Homebrew's `rust`. |
| 2026-10-27 | Debug builds use the bundle identifier `io.github.abouleinein.soroband.debug`, so a Debug build and the installed Release run side by side. |
| 2026-10-27 | Interface counters come from the interface MIB (`net.link.generic`, `IFDATA_GENERAL`): `NET_RT_IFLIST2` and `getifaddrs` give an unprivileged process 32-bit, kilobyte-rounded counters on macOS 27. |
| 2026-10-27 | The layout table lists only descriptor sizes observed on a real Mac (macOS 27 so far). Other versions run on interface totals until someone records a session there with `soroband live --for 60 --record <file>` and adds the sizes and a fixture. |
| 2026-10-27 | The app runs the engine from M1, so `budget.sh` measures the real app with its engine. |
| 2026-10-27 | Retransmitted bytes count as usage: they crossed the interface and count against a data cap. M1's attribution criterion is "within 1% of the body size plus the duplicate bytes the kernel reports for that flow (`nstat_rxduplicatebytes`)"; `soroband live --json` reports them per app as `rx_duplicate`. |
| 2026-10-27 | No header-byte estimate in v0.1. The reconciliation self-check (M3) shows the raw gap as "Other / overhead" always; it judges the ~15% gap only over windows with at least 10 MB on the interfaces in the last 10 minutes, shows "degraded" after two consecutive failing windows, and flags at once when apps sum to more than the interfaces by about 2%. M1's reconciliation criterion is judged under load; the idle gap is reported, not judged. |
| 2026-10-27 | The App-cryptex fix (Apple daemons under `/System/Volumes/Preboot/Cryptexes/App` grouped as "macOS & Services") is kept without another review round, and listed as unreviewed in Follow-ups. |
| 2026-10-27 | Network-quality cutoff for M1's two traffic criteria: a `traffic.sh` run is judged only if the kernel-reported duplicate bytes for curl's flow are under 1% of the body; runs over it are recorded, not judged; at least 3 judged runs must pass. `traffic.sh` prints which kind each run is and exits 3 for a run reported only. |
| 2026-10-27 | M2 review cap reached with two findings open; the user chose the recommended way forward: the "wait for the router" rule moves into `NetworkIdentity` as a tested function for Wi‑Fi and wired alike, a network with no stable key yet is booked to no network (id 0) instead of a shared interface key, `soroband apps --network 0` reaches those bytes, and one more blind review round runs after the fix. |
| 2026-10-27 | Debug builds keep their data in `~/Library/Application Support/Soroband Debug` (the Debug `soroband` command reads it too); release builds use `Soroband`. `SOROBAND_DATA_DIR` overrides it for the command's tests. |
| 2026-10-27 | A network's router address comes from the System Configuration store (`ARPResolvedHardwareAddress`), not the ARP table, which macOS 27 hides from non-system apps. Wi‑Fi without its name (no Location) is known by its router. |
| 2026-10-27 | Hour buckets are UTC hour starts; today starts at the local reset hour rounded down to a whole UTC hour (30 minutes early in half-hour time zones). |
| 2026-10-27 | `serde_json` reads and writes `settings.json` in the core, rather than a hand-written parser for a file users and agents edit. |
| 2026-10-27 | The menu bar item and popover are an AppKit `NSStatusItem` and `NSPopover` hosting SwiftUI, not `MenuBarExtra`: the app (and Debug builds, on an agent's command) can open the popover, and its view is released when it closes. Settings is an AppKit window for the same reason. |
| 2026-10-27 | The menu bar shows what crossed the network's interfaces (the true total), in whole megabytes below 1 GB and tenths of a gigabyte above, rounded down; a total that only grew redraws at most once a minute. Each redraw costs about 18 ms on a four-display Mac, which at every 5 s poll alone came to 0.36% CPU. Live speed redraws at every poll and says so in Settings. |
| 2026-10-27 | Self-check details beyond the 2026-10-27 rule: a window under 10 MB is not judged, breaks a run of failures and keeps a degraded verdict; a judged window that passes clears it; an overcount stays flagged until a whole window has passed without one. |
| 2026-10-27 | The `menu_bar` setting lives in the core's schema (a new `choice` kind) so `soroband config` and the Settings window change it alike. Launch at login is not a setting: macOS owns it through `SMAppService`. The first-run window is remembered in the app's `UserDefaults`. |
| 2026-10-27 | The popover has no History… button until M4 builds the History window; "+ N more apps" stands in for "+ N more in History". |
| 2026-10-27 | The project is named Soroband (soroban, the Japanese abacus, plus bandwidth) and published at `AboulEinein/soroband`, starting from one commit without the earlier development history. |
| 2026-10-27 | Replay fixtures are anonymized: every app, tool and process name outside macOS's own and the test programs is made up, keeping its place in the file system, and interface counters start at 0 or 1,000,000,000 with their changes kept. A new recording gets the same treatment before it is committed: its app paths and process names (in `P` records and in the descriptors' process-name field) replaced with made-up ones, and its interface counters rebased. |
| 2026-10-26 | Agent-friendly by design: a published install prompt any coding agent can follow, a `soroband config` command for every setting, and `--json` output on every query. |

## Open decisions

| Decision | Recommendation | Blocks |
| --- | --- | --- |
| Homebrew tap with a formula that builds from source | Decide at M7, after the DMG and install script exist | M7 |
| macOS 14–26 support: those versions run on interface totals until their descriptor sizes are recorded | Record a session on each supported version before M7 (the CI runner is macOS 26 and already exercises the fallback) | M7 |

## Follow-ups

Small items for a later nits pass.

- **Unreviewed fix.** The App-cryptex rule groups Apple daemons in the App cryptex (`/System/Volumes/Preboot/Cryptexes/App/usr/libexec/PasswordBreachAgent` and similar) as "macOS & Services". It has a test that failed before the fix, but no review round saw it.
- **Nothing keeps `rust-version` true.** `core/Cargo.toml` declares `rust-version = "1.85"`, and `cargo +1.85 test --workspace` passes, but CI builds only on `stable`, so code that needs a newer Rust passes CI unnoticed. A CI job on 1.85 would catch it.
- **`cargo mutants` timeouts.** The last run on the meter module and C API (317 mutants: 255 caught, 22 missed, 34 unviable) had 6 timeouts, all in loops that then never end:
  - `Engine::tick` → `Ok(())`;
  - `messages` `+=` → `*=`;
  - `Recorder` and `Replay` `recv` → `Ok(Some(0))` / `Ok(Some(1))` (4 mutants).
  None is on the `HDR_FLAG_CONTINUATION` check. A per-test timeout would turn them into plain kills.
- **`cargo mutants` miss.** `Meter::update` `rx_duplicate > 0` → `>=` adds zero entries to the duplicates map. No caller can see the difference, but a test asserting `Snapshot::rx_duplicates` exactly would kill it.
- **Wi‑Fi moves without a path change.** CoreWLAN's SSID-change events are not watched; a Wi‑Fi move that does not change the `NWPath` keeps the old network until the next path update.

- **Popover reads more than it shows.** The popover's summary uses `Core.history`, which also builds apps, networks, the heatmap and the busiest day it does not need, for up to 31 days, in the UI process. A bars-only read in the core would cost less; measure first with M6.
- **Test host shares the Debug data directory.** `xcodebuild test` launches the Debug app as its test host, which uses `~/Library/Application Support/Soroband Debug` like the running Debug app. Its engine books the same traffic while tests run, so the Debug totals run high, and a test that writes settings (`UsageTests`' layout change) writes the real Debug `settings.json`, then restores it. A test host could use its own data directory (`SOROBAND_DATA_DIR`).
- **Debug commands can still activate the app.** `open-popover`, `open-settings`, `open-onboarding` and `open-history` make the menu bar process yield activation to the UI process (`UIProcess.write`), which reaches `NSApp.activate()` (`PopoverController.show`, `SettingsView.swift`, `Onboarding.swift`, `HistoryWindow.swift`); macOS grants it when the user has just used Soroband. A Debug URL command could skip it.
- **History is up to a minute behind.** It reads what the engine has written (once a minute), so it can trail the popover by a minute's usage.
- **Snapshots draw the installed apps' icons.** Popover and History snapshots show Safari's, Music's, Messages' and Mail's icons from this Mac (`NSWorkspace.icon(forFile:)`), so a macOS update that changes them changes the baselines. A 1/255 change in them fits the snapshot tolerance; a redrawn icon needs a re-record, or fixed icons in the tests.
- **Snapshots on a 1x display are untested.** `Snapshot.render` draws into a fixed 2x Display P3 bitmap so a display's scale or color space cannot change the image; `renderingIgnoresTheDisplayColorSpace` checks the color space only, and no run has been made with a 1x main display.
- **The popover from the menu bar's overflow.** Opened from the overflow, the popover never makes Soroband the front app, so it takes no keyboard and Escape does not reach it. A click on the empty menu bar leaves the popover open, and two quick clicks open it and then close it. All three are as on `main` before M6 (M6a hand checklist steps 2 to 4; [#35](https://github.com/AboulEinein/soroband/pull/35)'s real-pointer comments).
- **The self-check's text says "apps".** The degraded and overcount messages (`PopoverView.swift`), the `Notice` cases in `PopoverContent.swift` and the overcount constant's doc in `ffi.rs` speak of apps alone, while the check (`check.rs`) compares apps plus local-network bytes with the interfaces.
- **Evidence branches.** `evidence/pr-35` and `evidence/m6b` hold only screenshots, linked from [#35](https://github.com/AboulEinein/soroband/pull/35)'s comments and [#36](https://github.com/AboulEinein/soroband/pull/36)'s description. Keeping or deleting them is the user's call; deleting them breaks those images.

## Gotchas

Things learned the hard way that no file or config will tell you.

**Kernel statistics socket**
- Poll replies arrive in chunks. Each chunk ends with a `SUCCESS` message; the `CONTINUATION` flag on it means "poll again with the same context". Stopping at the first `SUCCESS` loses most flows.
- Do not enable `PROVIDER_NOZERODELTAS` or `SUPPRESS_BORING_POLL`: flows idle at startup then never get a baseline and later report their whole lifetime (one Chrome connection added 22.7 MB that never crossed the interface).
- macOS 27 sends a 360-byte TCP descriptor; XNU source for macOS 26 (`bsd/net/ntstat.h`, xnu-12377) says 344. Fields up to the process name (offset 260) match. Never trust a struct size from source; check it per provider at runtime.
- The domain-name extension returns nothing to an unprivileged client.
- Userland TCP, UDP and QUIC providers returned no flows on this Mac; all traffic came through the kernel providers.
- Flow totals run below the interface counter because headers and acknowledgements are not part of a flow's bytes: 8–9% during a bulk download, about 22% on an idle minute.
- A flow's `rxbytes` includes duplicate bytes from retransmission; `nstat_counts` carries them separately at offset 112 of the update message (`nstat_rxduplicatebytes`, a `u32`). That counter misses some re-received bytes on a lossy network (likely partially overlapping segments): beyond the body and the reported duplicates, a clean 20 MB download carries about 33 KB of TLS and HTTP framing, a lossy one 59–234 KB.
- The kernel sends at most about 100 sources per chunk of a poll reply; 200 extra connections gave 2–3 chunks per poll.
- `com.apple.WebKit.Networking` flows carry the app that owns the web view as the effective pid.
- With `USE_UPDATE_FOR_ADD` the kernel still sends 32-byte `SRC_ADDED` messages (type 10001); the engine ignores them.
- GitHub's `macos-latest` runner is macOS 26, so CI runs the engine in its interface-only fallback; tests that touch the live kernel must accept both modes.

- macOS 27 hides the ARP table from non-system binaries: `sysctl` `NET_RT_FLAGS` with `RTF_LLINFO` returns nothing, and a copy of `/usr/sbin/arp` prints nothing. The router's address is in the System Configuration store (`scutil`, `show State:/Network/Service/<id>/IPv4`, key `ARPResolvedHardwareAddress`).
- A short `curl` often exits before its first poll, so the engine credits it as `process:curl` (no path). Match curl by name, not by `/usr/bin/curl`, outside `traffic.sh`.

**Interface counters**
- `NET_RT_IFLIST2` (and `getifaddrs`) give an unprivileged process counters wrapped to 32 bits and rounded to whole kilobytes on macOS 27 (en0: 3,785,922,560 against `netstat`'s 119,750,039,878). Read `net.link.generic` `IFDATA_GENERAL` per interface index instead.

**SwiftUI on macOS**
- `onHover` fires anywhere in the view's frame, not its shape. The island panel is 560 pt wide, so hover must be tested against the island's path (`onContinuousHover` plus `Path.contains`).
- Objects shared between the `MenuBarExtra`, windows and an `NSPanel` must be single instances owned outside SwiftUI state (static or injected). `@State` read in `App.init` gave the panel a different instance from the popover, so moments never reached the island.
- Transparent pixels of a borderless, non-opaque panel pass clicks through, which is what lets the island panel sit over the menu bar.

**Building**
- Homebrew's `rust` has only the host's standard library. Homebrew's `rustup` is keg-only: put `/opt/homebrew/opt/rustup/bin` first in `PATH` for universal builds.
- `xcodebuild test` launches the app as the test host, so a test run shows a second Soroband item for a moment.
- Linking the core built with Homebrew's `rust` warns that its standard library objects were built for macOS 27 while the app targets 14; rustup's standard library does not. Use rustup for anything that ships.
- `cargo-mutants` is in `~/.cargo/bin`, which is not on `PATH` by default.

**Verifying**
- Each worktree's Debug build registers the `soroband-debug://` scheme. `open "soroband-debug://…"` can launch another worktree's build, and every running Debug app answers `soroband debug state` and writes the same state file. Send URLs with `open -g -a <this build's Soroband.app>`, check the `pid` in `debug state`. `run-app.sh` stops only this worktree's `Soroband.app` and leaves other worktrees' Debug apps running. `networks.sh` ignores answers without a `network`.
- Every running Debug UI process answers `soroband debug history`, as every menu bar process answers `debug state`: with two builds running, check the answer's `pid` against the UI process's and ask again until it matches.
- With the item in macOS 27's menu bar overflow, `cliclick c:1190,11` on « expands it on the built-in display (a click at x 1180 lands on empty menu bar); each build's item frame is then in `soroband debug state` (`Item-0`). The popover timer's (`scripts/verify/clicktime.swift`) readings change between sessions: M6a's last paired run read warm medians of 250–271 ms, and M6b's, later the same day, read each warm open near 350 or 640 ms and each cold one near 520 or 800 ms, in `main` and the branch alike. Compare builds interleaved in one session, never against an older run.
- A copy of `/usr/bin/curl` outside `/usr/bin` does not run, so `traffic.sh` identifies `/usr/bin/curl` and reports a run without judging it when another curl runs at the same time (other agents on this Mac use curl).

**Working on this Mac**
- `NSWorkspace.openApplication` with `createsNewApplicationInstance` drops the arguments of a second instance of the same app; `UIProcess` starts it with `Process` instead. A UI process started with `open` gets `/dev/null` as standard input and quits at once (it quits when its input closes); start it from the menu bar process, or with a pipe held open.
- A second instance of a menu bar (`LSUIElement`) app takes activation at launch, which would take the keyboard from the user's app before anything shows. The UI process sets `.prohibited` until it shows a window.
- On macOS 27 a tracking area on an `NSStatusItem`'s button never fires, with the item in the bar or in its overflow: MenuBarAgent draws the item. `NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved)` and a listen-only `CGEventTap` do see pointer moves, but each costs the process about 37 µs a move, whatever the handler does.
- The menu bar process and the UI process run the same executable and both answer to its path: `pgrep -f "^<app>/Contents/MacOS/Soroband"` finds both; add `$` for the menu bar process alone. A `soroband-debug://` URL may reach either; the UI process hands it to the menu bar process.
- Neither process ignores `SIGPIPE`, and each writes to the other's pipe: both pipes' write ends set `F_SETNOSIGPIPE`, so a write to a process that died fails instead of killing the writer.
- `open -g <app> "soroband-debug://…"` hands the URL to the app as a document, which the app ignores; the URL needs `open -g -a <app> "soroband-debug://…"`.
- On macOS 27 status items have no window of their own: `MenuBarAgent` draws the whole menu bar, and an `NSStatusBarWindow`'s `windowNumber` (for example `4294967296`) is not a CGWindowID, so `screencapture -l` cannot capture one item. Use `screencapture -R` with the `rect` from `soroband debug state --json`, or `open -g -a <this build's Soroband.app> "soroband-debug://capture-status-item"` when the item is hidden.
- `NSImageRep.draw(in:)` composites with `.copy`; drawing a transparent bitmap over a fill needs `draw(in:from:operation: .sourceOver …)`.
- On macOS 27 every change of a status item's title redraws a "replicant" copy of the item for each display (`-[NSStatusItem _updateReplicants]`, an `NSView` cache-display each): about 18 ms of the main thread on a four-display Mac. Budget the menu bar text's change rate, not just its poll rate.
- The user works on this Mac while agents run the app, so nothing an agent does may bring Soroband to the front: an active Soroband takes the keyboard from whatever the user is typing in. `open` without `-g` does, so every `open` of a Debug build or a `soroband-debug://` URL passes `-g`. With `-g` the popover, Settings and the Welcome window still open (macOS refuses their `NSApp.activate()` unless the user has just used Soroband), and `screencapture -l` captures them; `soroband-debug://capture-window?number=<n>` renders any window in-process.
- `ImageRenderer` leaves out AppKit-backed controls (switches, segmented pickers, pop-up buttons). `app/SorobandTests/Snapshot.swift` renders snapshots through an `NSHostingView` in an offscreen window instead.
- Agents click the real pointer with `cliclick` (installed with Homebrew) and `scripts/verify/clicktime.swift`, because the user has granted T3 Code Accessibility permission; under another agent app, neither can click until that app is granted it. A pointer test moves the user's pointer, so it runs only when the user agrees, and sends keys only while the agent's own build is frontmost. Verify UI by rendering windows and capturing them with `screencapture -l <windowNumber>` (`prototypes/ui-spike/snapshot.sh` does this for the prototype). `SOROBAND_DEMO=<momentKind>` fires a moment at launch for a real-notch screenshot.
- The menu bar is crowded; a new status item sits behind the notch (the Soroband item did in M0).
- Streaming `nettop` (`-L 0`) costs more than a full CPU core; keep it out of any measurement path.

**GitHub**
- The `main` ruleset requires the Core, App and CodeRabbit checks, an up-to-date branch and resolved threads. A PR stacked on another PR's branch keeps that branch as its base; before merging the lower PR, retarget the stacked one with `gh pr edit <n> --base main`, so deleting the merged branch cannot close it.
- GitHub opens no PR between branches without a common commit, so CodeRabbit reviews the whole project through an empty commit as the base branch and, as the head, a commit with `main`'s tree whose parent is that empty commit (#15). CodeRabbit's included allowance is 10 reviews an hour.
- Force-pushing is refused for agents on this Mac; bring a branch up to date by merging `main` into it.

## Where things are

- `GLOSSARY.md`: the domain language used in code, docs and PRs, with the names to avoid.
- `docs/design.md`: product and architecture, performance budget, visual language.
- `docs/plan.md`: milestones, exit criteria, ledger, stopping rules, session prompt.
- `docs/review.md`: the review loop, the blind reviewer brief, when to run another round, and the reassessment with an advisor agent.
- `docs/coderabbit-findings.md`: every CodeRabbit finding, and why the blind loop missed the valid ones.
- `docs/review-retros.md`: each PR's reviews, what each found, and its retro.
- `docs/verification.md`: test rules, the tools for running and observing the app, per-milestone evidence.
- `docs/mockups/`: rendered UI prototype screens.
- `prototypes/`: throwaway code that settled the design; see its section in design.md.
