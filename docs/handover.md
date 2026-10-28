# Handover

The state of the project for whoever picks it up next. Read this file, then the ledger in [`plan.md`](plan.md), before starting work. At the end of a session, update **Current state**, **Next action** and the ledger.

## Current state (2026-10-27)

- M0 (repository foundation) is blocked on the hand checklist below; its code is complete in [PR #3](https://github.com/AboulEinein/soroband/pull/3) on branch `m0-foundation`, CI is green, and the review loop ran its 3 rounds (6 Low findings, all fixed). The Rust workspace, the universal XCFramework bridge, the menu bar app showing "Soroband <core version>", the build, install and verification scripts, the agent install guide and CI are in place.
- Open until the user runs the checklist below: whether the Location permission survives a rebuild, and seeing the menu bar item on screen (on this Mac it is hidden behind the notch).

## Next action

1. Run the M0 hand checklist (below) and report the results in PR #3. If item 3 passes, M0 can merge; if it fails, the signing approach needs rework before M1.
2. Review and merge PR #3, then start M1 with the session prompt in [`plan.md`](plan.md#session-prompt), on `m1-meter-engine` from `m0-foundation` if M0 is not merged yet.

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
| 2026-10-27 | The project is named Soroband (soroban, the Japanese abacus, plus bandwidth) and published at `AboulEinein/soroband`, without the earlier development history. |
| 2026-10-26 | Agent-friendly by design: a published install prompt any coding agent can follow, a `soroband config` command for every setting, and `--json` output on every query. |

## Open decisions

| Decision | Recommendation | Blocks |
| --- | --- | --- |
| Homebrew tap with a formula that builds from source | Decide at M6, after the DMG and install script exist | M6 |
| Default island style | Seamless | M5 |
| Island on or off by default | Off, so the first run is a plain menu bar app | M5 |

## Gotchas

Things learned the hard way that no file or config will tell you.

**Kernel statistics socket**
- Poll replies arrive in chunks. Each chunk ends with a `SUCCESS` message; the `CONTINUATION` flag on it means "poll again with the same context". Stopping at the first `SUCCESS` loses most flows.
- Do not enable `PROVIDER_NOZERODELTAS` or `SUPPRESS_BORING_POLL`: flows idle at startup then never get a baseline and later report their whole lifetime (one Chrome connection added 22.7 MB that never crossed the interface).
- macOS 27 sends a 360-byte TCP descriptor; XNU source for macOS 26 (`bsd/net/ntstat.h`, xnu-12377) says 344. Fields up to the process name (offset 260) match. Never trust a struct size from source; check it per provider at runtime.
- The domain-name extension returns nothing to an unprivileged client.
- Userland TCP, UDP and QUIC providers returned no flows on this Mac; all traffic came through the kernel providers.
- Flow totals run about 5% below the interface counter because headers and acknowledgements are not part of a flow's bytes.

**SwiftUI on macOS**
- `onHover` fires anywhere in the view's frame, not its shape. The island panel is 560 pt wide, so hover must be tested against the island's path (`onContinuousHover` plus `Path.contains`).
- Objects shared between the `MenuBarExtra`, windows and an `NSPanel` must be single instances owned outside SwiftUI state (static or injected). `@State` read in `App.init` gave the panel a different instance from the popover, so moments never reached the island.
- Transparent pixels of a borderless, non-opaque panel pass clicks through, which is what lets the island panel sit over the menu bar.

**Building**
- Homebrew's `rust` has only the host's standard library. Homebrew's `rustup` is keg-only: put `/opt/homebrew/opt/rustup/bin` first in `PATH` for universal builds.
- `xcodebuild test` launches the app as the test host, so a test run shows a second Soroband item for a moment.

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
