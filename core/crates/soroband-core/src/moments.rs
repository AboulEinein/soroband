//! The island's triggers from traffic: a data hog, background activity and a large transfer,
//! found in the bytes each poll booked per app, and the session a network leaves behind.
//!
//! [`Watch::observe`] takes what one poll booked per app ([`crate::ledger::Booked::by_app`]) and
//! returns the moments it starts. The app shows them on the island, or as notifications when the
//! island is off.
//!
//! - **Data hog:** one app moved at least `hog_bytes` within the last `window` seconds. It fires
//!   once, and again only after that app's bytes in the window have fallen below half the
//!   threshold.
//! - **Background activity:** an app moved at least `background_bytes` within the window while it
//!   was not the frontmost app (bytes it moved in front do not count). Re-armed the same way.
//! - **Large transfer:** an app moves at least [`TRANSFER_FLOOR`] bytes a second in poll after
//!   poll. Once such a run reaches `transfer_bytes` it is announced, then reported at each poll
//!   with its bytes so far and its speed, and once more as done when the app has moved less than
//!   the floor for [`TRANSFER_QUIET_POLLS`] polls in a row.
//!
//! Apps in `ignored` raise none of them.
//!
//! A [`Session`] adds up what crossed the interfaces while the Mac was on one network, for the
//! receipt the island shows when it leaves; [`recap`] sums a day as it ends.

use crate::meter::{App, Bytes};
use crate::store::{NetworkTotal, Store};
use serde_json::{Value, json};
use std::collections::{HashMap, VecDeque};

/// Bytes a second an app must move for a poll to count toward a large transfer: 100 KB/s.
pub const TRANSFER_FLOOR: u64 = 100_000;
/// Polls in a row below [`TRANSFER_FLOOR`] that end a transfer.
pub const TRANSFER_QUIET_POLLS: u8 = 2;

/// When the triggers fire, from the settings.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Limits {
    pub hog_bytes: u64,
    /// Seconds the data hog and background activity look back over.
    pub window: i64,
    pub background_bytes: u64,
    pub transfer_bytes: u64,
    /// App ids ([`App::id`]) that raise no moment.
    pub ignored: Vec<String>,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            hog_bytes: 100_000_000,
            window: 5 * 60,
            background_bytes: 50_000_000,
            transfer_bytes: 50_000_000,
            ignored: Vec::new(),
        }
    }
}

/// A moment found in the traffic.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    Hog {
        app: App,
        bytes: u64,
        minutes: i64,
    },
    Background {
        app: App,
        bytes: u64,
        /// It sent more than it received.
        uploading: bool,
    },
    Transfer {
        app: App,
        /// The system service that moved the bytes for the app ("App Store"), if one did.
        via: Option<&'static str>,
        bytes: u64,
        /// Bytes a second over the last poll.
        rate: u64,
        done: bool,
    },
    /// The Mac joined `network`: its bytes over the last 7 days and today, and the start of the
    /// last hour it was used before, if it was.
    Joined {
        network: i64,
        week: u64,
        today: u64,
        last_seen: Option<i64>,
    },
    /// The Mac left `network`, joined at `since`: what crossed its interfaces meanwhile, and the
    /// app that used most of it.
    Left {
        network: i64,
        since: i64,
        bytes: u64,
        top: Option<(App, u64)>,
    },
    /// A day ended: what crossed the interfaces on every network, on how many networks, and the
    /// app that used most.
    Recap {
        bytes: u64,
        networks: usize,
        top: Option<(App, u64)>,
    },
}

impl Event {
    /// The event as the app reads it: `{"kind": "hog", ...}`, apps as `{"id", "name", "bytes"}`.
    #[must_use]
    pub fn to_json(&self) -> Value {
        let app = |app: &App| json!({ "id": app.id, "name": app.name });
        let top = |top: &Option<(App, u64)>| {
            top.as_ref()
                .map(|(a, bytes)| json!({ "id": a.id, "name": a.name, "bytes": bytes }))
        };
        match self {
            Self::Hog {
                app: a,
                bytes,
                minutes,
            } => json!({ "kind": "hog", "app": app(a), "bytes": bytes, "minutes": minutes }),
            Self::Background {
                app: a,
                bytes,
                uploading,
            } => {
                json!({ "kind": "background", "app": app(a), "bytes": bytes, "uploading": uploading })
            }
            Self::Transfer {
                app: a,
                via,
                bytes,
                rate,
                done,
            } => json!({
                "kind": "transfer", "app": app(a), "via": via, "bytes": bytes, "rate": rate,
                "done": done,
            }),
            Self::Joined {
                network,
                week,
                today,
                last_seen,
            } => json!({
                "kind": "joined", "network": network, "week": week, "today": today,
                "last_seen": last_seen,
            }),
            Self::Left {
                network,
                since,
                bytes,
                top: t,
            } => json!({
                "kind": "left", "network": network, "since": since, "bytes": bytes, "top": top(t),
            }),
            Self::Recap {
                bytes,
                networks,
                top: t,
            } => json!({ "kind": "recap", "bytes": bytes, "networks": networks, "top": top(t) }),
        }
    }
}

