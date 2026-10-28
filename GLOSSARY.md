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
The one app that groups every process from macOS's own system directories.
_Avoid_: system, daemons

**Command-line tool**:
An app that is a lone executable outside any bundle or system directory, named by its file name (`curl`).

**Delegated traffic**:
Bytes a system daemon or WebKit's networking process moves on behalf of an app, credited to that app.

**Duplicate bytes**:
Received bytes that arrived more than once because of retransmission. They crossed the interface, so they count as usage.
_Avoid_: retransmitted bytes (fine in prose, but the field is `rx_duplicate`)

**Interface counter**:
The kernel's byte counter for one physical interface; the true total of what crossed the network.
_Avoid_: ground truth, true total (as names)

**Interface bytes**:
What the interface counters show for a network over a span; what the menu bar item shows.
_Avoid_: interface totals (except in "interface-only mode")

**Per-app mode**:
The engine mode in which flows are trusted and bytes are credited to apps.

**Interface-only mode**:
The engine mode in which only interface bytes are counted and no app is credited, entered when the layout guard meets an unknown layout.
_Avoid_: interface totals only, interface-only totals, "per-app counting is off"

**Layout guard**:
The check of each kernel descriptor's size against the layout table, which switches the engine to interface-only mode on an unknown size.

**Layout table**:
The descriptor sizes observed on a real Mac, per macOS version and provider. A size not in it is an unknown layout.

**Recording**:
A captured session of kernel messages, replayed by the tests as a fixture.

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
The string a network is recognized by on every join: its Wi‑Fi name, or its router address (`wifi:`, `wifi-router:`, `ethernet:`, `cellular:`).

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
The categorical color slot a network takes in the order it was first seen, the same in every view.

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

**Reset hour**:
The local hour at which today starts again (`reset_hour`, default 0). Nothing is deleted at it.
_Avoid_: daily reset, daily counter (the Settings label says "Daily counter resets at"; the setting is `reset_hour`)

**Today**:
The span from the most recent reset hour to now, rounded down to a whole UTC hour.

## Self-check

**Gap**:
How far the apps' sum falls below the interface bytes. Mostly packet headers and acknowledgements, which flows do not carry.
_Avoid_: overhead (alone)

**Other / overhead**:
The popover row that shows the gap, always and without a verdict.

**Self-check**:
The continuous comparison of the apps' sum with the interface bytes, which gives a verdict: ok, degraded or overcount.
_Avoid_: reconciliation, reconciliation self-check, engine self-check

**Judged window**:
A self-check window with enough interface bytes for its gap to be judged; it fails when the gap is too large. The length and thresholds are `WINDOW`, `MIN_WINDOW_BYTES` and `MAX_GAP_PERCENT` in `core/crates/soroband-core/src/check.rs`.

**Degraded**:
The verdict after two failing judged windows in a row, cleared by the next judged window that passes.

**Overcount**:
The verdict when apps sum to more than the interface bytes by over `OVERCOUNT_PERCENT` (`check.rs`), at any volume.
_Avoid_: over-counted, over-count

## Interface

**Menu bar item**:
The always-present item in the menu bar: network icon and today's interface bytes on the current network by default. "Not counting" when the engine has stopped.
_Avoid_: status item, menu bar label

**Menu bar mode**:
What the menu bar item shows: today on the current network, today on all networks, live speed, or icon only (the `menu_bar` setting).
_Avoid_: display mode, mode (alone; the engine has modes too)

**Live speed**:
Interface bytes per second, down and up, over the last poll.

**Popover**:
The panel the menu bar item opens: network card, Apps and Networks tabs, footer.

**Network card**:
The popover's header for the current network: name, kind, connected since, today's total, down/up split, live speed.
_Avoid_: header (its name in `PopoverContent`)

**Notice**:
The line above the popover's tabs when the engine has failed ("Not counting"), the engine is in interface-only mode, or the self-check is degraded or overcount.

**History window**:
The window for usage over any range (day to all time), by network and app.

**Island**:
The optional black shape at the notch that opens for moments. The menu bar item stays the main element.
Dynamic Island is the name of milestone M5, which builds it, and of its sections in `docs/plan.md` and `docs/design.md`.

**Glance**:
The island widened sideways, between rest and a moment.

**Moment**:
One short island event, each switchable: peek on hover, network joined, network left, hotspot meter, data hog, background activity, large transfer, daily recap.
_Avoid_: alert, notification (those are the fallback when the island is off)

**Seamless**:
The default island style: the shape covers the menu bar beside the notch while a moment is open.

**Keep menu bar clear**:
The island style that keeps the shape notch-wide inside the menu bar and widens it only below.

## Project

**Milestone**:
One step of the roadmap in `docs/plan.md` (M0 to M6), done on one branch with one PR.

**Ledger**:
The milestone table in `docs/plan.md`, the record of progress. The core's `Ledger` type holds bookings not yet written; in prose say bookings for that.

**Stacked branches**:
Milestone branches each made from the previous milestone's branch, with its PR against that branch.

**Hand checklist**:
The steps a milestone needs a person for (a permission prompt, a real hotspot), listed in the PR and the handover.

**Daily-use week**:
M3's exit criterion: the user runs the dogfood build every day for a week.

**Dogfood build**:
The installed release build the user runs daily.

**Judged run**:
A `traffic.sh` run under the network-quality cutoff, which counts toward M1's traffic criteria.

**Reported run**:
A `traffic.sh` run over the network-quality cutoff: recorded in the PR, not judged.

**Network-quality cutoff**:
Duplicate bytes for curl's flow under 1% of the body; the line between a judged run and a reported run.

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
Why a finding showed up in the round it did, one of a fixed set in `docs/review-retros.md`.

**Miss cause**:
Why the blind loop missed a valid CodeRabbit finding, one of a fixed set in `docs/coderabbit-findings.md`.

**Blind reviewer**:
A fresh agent each round that sees only the PR and its requirements.

**Conductor**:
The thread that starts milestone sessions in an unattended run and writes no code.

**Retrospective**:
The PR comment written in a reassessment (a fixed finding came back, or the findings repeat in kind or stop shrinking), naming the root cause and a way forward.
