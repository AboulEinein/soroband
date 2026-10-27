# Handover

The state of the project for whoever picks it up next. Read this file, then the ledger in [`plan.md`](plan.md), before starting work. At the end of a session, update **Current state**, **Next action** and the ledger.

## Current state (2026-10-26)

- Phase 0 is done: research, design, and three prototypes. No product code exists yet; `app/` and `core/` hold only READMEs.
- The design is settled in [`design.md`](design.md) and the mockups in [`mockups/`](mockups/).
- The initial commit on `main` holds the prototypes, docs and repository files.

## Next action

1. Start M0 with the session prompt in [`plan.md`](plan.md#session-prompt).

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

**Working on this Mac**
- Agents cannot click the menu bar (no Accessibility or Automation permission). Verify UI by rendering windows: `prototypes/ui-spike/snapshot.sh` opens each view as a window and captures it with `screencapture -l <windowNumber>`. `SOROBAND_DEMO=<momentKind>` fires a moment at launch for a real-notch screenshot.
- The menu bar is crowded; a new status item may sit behind the notch.
- Streaming `nettop` (`-L 0`) costs more than a full CPU core; keep it out of any measurement path.

## Where things are

- `GLOSSARY.md`: the domain language used in code, docs and PRs, with the names to avoid.
- `docs/design.md`: product and architecture, performance budget, visual language.
- `docs/plan.md`: milestones, exit criteria, ledger, stopping rules, session prompt.
- `docs/review.md`: the review loop, the blind reviewer brief, when to run another round, and the reassessment with an advisor agent.
- `docs/verification.md`: test rules, the tools for running and observing the app, per-milestone evidence.
- `docs/mockups/`: rendered UI prototype screens.
- `prototypes/`: throwaway code that settled the design; see its section in design.md.
