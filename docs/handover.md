# Handover

The state of the project for whoever picks it up next. Read this file, then the ledger in [`plan.md`](plan.md), before starting work. At the end of a session, update **Current state**, **Next action** and the ledger.

## Current state (2026-10-27)

- M0 (repository foundation) is blocked on the hand checklist below; its code is complete in [PR #3](https://github.com/AboulEinein/soroband/pull/3) on branch `m0-foundation`, CI is green, and the review loop ran its 3 rounds (6 Low findings, all fixed). The Rust workspace, the universal XCFramework bridge, the menu bar app showing "Soroband <core version>", the build, install and verification scripts, the agent install guide and CI are in place.
- M1 (meter engine) is in review in [PR #4](https://github.com/AboulEinein/soroband/pull/4) on branch `m1-meter-engine`, stacked on `m0-foundation`. The engine counts internet bytes per app from the kernel statistics socket; `soroband live` shows it; the app starts it at launch and reports it in `soroband debug state`. After the review retrospective, the user approved the failure-path fix (`tests/faults.rs`), decided both exit-criterion questions, and allowed one more blind review round. That round found one Low issue: Apple daemons in the App cryptex were named one by one. It is fixed, and the user kept the fix without another round (listed in Follow-ups). The user also set a network-quality cutoff for the traffic criteria; under it, 3 judged `traffic.sh` runs pass. CI is green.
- Measured under the cutoff: 3 judged `traffic.sh` runs, all at +0.16% attribution and −6.7% to −7.3% reconciliation. Lossy runs over the cutoff (8 so far) are reported in the PR; one of them reached +1.15%, because the kernel's duplicate counter misses some re-received bytes. Budget: engine 0.033% and 1.8 MB, Debug app 0.096% and 23.0 MB over 10 minutes, within budget but with little CPU headroom on a busy network.

## Next action

1. Run the M0 hand checklist (below) and report the results in PR #3. If item 3 passes, M0 can merge; if it fails, the signing approach needs rework before M1 merges.
2. Review PR #4, then merge PR #3 and PR #4 in order.
3. Start M2 with the session prompt in [`plan.md`](plan.md#session-prompt), on `m2-networks-storage` from `m1-meter-engine` if M1 is not merged yet.

### M0 hand checklist

1. **Menu bar item.** Look for "Soroband 0.1.0" in the menu bar. On this Mac it sits behind the notch; hide or quit another menu bar item to make room, then confirm it shows.
2. **Location permission across a rebuild, ad hoc signature.** From the repository root:
   1. `scripts/install.sh --adhoc`, click **Soroband › Allow Location Access…**, click **Allow**; the menu now reads **Location Access: Allowed**.
   2. `scripts/install.sh --adhoc` again, then open the Soroband menu. Note whether it still reads **Allowed**. Expected: it does not, because an ad hoc designated requirement is the build's cdhash.
3. **Location permission across a rebuild, stable signature.**
   1. `scripts/install.sh`, then allow Location access again as in 2.1 (the signature changed, so this one is expected).
   2. `scripts/install.sh` again, then open the Soroband menu. Expected: it still reads **Allowed**. If it does not, the stable signature does not carry the permission and M0's signing approach needs rework.

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
| 2026-10-27 | The project is named Soroband (soroban, the Japanese abacus, plus bandwidth) and published at `AboulEinein/soroband`, without the earlier development history. |
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
- **App idle CPU headroom.** The Debug app with the engine measured 0.096% of the 0.1% budget over 10 minutes on a busy network (0.023% on a quiet one). M3 adds the popover and menu bar label and must measure again; candidates if it is over: a longer poll interval while the popover is closed, or fewer allocations per poll.

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
- A copy of `/usr/bin/curl` outside `/usr/bin` does not run, so `traffic.sh` identifies `/usr/bin/curl` and fails if another curl runs at the same time (other agents on this Mac use curl).

**Working on this Mac**
- On macOS 27 status items have no window of their own: `MenuBarAgent` draws the whole menu bar, and an `NSStatusBarWindow`'s `windowNumber` (for example `4294967296`) is not a CGWindowID, so `screencapture -l` cannot capture one item. Use `screencapture -R` with the `rect` from `soroband debug state --json`, or `open "soroband-debug://capture-status-item"` when the item is hidden.
- `NSImageRep.draw(in:)` composites with `.copy`; drawing a transparent bitmap over a fill needs `draw(in:from:operation: .sourceOver …)`.
- Agents cannot click the menu bar (no Accessibility or Automation permission). Verify UI by rendering windows and capturing them with `screencapture -l <windowNumber>` (`prototypes/ui-spike/snapshot.sh` does this for the prototype). `SOROBAND_DEMO=<momentKind>` fires a moment at launch for a real-notch screenshot.
- The menu bar is crowded; a new status item sits behind the notch (the Soroband item did in M0).
- Streaming `nettop` (`-L 0`) costs more than a full CPU core; keep it out of any measurement path.

## Where things are

- `GLOSSARY.md`: the domain language used in code, docs and PRs, with the names to avoid.
- `docs/design.md`: product and architecture, performance budget, visual language.
- `docs/plan.md`: milestones, exit criteria, ledger, stopping rules, session prompt.
- `docs/review.md`: the review loop, the blind reviewer brief, the reassessment when the cap is hit.
- `docs/verification.md`: test rules, the tools for running and observing the app, per-milestone evidence.
- `docs/mockups/`: rendered UI prototype screens.
- `prototypes/`: throwaway code that settled the design; see its section in design.md.
