//! The app's metering loop over synthetic kernel sessions and a temporary database: which network
//! and hour bytes are booked to, when they are written, and what "today" holds.
//!
//! Each session has Mail (flow 1) and Safari (flow 2) at zero after the baseline; every poll in
//! the session says how far their counters moved, so each test's expected bytes are the
//! differences written out in its comments.

mod common;

use common::{MAIL, POLL, SAFARI, datagram, en0, mail, safari, start, success, tcp_update};
use soroband_core::meter::record::{Event, Replay};
use soroband_core::meter::{Bytes, Engine, ntstat};
use soroband_core::service::{Command, Service, WRITE_INTERVAL};
use soroband_core::settings::{self, Settings};
use soroband_core::store::{NetworkKind, NetworkTotal, Store};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// 2026-10-27 00:00:00 UTC.
const MIDNIGHT: i64 = 1_793_059_200;
const H: i64 = 3600;

fn utc(_: i64) -> i64 {
    0
}

/// A session whose polls report Mail's and Safari's received bytes and en0's received bytes, all
/// counted from the baseline (en0 starts at 1,000,000 in both directions).
fn session(polls: &[(u64, u64, u64)]) -> Replay {
    let mut events = start(
        &[],
        &[
            tcp_update(1, 0, 0, MAIL, false, 360),
            tcp_update(2, 0, 0, SAFARI, false, 360),
        ],
    );
    for (i, &(mail_rx, safari_rx, en0_rx)) in (1u64..).zip(polls) {
        events.extend([
            Event::Timeout,
            Event::Send(ntstat::poll_all(POLL + i)),
            datagram(&[
                tcp_update(1, mail_rx, 0, MAIL, false, 360),
                tcp_update(2, safari_rx, 0, SAFARI, false, 360),
                success(POLL + i, false),
            ]),
            en0(1_000_000 + en0_rx, 1_000_000),
        ]);
    }
    Replay::new(events)
}

struct Fixture {
    dir: PathBuf,
    store: Arc<Mutex<Store>>,
    home: i64,
    phone: i64,
}

