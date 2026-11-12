//! What the resource meter has read but not yet written: per (hour, app) and per minute.
//!
//! An hour row adds each read's counters, and keeps the footprint's time-weighted sum (each read's
//! footprint times the seconds since the read before) and its peak. An app's first read after one
//! without it weighs nothing: it may have started a moment before, so its footprint then (perhaps
//! still growing) does not stand for the interval; it still counts for the peak. Nor does a read
//! in which the app holds no memory: its processes exited, and only what they used before is
//! credited to it. A minute row keeps the system
//! gauges at the minute's last poll (the CPU busy share over the whole minute, the highest memory
//! pressure in it) and the five busiest apps by CPU, by footprint and by disk bytes written in the
//! reads that fell in it. A minute is written once it is over, unless everything is taken.

use super::{AppResources, Counters, Gauges, Reading, Volume};
use crate::day::hour_start;
use crate::meter::App;
use std::collections::BTreeMap;

/// Apps kept per measure in a minute row.
pub const TOP: usize = 5;

/// An app's resources in one hour.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResourceHour {
    pub hour: i64,
    pub app: App,
    /// CPU times in nanoseconds.
    pub counters: Counters,
    /// The footprint in bytes times the seconds it was held, summed over the reads.
    pub footprint_seconds: u64,
    /// Seconds the footprint was read over.
    pub seconds: u64,
    pub peak: u64,
    /// Whether a read in the hour came from the fallback ([`super::Source::Processes`]).
    pub fallback: bool,
}

impl ResourceHour {
    fn merge(&mut self, other: &Self) {
        self.counters += other.counters;
        self.footprint_seconds = self
            .footprint_seconds
            .saturating_add(other.footprint_seconds);
        self.seconds += other.seconds;
        self.peak = self.peak.max(other.peak);
        self.fallback |= other.fallback;
    }
}

/// What a minute row ranks apps by.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Measure {
    /// CPU time in nanoseconds.
    Cpu,
    /// Peak footprint in bytes.
    Memory,
    /// Disk bytes written.
    Written,
}

impl Measure {
    pub const ALL: [Self; 3] = [Self::Cpu, Self::Memory, Self::Written];

    /// The value stored in `resource_minute_apps.measure`.
    #[must_use]
    pub fn code(self) -> i64 {
        match self {
            Self::Cpu => 0,
            Self::Memory => 1,
            Self::Written => 2,
        }
    }
}

/// One minute: the gauges and the busiest apps.
#[derive(Debug, Clone, PartialEq)]
pub struct ResourceMinute {
    /// Unix time of the minute's start.
    pub minute: i64,
    /// The CPU busy share over the minute, from the poll before it to its last.
    pub cpu_busy: Option<f64>,
    pub memory_used: Option<u64>,
    pub memory_compressed: Option<u64>,
    pub swap_used: Option<u64>,
    /// The highest pressure level read in the minute.
    pub pressure: Option<u8>,
    /// Each local volume's free and total bytes, as last read in the minute; empty when none was
    /// read in it.
    pub volumes: Vec<Volume>,
    /// Up to [`TOP`] apps per measure, largest first, leaving out apps at zero.
    pub top: Vec<(Measure, Vec<(App, u64)>)>,
    pub fallback: bool,
}

#[derive(Debug, Default)]
struct Minute {
    /// The gauges of the poll before the minute's first.
    before: Option<Gauges>,
    last: Gauges,
    pressure: Option<u8>,
    volumes: Vec<Volume>,
    apps: BTreeMap<App, [u64; 3]>,
    fallback: bool,
}

/// Rows read since the last write.
#[derive(Debug, Default)]
pub struct ResourceLedger {
    hours: BTreeMap<(i64, App), ResourceHour>,
    minutes: BTreeMap<i64, Minute>,
    /// Finished minutes whose write failed.
    failed: BTreeMap<i64, ResourceMinute>,
    last_gauges: Option<Gauges>,
    /// The apps of the last read: an app's footprint stands for an interval it was read at both
    /// ends of.
    last_apps: std::collections::BTreeSet<App>,
}

