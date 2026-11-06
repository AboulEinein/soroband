# Changelog

Every release of Soroband. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/). The release workflow publishes each version's section below as its GitHub release notes.

## [0.1.0] - Unreleased

The first release.

### Added

- **Menu bar item.** Today's usage on the network you are on, with a network icon. Up to four readings (today's total, download, upload, live download or upload speed), stacked, labeled or inline, counting the current network or every network.
- **Popover.** The current network with today's total, its download and upload, and today's hours as bars; today's apps on this network or on all networks; today per network; and "Other / overhead", the gap between what crossed the network and what apps account for.
- **History.** Day, week, month, year and all time, per network or across all of them: a usage chart, the apps with their split per network, a weekday-by-hour heatmap, and CSV export. Usage is kept forever, per hour, per network and per app.
- **Networks.** Wi‑Fi (by name once Location access is allowed, by its router until then), Ethernet (by its router) and iPhone hotspots are told apart and metered on their own. Each network can be renamed and given a color.
- **Dynamic Island moments** (off until turned on). Short updates that grow from the notch: a peek on hover, network joined and left, a hotspot meter, a data hog, background activity, large transfers and a daily recap. Each can be switched off, and alerts become notifications while the island is off.
- **The `soroband` command.** `soroband today`, `soroband apps` and `soroband live` print usage, with `--json` for scripts and agents; `soroband config` lists and changes every setting, and the running app applies a change at once; `soroband update` installs the newest release.
- **Install guides for coding agents:** [`docs/agents/install.md`](docs/agents/install.md) and [`docs/agents/configure.md`](docs/agents/configure.md).

### Known limitations

- **Per-app counting needs macOS 27.** Soroband reads the kernel's per-connection records only in the layouts it has seen on a real Mac. On macOS 14 to 26 it counts each network's total without the per-app breakdown, and the popover says so.
- **Not notarized.** Soroband is signed ad hoc, without a paid Apple Developer account, so macOS blocks the first launch of the downloaded app once: open System Settings › Privacy & Security and click Open Anyway. An app built from source opens without it.
- **Location access after an update.** Each release is signed ad hoc, so macOS treats an updated app as a new one. Whether it asks for Location access again after `soroband update` is checked before this release is published, and stated here.

[0.1.0]: https://github.com/AboulEinein/soroband/releases/tag/v0.1.0
