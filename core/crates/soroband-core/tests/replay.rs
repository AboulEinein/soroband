//! Replays of kernel sessions through the engine.
//!
//! The fixtures in `tests/fixtures` were recorded on macOS 27.0.1 with
//! `soroband live --interval 5 --record <file>`:
//!
//! - `curl-20mb.rec`: 60 s. About 12 s in, `curl` downloaded a 20,000,000-byte body from
//!   `speed.cloudflare.com/__down?bytes=20000000` (curl reported `size_download` 20000000). curl's
//!   flow was polled once mid-transfer; its final update and removal arrived between polls. The
//!   kernel counted 20,175,944 bytes received, 139,152 of them duplicates from retransmission;
//!   they crossed the interface, so they are usage.
//! - `many-flows.rec`: 15 s while a script held 200 extra TCP connections open, so each poll reply
//!   came in several chunks.
//! - `webkit-delegated.rec`: 25 s. A small program (`wkload`) loaded a 5,000,000-byte body in an
//!   off-screen `WKWebView`; the `WebKit` networking process moved the bytes on its behalf.
//!
//! The synthetic sessions at the end build kernel messages by hand for the edge cases, with the
//! expected numbers worked out in each test.
//!
//! The fixtures are anonymized: every app, tool and process name outside macOS's own and the
//! test programs (`curl`, `wkload`) is made up, keeping its place in the file system (a helper
//! inside its app, an app inside `/Library/Application Support`, a tool named by its version),
//! and each interface counter starts at 0 or 1,000,000,000, keeping its changes.

mod common;

use common::{MAIL, MAIL_PATH, SAFARI, SAFARI_PATH, mail, pack, removed, success, tcp_update};
use soroband_core::meter::ntstat;
use soroband_core::meter::process::SERVICES;
use soroband_core::meter::record::{self, Event, Replay};
use soroband_core::meter::{Bytes, Engine, Mode, Snapshot};
use std::time::Duration;

fn fixture(name: &str) -> Vec<Event> {
    let path = format!("{}/tests/fixtures/{name}", env!("CARGO_MANIFEST_DIR"));
    record::parse(&std::fs::read(&path).expect("fixture")).expect("valid recording")
}

/// Runs the engine over a whole recording, ticking as the recorder did.
fn run(replay: Replay) -> (Snapshot, Replay) {
    let mut engine = Engine::start(replay).expect("start");
    while !engine.host().finished() {
        engine.tick(Duration::from_secs(5)).expect("tick");
    }
    (engine.snapshot(), engine.into_host())
}

fn app<'a>(snapshot: &'a Snapshot, name: &str) -> Option<&'a Bytes> {
    snapshot
        .apps
        .iter()
        .find(|(app, _)| app.name == name)
        .map(|(_, bytes)| bytes)
}

fn within(actual: u64, expected: u64, fraction: f64) -> bool {
    #[allow(clippy::cast_precision_loss)]
    let (actual, expected) = (actual as f64, expected as f64);
    (actual - expected).abs() <= expected * fraction
}

#[test]
fn known_download_is_attributed_to_its_process_within_one_percent() {
    let (snapshot, _) = run(Replay::new(fixture("curl-20mb.rec")));
    let curl = app(&snapshot, "curl").expect("curl was credited");
    assert!(
        within(curl.rx, 20_000_000, 0.01),
        "curl received {} bytes",
        curl.rx
    );
}

#[test]
fn known_download_is_within_one_percent_of_its_body_plus_its_duplicate_bytes() {
    let (snapshot, _) = run(Replay::new(fixture("curl-20mb.rec")));
    let (curl_app, curl) = snapshot
        .apps
        .iter()
        .find(|(a, _)| a.name == "curl")
        .expect("curl");
    // The kernel reported 139,152 duplicate bytes on curl's flow (read from the recording with a
    // separate script), so the expected total is 20,139,152.
    let duplicates = snapshot.rx_duplicate(curl_app);
    assert_eq!(duplicates, 139_152);
    assert!(
        within(curl.rx, 20_000_000 + duplicates, 0.01),
        "curl received {}",
        curl.rx
    );
}

#[test]
fn closed_flow_final_bytes_are_counted() {
    // curl's only poll saw 10,737,534 bytes; the rest came in the update sent when it closed.
    let (snapshot, _) = run(Replay::new(fixture("curl-20mb.rec")));
    assert!(app(&snapshot, "curl").expect("curl").rx > 20_000_000);
}

