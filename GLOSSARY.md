# Soroband

The language of Soroband, a macOS menu bar app that meters internet usage per app and per network. Code, docs, PRs and reviews use these terms as written here.

## Counting

**Engine**:
The part of the core that counts bytes from the kernel's network statistics, per flow and per interface.
_Avoid_: meter (the module is `meter`; say engine for the thing that runs)

**Internet traffic**:
Bytes that cross a physical interface (Wi‑Fi, wired, cellular) to a non-local address. Only internet traffic counts; LAN, link-local, multicast, loopback and VPN tunnel traffic does not.

**Flow**:
One TCP or UDP connection as the kernel reports it, with its own byte counters and the process that owns it.
_Avoid_: connection, source (the kernel's word)

**Poll**:
One request to the kernel for every flow's counters, and the booking of what moved since the last one. It runs at the interval the app starts the engine with, faster while the popover is open (`LIVE_INTERVAL`), and at once on a network switch.
_Avoid_: tick, count

**Baseline**:
The first complete poll after the engine starts. Only bytes moved after it count, for apps and interfaces alike.

**Continuation**:
A flag on a chunk of a poll reply saying more chunks follow; a poll is complete only after the last one.

**App**:
What a flow's bytes are credited to: the outermost `.app` bundle of the process, "macOS & Services", or a command-line tool.
_Avoid_: process (a process is credited to an app; several processes can share one)

**macOS & Services**:
The one app that groups every process from macOS's own system directories, and from the simulated OS inside an iOS Simulator runtime.
_Avoid_: system, daemons

**Command-line tool**:
An app that is a lone executable outside any bundle or system directory, named by its file name (`curl`), or by its directory when it is installed as `<tool>/versions/1.4.3`.

**Delegated traffic**:
Bytes a system daemon or WebKit's networking process moves on behalf of an app, credited to that app.

**Duplicate bytes**:
Received bytes that arrived more than once because of retransmission. They crossed the interface, so they count as usage.
_Avoid_: retransmitted bytes (fine in prose, but the field is `rx_duplicate`)

**Interface counter**:
The kernel's byte counter for one physical interface; the true total of what crossed the network.
_Avoid_: ground truth, true total (as names)

**Interface bytes**:
What the interface counters show for a network over a span, less its local-network bytes; what is stored per (hour, network) and what the menu bar item shows.
_Avoid_: interface totals (except in "interface-only mode")

**Per-app mode**:
The engine mode in which flows are trusted and bytes are credited to apps.

**Interface-only mode**:
The engine mode in which only interface bytes are counted and no app is credited, entered when the layout guard meets an unknown layout. With no flows read, local-network bytes cannot be told apart and stay in the interface bytes.
_Avoid_: interface totals only, interface-only totals, "per-app counting is off"

**Layout guard**:
The check of each kernel descriptor's size against the layout table, which switches the engine to interface-only mode on an unknown size.

**Layout table**:
The descriptor sizes observed on a real Mac, per macOS version and provider. A size not in it is an unknown layout.

**Recording**:
A captured session of kernel messages, replayed by the tests as a fixture.

## Resources

**Resource meter**:
The part of the core that credits each app's CPU, memory, disk and energy (`resources`), run by the engine at its polls. It names apps as the engine does.

**Coalition**:
The kernel's group of an app and the processes it starts (its helpers, and the commands a terminal runs), with counters that keep what its processes used after they exit. The resource meter reads resource coalitions.
_Avoid_: process group, job

**Shared coalition**:
A coalition holding processes of more than one app, such as a terminal and the commands it runs; the resource meter splits it among them.

**Coalition leader**:
The app of a coalition's lowest process id. Its own processes in a shared coalition are not read; it takes what the coalition used that no other member's read accounts for, less what members that exited are credited.

**Resource read**:
One read of every coalition (or, in the fallback, every process of the user's) and the crediting of what each app used since the last one. It runs once a minute, and at every poll while the CPU is over 50% busy or memory is under pressure.
_Avoid_: scan, sample

**System gauges**:
CPU busy share, memory used, compressed and swapped, memory pressure, and each local volume's free space, read at every poll (the volumes once a minute).

**Footprint**:
The memory a process holds as macOS counts it for Activity Monitor's Memory column (`phys_footprint`), summed over an app's processes.
_Avoid_: RSS, resident memory

**Memory pressure**:
The kernel's level of memory shortage: normal, warning or critical (`kern.memorystatus_vm_pressure_level`). Under pressure means warning or critical. As a percent, the share of memory the kernel does not count as available (100 less `kern.memorystatus_level`), which a gauge shows when memory reads as pressure.

**Coalition layout guard**:
The check, at the first resource read and hourly, that the coalition fields the resource meter reads agree with its processes' own counts. A layout that fails it puts the resource meter in the fallback.

**Fallback**:
The resource meter reading the user's own processes one by one, when the coalition calls are missing or fail the coalition layout guard. It leaves out other users' and root processes; rows it stored are marked.

**Minute record**:
The system gauges (each local volume's free space included) and the five busiest apps by CPU, footprint and disk bytes written, per minute, kept for `resource_minutes_days` days. History's Day page draws it as the minute chart.

**Mac total**:
The Mac's resources in one hour, its apps summed (`resource_usage_total`): CPU time, disk bytes and energy add up, and the footprint is averaged over the time it was read, the longest any app of the hour was read for. History's resource pages are drawn from it.

**Measure**:
One resource as History and the popover list apps by it: CPU time, average footprint (memory), disk bytes read and written, or energy in watt-hours. The `resource_measures` setting picks which are shown; resources are the Mac's, not a network's.
_Avoid_: metric, resource type

**Gauge**:
A system gauge as a view shows it now, read as the Show setting says: in the popover's Resources tab, a menu bar reading, and the minute chart's lines.

**Show setting**:
How each resource reads, one setting per resource for every view: CPU as a percent or in cores; memory as used, free or pressure, as an amount or a percent; disk as used or free on a picked volume, as an amount or a percent (`resource_cpu`, `resource_memory`, `resource_memory_unit`, `resource_disk`, `resource_disk_unit`, `resource_disk_volume`).
_Avoid_: display mode, format

## Networks

**Network**:
One place the Mac gets internet from, known again each time it is joined, with a stable id, a network key, a name and a network kind.

**Network kind**:
Wi‑Fi, Ethernet or hotspot. Picked when the network is first seen; the user can change it.
_Avoid_: type (the Settings label says "Type"; the code and `--json` say `kind`)

**Hotspot**:
A network of kind hotspot: a path macOS marks expensive (an iPhone's Personal Hotspot), a cellular path, or one the user marked.
_Avoid_: expensive path (the signal that marks one)

**Network key**:
The string a network is recognized by on every join: its Wi‑Fi name, or its router address (`wifi:`, `wifi-router:`, `ethernet:`, `cellular:`). A `wifi-router:` key is replaced once the Wi‑Fi's name is readable (see Network merge).

**Network merge**:
What happens to a Wi‑Fi network known by its router when its name becomes readable: it takes the name's key, keeping its id and history, or, when a network with that name already exists, its usage is added into that network and it leaves the registry (`Command::Merge`).

**Network identity**:
The network key, name and kind worked out from what the Mac can see of the current path.

**Router address**:
The hardware address of the network's router, which tells apart wired networks and Wi‑Fi whose name is hidden.
_Avoid_: gateway MAC, router's hardware address

**Waiting for the router**:
The state of a network whose only possible key is a router address not resolved yet. Its usage goes to no network.

**No network**:
Where usage is booked while no network is identified (id 0). Shown as "Unknown network".
_Avoid_: unknown network (except as the label), network 0

**Network registry**:
The core's list of every network seen, with the user's edits to names and kinds.
_Avoid_: network list

**Network switch**:
The moment the current network changes. The engine polls at once so bytes land on the network they used.
_Avoid_: path change (the event that may cause one)

**Network color**:
The categorical color slot a network takes, the same in every view: the one the user picked in Settings › Networks, or else the slot of its place in the order networks were first seen.

**Last used**:
The last hour a network carried bytes.

## Time and storage

**Bucket**:
The bytes of one (hour, network, app), or of one (hour, network) for interface bytes. The smallest unit of history.
_Avoid_: row, hour bucket, in-memory bucket

**Booking**:
Adding what moved since the last poll to the buckets of the hour the poll ran in, on the network current then.
_Avoid_: ledger (for this concept; see Ledger)

**Hour**:
A UTC hour start. Buckets are keyed by it.

**Daily sums**:
The bytes of each (UTC day, network, app), kept in `usage_day` beside the buckets and written with them, so a long History range reads one row a day instead of 24.
_Avoid_: rollup, daily buckets

**Reset hour**:
The local hour at which today starts again (`reset_hour`, default 0). Nothing is deleted at it.
_Avoid_: daily reset, daily counter (the Settings label says "Daily counter resets at"; the setting is `reset_hour`)

**Today**:
The span from the most recent reset hour to now, rounded down to a whole UTC hour.

## Self-check

**Gap**:
How far the apps' sum falls below the interface bytes. Mostly packet headers and acknowledgements, which flows do not carry, of internet and local-network flows alike; local-network flows' own bytes are not part of it.
_Avoid_: overhead (alone)

**Other / overhead**:
The row of the popover's and History's app lists that shows the gap, always and without a verdict. Local-network bytes never show in it, but their packet headers and acknowledgements do: a large LAN transfer leaves roughly 8–10% of its size there.

**Local-network bytes**:
Bytes of flows the kernel marks local (`Snapshot::local`): LAN traffic such as Time Machine, AirPlay or a NAS. They cross the interfaces but are not internet traffic, so they are never usage: each poll takes them off the interface bytes it stores, and the self-check counts them as explained. Their packet headers and acknowledgements are not flow bytes, so they stay in the interface bytes.

**Self-check**:
The continuous comparison of the apps' sum plus local-network bytes with what crossed the interfaces, which gives a verdict: ok, degraded or overcount.
_Avoid_: reconciliation, reconciliation self-check, engine self-check

**Judged window**:
A self-check window with enough bytes across the interfaces for its gap to be judged; it fails when the apps and local-network bytes cover too little of what crossed the interfaces. The length and thresholds are `WINDOW`, `MIN_WINDOW_BYTES` and `MAX_GAP_PERCENT` in `core/crates/soroband-core/src/check.rs`.

**Degraded**:
The verdict after two failing judged windows in a row, cleared by the next judged window that passes.

**Overcount**:
The verdict when apps and local-network bytes together sum to more than crossed the interfaces by over `OVERCOUNT_PERCENT` (`check.rs`), once they reach `MIN_WINDOW_BYTES` in the window.
_Avoid_: over-counted, over-count

## Interface

**Menu bar item**:
The always-present item in the menu bar: the network kind's icon (or the Soroband glyph) and today's interface bytes on the current network by default. "Not counting" when the engine has stopped.
_Avoid_: status item, menu bar label

**Menu bar layout**:
What the menu bar item shows: its icon, the network kind's or the Soroband glyph, and next to it up to four readings in order, counting today on the current network or on every network, drawn in a menu bar style (the `menu_bar_icon`, `menu_bar_readings`, `menu_bar_scope` and `menu_bar_style` settings). No reading leaves the icon alone.
_Avoid_: display mode, menu bar mode, menu bar count, menu bar line

**Reading**:
One value the menu bar item can show: today's total, download or upload as crossed the interfaces less the local-network bytes, the live download or upload speed, or a gauge (CPU, memory or disk).

**Menu bar style**:
How the readings are drawn: **stacked** (in pairs, the first on top, in a smaller size; a reading without a partner at full size), **labeled** (each value under a small caption) or **inline** (one line at the menu bar's size).

**Soroband glyph**:
The Soroband mark (a rounded diamond cut by an S) as the menu bar item's icon, in place of the network kind's, whatever the network (`menu_bar_icon` `soroband`). While the engine has stopped, a warning sign replaces it as it replaces the network icon.
_Avoid_: logo, app icon (the icon in Finder and the Dock)

**Live speed**:
Interface bytes per second, down and up, over the last poll.

**Popover**:
The panel the menu bar item opens: hero card, Apps, Networks and Resources tabs, footer with the History card. The Resources tab shows the gauges now and today's apps by one measure.

**Hero card**:
The popover's top card, tinted with the current network's color: name, kind, when the Mac joined it, live speed, today's total, down/up split, today on all networks, and today's hours as bars.
_Avoid_: network card, header (its name in `PopoverContent`)

**History card**:
The popover's entry to History: this month and the last 7 days on the network History opens on (the current one while the Apps tab shows only it, every network otherwise).
_Avoid_: History button

**Notice**:
The line above the popover's tabs when the engine has failed ("Not counting"), the engine is in interface-only mode, or the self-check is degraded or overcount.

**History window**:
The window for usage over a range, by network and app: headline card, Where it went (share by network), usage chart, apps and heatmap. A measure picker turns the whole page to one resource, on the Mac rather than a network. It is a window of the UI process.

**Menu bar process**:
The Soroband process that runs all day: the menu bar item, the engine and the network monitor, and no window. It runs AppKit alone; the UI process runs the SwiftUI app.
_Avoid_: agent, daemon, main app

**UI process**:
A second instance of Soroband.app, started with `--ui` by the menu bar process, that shows the popover, Settings, History and the Welcome window. It reads the database without starting the engine, gets the engine's numbers from the menu bar process, and sends it the changes the user makes. It quits after the linger, or when the menu bar process quits, so no window's memory stays in the process that runs all day.
_Avoid_: helper, History process (its earlier, History-only form)

**Linger**:
The 10 minutes the menu bar process lets a UI process wait after its last window closed before it quits it. A popover opened within it opens warm.
_Avoid_: keep-alive, grace period

**Theme**:
How Soroband's windows look: an appearance and an accent, set in Settings › Appearance (the `appearance` and `accent` settings). It applies to the windows of the UI process; the island keeps its own dark look.
_Avoid_: skin, color scheme (SwiftUI's name for light or dark)

**Appearance**:
Light or dark for Soroband's windows: **system** (as macOS is, the default), **light** or **dark**.
_Avoid_: mode, dark mode (macOS's own setting)

**Accent**:
The color of what Soroband draws to show a selection or highlight in its windows: **system** (macOS's accent color, the default), or coral, amber, emerald, teal, sky, indigo, plum or rose, the colors of Soroband's icons, each with a light and a dark step.
_Avoid_: tint (SwiftUI's mechanism for it), highlight color

**App icon**:
Soroband's icon in the Dock, in Finder and in Settings › About: **graphite** (the bundle's own, the default) or one of Soroband's 12 other icons, set in Settings › Appearance (the `app_icon` setting). Finder shows it as the bundle's custom icon.
_Avoid_: logo, glyph (the menu bar's mark), alternate icon (iOS's mechanism)

**Range**:
What History shows: a day, week, month or year of the calendar, or all time.
_Avoid_: period (the calendar unit a range steps by)

**Bar**:
One column of History's usage chart: an hour, a local day or a local month, stacked by network.
_Avoid_: bucket (a stored unit of usage)

**Island**:
The optional black shape at the notch that opens for moments. The menu bar item stays the main element. The menu bar process draws it, with AppKit.
Dynamic Island is the name of milestone M5, which builds it, and of its sections in `docs/plan.md` and `docs/design.md`.

**Glance**:
The island widened sideways, between rest and a moment. The hotspot meter is the only one.

**Moment**:
One short island event, each switchable: peek on hover, network joined, network left, hotspot meter, data hog, background activity, large transfer, daily recap.
_Avoid_: notification (the fallback when the island is off); alert for any moment (it names two)

**Alert**:
A moment that warns: the data hog and background activity. Alerts go first in the moment queue, may show while an app is full screen, and become notifications while the island is off.

**Moment queue**:
The moments waiting to open, alerts first, then large transfers, then the rest; one opens at a time.

**Peek**:
The moment that opens when the pointer rests on the notch: today on this network, the live speed and the top 3 apps.

**Hotspot meter**:
The glance shown while the Mac is on a hotspot: today on it and the live speed, either side of the notch.

**Data hog**:
One app that used more than a threshold within a window (default 100 MB in 5 minutes).

**Background activity**:
An app that used more than a threshold within the data hog's window (default 50 MB) while it was not the frontmost app.

**Large transfer**:
An app moving at least 100 KB/s poll after poll, shown once its run passes a threshold (default 50 MB) and again when it stops. It names the system service that moved the bytes for the app ("Xcode via App Store").

**Session**:
The time the Mac spent on one network, from joining it to leaving it; network left shows its receipt.
_Avoid_: visit

**Ignored app**:
An app that raises no moment (`island_ignored_apps`).

**Seamless**:
The default island style: the shape covers the menu bar beside the notch while a moment is open.

**Keep menu bar clear**:
The island style that keeps the shape notch-wide inside the menu bar and widens it only below.

## Project

**Milestone**:
One step of the roadmap in `docs/plan.md` (M0 to M7), done on one branch with one PR.

**Ledger**:
The milestone table in `docs/plan.md`, the record of progress. The core's `Ledger` type holds bookings not yet written; in prose say bookings for that.

**Stacked branches**:
Milestone branches each made from the previous milestone's branch, with its PR against that branch.

**Hand checklist**:
The steps a milestone needs a person for (a permission prompt, a real hotspot), listed in the PR and the handover.

**Daily-use week**:
M3's exit criterion: the user runs the dogfood build every day for a week.

**Dogfood build**:
The installed source build the user runs daily.

**Release**:
A version published on GitHub by the release workflow from a version tag: `Soroband.dmg` (the app, with the `soroband` command in `Contents/Helpers`), its SHA-256 checksum, and its section of `CHANGELOG.md` as notes. Signed ad hoc, not notarized; `soroband update` installs the newest one.

**Build stamp**:
The commit a build was made from, written into the app and the `soroband` command when they are built (`scripts/build-stamp.sh`): HEAD's short SHA and the branch, and in the app `-dirty` when the checkout had uncommitted changes. Settings › About and `soroband version` show it after the version and the build number, the count of commits up to it (0 when the clone cannot count them): `0.1.0 (412) · 16e85ce main`.
_Avoid_: build ID, revision

**Source build**:
Soroband built and installed on the user's Mac by `scripts/install.sh`, signed with "Soroband Local Signing"; updated from its clone, never by `soroband update`.

**Judged run**:
A `traffic.sh` run under the network-quality cutoff, with no other curl in the window and a download that finished in time, which counts toward M1's traffic criteria.

**Reported run**:
A `traffic.sh` run over the network-quality cutoff, with another curl in the window, or with a download that did not finish in time: recorded in the PR, not judged.

**Network-quality cutoff**:
Duplicate bytes for curl's flow under 1% of the body; one of the conditions for a judged run.

**Round**:
One blind review of a PR, posted on it.

**Planned rounds**:
The rounds a PR expects, written in its description before round 1; a budget for judgment, not a limit. Whether another round runs is judged after each one.
_Avoid_: round cap

**Blind loop**:
The blind review rounds of a PR, run while it is a draft and again for fixes that change behavior after CodeRabbit's review. CodeRabbit reviews once it first ends.

**Review retro**:
A PR's entry in `docs/review-retros.md`: the findings of each review (blind rounds, direct reviews, CodeRabbit) and their origins, then why the review took the rounds it did and what to change. Not the retrospective, which is written only in a reassessment.

**Finding origin**:
Why a finding showed up in the review it did, one of a fixed set in `docs/review-retros.md`.

**Miss cause**:
Why the blind loop missed a valid CodeRabbit finding, one of a fixed set in `docs/coderabbit-findings.md`.

**Reach list**:
The Reach section of a PR body: the callers, consumers, paths into changed state and boundaries the diff reaches, each with how it is covered, written by the developer from `REVIEW.md`'s rules before review. A reach the reviewer finds missing from it is a finding against it.

**Sibling search**:
The search that comes with every fix: name the defect class, find the same defect elsewhere in the repository, test and fix each, and state it as `Siblings checked: <search>, <result>`.

**Records-only commit**:
A commit that changes only the records (rows, entries and retros) in `docs/review-retros.md` and `docs/coderabbit-findings.md`. How it is reviewed is in `docs/review.md` (Rounds step 4, CodeRabbit step 7).

**Blind reviewer**:
A fresh agent each round that sees only the PR and its requirements.

**Conductor**:
The thread that starts milestone sessions in an unattended run and writes no code.

**Retrospective**:
The PR comment written in a reassessment (a fixed finding came back, or the findings repeat in kind or stop shrinking), naming the root cause and a way forward.
