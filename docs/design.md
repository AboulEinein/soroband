# Soroband design

A macOS menu bar app that meters network usage per network (Wi‑Fi, Ethernet, hotspot) and per app, and keeps every day of history.

Screenshots of the UI prototype: [popover](mockups/popover.png), [history](mockups/history.png), [history with an app expanded](mockups/history-expanded.png), [settings](mockups/settings.png).

## Reference apps

| App | Per network | Per app | History | How it counts |
| --- | --- | --- | --- | --- |
| Bandwidth+ | No | No | Totals since reset | Interface counters, sandboxed App Store app |
| Hotspot Meter | Yes: SSID or tethered interface, first/last seen | No | Per-network totals, session counter | `NWPathMonitor` + interface byte counters; Location permission for SSID; sandboxed, App Store |
| TripMode | Profiles per network | Yes, live and historical | Per app, per session/day/month | Network Extension filter; also blocks apps |
| Bytetally | Pro: filter history by Wi‑Fi, per-network caps | Yes | Pro: any range, heatmap, CSV/JSON export | Sandboxed, per-app attribution incl. VPN |
| NetPulse | No | Yes, top 10 | Daily trends | Not documented |

Hotspot Meter keeps a record per network, can start tracking on its own when a hotspot joins, and alerts per session and per network. It meters the interface, so it cannot say which app used the data. That gap is the point of Soroband.

## Decisions

- Distribution: built from source on the user's Mac (ad-hoc signed, no paid Apple account), outside the App Store, so no sandbox.
- Menu bar default: today on the current network.
- Data caps and alerts: later, not v1.
- Only internet traffic counts. Flows to local addresses (LAN, link-local, multicast, loopback) are excluded.

## How it works

1. **Network identity.** `NWPathMonitor` reports interface changes and `isExpensive` (set for iPhone Personal Hotspot); the first physical interface of the path (Wi‑Fi, wired, cellular) carries the traffic, after any VPN tunnel. Wi‑Fi is known by its name from CoreWLAN `CWWiFiClient` (needs Location permission), or by its router's hardware address while the name is hidden. When the name becomes readable, the network known by that router becomes the named one: it takes the name's key, keeping its id and history, or, if the named network already exists, its usage is added into it and it leaves the registry. The name is retried each second for 10 s after Location access is granted, because macOS can take seconds to reveal it. Ethernet is known by the router's hardware address, so "Desk Dock" and "Office LAN" stay separate. Until the router of such a network is resolved, its usage is booked to no network ("Unknown network", id 0) rather than to a key two networks would share; the app looks again every second, then every 30 s, until the path changes. The router's address comes from the IPv4 state macOS publishes per network service (`ARPResolvedHardwareAddress` under `State:/Network/Service/<id>/IPv4` in the System Configuration dynamic store): the kernel's ARP table is hidden from apps outside the system on macOS 27. Hotspot = expensive path, or a network the user marks as hotspot. The registry lives in the core's database: each network has a stable id, the key it was identified by, and a name and kind the user can change; a known network keeps its edits. Event-driven: nothing polls while an identified network is stable; only a network still waiting for its router (one without IPv4, for example) is looked at again every 30 s.
2. **Per-app counting: our own meter engine.** A small Rust core talks straight to the kernel's network statistics control socket (`com.apple.network.statistics`, protocol in XNU's open source `bsd/net/ntstat.h`). No `nettop`, no private framework. See "Meter engine" below.
3. **Ground truth.** The interface MIB's 64-bit byte counters (`net.link.generic`, `IFDATA_GENERAL`) give the true total per network. `getifaddrs` and the routing socket's `NET_RT_IFLIST2` are not usable: on macOS 27 an unprivileged process gets counters wrapped to 32 bits and rounded to whole kilobytes. Any gap between that and the app sum shows as "Other", so totals always match what the network saw.
4. **Storage.** SQLite (system `libsqlite3`, no ORM), WAL mode, `usage.sqlite` in `~/Library/Application Support/Soroband` (Debug builds: `Soroband Debug`). One row per (hour, network, app) with bytes down/up, primary key on those three columns, app names in their own table; the same bytes per (UTC day, network, app) in `usage_day`, written in the same transaction, so History reads whole days from it; interface bytes per (hour, network) for the reconciliation and for Macs on interface totals only. Hours are UTC hour starts. Each poll's new bytes go to the hour the poll ran in, on the network current then; the in-memory bucket is written once a minute, on a network change, at the start of a new day and on quit. Kept forever. Measured with `cargo run --release --example db-growth`: 32–36 bytes a row, 30.9 KB a day (11.3 MB a year) with 40 apps an hour on 2 networks, 12.8 KB a day (4.7 MB a year) with 15 apps an hour on one.
5. **Daily reset.** The menu bar counter covers "today" from a configurable reset hour (default midnight, local time). Nothing is deleted at reset. Today's start is rounded down to a whole UTC hour so it falls on a bucket boundary; in a time zone with a half-hour offset, today starts 30 minutes before the reset hour.
6. **Settings.** The core owns one schema (key, type, default, description) and stores values in `settings.json` next to the database. `soroband config set` validates and saves a value, then posts the Darwin notification `<bundle id>.settings-changed`; the app tells the core to reread the file, so changes apply without a restart.