impl Fixture {
    fn new(name: &str) -> Self {
        let dir =
            std::env::temp_dir().join(format!("soroband-service-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let mut store = Store::open(&dir.join("usage.sqlite")).unwrap();
        let home = store
            .join_network("wifi:Home", "Home", NetworkKind::Wifi)
            .unwrap()
            .id;
        let phone = store
            .join_network("wifi:iPhone", "iPhone", NetworkKind::Hotspot)
            .unwrap()
            .id;
        Self {
            dir,
            store: Arc::new(Mutex::new(store)),
            home,
            phone,
        }
    }

    fn service(&self, replay: Replay, now: i64) -> Service<Replay> {
        Service::new(
            Engine::start(replay).unwrap(),
            Arc::clone(&self.store),
            self.dir.join(settings::FILE_NAME),
            utc,
            now,
        )
        .unwrap()
    }

    /// What another process (the `soroband` command) reads from the database file.
    fn reader(&self) -> Store {
        Store::open_read_only(&self.dir.join("usage.sqlite")).unwrap()
    }

    fn set_reset_hour(&self, hour: &str) {
        let path = self.dir.join(settings::FILE_NAME);
        let mut settings = Settings::load(&path).unwrap();
        settings.set(settings::RESET_HOUR, hour).unwrap();
        settings.save(&path).unwrap();
    }
}

fn tick(service: &mut Service<Replay>, now: i64) {
    service.tick(Duration::from_secs(5), now).unwrap();
}

fn rx(rx: u64) -> Bytes {
    Bytes { rx, tx: 0 }
}

#[test]
fn bytes_polled_before_a_network_change_stay_on_the_old_network() {
    let f = Fixture::new("switch");
    let t = MIDNIGHT + 10 * H;
    let mut service = f.service(session(&[(1_000, 0, 1_100), (1_000, 500, 1_650)]), t);
    service.apply(&Command::Network(f.home), t).unwrap();
    // Home: Mail 1,000 and en0 1,100.
    tick(&mut service, t + 5);
    service.apply(&Command::Network(f.phone), t + 7).unwrap();
    // The change wrote Home's bytes at once, without waiting for the minute.
    assert_eq!(
        f.reader().app_totals(0, Some(f.home)).unwrap(),
        [(mail(), rx(1_000))]
    );
    // iPhone: Safari 500 and en0 1,650 - 1,100 = 550.
    tick(&mut service, t + 10);
    assert!(!service.apply(&Command::Stop, t + 12).unwrap());
    let reader = f.reader();
    assert_eq!(
        reader.app_totals(0, Some(f.phone)).unwrap(),
        [(safari(), rx(500))]
    );
    assert_eq!(
        reader.network_totals(0).unwrap(),
        [
            NetworkTotal {
                network: f.home,
                apps: rx(1_000),
                interfaces: rx(1_100),
            },
            NetworkTotal {
                network: f.phone,
                apps: rx(500),
                interfaces: rx(550),
            },
        ]
    );
}

/// Today's apps as the popover lists them: (network, app name, bytes).
fn today_apps(service: &Service<Replay>) -> Vec<(i64, String, Bytes)> {
    service
        .today_apps()
        .map(|(network, app, bytes)| (network, app.name.clone(), bytes))
        .collect()
}

#[test]
fn todays_apps_are_kept_per_network_across_a_switch_and_a_restart() {
    let f = Fixture::new("today-apps");
    let t = MIDNIGHT + 10 * H;
    let mut first = f.service(session(&[(1_000, 0, 1_100), (1_000, 500, 1_650)]), t);
    first.apply(&Command::Network(f.home), t).unwrap();
    // Home: Mail 1,000.
    tick(&mut first, t + 5);
    first.apply(&Command::Network(f.phone), t + 6).unwrap();
    // iPhone: Safari 500.
    tick(&mut first, t + 10);
    assert_eq!(
        today_apps(&first),
        [
            (f.home, "Mail".into(), rx(1_000)),
            (f.phone, "Safari".into(), rx(500)),
        ]
    );
    // What the last poll booked to the current network, for the live speed.
    assert_eq!(first.last_booked().interfaces, rx(550));
    first.apply(&Command::Stop, t + 11).unwrap();

    // The next run reads them back and adds to them: Mail 300 more on Home.
    let mut second = f.service(session(&[(300, 0, 400)]), t + 60);
    second.apply(&Command::Network(f.home), t + 60).unwrap();
    tick(&mut second, t + 65);
    assert_eq!(
        today_apps(&second),
        [
            (f.home, "Mail".into(), rx(1_300)),
            (f.phone, "Safari".into(), rx(500)),
        ]
    );
}

#[test]
fn todays_apps_start_again_at_the_reset_hour() {
    let f = Fixture::new("today-apps-reset");
    let mut service = f.service(session(&[(1_000, 0, 0), (1_000, 70, 0)]), MIDNIGHT + H);
    service
        .apply(&Command::Network(f.home), MIDNIGHT + H)
        .unwrap();
    // Mail at 02:00, Safari at 05:00; a 04:00 reset leaves Safari alone.
    tick(&mut service, MIDNIGHT + 2 * H);
    tick(&mut service, MIDNIGHT + 5 * H);
    f.set_reset_hour("4");
    service
        .apply(&Command::ReloadSettings, MIDNIGHT + 5 * H)
        .unwrap();
    assert_eq!(today_apps(&service), [(f.home, "Safari".into(), rx(70))]);
}

#[test]
fn apps_far_below_the_interfaces_for_twenty_minutes_degrade_the_self_check() {
    use soroband_core::check::{Verdict, WINDOW};
    let f = Fixture::new("self-check");
    let t = MIDNIGHT + 10 * H;
    // Each window: en0 10 MB more, Mail only 0.5 MB more, a 95% gap.
    let mut service = f.service(
        session(&[
            (500_000, 0, 10_000_000),
            (1_000_000, 0, 20_000_000),
            (1_500_000, 0, 30_000_000),
        ]),
        t,
    );
    service.apply(&Command::Network(f.home), t).unwrap();
    tick(&mut service, t + 5);
    tick(&mut service, t + 5 + WINDOW);
    assert_eq!(service.check(), Verdict::Ok, "one failing window");
    tick(&mut service, t + 5 + 2 * WINDOW);
    assert_eq!(service.check(), Verdict::Degraded);
}

#[test]
fn bytes_are_written_once_a_minute() {
    let f = Fixture::new("minute");
    let t = MIDNIGHT + 10 * H;
    let mut service = f.service(session(&[(1_000, 0, 0), (3_000, 0, 0)]), t);
    service.apply(&Command::Network(f.home), t).unwrap();
    tick(&mut service, t + WRITE_INTERVAL - 1);
    assert_eq!(f.reader().app_totals(0, None).unwrap(), []);
    // Today's totals include the unwritten bytes.
    assert_eq!(service.today().network.apps, rx(1_000));
    tick(&mut service, t + WRITE_INTERVAL);
    assert_eq!(
        f.reader().app_totals(0, None).unwrap(),
        [(mail(), rx(3_000))]
    );
}

#[test]
fn todays_totals_survive_a_restart() {
    let f = Fixture::new("restart");
    let t = MIDNIGHT + 10 * H;
    let mut first = f.service(session(&[(1_000, 200, 1_500)]), t);
    first.apply(&Command::Network(f.home), t).unwrap();
    tick(&mut first, t + 5);
    first.apply(&Command::Stop, t + 6).unwrap();

    // The next run starts with its own engine at zero and adds to what is stored.
    let mut second = f.service(session(&[(300, 0, 400)]), t + 60);
    assert_eq!(second.today().all.apps, rx(1_200));
    second.apply(&Command::Network(f.home), t + 60).unwrap();
    tick(&mut second, t + 65);
    let today = second.today();
    assert_eq!(today.network.network, f.home);
    assert_eq!(today.network.apps, rx(1_500));
    assert_eq!(today.network.interfaces, rx(1_900));
    second.apply(&Command::Stop, t + 66).unwrap();
    assert_eq!(
        f.reader().app_totals(0, None).unwrap(),
        [(mail(), rx(1_300)), (safari(), rx(200))]
    );
}

#[test]
fn a_new_day_starts_today_from_zero_and_keeps_yesterday_stored() {
    let f = Fixture::new("rollover");
    let t = MIDNIGHT + 24 * H;
    let mut service = f.service(session(&[(1_000, 0, 0), (1_400, 0, 0)]), t - 10);
    service.apply(&Command::Network(f.home), t - 10).unwrap();
    tick(&mut service, t - 2);
    assert_eq!(service.today().start, MIDNIGHT);
    // The poll 2 s after midnight books the 400 bytes moved since 23:59:58 to the new day.
    tick(&mut service, t + 3);
    let today = service.today();
    assert_eq!(today.start, t);
    assert_eq!(today.network.apps, rx(400));
    // The new day began with a write, so both days are stored.
    let reader = f.reader();
    assert_eq!(
        reader.app_totals(MIDNIGHT, None).unwrap(),
        [(mail(), rx(1_400))]
    );
    assert_eq!(reader.app_totals(t, None).unwrap(), [(mail(), rx(400))]);
}

#[test]
fn changing_the_reset_hour_recounts_today() {
    let f = Fixture::new("reset-hour");
    let mut service = f.service(session(&[(1_000, 0, 0), (1_000, 70, 0)]), MIDNIGHT + H);
    service
        .apply(&Command::Network(f.home), MIDNIGHT + H)
        .unwrap();
    // Mail at 02:00, Safari at 05:00.
    tick(&mut service, MIDNIGHT + 2 * H);
    tick(&mut service, MIDNIGHT + 5 * H);
    assert_eq!(service.today().all.apps, rx(1_070));

    // `soroband config set reset_hour 4`: today now starts at 04:00 and holds only Safari's 70.
    f.set_reset_hour("4");
    service
        .apply(&Command::ReloadSettings, MIDNIGHT + 5 * H)
        .unwrap();
    let today = service.today();
    assert_eq!((today.reset_hour, today.start), (4, MIDNIGHT + 4 * H));
    assert_eq!(today.all.apps, rx(70));

    // Back to midnight: Mail's bytes count again; they were never deleted.
    f.set_reset_hour("0");
    service
        .apply(&Command::ReloadSettings, MIDNIGHT + 5 * H)
        .unwrap();
    assert_eq!(service.today().all.apps, rx(1_070));
}

#[test]
fn unreadable_settings_keep_the_reset_hour_in_use() {
    let f = Fixture::new("bad-settings");
    f.set_reset_hour("4");
    let mut service = f.service(session(&[]), MIDNIGHT + 5 * H);
    assert_eq!(service.today().reset_hour, 4);
    std::fs::write(f.dir.join(settings::FILE_NAME), "{ not json").unwrap();
    service
        .apply(&Command::ReloadSettings, MIDNIGHT + 5 * H)
        .unwrap();
    assert_eq!(service.today().reset_hour, 4);
}

#[test]
fn rejoining_the_current_network_writes_nothing() {
    let f = Fixture::new("same-network");
    let t = MIDNIGHT + 10 * H;
    let mut service = f.service(session(&[(1_000, 0, 0)]), t);
    service.apply(&Command::Network(f.home), t).unwrap();
    tick(&mut service, t + 5);
    // The path monitor reports the same network again: no write, the minute still counts.
    service.apply(&Command::Network(f.home), t + 6).unwrap();
    assert_eq!(f.reader().app_totals(0, None).unwrap(), []);
}

#[test]
fn today_names_the_current_network_before_it_moves_any_bytes() {
    let f = Fixture::new("quiet-network");
    let t = MIDNIGHT + 10 * H;
    let mut service = f.service(session(&[]), t);
    service.apply(&Command::Network(f.phone), t).unwrap();
    let today = service.today();
    assert_eq!(today.network.network, f.phone);
    assert_eq!(today.network.apps, Bytes::default());
}

#[test]
fn a_database_error_names_the_database() {
    let error = soroband_core::service::Error::from(rusqlite_error());
    assert!(error.to_string().starts_with("usage database: "), "{error}");
}

fn rusqlite_error() -> soroband_core::store::Error {
    Store::open_read_only(&std::env::temp_dir().join("soroband-no-such-dir/usage.sqlite"))
        .unwrap_err()
}

#[test]
fn a_failed_write_keeps_its_bytes_and_still_switches_networks() {
    let f = Fixture::new("locked");
    let t = MIDNIGHT + 10 * H;
    let mut service = f.service(session(&[(1_000, 0, 0), (1_000, 300, 0)]), t);
    service.apply(&Command::Network(f.home), t).unwrap();
    tick(&mut service, t + 5);
    // Another connection holds the write lock past the 2 s busy timeout.
    let blocker = rusqlite::Connection::open(f.dir.join("usage.sqlite")).unwrap();
    blocker.execute_batch("BEGIN EXCLUSIVE").unwrap();
    assert!(service.apply(&Command::Network(f.phone), t + 6).is_err());
    blocker.execute_batch("COMMIT").unwrap();
    // Safari's 300 bytes after the failed write go to the iPhone; Mail's 1,000 stay on Home.
    tick(&mut service, t + 10);
    service.apply(&Command::Stop, t + 12).unwrap();
    let reader = f.reader();
    assert_eq!(
        reader.app_totals(0, Some(f.home)).unwrap(),
        [(mail(), rx(1_000))]
    );
    assert_eq!(
        reader.app_totals(0, Some(f.phone)).unwrap(),
        [(safari(), rx(300))]
    );
}

#[test]
fn a_failed_read_of_a_new_day_is_retried() {
    let f = Fixture::new("failed-read");
    let t = MIDNIGHT + 24 * H;
    let mut service = f.service(
        session(&[(1_000, 0, 0), (1_000, 0, 0), (1_000, 0, 0)]),
        t - 10,
    );
    service.apply(&Command::Network(f.home), t - 10).unwrap();
    tick(&mut service, t - 2);
    service.write(t - 1).unwrap();
    // Nothing moves at midnight, so the new day's write succeeds and only the read fails.
    let other = rusqlite::Connection::open(f.dir.join("usage.sqlite")).unwrap();
    other
        .execute_batch("ALTER TABLE usage RENAME TO usage_away")
        .unwrap();
    assert!(service.tick(Duration::from_secs(5), t + 3).is_err());
    other
        .execute_batch("ALTER TABLE usage_away RENAME TO usage")
        .unwrap();
    tick(&mut service, t + 8);
    let today = service.today();
    assert_eq!(today.start, t);
    // Yesterday's 1,000 bytes are not today's.
    assert_eq!(today.all.apps, Bytes::default());
}
