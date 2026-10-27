//! Books the meter's new bytes to (hour, network, app) until they are written to the store.
//!
//! The engine reports totals since it started. After each poll [`Ledger::book`] takes the part of
//! each total that is new since the last booking and adds it to the hour the poll ran in, on the
//! network current at that moment. The bytes moved between two polls all land in the hour of the
//! second poll, so an hour boundary moves at most one poll interval of bytes into the next hour.

use crate::day::hour_start;
use crate::meter::{App, Bytes, Snapshot};
use crate::store::{AppUsage, InterfaceUsage};
use std::collections::HashMap;

#[derive(Debug, Default)]
pub struct Ledger {
    network: i64,
    /// Totals at the last booking.
    seen_apps: HashMap<App, Bytes>,
    seen_interfaces: Bytes,
    /// Booked and not yet written, by (hour, network, app) and (hour, network).
    apps: HashMap<(i64, i64, App), Bytes>,
    interfaces: HashMap<(i64, i64), Bytes>,
}

/// What one booking added for the current network.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct Booked {
    pub apps: Bytes,
    pub interfaces: Bytes,
}

impl Ledger {
    /// A ledger booking to `network`, for an engine whose totals are all still zero.
    #[must_use]
    pub fn new(network: i64) -> Self {
        Self {
            network,
            ..Self::default()
        }
    }

    #[must_use]
    pub fn network(&self) -> i64 {
        self.network
    }

    /// Books from now on to `network`. Bytes booked before stay on the previous network.
    pub fn switch(&mut self, network: i64) {
        self.network = network;
    }

    /// Books what is new in `snapshot` since the last booking to the hour of `now`.
    pub fn book(&mut self, snapshot: &Snapshot, now: i64) -> Booked {
        let hour = hour_start(now);
        let mut booked = Booked::default();
        for (app, total) in &snapshot.apps {
            let seen = self.seen_apps.entry(app.clone()).or_default();
            let delta = Bytes {
                rx: total.rx.saturating_sub(seen.rx),
                tx: total.tx.saturating_sub(seen.tx),
            };
            *seen = *total;
            if delta.total() > 0 {
                *self
                    .apps
                    .entry((hour, self.network, app.clone()))
                    .or_default() += delta;
                booked.apps += delta;
            }
        }
        let delta = Bytes {
            rx: snapshot
                .interfaces
                .rx
                .saturating_sub(self.seen_interfaces.rx),
            tx: snapshot
                .interfaces
                .tx
                .saturating_sub(self.seen_interfaces.tx),
        };
        self.seen_interfaces = snapshot.interfaces;
        if delta.total() > 0 {
            *self.interfaces.entry((hour, self.network)).or_default() += delta;
            booked.interfaces = delta;
        }
        booked
    }