#[test]
fn app_sum_is_within_ten_percent_of_the_interface_counter() {
    let (snapshot, _) = run(Replay::new(fixture("curl-20mb.rec")));
    let (apps, interfaces) = (snapshot.apps_total().total(), snapshot.interfaces.total());
    assert!(
        interfaces > 20_000_000,
        "the interfaces carried the download: {interfaces}"
    );
    assert!(
        within(apps, interfaces, 0.10),
        "apps {apps} vs interfaces {interfaces}"
    );
}

#[test]
fn bytes_moved_before_the_baseline_are_not_counted() {
    // Long-lived flows (browsers, sync clients) carry gigabytes of lifetime bytes at startup.
    // Booking them would push the app sum far above what the interfaces carried.
    let (snapshot, _) = run(Replay::new(fixture("curl-20mb.rec")));
    assert!(snapshot.apps_total().total() <= snapshot.interfaces.total());
}

#[test]
fn helpers_are_credited_to_their_app() {
    let (snapshot, _) = run(Replay::new(fixture("curl-20mb.rec")));
    // The browser's traffic came from "Lumen Browser Helper (Renderer)" inside Lumen Browser.app.
    let browser = snapshot
        .apps
        .iter()
        .find(|(app, _)| app.name == "Lumen Browser");
    assert_eq!(
        browser.map(|(app, _)| app.id.as_str()),
        Some("/Applications/Lumen Browser.app")
    );
    assert!(
        snapshot
            .apps
            .iter()
            .all(|(app, _)| !app.name.contains("Helper (")),
        "{:?}",
        snapshot.apps
    );
}

#[test]
fn chunked_poll_replies_are_read_to_the_last_chunk() {
    let (snapshot, replay) = run(Replay::new(fixture("many-flows.rec")));
    // Replay panics if the engine skips a continuation request; it also has to reach the end.
    assert!(replay.finished());
    let polls: Vec<u64> = replay
        .sent
        .iter()
        .filter(|m| {
            ntstat::messages(m)
                .next()
                .is_some_and(|m| m.kind == ntstat::MSG_GET_UPDATE)
        })
        .map(|m| ntstat::messages(m).next().unwrap().context)
        .collect();
    let repeated = polls.windows(2).filter(|w| w[0] == w[1]).count();
    assert!(
        repeated >= 4,
        "continuation requests repeat the poll's context: {polls:x?}"
    );
    // The script's 200 connections plus the Mac's own flows, all tracked.
    assert!(snapshot.flows > 200, "{} flows", snapshot.flows);
}

#[test]
fn delegated_download_is_credited_to_the_app_it_serves() {
    let (snapshot, _) = run(Replay::new(fixture("webkit-delegated.rec")));
    let wkload = app(&snapshot, "wkload").expect("wkload was credited");
    assert!(
        within(wkload.rx, 5_000_000, 0.01),
        "wkload received {}",
        wkload.rx
    );
    let services = app(&snapshot, SERVICES).map_or(0, |b| b.rx);
    assert!(
        services < 1_000_000,
        "the download did not go to macOS & Services: {services}"
    );
}

#[test]
fn unknown_macos_version_counts_interface_totals_only() {
    let (on_27, _) = run(Replay::new(fixture("curl-20mb.rec")));
    let (on_26, _) = run(Replay::new(fixture("curl-20mb.rec")).as_macos(26));
    // The first update in the recording is a UDP flow's.
    assert_eq!(
        on_26.mode,
        Mode::InterfaceOnly {
            reason: "kernel UDP descriptor of 280 bytes is not known for macOS 26".into()
        }
    );
    assert_eq!(on_26.apps, []);
    assert_eq!(on_26.interfaces, on_27.interfaces);
    assert!(on_26.interfaces.total() > 20_000_000);
}

// Synthetic sessions.

const EN0: &str = "en0";

/// Messages packed into one datagram, each on an 8-byte boundary.
fn datagram(messages: &[Vec<u8>]) -> Event {
    Event::Recv(pack(messages))
}

fn en0(rx: u64, tx: u64) -> Event {
    Event::Interfaces(vec![soroband_core::meter::interfaces::InterfaceCounter {
        name: EN0.into(),
        rx,
        tx,
    }])
}

const POLL: u64 = 1 << 32;

