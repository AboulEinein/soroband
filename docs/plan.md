# Plan

Roadmap from prototypes to the first public release. Each milestone is one branch and one pull request, merged into `main` after review. The ledger is the single record of progress: update it when a milestone changes state.

## Ledger

| ID | Milestone | Phase | Status | PR |
| --- | --- | --- | --- | --- |
| P0 | Research and prototypes | 0 | done | – |
| M0 | Repository foundation | 1 | blocked (hand checklist: menu bar item on screen, Location across a rebuild) | [#3](https://github.com/AboulEinein/soroband/pull/3) |
| M1 | Meter engine | 1 | in review | [#4](https://github.com/AboulEinein/soroband/pull/4) |
| M2 | Network identity and storage | 1 | blocked (hand checklist: Location, real hotspot switch, Wi‑Fi without its name) | [#5](https://github.com/AboulEinein/soroband/pull/5) |
| M3 | Menu bar and popover (first dogfood build) | 1 | blocked (hand checklist and daily-use week) | [#6](https://github.com/AboulEinein/soroband/pull/6) |
| M4 | History window | 2 | planned | – |
| M5 | Dynamic Island moments | 2 | planned | – |
| M6 | Release v0.1.0 | 3 | planned | – |

M0–M3 are stacked pull requests, each against the previous milestone's branch, merged in order once their checklists pass. The checklists are in [`handover.md`](handover.md#next-action).

Statuses: `planned`, `in progress`, `in review`, `done`, `blocked (<reason>)`.

## Phases

1. **Foundation and first features (M0–M3).** Ends with a build you run every day: real per-app, per-network counting, stored forever, shown in the menu bar and popover.
2. **History and island (M4–M5).** M4 and M5 touch separate parts of the app and can run in parallel once M3 is merged.
3. **Release (M6).** Release workflow with a DMG, install prompt for agents.

## Milestones

Every milestone ends on its exit criteria. A milestone is `done` only when each criterion is checked with evidence in the PR description, as [`verification.md`](verification.md) describes for that milestone.

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
- Network-quality cutoff for the two criteria above: a `traffic.sh` run is judged only if the kernel-reported duplicate bytes for curl's flow are under 1% of the body (200,000 bytes for the 20 MB file). Runs over the cutoff are recorded in the PR but not judged. At least 3 judged runs must pass.
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
- Menu bar item: network icon and today's total on the current network; other display modes in Settings.
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
- Memory ≤ 60 MB while open, back under 30 MB after closing.

### M5: Dynamic Island moments

Deliverables:
- Island panel with notch geometry, the seamless and keep-menu-bar-clear styles, hover tested against the island's outline.
- Moment queue with priorities and durations.
- Triggers from real events: network joined and left, hotspot meter, peek on hover, data hog, background activity (frontmost app from `NSWorkspace`), large transfer.
- Island settings tab, notification fallback, full-screen detection, display choice, "Pause until off hotspot".

Exit criteria:
- Each moment fires from real traffic in a scripted test (for example, a large `curl` download fires the large-transfer moment).
- No CPU cost while no moment is showing.

### M6: Release v0.1.0

Deliverables:
- A GitHub Actions release workflow on a version tag: CI checks, then a universal (arm64 + x86_64) ad-hoc signed build packaged as `Soroband.dmg` (app plus `soroband` command), attached to a GitHub release with notes and a SHA-256 checksum.
- `docs/agents/install.md` covers both routes: download the DMG, verify the checksum, copy to `/Applications`, clear the quarantine flag with the user's consent (`xattr -dr com.apple.quarantine`), link the `soroband` command; or build from source with `scripts/install.sh`. Update path: `soroband update` downloads and installs the newest release the same way.
- README screenshots from the real app, `CHANGELOG.md`.

Exit criteria:
- On a second Mac user account, the DMG installs after one Open Anyway approval and the app runs.
- A coding agent following the README's install prompt ends with Soroband running, by either route.
- Whether macOS asks for Location permission again after an update is tested and written in the release notes.

## Later

Data caps and alerts, per-domain usage (DNS correlation), desktop widget, CSV and JSON export of any range, localization.

## How the work runs

- **One milestone per session.** Start each session with the prompt below. A fresh session per milestone keeps context small; the handover carries what matters across.
- **Orchestrator plus agents inside a session.** The session lead plans the milestone, does the coupled work itself, and spawns agents only for independent tracks (for example, in M4 the chart views and the SQL queries), for the blind reviewer of each round, for the direct review of comment or wording fixes, and for an advisor agent on a review judgment or reassessment.
- **Parallel sessions only after M3.** M0–M3 change shared interfaces (the bridge, the schema), so they run in order. M4 and M5 can run as two sessions in separate worktrees.

Estimated sessions: M0 1, M1 1–2, M2 1, M3 1–2, M4 1, M5 2, M6 1, so about 9 sessions. Calendar time depends mostly on review turnaround and the M3 daily-use week.

### Unattended runs

Milestones can run overnight as a chain, one fresh thread per milestone, started by a conductor thread that writes no code.

- **Stacked branches.** Nothing is merged without the user, so each milestone branches from the previous milestone's branch and opens its PR against it: `m<n>-<name>` from the branch of milestone n−1, the first from `main`. The user merges them in order; GitHub retargets each PR to `main` as its base merges.
- **When the chain continues.** The next milestone starts only if the previous one ended `in review`, or `blocked` solely on a hand-run checklist (a permission prompt, a real hotspot, the daily-use week). Anything else stops the chain: a decision needed, repeated failures, red CI.
- **The conductor checks the review judgment.** Each milestone thread runs its own review loop as [`review.md`](review.md#rounds) describes, then CodeRabbit's review ([`review.md`](review.md#coderabbit)). When a thread stops, the conductor checks its review record against that loop and may send work back to the same thread. It asks the user only when the way forward needs a decision.
- **Hand-run checklists** collect in each PR and in the handover; the user runs them in the morning, in milestone order.

### When a session stops

A session stops in exactly one of two states, and never starts the next milestone.

- **In review.** Every exit criterion is checked with evidence in an open PR, CI is green, and the review in [`review.md`](review.md), the blind loop and then CodeRabbit's review, has ended with nothing left to act on. The ledger says `in review`.
- **Blocked.** The work needs a person (a permission prompt, a real hotspot, a decision), the same problem has failed three fixes, the work outgrows the milestone, or a review reassessment needs a decision (see [`review.md`](review.md#reassess-instead-of-another-round)), or CodeRabbit did not review (see [`review.md`](review.md#coderabbit)). The ledger says `blocked (<reason>)` and the handover lists exactly what is needed.

In both cases, update **Current state** and **Next action** in the handover, and add any new gotcha, before the final report. The user merges the PR; the next session marks the milestone `done` after checking the merge.

### Session prompt

Paste this into a new session, with the milestone ID and branch filled in:

```text
Run milestone M4 of Soroband on branch m4-history, created from main, with its PR against main.

Before anything else, read AGENTS.md, docs/handover.md, docs/plan.md, docs/verification.md and docs/review.md.

Deliver everything listed for the milestone in plan.md. Verify it the way verification.md describes for this milestone: tests that go red when the behavior breaks, then build and run the real app and capture evidence. Nothing counts as done on reasoning alone.

Open the PR as a draft and run the review loop in review.md: state the planned rounds, use a fresh blind reviewer with the pr-review skill (--no-story --submit, so its comments are posted on the PR) each round, never stop with fixes no reviewer has seen, and reassess with an advisor agent as review.md describes. When the blind loop ends, mark the PR ready and handle CodeRabbit's review as review.md describes, logging every finding in docs/coderabbit-findings.md. Start the PR's entry in docs/review-retros.md before round 1, add a row for every blind round and direct review, commit CodeRabbit's rows and the retro as review.md describes, and if you stop blocked, commit every record noted so far with the retro. Stop as plan.md's "When a session stops" says: in review, or blocked. Update the ledger and the handover before you stop, in the commit that carries the review's records.

Report: the PR link, each exit criterion with its evidence, any checklist I need to run by hand, and anything blocked with what you need from me.
```
