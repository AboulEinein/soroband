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

1. **Network identity.** `NWPathMonitor` reports interface changes and `isExpensive` (set for iPhone Personal Hotspot). Wi‑Fi name from CoreWLAN `CWWiFiClient` (needs Location permission). Ethernet identified by gateway MAC so "Desk Dock" and "Office LAN" stay separate. Hotspot = expensive path, or a Wi‑Fi/USB interface the user marks as hotspot. Users can rename any network and fix its type. All event-driven: nothing polls while the network is stable.
2. **Per-app counting: our own meter engine.** A small Rust core talks straight to the kernel's network statistics control socket (`com.apple.network.statistics`, protocol in XNU's open source `bsd/net/ntstat.h`). No `nettop`, no private framework. See "Meter engine" below.
3. **Ground truth.** The interface MIB's 64-bit byte counters (`net.link.generic`, `IFDATA_GENERAL`) give the true total per network. `getifaddrs` and the routing socket's `NET_RT_IFLIST2` are not usable: on macOS 27 an unprivileged process gets counters wrapped to 32 bits and rounded to whole kilobytes. Any gap between that and the app sum shows as "Other", so totals always match what the network saw.
4. **Storage.** SQLite (system `libsqlite3`, no ORM), WAL mode. One row per (hour, network, app) with bytes down/up, primary key on those three columns. Kept forever: a year of heavy use is a few MB.
5. **Daily reset.** The menu bar counter covers "today" from a configurable reset hour (default midnight). Nothing is deleted at reset.

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
- **Self-check:** the app sum is reconciled against the interface counter all the time. Flows carry no headers, so the app sum runs 8–10% below the interfaces during a bulk download and about 22% below on an idle minute, where headers, acknowledgements and link-local chatter are a large share of small packets. v0.1 makes no header-byte estimate. The rule (built in M3):
  - The raw gap always shows as "Other / overhead", with no verdict.
  - The ~15% gap is judged only over windows with enough interface volume: at least 10 MB on the interfaces in the last 10 minutes.
  - "Degraded" shows only after two consecutive failing windows.
  - Apps summing to more than the interfaces, by about 2%, flags at once, whatever the volume: flows never carry more than crossed the wire.

Risks and how the design handles them:

- **Layout drift.** The protocol is versioned only by struct size. macOS 27 sends a 360-byte TCP descriptor; the newest published XNU (macOS 26) says 344. The engine reads only stable leading fields (counters, pid, epid, name, interface properties), checks each descriptor's size against a table of sizes observed per macOS version and provider, and falls back to interface-only totals (step 3) when a size is unknown, reporting why. Only macOS 27's kernel TCP and UDP providers are in the table so far (the userland providers sent nothing there); each version added needs a recording from a Mac running it. CI replays the recorded sessions in `core/crates/soroband-core/tests/fixtures`.
- **Idle-flow baseline.** The kernel can skip unchanged flows (`NOZERODELTAS`, `SUPPRESS_BORING_POLL`), but then a flow idle at startup later reports its whole lifetime. Seen in the probe: one Chrome connection added 22.7 MB that never crossed the interface. The engine polls every flow; at ~150 flows this costs 0.058% CPU.
- **Domains.** The kernel has a per-flow domain extension, but it returned nothing to an unprivileged client. Per-domain usage is out unless we add DNS correlation later.

Shape: Rust crate `soroband-core` (socket client, aggregation, SQLite) exposed through a small C API to the SwiftUI app, in one process. The same crate gives a `soroband` CLI (`soroband today`, `soroband apps --network Office`, `soroband config`), installed next to the app.

## Performance budget

| Measure | Budget | Evidence |
| --- | --- | --- |
| CPU, idle, popover closed | ≤ 0.1% average | Rust probe: 0.035–0.058% at 5 s polls, ~150 flows; `soroband-core` engine 0.017–0.033%, Debug app with engine 0.023–0.096% (M1) |
| Memory, popover closed | ≤ 25 MB footprint | Bare SwiftUI `MenuBarExtra` app: 16 MB; Rust engine: 1.7–1.8 MB; Debug app with engine: 17.0–23.0 MB (M1) |
| Memory, History window open | ≤ 60 MB, back under 30 MB after closing | Not measured yet |
| Disk writes | One SQLite transaction per minute | Design |
| Energy | No timers firing more than every 5 s when the popover is closed | Design |

How the app stays inside the budget:

- **Engine:** one socket, one thread blocked in `poll(2)` between 5 s polls. Deltas accumulate in a map keyed by (network, app), about 50 entries. A flow's state is two counters and a name, dropped when the flow closes.
- **Writes:** the in-memory hour bucket flushes to SQLite once a minute, on network change, and on quit.
- **Menu bar label:** redraws only when the displayed string changes; at most every 5 s.
- **Popover:** reads today's in-memory aggregates, never SQLite. While it is open the query interval drops to 1 s for live speed, and returns to 5 s when it closes.
- **History window:** created on open and released on close. Queries aggregate in SQL (`GROUP BY` on the indexed columns), returning at most a few hundred rows per chart. No raw rows load into memory.
- **Dependencies:** Apple frameworks in the app; `libc` and `rusqlite` (system SQLite) in the engine.
- **App icons:** loaded lazily, small size only, cached by bundle ID.

The spike does none of this (it holds 60 days of fake rows in memory and rescans them every second), which is why it measures 71 MB. It is for the look, not the footprint.

## UI

**Menu bar item:** network type icon + today's total on the current network. Other options: today on all networks, live speed, or icon only.

**Popover** (click the item):
- Current network card: name, type, connected since, today's total, down/up split, live speed.
- Apps tab: today's top apps on this network, toggle for all networks (bars then split by network color).
- Networks tab: today per network; unused ones show "last used".
- Footer: today across all networks, History…, Settings, Quit.

**History window:**
- Sidebar: All Networks, then networks grouped by Wi‑Fi / Hotspot / Ethernet, each icon in its network color; "Connected" badge on the current one.
- Toolbar: Day / Week / Month / Year / All Time, previous/next, Today.
- Stat tiles: total with change vs the same elapsed span of the previous period; download/upload with a ratio bar; daily average; busiest day.
- Usage chart: bars stacked by network (one color for a single network), dashed average line, hover tooltip listing each network and the total for that bar.
- Apps: every app with its share of the total and a bar split by network; click an app for its download/upload per network.
- Share by network: one 100% bar plus a row per network with share and bytes.
- When you use data: weekday × hour heatmap (Week and longer), hover a cell for its value.

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