/// Subscriptions, then the kernel's first updates, then the baseline poll.
fn start(first_updates: &[Vec<u8>], baseline_reply: &[Vec<u8>]) -> Vec<Event> {
    let mut events = vec![Event::MacosMajor(27)];
    events.extend(ntstat::PROVIDERS.map(|p| Event::Send(ntstat::add_all_sources(p))));
    events.push(Event::Process {
        pid: MAIL,
        path: Some(MAIL_PATH.into()),
    });
    events.push(Event::Process {
        pid: SAFARI,
        path: Some(SAFARI_PATH.into()),
    });
    if !first_updates.is_empty() {
        events.push(datagram(first_updates));
    }
    events.push(Event::Timeout);
    events.push(Event::Send(ntstat::poll_all(POLL)));
    let mut reply = baseline_reply.to_vec();
    reply.push(success(POLL, false));
    events.push(datagram(&reply));
    events.push(en0(1_000_000, 1_000_000));
    events
}

#[test]
fn only_bytes_after_the_baseline_are_booked() {
    let mut events = start(
        &[tcp_update(1, 9_000_000, 800_000, MAIL, false, 360)],
        &[tcp_update(2, 50_000, 6_000, SAFARI, false, 360)],
    );
    events.extend([
        Event::Timeout,
        Event::Send(ntstat::poll_all(POLL + 1)),
        datagram(&[
            tcp_update(1, 9_000_700, 800_100, MAIL, false, 360),
            tcp_update(2, 50_000, 6_000, SAFARI, false, 360),
            success(POLL + 1, false),
        ]),
        en0(1_000_900, 1_000_200),
    ]);
    let (snapshot, _) = run(Replay::new(events));
    // Mail: 9,000,700 - 9,000,000 received, 800,100 - 800,000 sent. Safari moved nothing since
    // the baseline, so it is not listed.
    assert_eq!(snapshot.apps, vec![(mail(), Bytes { rx: 700, tx: 100 })]);
    assert_eq!(snapshot.interfaces, Bytes { rx: 900, tx: 200 });
}

#[test]
fn final_update_of_a_closed_flow_is_booked_between_polls() {
    let mut events = start(&[], &[tcp_update(7, 100, 10, MAIL, false, 360)]);
    events.extend([
        // Unasked, between polls: the flow's last counters, then its removal.
        datagram(&[tcp_update(7, 5_100, 510, MAIL, false, 360), removed(7)]),
        Event::Timeout,
        Event::Send(ntstat::poll_all(POLL + 1)),
        datagram(&[success(POLL + 1, false)]),
        en0(1_005_000, 1_000_500),
    ]);
    let (snapshot, _) = run(Replay::new(events));
    assert_eq!(snapshot.apps, vec![(mail(), Bytes { rx: 5_000, tx: 500 })]);
    assert_eq!(snapshot.flows, 0, "the removed flow is forgotten");
}

#[test]
fn local_network_flows_are_not_internet_traffic() {
    let mut events = start(
        &[],
        &[
            tcp_update(1, 0, 0, MAIL, false, 360),
            tcp_update(2, 0, 0, SAFARI, true, 360),
        ],
    );
    events.extend([
        Event::Timeout,
        Event::Send(ntstat::poll_all(POLL + 1)),
        datagram(&[
            tcp_update(1, 3_000, 300, MAIL, false, 360),
            tcp_update(2, 40_000, 4_000, SAFARI, true, 360),
            success(POLL + 1, false),
        ]),
        en0(1_043_000, 1_004_300),
    ]);
    let (snapshot, _) = run(Replay::new(events));
    assert_eq!(snapshot.apps, vec![(mail(), Bytes { rx: 3_000, tx: 300 })]);
    assert_eq!(
        snapshot.local,
        Bytes {
            rx: 40_000,
            tx: 4_000
        }
    );
}

#[test]
fn continuation_asks_for_the_next_chunk_of_the_same_poll() {
    let mut events = start(&[], &[]);
    events.extend([
        Event::Timeout,
        Event::Send(ntstat::poll_all(POLL + 1)),
        datagram(&[
            tcp_update(1, 1_000, 0, MAIL, false, 360),
            success(POLL + 1, true),
        ]),
        Event::Send(ntstat::poll_all(POLL + 1)),
        datagram(&[
            tcp_update(2, 2_000, 0, SAFARI, false, 360),
            success(POLL + 1, false),
        ]),
        en0(1_003_000, 1_000_000),
    ]);
    let (snapshot, replay) = run(Replay::new(events));
    assert!(replay.finished());
    // Both chunks' flows are new since the baseline, so all their bytes count.
    assert_eq!(snapshot.apps_total(), Bytes { rx: 3_000, tx: 0 });
}