/// What crossed the interfaces while the Mac was on one network.
#[derive(Debug)]
pub struct Session {
    network: i64,
    since: i64,
    bytes: u64,
    apps: HashMap<App, u64>,
}

impl Session {
    #[must_use]
    pub fn new(network: i64, since: i64) -> Self {
        Self {
            network,
            since,
            bytes: 0,
            apps: HashMap::new(),
        }
    }

    #[must_use]
    pub fn network(&self) -> i64 {
        self.network
    }

    /// Adds one poll: its interface bytes (local-network bytes taken off) and its bytes per app.
    pub fn add(&mut self, interfaces: Bytes, apps: &[(App, Bytes)]) {
        self.bytes += interfaces.total();
        for (app, bytes) in apps {
            *self.apps.entry(app.clone()).or_default() += bytes.total();
        }
    }

    /// The receipt for leaving the network; none for no network (id 0).
    #[must_use]
    pub fn receipt(self) -> Option<Event> {
        (self.network != 0).then(|| Event::Left {
            network: self.network,
            since: self.since,
            bytes: self.bytes,
            top: top(self.apps.into_iter()),
        })
    }
}

/// The day that ends: today's totals per network and per (network, app).
pub fn recap<'a>(
    networks: impl Iterator<Item = &'a NetworkTotal>,
    apps: impl Iterator<Item = (i64, &'a App, Bytes)>,
) -> Event {
    let mut bytes = 0;
    let mut used = 0;
    for total in networks {
        bytes += total.interfaces.total();
        used += usize::from(total.interfaces.total() > 0);
    }
    let mut per_app: HashMap<App, u64> = HashMap::new();
    for (_, app, b) in apps {
        *per_app.entry(app.clone()).or_default() += b.total();
    }
    Event::Recap {
        bytes,
        networks: used,
        top: top(per_app.into_iter()),
    }
}

/// Moments waiting for the app to take them, at most `capacity`: past it the oldest goes, so an
/// app that stops taking them holds the latest.
#[derive(Debug)]
pub struct Pending {
    events: VecDeque<Value>,
    capacity: usize,
}

impl Pending {
    #[must_use]
    pub const fn new(capacity: usize) -> Self {
        Self {
            events: VecDeque::new(),
            capacity,
        }
    }

    pub fn push(&mut self, event: &Event) {
        if self.events.len() == self.capacity {
            self.events.pop_front();
        }
        self.events.push_back(event.to_json());
    }

    /// Every waiting moment, oldest first, as a JSON array; none wait afterwards.
    pub fn take(&mut self) -> Value {
        Value::from(self.events.drain(..).collect::<Vec<_>>())
    }

    pub fn clear(&mut self) {
        self.events.clear();
    }
}

/// The `count` apps with the most bytes today on `network`, most first (ties by id), from
/// today's bytes per (network, app).
pub fn top_apps<'a>(
    apps: impl Iterator<Item = (i64, &'a App, Bytes)>,
    network: i64,
    count: usize,
) -> Vec<(App, u64)> {
    let mut on_network: Vec<(App, u64)> = apps
        .filter(|&(n, _, bytes)| n == network && bytes.total() > 0)
        .map(|(_, app, bytes)| (app.clone(), bytes.total()))
        .collect();
    on_network.sort_by(|(a, x), (b, y)| y.cmp(x).then_with(|| a.id.cmp(&b.id)));
    on_network.truncate(count);
    on_network
}

