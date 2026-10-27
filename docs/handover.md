# Handover

The state of the project for whoever picks it up next. Read this file, then the ledger in [`plan.md`](plan.md), before starting work. At the end of a session, update **Current state**, **Next action** and the ledger.

## Current state (2026-10-27)

- The code of M0–M3 is on `main` of the public repository `AboulEinein/soroband`. It was built and reviewed in an earlier private repository under an earlier working name; that history and its pull requests are not published, so the milestones have no public PR. Each milestone's review loop ended with nothing left to act on, and CI was green.
- M0 (repository foundation): the Rust workspace, the universal XCFramework bridge, the menu bar app showing "Soroband <core version>", the build, install and verification scripts, the agent install guide and CI. Its hand checklist (below) has not been run.
- M1 (meter engine): the engine counts internet bytes per app from the kernel statistics socket; `soroband live` shows it; the app starts it at launch and reports it in `soroband debug state`. Under the network-quality cutoff, 3 judged `traffic.sh` runs passed, all at +0.16% attribution and −6.7% to −7.3% reconciliation; one lossy run over the cutoff reached +1.15%, because the kernel's duplicate counter misses some re-received bytes. Budget: engine 0.033% and 1.8 MB, Debug app 0.096% and 23.0 MB over 10 minutes. The replay fixtures are anonymized (see Decisions).
- M2 (network identity and storage): simulated switches (`scripts/verify/networks.sh`, 6 of 6 runs), the restart check and `config set` on the running app pass, and growth is measured at 27.9 KB a day. Budget: Debug app 0.059% CPU and 19.0 MB over 10 minutes. Its hand checklist (below) has not been run.
- M3 (menu bar and popover): the menu bar item (network icon and today's total, or today on all networks, live speed, icon only, through the `menu_bar` setting), the popover (network card, Apps and Networks tabs, "Other / overhead", footer), Settings (General and Networks), launch at login through `SMAppService`, the first-run Location window, and the engine self-check in `core/crates/soroband-core/src/check.rs`. The menu bar item and popover are AppKit (`NSStatusItem`, `NSPopover`) hosting SwiftUI, so Debug builds open them on command (`open-popover`, `open-settings`). Budget: Debug app 0.096% CPU and 21.0 MB over 10 minutes with the popover closed, on a busy network; 0.055% in icon-only mode. Its hand checklist and the daily-use week (exit criterion 2) need the user.
- The app is named Soroband, with the bundle identifier `io.github.abouleinein.soroband` (Debug: `.debug`), data in `~/Library/Application Support/Soroband`, and the `soroband` command. macOS treats it as a new app: it starts with empty data and asks for Location again. An install from before the rename is a separate app, with its own bundle identifier, data folder and signing keychain; nothing in this repository touches it, and it shows its own menu bar item while it runs.

## Next action

1. Run the M0 hand checklist (below). If item 3 fails, the signing approach needs rework.
2. Run the M2 hand checklist (below).
3. Run the M3 hand checklist (below) and start the daily-use week; note issues as follow-ups in the ledger.
4. After the week, mark M0–M3 `done` in the ledger for each checklist that passed. M4 and M5 can then start as two sessions in separate worktrees.

### M0 hand checklist

1. **Menu bar item.** Look for "Soroband 0.1.0" in the menu bar. On this Mac it sits behind the notch; hide or quit another menu bar item to make room, then confirm it shows.
2. **Location permission across a rebuild, ad hoc signature.** From the repository root:
   1. `scripts/install.sh --adhoc`, click **Soroband › Allow Location Access…**, click **Allow**; the menu now reads **Location Access: Allowed**.
   2. `scripts/install.sh --adhoc` again, then open the Soroband menu. Note whether it still reads **Allowed**. Expected: it does not, because an ad hoc designated requirement is the build's cdhash.
3. **Location permission across a rebuild, stable signature.**
   1. `scripts/install.sh`, then allow Location access again as in 2.1 (the signature changed, so this one is expected).
   2. `scripts/install.sh` again, then open the Soroband menu. Expected: it still reads **Allowed**. If it does not, the stable signature does not carry the permission and M0's signing approach needs rework.

### M2 hand checklist

1. **Location permission, so Wi‑Fi is named.** `scripts/install.sh`, then **Soroband › Allow Location Access…** › **Allow**. `soroband today` then lists the Wi‑Fi under its name. A network seen before the permission stays as "Wi-Fi", known by its router.
2. **Real hotspot switch.** On Wi‑Fi, note `soroband today --json`. Join the iPhone's Personal Hotspot and run `/usr/bin/curl -o /dev/null https://speed.cloudflare.com/__down?bytes=20000000`. Rejoin the Wi‑Fi. Then check:
   - `soroband apps --network "<iPhone's name>" --json` shows curl at about 20,000,000 B.
   - `soroband today --json` lists the iPhone with `"kind": "hotspot"`.
   - The Wi‑Fi's `interfaces.rx` grew by much less than 20 MB.
3. **Wi‑Fi without its name.** With Location off for the app, join a Wi‑Fi network. Within a few seconds `soroband debug state --json` (Debug build) shows a `wifi-router:` key, never `wifi-interface:`; a second such network gets its own key.

### M3 hand checklist

1. **Install the dogfood build.** `scripts/install.sh`. The installed app replaces `/Applications/Soroband.app`; quit any other Soroband first so only one item shows.
2. **Popover by hand.** Click the menu bar item: the popover opens under it; click elsewhere and it closes; open it and click the item again: it closes and stays closed. Switch Apps and Networks, flip All networks, click the gear (Settings opens), and the power button (Soroband quits; reopen it).
3. **Settings by hand.** Change Menu bar shows to each option and back; set Daily counter resets at to another hour and back; rename a network and press Return; the popover shows the new name.
4. **Launch at login.** Turn it on in Settings › General. System Settings › General › Login Items lists Soroband. Log out and in: Soroband starts. (Debug builds outside `/Applications` report "macOS cannot find this copy", so this needs the installed build.)
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
| 2026-10-26 | Bundle identifier `io.github.abouleinein.soroband`. Minimum macOS 14 (Sonoma). |
| 2026-10-26 | No paid Apple Developer Program, so builds are ad-hoc signed and never notarized. Building from source on the user's Mac avoids Gatekeeper entirely, because a local build carries no quarantine flag. Homebrew casks are ruled out: since 2026-09-01 Homebrew no longer supports casks that fail Gatekeeper checks. |
| 2026-10-27 | License: MIT. |
| 2026-10-27 | Releases also ship an ad-hoc signed `Soroband.dmg` on GitHub. Without notarization, the first launch needs one Open Anyway approval in System Settings (or an agent clears the quarantine flag with the user's consent). |
| 2026-10-27 | Reviews: a fresh blind reviewer per round using the `pr-review` skill. No PR is handed over with fixes no reviewer has seen; whether another round adds value is judged, not capped, and a reassessment brings in an independent advisor agent unless the root cause is already plain (`docs/review.md`). This overrides the round caps in the user's global instructions, and their rule to stop and ask when a fixed finding returns: that case goes to the reassessment, which asks the user only when the way forward needs a decision. |
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
| Homebrew tap with a formula that builds from source | Decide at M6, after the DMG and install script exist | M6 |
| macOS 14–26 support: those versions run on interface totals until their descriptor sizes are recorded | Record a session on each supported version before M6 (the CI runner is macOS 26 and already exercises the fallback) | M6 |
| Default island style | Seamless | M5 |
| Island on or off by default | Off, so the first run is a plain menu bar app | M5 |

## Follow-ups

Small items for a later nits pass.

- **Unreviewed fix.** The App-cryptex rule groups Apple daemons in the App cryptex (`/System/Volumes/Preboot/Cryptexes/App/usr/libexec/PasswordBreachAgent` and similar) as "macOS & Services". It has a test that failed before the fix, but no review round saw it.
- **`cargo mutants` timeouts.** The last run on the meter module and C API (317 mutants: 255 caught, 22 missed, 34 unviable) had 6 timeouts, all in loops that then never end:
  - `Engine::tick` → `Ok(())`;
  - `messages` `+=` → `*=`;
  - `Recorder` and `Replay` `recv` → `Ok(Some(0))` / `Ok(Some(1))` (4 mutants).
  None is on the `HDR_FLAG_CONTINUATION` check. A per-test timeout would turn them into plain kills.
- **`cargo mutants` miss.** `Meter::update` `rx_duplicate > 0` → `>=` adds zero entries to the duplicates map. No caller can see the difference, but a test asserting `Snapshot::rx_duplicates` exactly would kill it.
- **Registry-failure fallback is untested.** When `Core.networkChanged` fails (the database cannot record a network), `NetworkMonitor` books to no network (id 0). The branch has no unit test, because `NetworkMonitor` is bound to live system APIs; moving the decision into `NetworkIdentity` would make it testable.
- **Wi‑Fi moves without a path change.** CoreWLAN's SSID-change events are not watched; a Wi‑Fi move that does not change the `NWPath` keeps the old network until the next path update.
- **App idle CPU headroom.** The Debug app with the engine measured 0.096% of the 0.1% budget over 10 minutes on a busy network (0.023% on a quiet one). M3 adds the popover and menu bar label and must measure again; candidates if it is over: a longer poll interval while the popover is closed, or fewer allocations per poll.

- **Test host shares the Debug database.** `xcodebuild test` launches the Debug app as its test host, which starts the engine on `~/Library/Application Support/Soroband Debug` like the running Debug app, so both book the same traffic while tests run and the Debug totals run high. A test host could use its own data directory.
- **Version-named tools.** An executable named by its version (a command-line tool installed as `~/.local/share/<tool>/versions/1.4.3`) shows in the popover as "1.4.3" with a generic icon. The core could name such a tool by its parent directory.
- **Segmented control width.** The popover's Apps/Networks control keeps its natural width on macOS 27 instead of the mockup's full width.
- **App CPU headroom.** M3's Debug app measured 0.096% of the 0.1% budget on a busy network, 0.055% in icon-only mode. Live speed mode is over budget by design (it redraws every 5 s) and was not measured.

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
- Each worktree's Debug build registers the `soroband-debug://` scheme. `open "soroband-debug://…"` can launch another worktree's build, and every running Debug app answers `soroband debug state` and writes the same state file. Send URLs with `open -g -a <this build's Soroband.app>`, check the `pid` in `debug state`, and note that `run-app.sh` kills whichever Debug app answers first. `networks.sh` ignores answers without a `network`.
- A copy of `/usr/bin/curl` outside `/usr/bin` does not run, so `traffic.sh` identifies `/usr/bin/curl` and fails if another curl runs at the same time (other agents on this Mac use curl).

**Working on this Mac**
- On macOS 27 status items have no window of their own: `MenuBarAgent` draws the whole menu bar, and an `NSStatusBarWindow`'s `windowNumber` (for example `4294967296`) is not a CGWindowID, so `screencapture -l` cannot capture one item. Use `screencapture -R` with the `rect` from `soroband debug state --json`, or `open "soroband-debug://capture-status-item"` when the item is hidden.
- `NSImageRep.draw(in:)` composites with `.copy`; drawing a transparent bitmap over a fill needs `draw(in:from:operation: .sourceOver …)`.
- On macOS 27 every change of a status item's title redraws a "replicant" copy of the item for each display (`-[NSStatusItem _updateReplicants]`, an `NSView` cache-display each): about 18 ms of the main thread on a four-display Mac. Budget the menu bar text's change rate, not just its poll rate.
- An app that receives a URL with `open -g` cannot bring itself forward (`NSApp.activate()` is refused for an app the user did not just use), and a popover or window left behind other windows is never drawn: `screencapture -l` returns an empty frame. For captures, send the URL with `open -a <this build's Soroband.app>` (no `-g`); `soroband-debug://capture-window?number=<n>` renders any window in-process.
- `ImageRenderer` leaves out AppKit-backed controls (switches, segmented pickers, pop-up buttons). `app/SorobandTests/Snapshot.swift` renders snapshots through an `NSHostingView` in an offscreen window instead.
- Agents cannot click the menu bar (no Accessibility or Automation permission). Verify UI by rendering windows and capturing them with `screencapture -l <windowNumber>` (`prototypes/ui-spike/snapshot.sh` does this for the prototype). `SOROBAND_DEMO=<momentKind>` fires a moment at launch for a real-notch screenshot.
- The menu bar is crowded; a new status item sits behind the notch (the Soroband item did in M0).
- Streaming `nettop` (`-L 0`) costs more than a full CPU core; keep it out of any measurement path.

## Where things are

- `GLOSSARY.md`: the domain language used in code, docs and PRs, with the names to avoid.
- `docs/design.md`: product and architecture, performance budget, visual language.
- `docs/plan.md`: milestones, exit criteria, ledger, stopping rules, session prompt.
- `docs/review.md`: the review loop, the blind reviewer brief, when to run another round, and the reassessment with an advisor agent.
- `docs/verification.md`: test rules, the tools for running and observing the app, per-milestone evidence.
- `docs/mockups/`: rendered UI prototype screens.
- `prototypes/`: throwaway code that settled the design; see its section in design.md.