fn minute_start(time: i64) -> i64 {
    time - time.rem_euclid(60)
}

impl ResourceLedger {
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.hours.is_empty() && self.minutes.is_empty() && self.failed.is_empty()
    }

    /// Notes the gauges of a poll at Unix time `now`.
    pub fn poll(&mut self, gauges: Gauges, now: i64) {
        let before = self.last_gauges;
        let minute = self
            .minutes
            .entry(minute_start(now))
            .or_insert_with(|| Minute {
                before,
                ..Minute::default()
            });
        minute.last = gauges;
        minute.pressure = minute.pressure.max(gauges.pressure);
        self.last_gauges = Some(gauges);
    }

    /// Notes the local volumes, read at Unix time `now`.
    pub fn volumes(&mut self, volumes: Vec<Volume>, now: i64) {
        self.minutes.entry(minute_start(now)).or_default().volumes = volumes;
    }

    /// Adds a read made at Unix time `now`.
    pub fn book(&mut self, reading: &Reading, now: i64) {
        let hour = hour_start(now);
        #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)] // a read's interval
        let interval = reading.seconds.round().max(0.0) as u64;
        let fallback = reading.fallback();
        let minute = self.minutes.entry(minute_start(now)).or_default();
        minute.fallback |= fallback;
        for (
            app,
            AppResources {
                counters,
                footprint,
            },
        ) in &reading.apps
        {
            let seconds = if *footprint > 0 && self.last_apps.contains(app) {
                interval
            } else {
                0
            };
            let row = ResourceHour {
                hour,
                app: app.clone(),
                counters: *counters,
                footprint_seconds: footprint.saturating_mul(seconds),
                seconds,
                peak: *footprint,
                fallback,
            };
            self.hours
                .entry((hour, app.clone()))
                .and_modify(|r| r.merge(&row))
                .or_insert(row);
            let top = minute.apps.entry(app.clone()).or_default();
            top[0] += counters.cpu;
            top[1] = top[1].max(*footprint);
            top[2] += counters.written;
        }
        self.last_apps = reading
            .apps
            .iter()
            .filter(|(_, r)| r.footprint > 0)
            .map(|(app, _)| app.clone())
            .collect();
    }

    /// Takes every hour row, and the minutes that are over at Unix time `now` (all of them when
    /// `all`).
    pub fn take(&mut self, now: i64, all: bool) -> (Vec<ResourceHour>, Vec<ResourceMinute>) {
        let hours = std::mem::take(&mut self.hours).into_values().collect();
        let current = minute_start(now);
        let kept = if all {
            BTreeMap::new()
        } else {
            self.minutes.split_off(&current)
        };
        let mut minutes: Vec<ResourceMinute> =
            std::mem::take(&mut self.failed).into_values().collect();
        minutes.extend(
            std::mem::replace(&mut self.minutes, kept)
                .into_iter()
                .map(|(start, m)| finish(start, &m)),
        );
        (hours, minutes)
    }

    /// Puts back rows whose write failed, for the next write.
    pub fn restore(&mut self, hours: Vec<ResourceHour>, minutes: Vec<ResourceMinute>) {
        for row in hours {
            self.hours
                .entry((row.hour, row.app.clone()))
                .and_modify(|r| r.merge(&row))
                .or_insert(row);
        }
        for m in minutes {
            self.failed.entry(m.minute).or_insert(m);
        }
    }
}