/// What network joined says about `network` at Unix time `now`: what crossed its interfaces in
/// the last 7 days (stored) and today (`today`, the service's totals, written or not), and the
/// last hour it carried bytes before. A failed read gives 0 and no last hour.
pub fn joined<'a>(
    store: &Store,
    today: impl Iterator<Item = &'a NetworkTotal>,
    network: i64,
    now: i64,
) -> Event {
    let week = store
        .network_totals(now - 7 * 24 * 3600)
        .map_or(0, |totals| interfaces_of(totals.iter(), network));
    Event::Joined {
        network,
        week,
        today: interfaces_of(today, network),
        last_seen: store
            .last_used()
            .ok()
            .and_then(|last| last.get(&network).copied()),
    }
}

/// What crossed `network`'s interfaces in `totals`, or 0 when it is not there.
fn interfaces_of<'a>(mut totals: impl Iterator<Item = &'a NetworkTotal>, network: i64) -> u64 {
    totals
        .find(|t| t.network == network)
        .map_or(0, |t| t.interfaces.total())
}

/// The app with the most bytes; ties go to the first app by id, so the answer never depends on
/// a map's order.
fn top(apps: impl Iterator<Item = (App, u64)>) -> Option<(App, u64)> {
    apps.filter(|&(_, bytes)| bytes > 0)
        .max_by(|(a, x), (b, y)| x.cmp(y).then_with(|| b.id.cmp(&a.id)))
}

#[derive(Debug)]
struct Recent {
    app: App,
    /// Each poll within the window, oldest first.
    polls: VecDeque<Poll>,
    hog_armed: bool,
    background_armed: bool,
    run: Option<Run>,
}

#[derive(Debug, Clone, Copy)]
struct Poll {
    time: i64,
    bytes: Bytes,
    /// The app was the frontmost app at this poll.
    in_front: bool,
}

#[derive(Debug)]
struct Run {
    bytes: u64,
    announced: bool,
    quiet: u8,
}

#[derive(Debug, Default)]
pub struct Watch {
    limits: Limits,
    apps: HashMap<String, Recent>,
    last_poll: Option<i64>,
}

impl Watch {
    #[must_use]
    pub fn new(limits: Limits) -> Self {
        Self {
            limits,
            ..Self::default()
        }
    }

    pub fn set_limits(&mut self, limits: Limits) {
        self.apps.retain(|id, _| !limits.ignored.contains(id));
        self.limits = limits;
    }

    /// Takes what one poll at Unix time `now` booked per app, with the service that moved each
    /// app's bytes for it (`via`), and the frontmost app's id. Returns the moments it starts.
    pub fn observe(
        &mut self,
        now: i64,
        booked: &[(App, Bytes)],
        via: &dyn Fn(&App) -> Option<&'static str>,
        frontmost: Option<&str>,
    ) -> Vec<Event> {
        // The first poll's span is unknown, so it rates no transfer.
        let elapsed = self.last_poll.map(|last| (now - last).max(1));
        self.last_poll = Some(now);
        for (app, bytes) in booked {
            if bytes.total() == 0 || self.limits.ignored.contains(&app.id) {
                continue;
            }
            let recent = self.apps.entry(app.id.clone()).or_insert_with(|| Recent {
                app: app.clone(),
                polls: VecDeque::new(),
                hog_armed: true,
                background_armed: true,
                run: None,
            });
            recent.polls.push_back(Poll {
                time: now,
                bytes: *bytes,
                in_front: frontmost == Some(app.id.as_str()),
            });
        }
        let mut events = Vec::new();
        let limits = &self.limits;
        for recent in self.apps.values_mut() {
            while recent
                .polls
                .front()
                .is_some_and(|poll| poll.time <= now - limits.window)
            {
                recent.polls.pop_front();
            }
            let mut sum = Bytes::default();
            let mut behind = Bytes::default();
            for poll in &recent.polls {
                sum += poll.bytes;
                if !poll.in_front {
                    behind += poll.bytes;
                }
            }
            let this_poll = recent
                .polls
                .back()
                .filter(|poll| poll.time == now)
                .map_or(Bytes::default(), |poll| poll.bytes);
            let fired_hog = check_hog(recent, sum, limits, &mut events);
            if !fired_hog {
                check_background(recent, behind, limits, frontmost, &mut events);
            }
            if let Some(elapsed) = elapsed {
                check_transfer(recent, this_poll, elapsed, limits, via, &mut events);
            }
        }
        self.apps
            .retain(|_, recent| !recent.polls.is_empty() || recent.run.is_some());
        events
    }
}