#[test]
fn unknown_descriptor_size_switches_to_interface_totals_and_says_why() {
    let mut events = start(&[], &[tcp_update(1, 0, 0, MAIL, false, 360)]);
    events.extend([
        Event::Timeout,
        Event::Send(ntstat::poll_all(POLL + 1)),
        // 344 bytes: the size in the macOS 26 XNU source, never seen on macOS 27.
        datagram(&[
            tcp_update(1, 5_000, 0, MAIL, false, 344),
            success(POLL + 1, false),
        ]),
        en0(1_005_200, 1_000_100),
    ]);
    let (snapshot, _) = run(Replay::new(events));
    assert_eq!(
        snapshot.mode,
        Mode::InterfaceOnly {
            reason: "kernel TCP descriptor of 344 bytes is not known for macOS 27".into()
        }
    );
    assert_eq!(snapshot.apps, []);
    assert_eq!(snapshot.interfaces, Bytes { rx: 5_200, tx: 100 });
}

#[test]
fn baseline_poll_is_repeated_until_its_reply_completes() {
    let mut events = vec![Event::MacosMajor(27)];
    events.extend(ntstat::PROVIDERS.map(|p| Event::Send(ntstat::add_all_sources(p))));
    events.push(Event::Process {
        pid: MAIL,
        path: Some(MAIL_PATH.into()),
    });
    events.extend([
        Event::Timeout,
        // The first baseline reply stops after its first chunk: flow 2 never arrives.
        Event::Send(ntstat::poll_all(POLL)),
        datagram(&[
            tcp_update(1, 9_000_000, 0, MAIL, false, 360),
            success(POLL, true),
        ]),
        Event::Send(ntstat::poll_all(POLL)),
        Event::Timeout,
        // The engine polls again, without reading the interfaces in between, and gets both flows.
        Event::Send(ntstat::poll_all(POLL + 1)),
        datagram(&[
            tcp_update(1, 9_000_000, 0, MAIL, false, 360),
            tcp_update(2, 7_000_000, 0, MAIL, false, 360),
            success(POLL + 1, false),
        ]),
        en0(1_000_000, 1_000_000),
        Event::Timeout,
        Event::Send(ntstat::poll_all(POLL + 2)),
        datagram(&[
            tcp_update(1, 9_000_100, 0, MAIL, false, 360),
            tcp_update(2, 7_000_500, 0, MAIL, false, 360),
            success(POLL + 2, false),
        ]),
        en0(1_000_600, 1_000_000),
    ]);
    let (snapshot, _) = run(Replay::new(events));
    // 100 + 500 bytes since the completed baseline; without the second baseline poll flow 2
    // would book its 7,000,500 lifetime bytes.
    assert_eq!(snapshot.apps, vec![(mail(), Bytes { rx: 600, tx: 0 })]);
}

#[test]
fn engine_does_not_start_without_a_complete_baseline() {
    let mut events = vec![Event::MacosMajor(27)];
    events.extend(ntstat::PROVIDERS.map(|p| Event::Send(ntstat::add_all_sources(p))));
    events.push(Event::Timeout);
    for attempt in 0..3 {
        events.extend([
            Event::Send(ntstat::poll_all(POLL + attempt)),
            Event::Timeout,
        ]);
    }
    let error = Engine::start(Replay::new(events)).expect_err("no baseline");
    assert_eq!(error.kind(), std::io::ErrorKind::TimedOut);
}

/// `tcp_update` with `nstat_rxduplicatebytes` (offset 112 of the message) set.
fn with_duplicates(mut update: Vec<u8>, rx_duplicate: u32) -> Vec<u8> {
    update[112..116].copy_from_slice(&rx_duplicate.to_ne_bytes());
    update
}

#[test]
fn only_duplicate_bytes_after_the_baseline_are_reported() {
    let mut events = start(
        &[],
        &[with_duplicates(
            tcp_update(1, 9_000_000, 0, MAIL, false, 360),
            50_000,
        )],
    );
    events.extend([
        Event::Timeout,
        Event::Send(ntstat::poll_all(POLL + 1)),
        datagram(&[
            with_duplicates(tcp_update(1, 9_002_000, 0, MAIL, false, 360), 50_300),
            success(POLL + 1, false),
        ]),
        en0(1_002_000, 1_000_000),
    ]);
    let (snapshot, _) = run(Replay::new(events));
    // 2,000 bytes received since the baseline, 300 of them duplicates (50,300 - 50,000).
    assert_eq!(snapshot.apps, vec![(mail(), Bytes { rx: 2_000, tx: 0 })]);
    assert_eq!(snapshot.rx_duplicate(&mail()), 300);
}