    /// Whether anything is booked and not yet taken.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.apps.is_empty() && self.interfaces.is_empty()
    }

    /// Takes everything booked, for writing to the store.
    pub fn take(&mut self) -> (Vec<AppUsage>, Vec<InterfaceUsage>) {
        let mut apps: Vec<AppUsage> = self
            .apps
            .drain()
            .map(|((hour, network, app), bytes)| AppUsage {
                hour,
                network,
                app,
                bytes,
            })
            .collect();
        apps.sort_by(|a, b| (a.hour, a.network, &a.app).cmp(&(b.hour, b.network, &b.app)));
        let mut interfaces: Vec<InterfaceUsage> = self
            .interfaces
            .drain()
            .map(|((hour, network), bytes)| InterfaceUsage {
                hour,
                network,
                bytes,
            })
            .collect();
        interfaces.sort_by_key(|i| (i.hour, i.network));
        (apps, interfaces)
    }

    /// Puts rows back after a failed write, so the next write retries them.
    pub fn restore(&mut self, apps: Vec<AppUsage>, interfaces: Vec<InterfaceUsage>) {
        for row in apps {
            *self
                .apps
                .entry((row.hour, row.network, row.app))
                .or_default() += row.bytes;
        }
        for row in interfaces {
            *self.interfaces.entry((row.hour, row.network)).or_default() += row.bytes;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{Booked, Ledger};
    use crate::meter::{App, Bytes, Mode, Snapshot};
    use crate::store::{AppUsage, InterfaceUsage};

    const H: i64 = 3600;
    // 2026-10-27 10:00:00 UTC.
    const TEN: i64 = 1_793_059_200 + 10 * H;

    fn app(name: &str) -> App {
        App {
            id: format!("/Applications/{name}.app"),
            name: name.into(),
        }
    }

    fn snapshot(apps: &[(&str, u64, u64)], interfaces: (u64, u64)) -> Snapshot {
        Snapshot {
            mode: Mode::PerApp,
            apps: apps
                .iter()
                .map(|&(name, rx, tx)| (app(name), Bytes { rx, tx }))
                .collect(),
            local: Bytes::default(),
            interfaces: Bytes {
                rx: interfaces.0,
                tx: interfaces.1,
            },
            flows: 0,
            rx_duplicates: Vec::new(),
        }
    }

    fn row(hour: i64, network: i64, name: &str, rx: u64, tx: u64) -> AppUsage {
        AppUsage {
            hour,
            network,
            app: app(name),
            bytes: Bytes { rx, tx },
        }
    }

    #[test]
    fn only_bytes_new_since_the_last_booking_are_booked() {
        let mut ledger = Ledger::new(1);
        ledger.book(&snapshot(&[("Mail", 100, 10)], (150, 20)), TEN + 5);
        let booked = ledger.book(&snapshot(&[("Mail", 130, 10)], (190, 25)), TEN + 10);
        assert_eq!(
            booked,
            Booked {
                apps: Bytes { rx: 30, tx: 0 },
                interfaces: Bytes { rx: 40, tx: 5 },
            }
        );
        let (apps, interfaces) = ledger.take();
        // Both bookings fall in the 10:00 hour, so they add up to the totals.
        assert_eq!(apps, [row(TEN, 1, "Mail", 130, 10)]);
        assert_eq!(
            interfaces,
            [InterfaceUsage {
                hour: TEN,
                network: 1,
                bytes: Bytes { rx: 190, tx: 25 },
            }]
        );
        assert!(ledger.is_empty());
    }

    #[test]
    fn bytes_after_an_hour_boundary_go_to_the_new_hour() {
        let mut ledger = Ledger::new(1);
        ledger.book(&snapshot(&[("Mail", 100, 0)], (0, 0)), TEN + H - 1);
        ledger.book(&snapshot(&[("Mail", 160, 0)], (0, 0)), TEN + H);
        let (apps, _) = ledger.take();
        assert_eq!(
            apps,
            [row(TEN, 1, "Mail", 100, 0), row(TEN + H, 1, "Mail", 60, 0)]
        );
    }

    #[test]
    fn bytes_after_a_network_switch_go_to_the_new_network() {
        let mut ledger = Ledger::new(1);
        ledger.book(&snapshot(&[("Mail", 100, 0)], (120, 0)), TEN);
        ledger.switch(2);
        assert_eq!(ledger.network(), 2);
        ledger.book(
            &snapshot(&[("Mail", 100, 0), ("Safari", 40, 4)], (170, 4)),
            TEN + 5,
        );
        let (apps, interfaces) = ledger.take();
        assert_eq!(
            apps,
            [row(TEN, 1, "Mail", 100, 0), row(TEN, 2, "Safari", 40, 4)]
        );
        assert_eq!(
            interfaces,
            [
                InterfaceUsage {
                    hour: TEN,
                    network: 1,
                    bytes: Bytes { rx: 120, tx: 0 },
                },
                InterfaceUsage {
                    hour: TEN,
                    network: 2,
                    bytes: Bytes { rx: 50, tx: 4 },
                },
            ]
        );
    }

    #[test]
    fn interface_only_engine_books_interface_bytes_and_no_apps() {
        let mut ledger = Ledger::new(1);
        ledger.book(&snapshot(&[("Mail", 100, 0)], (100, 0)), TEN);
        ledger.take();
        // The engine switched to interface totals: its app list is now empty.
        let mut only = snapshot(&[], (180, 0));
        only.mode = Mode::InterfaceOnly {
            reason: "test".into(),
        };
        let booked = ledger.book(&only, TEN + 5);
        assert_eq!(booked.apps, Bytes::default());
        assert_eq!(booked.interfaces, Bytes { rx: 80, tx: 0 });
        let (apps, _) = ledger.take();
        assert_eq!(apps, []);
    }

    #[test]
    fn a_poll_where_nothing_moved_books_nothing() {
        let mut ledger = Ledger::new(1);
        ledger.book(&snapshot(&[("Mail", 100, 0)], (100, 0)), TEN);
        ledger.take();
        let booked = ledger.book(&snapshot(&[("Mail", 100, 0)], (100, 0)), TEN + 5);
        assert_eq!(booked, Booked::default());
        // Nothing to write, so the minute's write is skipped.
        assert!(ledger.is_empty());
    }

    #[test]
    fn restored_rows_are_written_with_the_next_ones() {
        let mut ledger = Ledger::new(1);
        ledger.book(&snapshot(&[("Mail", 100, 0)], (100, 0)), TEN);
        let (apps, interfaces) = ledger.take();
        ledger.book(&snapshot(&[("Mail", 150, 0)], (160, 0)), TEN + 5);
        ledger.restore(apps, interfaces);
        let (apps, interfaces) = ledger.take();
        assert_eq!(apps, [row(TEN, 1, "Mail", 150, 0)]);
        assert_eq!(interfaces[0].bytes, Bytes { rx: 160, tx: 0 });
    }
}