fn check_hog(recent: &mut Recent, sum: Bytes, limits: &Limits, events: &mut Vec<Event>) -> bool {
    if sum.total() < limits.hog_bytes / 2 {
        recent.hog_armed = true;
    }
    if recent.hog_armed && sum.total() >= limits.hog_bytes {
        recent.hog_armed = false;
        // One alert for one burst: a hog that is also in the background is told once, as a hog.
        recent.background_armed = false;
        events.push(Event::Hog {
            app: recent.app.clone(),
            bytes: sum.total(),
            minutes: limits.window / 60,
        });
        return true;
    }
    false
}

/// `behind`: the bytes in the window the app moved while not in front.
fn check_background(
    recent: &mut Recent,
    behind: Bytes,
    limits: &Limits,
    frontmost: Option<&str>,
    events: &mut Vec<Event>,
) {
    if behind.total() < limits.background_bytes / 2 {
        recent.background_armed = true;
    }
    if recent.background_armed
        && behind.total() >= limits.background_bytes
        && frontmost != Some(recent.app.id.as_str())
    {
        recent.background_armed = false;
        events.push(Event::Background {
            app: recent.app.clone(),
            bytes: behind.total(),
            uploading: behind.tx > behind.rx,
        });
    }
}

fn check_transfer(
    recent: &mut Recent,
    this_poll: Bytes,
    elapsed: i64,
    limits: &Limits,
    via: &dyn Fn(&App) -> Option<&'static str>,
    events: &mut Vec<Event>,
) {
    let rate = this_poll.total() / u64::try_from(elapsed).unwrap_or(1);
    let moving = rate >= TRANSFER_FLOOR;
    let Some(run) = &mut recent.run else {
        if moving {
            recent.run = Some(Run {
                bytes: this_poll.total(),
                announced: false,
                quiet: 0,
            });
            announce(recent, rate, limits, via, events);
        }
        return;
    };
    run.bytes += this_poll.total();
    if moving {
        run.quiet = 0;
    } else {
        run.quiet += 1;
        if run.quiet >= TRANSFER_QUIET_POLLS {
            if run.announced {
                events.push(Event::Transfer {
                    app: recent.app.clone(),
                    via: via(&recent.app),
                    bytes: run.bytes,
                    rate: 0,
                    done: true,
                });
            }
            recent.run = None;
            return;
        }
    }
    announce(recent, rate, limits, via, events);
}