## Meter engine

**Measured on this Mac** (`prototypes/meter-probe`, 40 s window, 5 s polls, ~150 live connections, a known 20 MB `curl` download):

| Approach | CPU (average) | Memory | Accuracy |
| --- | --- | --- | --- |
| `nettop` streaming (`-L 0`) | 137% (42 s CPU in 31 s) | 4 MB + parsing | n/a |
| `NetworkStatistics.framework` (`prototypes/nstat-probe/nstat-probe.m`) | 0.31% | 7.8 MB | not validated |
| **Own kernel-socket client, Rust** (`prototypes/meter-probe`) | **0.035–0.058%** | **2.0 MB**, 353 KB binary | `curl` 20.03 MB of 20.00; all apps 30.31 MB vs 31.89 MB on the interface (the gap is packet headers, which flows don't carry) |
| **`soroband-core` engine** (M1, `soroband live`, 10 min idle, 5 s polls, 70–95 flows) | **0.017–0.033%** | **1.7–1.8 MB** footprint, 386 KB binary | `curl` 20,032,868 B for a 20,000,000 B body (+0.16%); all apps 8% below the interfaces over 60 s with the download, 22% below on an idle minute |
| The Debug app running the engine (M1, 10 min idle) | 0.023–0.096% | 17.0–23.0 MB footprint | Same engine. Engine cost rises with the Mac's network activity; over the same 2 minutes the Debug app took 0.050%, `soroband live` 0.042% and the M0 app without an engine 0.017% |

How it works:

- One `PF_SYSTEM` control socket. Subscribe to all TCP and UDP flows with a kernel-side filter that accepts only Wi‑Fi, wired and cellular interfaces, so loopback, AWDL and VPN tunnels never reach us. Each flow's own `IS_LOCAL` property drops LAN traffic.
- Every 5 s send one poll; the kernel replies with byte counters plus process name, pid and the effective pid in chunks. Book the delta per flow to (current network, app). Closed flows send a final update, so short connections are not lost.
- **Delegated traffic:** the kernel reports the effective pid when a daemon (`nsurlsessiond`, App Store, `softwareupdated`) or WebKit's networking process moves data for an app, so a background download or a web view's page is credited to the app it serves.
- **Attribution:** a process inside an `.app` bundle is credited to the outermost bundle (helpers, XPC services and login items roll up). Processes under `/System/Library/`, `/System/iOSSupport/`, `/usr/libexec/`, `/usr/sbin/`, `/sbin/` and `/Library/Apple/` (also inside the OS and App cryptexes) are "macOS & Services". Any other executable is a command-line tool, named by its file name (`curl`). A process that exited before it was looked up keeps the name the kernel reported.
- **Retransmissions count.** A flow's received bytes include duplicates from retransmission; they crossed the interface, so they are usage. The kernel reports the duplicates it recognised per flow (`nstat_rxduplicatebytes`), and `soroband live --json` shows them per app as `rx_duplicate`. On a lossy Wi‑Fi a 20 MB download carried up to 568 KB of them (+2.8%). That counter does not cover every re-received byte: on lossy downloads the excess beyond body plus reported duplicates grew from about 33 KB (TLS and HTTP framing on a clean run) to between 59 KB and 234 KB.
- **Exact network switches:** on a path-change event the engine polls immediately and closes the bucket, so bytes land on the network they used, not the next one.
- **Self-check:** the app sum is reconciled against the interface counter all the time (`core/crates/soroband-core/src/check.rs`). Flows carry no headers, so the app sum runs 8–10% below the interfaces during a bulk download and about 22% below on an idle minute, where headers, acknowledgements and link-local chatter are a large share of small packets. v0.1 makes no header-byte estimate. The rule:
  - The raw gap always shows as "Other / overhead" in the popover's Apps tab, with no verdict.
  - The gap is judged over consecutive 10-minute windows, and only in a window with at least 10 MB on the interfaces. Such a window fails when the apps cover less than 85% of the interface bytes.
  - "Degraded" shows after two failing windows in a row, and clears at the next judged window that passes. A window under 10 MB is not judged: it breaks a run of failures but keeps a degraded verdict.
  - Apps summing to more than the interfaces by over 2% flags at once, whatever the volume, because flows never carry more than crossed the wire. The flag stays until a whole window has passed without it.
  - On interface totals only (an unknown descriptor layout) nothing is judged; the popover says per-app counting is off.

Risks and how the design handles them:

- **Layout drift.** The protocol is versioned only by struct size. macOS 27 sends a 360-byte TCP descriptor; the newest published XNU (macOS 26) says 344. The engine reads only stable leading fields (counters, pid, epid, name, interface properties), checks each descriptor's size against a table of sizes observed per macOS version and provider, and falls back to interface-only totals (step 3) when a size is unknown, reporting why. Only macOS 27's kernel TCP and UDP providers are in the table so far (the userland providers sent nothing there); each version added needs a recording from a Mac running it. CI replays the recorded sessions in `core/crates/soroband-core/tests/fixtures`.
- **Idle-flow baseline.** The kernel can skip unchanged flows (`NOZERODELTAS`, `SUPPRESS_BORING_POLL`), but then a flow idle at startup later reports its whole lifetime. Seen in the probe: one Chrome connection added 22.7 MB that never crossed the interface. The engine polls every flow; at ~150 flows this costs 0.058% CPU.
- **Domains.** The kernel has a per-flow domain extension, but it returned nothing to an unprivileged client. Per-domain usage is out unless we add DNS correlation later.

Shape: Rust crate `soroband-core` (socket client, aggregation, SQLite, settings) exposed through a small C API to the SwiftUI app, in one process. A network change from the app wakes the engine thread through a pipe, so it polls at once and books what moved so far to the previous network before switching. The same crate gives a `soroband` CLI (`soroband today`, `soroband apps --network Office`, `soroband config`), installed next to the app.

## Performance budget

| Measure | Budget | Evidence |
| --- | --- | --- |
| CPU, idle, popover closed | ≤ 0.1% average | Rust probe: 0.035–0.058% at 5 s polls, ~150 flows; `soroband-core` engine 0.017–0.033%, Debug app with engine 0.023–0.096% (M1); Debug app with menu bar total and popover 0.096% on a busy network (71 MB in 10 min), 0.055% icon only (M3) |
| Memory, popover closed | ≤ 25 MB footprint | Bare SwiftUI `MenuBarExtra` app: 16 MB; Rust engine: 1.7–1.8 MB; Debug app with engine: 17.0–23.0 MB (M1); with menu bar item and popover: 21.0 MB (M3), measured before the popover first opened; once it has opened and closed, 37–45 MB, which AppKit and SwiftUI keep (M4, a follow-up in the handover) |
| Memory, History window open | ≤ 60 MB, back under 30 MB after closing | History process 50–56 MB on every range of a synthetic year; its standby 22 MB while the popover is open; the menu bar app keeps nothing of History, because the History process quits when its window closes (M4, Debug build) |
| History opens | Under 300 ms with a year of data | 199–244 ms from the click to the window drawn with its data, every range, Debug build (M4) |
| Disk writes | One SQLite transaction per minute | Design |
| Energy | No timers firing more than every 5 s when the popover is closed | Design |

How the app stays inside the budget:

- **Engine:** one socket, one thread blocked in `poll(2)` between 5 s polls. Deltas accumulate in a map keyed by (network, app), about 50 entries. A flow's state is two counters and a name, dropped when the flow closes.
- **Writes:** the in-memory hour bucket flushes to SQLite once a minute, on network change, and on quit.
- **Menu bar label:** an AppKit status item, updated from the engine's poll callback. It redraws only when the displayed text changes, and each redraw costs about 18 ms of the main thread on a Mac with four displays (macOS redraws a copy of the item for each), which at every 5 s poll alone is 0.36% CPU. So a total shows whole megabytes below 1 GB and tenths of a gigabyte above, and a total that only grew redraws at most once a minute; a new network, a mode change or a total that went down at the reset hour redraws at once. The live speed mode redraws at every poll and is the costly one.
- **Popover:** reads today's in-memory aggregates, never SQLite; only the network list (names, kinds and when each was last used) is read from the database, once when the popover opens. While it is open the engine polls every 1 s for live speed and publishes today's per-app list; when it closes, polls return to 5 s, the list stops, and the popover's view and app icons are released.
- **History window:** its own process, a second instance of Soroband.app started with `--history` (`app/Soroband/HistoryProcess.swift`), which reads the database without the engine and quits when its window closes. In the menu bar app's process AppKit, SwiftUI and Charts kept 13–40 MB after the window closed, freed but fragmented, which no API returns; a process that ends returns everything. Launching costs about 150 ms, so the popover starts a History process in standby when it opens: it loads its frameworks, opens the database and draws a small History offscreen, then waits on its standard input; History… hands it the options, and an unused standby quits when the popover closes. Standby, and History while its window is opened, cannot take activation from the menu bar app, which would close the popover. Queries aggregate in SQL (`GROUP BY` on the primary keys; whole days from `usage_day`, the hours at the ends of a range from `usage`) on a read-only connection with a 256 KB page cache, run on another thread while the window is built, and return at most a few thousand grouped rows (one per app and network). No stored row loads into memory.
- **Dependencies:** Apple frameworks in the app; `libc`, `rusqlite` (system SQLite) and `serde_json` (the settings file) in the core.
- **App icons:** loaded lazily, small size only, cached by bundle ID.

The spike does none of this (it holds 60 days of fake rows in memory and rescans them every second), which is why it measures 71 MB. It is for the look, not the footprint.

## UI

**Menu bar item:** network type icon + today's total on the current network, as crossed its interfaces. Other options (the `menu_bar` setting): today on all networks, live speed, or icon only. Either "today" option shows the total, download, upload, or both side by side (the `menu_bar_count` setting). While the engine has stopped it reads "Not counting".

**Popover** (click the item):
- Current network card: name, type, connected since, today's total, down/up split, live speed.
- Apps tab: today's top apps on this network, toggle for all networks (bars then split by network color), then "Other / overhead", the raw gap between the interfaces and the apps. A notice above the tabs shows when the self-check is degraded or over-counted, or the engine runs on interface totals.
- Networks tab: today per network; unused ones show "last used".
- Footer: today across all networks, History…, Settings, Quit.

**History window:**
- Sidebar: All Networks, then networks grouped by Wi‑Fi / Hotspot / Ethernet, each icon in its network color; "Connected" badge on the current one.
- Toolbar: Day / Week / Month / Year / All Time, previous/next, Today, Export CSV (every stored (hour, network, app) row of the range and network shown). Opens on this month: on the current network when the popover's Apps tab shows only that network, on every network otherwise.
- Stat tiles: total with change vs the same elapsed span of the previous period; download/upload with a ratio bar; daily average; busiest day.
- Usage chart: bars stacked by network (one color for a single network) of what crossed the interfaces: hours for Day, local days for Week and Month, months for Year, days or months for All Time (months past three months of history); dashed average line over the bars elapsed so far; hover tooltip listing each network and the total for that bar.
- Apps: the top 12 apps (Show all for the rest) with their share of the total and a bar split by network, then "Other / overhead"; click an app for its download/upload per network.
- Share by network: one 100% bar plus a row per network with share and bytes.
- When you use data: weekday × hour heatmap (Week and longer), hover a cell for its value. Local days, hours and weekdays come from each stored hour's middle, so in a half-hour time zone an hour belongs where most of it falls.
- Shows what has been written: up to a minute behind the popover.

**Dynamic Island moments** (optional, see [mockup](mockups/island-moments.png)):
- The menu bar item is always present and is the main element; the island never replaces it.
- One black shape hanging from the top edge: at rest it is exactly the notch; a glance widens it sideways; a moment grows it into a panel, and content fades in after the shape has grown.
- Style setting: **Seamless** (default) covers the menu bar next to the notch while a moment is open, like other notch apps. **Keep menu bar clear** keeps the shape notch-wide inside the menu bar and widens it only below, so no menu bar item is ever covered.
- Moments, each switchable in Settings:
  - **Peek on hover:** hover the notch for today's total on this network, live speed and the top 3 apps.
  - **Network joined:** this network's usage this week, last visit, today here.
  - **Network left:** session receipt: bytes, duration, top app.
  - **Hotspot meter:** a small live counter under the notch while on a hotspot.
  - **Data hog:** one app over a threshold (default 100 MB in 5 min). Actions: Pause until off hotspot (quits the app and reopens it later; optional), Ignore app, Details.
  - **Background activity:** data moving while no app is in front (default over 50 MB). Actions: Details, Ignore app.
  - **Large transfer:** progress for transfers over 50 MB, credited to the app a system service works for ("Xcode via App Store"), ending in a checkmark.
  - **Daily recap:** one line at the reset hour. Off by default.
- One moment expands at a time; others queue. Hovering keeps a moment open. Moments close on their own after a few seconds.
- Full screen: hidden by default; alerts (data hog, background activity) can still show.
- Cost: one transparent, click-through panel that redraws only while a moment animates.

**Settings:**
- General: menu bar display, reset hour, launch at login.
- Island: master switch (off means a plain menu bar app), style (seamless or keep menu bar clear), each moment on/off, thresholds for data hog, background activity and large transfer, the pause action, full-screen behavior, built-in or all displays, and "send alerts as notifications" when the island is off.
- Networks: rename, type.
- Data: export CSV, show database.

## Visual language

- Networks use categorical slots in fixed order: blue, orange, aqua, yellow, magenta (light and dark steps differ, `prototypes/ui-spike/Sources/Soroband/Model.swift`). Validated with the dataviz palette checker: all checks pass in dark mode; in light mode aqua, yellow and magenta sit below 3:1 contrast, so every colored mark has a text label next to it. A network keeps its color in every view.
- Magnitude (heatmap) uses one blue ramp whose low end fades into the background.
- Apps are not colored; their bars carry network colors.
- 2 pt gaps between stacked segments, 2 pt corner radius, recessive grid.

## Prototypes

Throwaway code that settled the design; the product code lives in `app/` and `core/`.

- `prototypes/meter-probe`: the engine prototype. `cargo run --release -- 40 5` prints per-app internet bytes for 40 s (`METER_DEBUG=1` for message diagnostics).
- `prototypes/nstat-probe`: the same measurement through `NetworkStatistics.framework`, kept for comparison.
- `prototypes/ui-spike`: SwiftUI app with 60 days of fake data and fake live traffic. `run.sh` launches it in the menu bar; `snapshot.sh` re-renders `docs/mockups/`. The ⇅ button in the popover simulates joining another network (which fires the left and joined moments) and fires any moment on demand. `SOROBAND_DEMO=dataHog .build/debug/Soroband` fires one moment at launch.