fn finish(start: i64, m: &Minute) -> ResourceMinute {
    let top = Measure::ALL
        .iter()
        .enumerate()
        .map(|(i, &measure)| {
            let mut apps: Vec<(App, u64)> = m
                .apps
                .iter()
                .filter(|(_, v)| v[i] > 0)
                .map(|(a, v)| (a.clone(), v[i]))
                .collect();
            apps.sort_by(|(a, x), (b, y)| y.cmp(x).then_with(|| a.cmp(b)));
            apps.truncate(TOP);
            (measure, apps)
        })
        .collect();
    ResourceMinute {
        minute: start,
        cpu_busy: m.before.and_then(|before| m.last.busy_since(&before)),
        memory_used: m.last.memory_used,
        memory_compressed: m.last.memory_compressed,
        swap_used: m.last.swap_used,
        pressure: m.pressure,
        volumes: m.volumes.clone(),
        top,
        fallback: m.fallback,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::resources::Source;

    fn app(name: &str) -> App {
        App {
            id: format!("/Applications/{name}.app"),
            name: name.into(),
        }
    }

    fn reading(seconds: f64, apps: &[(&str, u64, u64)]) -> Reading {
        Reading {
            seconds,
            apps: apps
                .iter()
                .map(|&(name, cpu, footprint)| {
                    (
                        app(name),
                        AppResources {
                            counters: Counters {
                                cpu,
                                written: cpu * 2,
                                ..Counters::default()
                            },
                            footprint,
                        },
                    )
                })
                .collect(),
            source: Source::Coalitions,
        }
    }

    #[test]
    fn hour_rows_add_counters_and_weigh_the_footprint_by_time() {
        let mut ledger = ResourceLedger::default();
        ledger.book(&reading(0.0, &[("Mail", 0, 100)]), 3600);
        ledger.book(&reading(60.0, &[("Mail", 5, 300)]), 3660);
        ledger.book(&reading(30.0, &[("Mail", 7, 900)]), 3690);
        let (hours, _) = ledger.take(3700, false);
        assert_eq!(
            hours,
            [ResourceHour {
                hour: 3600,
                app: app("Mail"),
                counters: Counters {
                    cpu: 12,
                    written: 24,
                    ..Counters::default()
                },
                footprint_seconds: 300 * 60 + 900 * 30,
                seconds: 90,
                peak: 900,
                fallback: false,
            }]
        );
    }

    #[test]
    fn an_apps_first_read_counts_for_its_peak_but_not_its_average() {
        let mut ledger = ResourceLedger::default();
        // Read 0.1 s after it started, still filling its memory, then held at 500 for a minute.
        ledger.book(&reading(60.0, &[("Mail", 0, 5)]), 60);
        ledger.book(&reading(60.0, &[("Mail", 0, 500)]), 120);
        // Exited, with what it used before its exit credited: no memory to average.
        ledger.book(&reading(60.0, &[("Mail", 7, 0)]), 180);
        ledger.book(&reading(60.0, &[("Mail", 0, 900)]), 240);
        let (hours, _) = ledger.take(4000, true);
        assert_eq!(hours[0].footprint_seconds, 500 * 60);
        assert_eq!(hours[0].seconds, 60);
        assert_eq!(hours[0].peak, 900);
    }

    #[test]
    fn reads_either_side_of_an_hour_go_to_their_own_hours() {
        let mut ledger = ResourceLedger::default();
        ledger.book(&reading(60.0, &[("Mail", 5, 300)]), 3599);
        ledger.book(&reading(60.0, &[("Mail", 7, 100)]), 3600);
        let (hours, _) = ledger.take(3700, false);
        let rows: Vec<(i64, u64, u64)> = hours
            .iter()
            .map(|h| (h.hour, h.counters.cpu, h.peak))
            .collect();
        assert_eq!(rows, [(0, 5, 300), (3600, 7, 100)]);
    }

    #[test]
    fn a_minute_is_taken_once_it_is_over_and_ranks_its_busiest_apps() {
        let mut ledger = ResourceLedger::default();
        let ticks = |busy: u64, idle: u64| Gauges {
            cpu_ticks: Some([busy, 0, idle, 0]),
            pressure: Some(1),
            ..Gauges::default()
        };
        ledger.poll(ticks(0, 100), 55);
        ledger.poll(ticks(30, 170), 65);
        ledger.poll(ticks(120, 180), 115);
        let names = ["A", "B", "C", "D", "E", "F", "G"];
        let apps: Vec<(&str, u64, u64)> = names
            .iter()
            .zip(1..)
            .map(|(n, i)| (*n, i, 100 - i))
            .collect();
        ledger.book(&reading(60.0, &apps), 70);
        let (_, minutes) = ledger.take(119, false);
        assert_eq!(minutes.len(), 1, "only the minute from 0 is over");
        assert_eq!(minutes[0].minute, 0);
        let (_, minutes) = ledger.take(120, false);
        let m = &minutes[0];
        assert_eq!(m.minute, 60);
        // From the poll before the minute to its last: 120 busy ticks and 80 idle.
        assert_eq!(m.cpu_busy, Some(0.6));
        let cpu: Vec<&str> = m.top[0].1.iter().map(|(a, _)| a.name.as_str()).collect();
        assert_eq!(cpu, ["G", "F", "E", "D", "C"]);
        let memory: Vec<&str> = m.top[1].1.iter().map(|(a, _)| a.name.as_str()).collect();
        assert_eq!(memory, ["A", "B", "C", "D", "E"]);
    }

    #[test]
    fn rows_put_back_after_a_failed_write_are_taken_again_once() {
        let mut ledger = ResourceLedger::default();
        ledger.book(&reading(60.0, &[("Mail", 5, 300)]), 3660);
        let (hours, minutes) = ledger.take(4000, true);
        ledger.book(&reading(60.0, &[("Mail", 1, 100)]), 3720);
        ledger.restore(hours, minutes.clone());
        let (hours, again) = ledger.take(4000, true);
        assert_eq!(hours[0].counters.cpu, 6);
        assert_eq!(hours[0].peak, 300);
        assert_eq!(again.len(), 2);
        assert_eq!(again[0].top, minutes[0].top);
    }

    #[test]
    fn measures_are_stored_as_distinct_codes() {
        let codes: Vec<i64> = Measure::ALL.iter().map(|m| m.code()).collect();
        assert_eq!(codes, [0, 1, 2]);
    }

    #[test]
    fn a_minute_keeps_the_volumes_and_marks_the_fallback() {
        let mut ledger = ResourceLedger::default();
        assert!(ledger.is_empty());
        let volume = Volume {
            path: "/".into(),
            free: 123,
            size: 456,
        };
        ledger.volumes(vec![volume.clone()], 70);
        let mut fallback = reading(60.0, &[("Mail", 0, 100)]);
        fallback.source = Source::Processes {
            reason: "test".into(),
        };
        ledger.book(&fallback, 75);
        ledger.book(&reading(60.0, &[("Mail", 3, 100)]), 3600);
        assert!(!ledger.is_empty());
        let (hours, minutes) = ledger.take(4000, false);
        assert!(ledger.is_empty());
        assert_eq!(minutes[0].volumes, [volume]);
        assert_eq!(minutes[1].volumes, []);
        assert!(minutes[0].fallback && !minutes[1].fallback);
        assert!(hours.iter().find(|h| h.hour == 0).unwrap().fallback);
        assert!(!hours.iter().find(|h| h.hour == 3600).unwrap().fallback);
        // An app at zero is not among the busiest by CPU.
        assert_eq!(minutes[0].top[0].1, []);
        assert_eq!(minutes[0].top[1].1.len(), 1);
    }

    #[test]
    fn an_hour_with_one_read_from_the_fallback_stays_marked() {
        let mut ledger = ResourceLedger::default();
        let mut fallback = reading(60.0, &[("Mail", 1, 100)]);
        fallback.source = Source::Processes {
            reason: "test".into(),
        };
        ledger.book(&fallback, 60);
        ledger.book(&reading(60.0, &[("Mail", 1, 100)]), 120);
        let (hours, _) = ledger.take(4000, true);
        assert!(hours[0].fallback);
        // A minute's disk written adds over its reads.
        let mut ledger = ResourceLedger::default();
        ledger.book(&reading(60.0, &[("Mail", 2, 100)]), 60);
        ledger.book(&reading(5.0, &[("Mail", 3, 100)]), 65);
        let (_, minutes) = ledger.take(4000, true);
        assert_eq!(minutes[0].top[2].1, [(app("Mail"), 10)]);
    }
}