/// Reports the run once it has reached the threshold, and at each poll after that.
fn announce(
    recent: &mut Recent,
    rate: u64,
    limits: &Limits,
    via: &dyn Fn(&App) -> Option<&'static str>,
    events: &mut Vec<Event>,
) {
    let Some(run) = &mut recent.run else { return };
    if run.bytes < limits.transfer_bytes {
        return;
    }
    run.announced = true;
    events.push(Event::Transfer {
        app: recent.app.clone(),
        via: via(&recent.app),
        bytes: run.bytes,
        rate,
        done: false,
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    const MB: u64 = 1_000_000;

    fn app(name: &str) -> App {
        App::from_executable(&format!("/Applications/{name}.app/Contents/MacOS/{name}"))
    }

    fn down(mb: u64) -> Bytes {
        Bytes { rx: mb * MB, tx: 0 }
    }

    fn no_via(_: &App) -> Option<&'static str> {
        None
    }

    /// Feeds `polls` (seconds since start, bytes) for `app` 5 s apart and returns every event.
    fn feed(
        watch: &mut Watch,
        who: &App,
        polls: &[(i64, Bytes)],
        frontmost: Option<&str>,
    ) -> Vec<Event> {
        polls
            .iter()
            .flat_map(|&(t, bytes)| watch.observe(t, &[(who.clone(), bytes)], &no_via, frontmost))
            .collect()
    }

    /// The alerts: every event but transfers, which large polls also start.
    fn alerts(events: Vec<Event>) -> Vec<Event> {
        events
            .into_iter()
            .filter(|e| !matches!(e, Event::Transfer { .. }))
            .collect()
    }

    fn hogs(events: &[Event]) -> Vec<u64> {
        events
            .iter()
            .filter_map(|e| match e {
                Event::Hog { bytes, .. } => Some(*bytes / MB),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn hog_fires_once_when_an_app_passes_the_threshold_within_the_window() {
        // 25 MB every 5 s: 100 MB at the fourth poll (t = 15).
        let music = app("Music");
        let mut watch = Watch::new(Limits::default());
        let polls: Vec<_> = (0..8).map(|i| (i * 5, down(25))).collect();
        let events = alerts(feed(&mut watch, &music, &polls, Some(&music.id)));
        assert_eq!(
            hogs(&events),
            vec![100],
            "once, at 100 MB, not again at 125..200 MB"
        );
        assert!(matches!(&events[0], Event::Hog { minutes: 5, .. }));
    }

    #[test]
    fn hog_ignores_bytes_older_than_the_window() {
        // 60 MB, then 60 MB six minutes later: never 100 MB within 5 minutes.
        let music = app("Music");
        let mut watch = Watch::new(Limits::default());
        let events = feed(
            &mut watch,
            &music,
            &[(0, down(60)), (360, down(60))],
            Some(&music.id),
        );
        assert_eq!(hogs(&events), Vec::<u64>::new());
    }

    #[test]
    fn hog_fires_again_only_after_falling_below_half_the_threshold() {
        let music = app("Music");
        let mut watch = Watch::new(Limits::default());
        // 100 MB at t = 0 fires; at t = 301 the first poll left the window, 60 MB remain (over
        // 50 MB, still disarmed), so 60 + 45 MB does not fire. At t = 700 nothing is in the
        // window (re-armed), and 100 MB fires again.
        let polls = [
            (0, down(100)),
            (1, down(60)),
            (301, down(45)),
            (700, down(100)),
        ];
        let events = feed(&mut watch, &music, &polls, Some(&music.id));
        assert_eq!(hogs(&events), vec![100, 100]);
    }

    #[test]
    fn background_fires_for_an_app_that_is_not_in_front() {
        let mail = app("Mail");
        let mut watch = Watch::new(Limits::default());
        let polls = [(0, down(30)), (5, down(30))];
        let events = alerts(feed(
            &mut watch,
            &mail,
            &polls,
            Some("/Applications/Safari.app"),
        ));
        assert_eq!(
            events,
            vec![Event::Background {
                app: mail.clone(),
                bytes: 60 * MB,
                uploading: false
            }]
        );
        let mut front = Watch::new(Limits::default());
        assert!(
            alerts(feed(&mut front, &mail, &polls, Some(&mail.id))).is_empty(),
            "the frontmost app is not in the background"
        );
    }

    #[test]
    fn bytes_moved_in_front_are_not_background_activity() {
        // Safari downloads 60 MB in front, then the user switches to Mail with nothing more moving:
        // no alert. Then 30 MB while behind, still under 50 MB on its own: no alert.
        let safari = app("Safari");
        let limits = Limits {
            hog_bytes: u64::MAX,
            ..Limits::default()
        };
        let mut watch = Watch::new(limits);
        let mut events = feed(
            &mut watch,
            &safari,
            &[(0, down(30)), (5, down(30))],
            Some(&safari.id),
        );
        events.extend(watch.observe(10, &[], &no_via, Some("/System/Applications/Mail.app")));
        events.extend(feed(
            &mut watch,
            &safari,
            &[(15, down(30))],
            Some("/System/Applications/Mail.app"),
        ));
        assert_eq!(alerts(events), []);
        // 25 MB more behind makes 55 MB moved while not in front.
        let more = alerts(feed(
            &mut watch,
            &safari,
            &[(20, down(25))],
            Some("/System/Applications/Mail.app"),
        ));
        assert!(matches!(more[..], [Event::Background { bytes, .. }] if bytes == 55 * MB));
    }

    #[test]
    fn background_tells_an_upload_from_a_download() {
        let photos = app("Photos");
        let mut watch = Watch::new(Limits::default());
        let up = Bytes {
            rx: MB,
            tx: 59 * MB,
        };
        let events = alerts(feed(&mut watch, &photos, &[(0, up)], None));
        assert!(matches!(
            events[..],
            [Event::Background {
                uploading: true,
                ..
            }]
        ));
    }

    #[test]
    fn a_hog_in_the_background_is_one_alert() {
        // 120 MB in one poll from an app not in front passes both thresholds: one hog alert.
        let mail = app("Mail");
        let mut watch = Watch::new(Limits::default());
        let events = alerts(feed(
            &mut watch,
            &mail,
            &[(0, down(120)), (5, down(10))],
            None,
        ));
        assert_eq!(events.len(), 1);
        assert!(matches!(events[0], Event::Hog { .. }));
    }

    #[test]
    fn ignored_apps_raise_nothing() {
        let music = app("Music");
        let limits = Limits {
            ignored: vec![music.id.clone()],
            ..Limits::default()
        };
        let mut watch = Watch::new(limits);
        assert_eq!(
            feed(&mut watch, &music, &[(0, down(200)), (5, down(200))], None),
            []
        );
    }

    fn transfers(events: &[Event]) -> Vec<(u64, u64, bool)> {
        events
            .iter()
            .filter_map(|e| match e {
                Event::Transfer {
                    bytes, rate, done, ..
                } => Some((*bytes / MB, *rate / MB, *done)),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn a_transfer_is_announced_at_the_threshold_reported_each_poll_and_done_when_quiet() {
        // 10 MB every 5 s (2 MB/s). The first poll (t = 0) rates nothing, so the run starts at
        // t = 5 and reaches 50 MB at t = 25. Then 0 at t = 35 and t = 40: done at the second quiet
        // poll, with every byte of the run.
        let xcode = app("Xcode");
        let limits = Limits {
            hog_bytes: u64::MAX,
            background_bytes: u64::MAX,
            ..Limits::default()
        };
        let mut watch = Watch::new(limits);
        let mut polls: Vec<_> = (0..7).map(|i| (i * 5, down(10))).collect();
        polls.extend([(35, Bytes::default()), (40, Bytes::default())]);
        let events = feed(&mut watch, &xcode, &polls, None);
        assert_eq!(
            transfers(&events),
            vec![
                (50, 2, false),
                (60, 2, false),
                (60, 0, false),
                (60, 0, true)
            ]
        );
    }

    #[test]
    fn a_slow_trickle_is_not_a_transfer() {
        // 400 KB every 5 s is 80 KB/s, under the 100 KB/s floor: never a run, however long.
        let mail = app("Mail");
        let limits = Limits {
            transfer_bytes: MB,
            ..Limits::default()
        };
        let mut watch = Watch::new(limits);
        let trickle = Bytes { rx: 400_000, tx: 0 };
        let polls: Vec<_> = (0..20).map(|i| (i * 5, trickle)).collect();
        assert_eq!(transfers(&feed(&mut watch, &mail, &polls, None)), []);
    }

    #[test]
    fn the_first_poll_rates_no_transfer() {
        // 400 KB in the first poll, whose span is unknown: rated over 1 s it would pass the
        // 100 KB/s floor. At 5 s polls it is 80 KB/s, under it.
        let mail = app("Mail");
        let limits = Limits {
            transfer_bytes: 1,
            ..Limits::default()
        };
        let mut watch = Watch::new(limits);
        let trickle = Bytes { rx: 400_000, tx: 0 };
        assert_eq!(
            transfers(&feed(
                &mut watch,
                &mail,
                &[(0, trickle), (5, trickle)],
                None
            )),
            []
        );
    }

    #[test]
    fn a_short_run_that_ends_under_the_threshold_says_nothing() {
        let safari = app("Safari");
        let mut watch = Watch::new(Limits::default());
        let polls = [
            (0, down(20)),
            (5, down(20)),
            (10, Bytes::default()),
            (15, Bytes::default()),
        ];
        assert_eq!(transfers(&feed(&mut watch, &safari, &polls, None)), []);
    }

    #[test]
    fn leaving_a_network_gives_its_session_and_top_app() {
        let (music, safari) = (app("Music"), app("Safari"));
        let mut session = Session::new(4, 1_000);
        session.add(
            down(30),
            &[(music.clone(), down(12)), (safari.clone(), down(10))],
        );
        session.add(down(5), &[(safari.clone(), down(4))]);
        assert_eq!(
            session.receipt(),
            Some(Event::Left {
                network: 4,
                since: 1_000,
                bytes: 35 * MB,
                top: Some((safari, 14 * MB)),
            })
        );
        assert_eq!(
            Session::new(0, 1_000).receipt(),
            None,
            "no network, no receipt"
        );
        assert!(matches!(
            Session::new(4, 0).receipt(),
            Some(Event::Left {
                top: None,
                bytes: 0,
                ..
            })
        ));
    }

    #[test]
    fn the_recap_sums_every_network_and_names_the_top_app_across_them() {
        // Music: 30 MB on network 1 and 30 MB on network 2 (60 MB) beats Safari's 50 MB on one.
        let (music, safari) = (app("Music"), app("Safari"));
        let total = |network, mb| NetworkTotal {
            network,
            apps: down(mb),
            interfaces: down(mb),
        };
        let networks = [total(1, 90), total(2, 40), total(3, 0)];
        let apps = [
            (1, &music, down(30)),
            (1, &safari, down(50)),
            (2, &music, down(30)),
        ];
        assert_eq!(
            recap(networks.iter(), apps.into_iter()),
            Event::Recap {
                bytes: 130 * MB,
                networks: 2,
                top: Some((music, 60 * MB)),
            }
        );
    }

    #[test]
    fn pending_moments_keep_the_latest_when_full() {
        let mut pending = Pending::new(2);
        for networks in 1..=3 {
            pending.push(&Event::Recap {
                bytes: 0,
                networks,
                top: None,
            });
        }
        let kept: Vec<_> = pending
            .take()
            .as_array()
            .unwrap()
            .iter()
            .map(|e| e["networks"].clone())
            .collect();
        assert_eq!(kept, [2, 3], "the oldest went");
        assert_eq!(
            pending.take(),
            Value::from(Vec::<Value>::new()),
            "taken once"
        );
    }

    #[test]
    fn top_apps_are_this_networks_most_bytes_first_at_most_count() {
        let (a, b, c, d) = (app("Alpha"), app("Bravo"), app("Charlie"), app("Delta"));
        let today = [
            (1, &a, down(5)),
            (1, &b, down(9)),
            (2, &c, down(50)),
            (1, &c, down(7)),
            (1, &d, down(1)),
            (1, &d, Bytes::default()),
        ];
        let top = top_apps(today.iter().copied(), 1, 3);
        assert_eq!(
            top,
            [
                (b.clone(), 9 * MB),
                (c.clone(), 7 * MB),
                (a.clone(), 5 * MB)
            ]
        );
        assert_eq!(
            top_apps(today.iter().copied(), 2, 3),
            [(c.clone(), 50 * MB)]
        );
        assert_eq!(top_apps(today.iter().copied(), 3, 3), []);
    }

    #[test]
    fn joined_reads_the_last_7_days_today_and_the_last_hour_used() {
        use crate::store::{InterfaceUsage, NetworkKind};
        let now = 1_793_059_200; // 2026-10-27 00:00 UTC
        let mut store = Store::open(&crate::store::tests::temp_db("moments-joined")).unwrap();
        let office = store
            .join_network("wifi:Office", "Office", NetworkKind::Wifi)
            .unwrap()
            .id;
        let home = store
            .join_network("wifi:Home", "Home", NetworkKind::Wifi)
            .unwrap()
            .id;
        let row = |hour, network, mb| InterfaceUsage {
            hour,
            network,
            bytes: down(mb),
        };
        // 8 days ago (outside), 2 days ago and an hour ago on Office; Home only 3 hours ago.
        let rows = [
            row(now - 8 * 86_400, office, 100),
            row(now - 2 * 86_400, office, 20),
            row(now - 3600, office, 3),
            row(now - 3 * 3600, home, 40),
        ];
        store.add(&[], &rows).unwrap();
        let today = [NetworkTotal {
            network: office,
            apps: down(1),
            interfaces: down(4),
        }];
        assert_eq!(
            joined(&store, today.iter(), office, now),
            Event::Joined {
                network: office,
                week: 23 * MB,
                today: 4 * MB,
                last_seen: Some(now - 3600),
            }
        );
        let never = store
            .join_network("wifi:New", "New", NetworkKind::Wifi)
            .unwrap()
            .id;
        assert_eq!(
            joined(&store, today.iter(), never, now),
            Event::Joined {
                network: never,
                week: 0,
                today: 0,
                last_seen: None,
            }
        );
    }

    #[test]
    fn a_transfer_names_the_service_that_moved_it() {
        let xcode = app("Xcode");
        let mut watch = Watch::new(Limits::default());
        let via = |a: &App| (a.name == "Xcode").then_some("App Store");
        watch.observe(0, &[], &via, None);
        let events = watch.observe(5, &[(xcode.clone(), down(60))], &via, None);
        assert!(events.iter().any(|e| matches!(
            e,
            Event::Transfer {
                via: Some("App Store"),
                ..
            }
        )));
    }
}
