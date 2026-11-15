//! What History shows for one resource over a range, and the minute record of the past days,
//! aggregated in SQL as [`crate::history`] aggregates bytes.
//!
//! The Mac's resources in an hour are its apps' summed: CPU time, disk bytes and energy add up;
//! the footprint is averaged over the time the engine read it, which is the longest any app of the
//! hour was read for, so an app that ran ten minutes of the hour adds a sixth of its footprint. A
//! longer span averages its hours the same way, weighted by the time read in each, and its peak
//! is the highest hour's average. Charts, the heatmap and the busiest day are folded from the
//! Mac's hourly totals (`resource_usage_total`); the apps come from daily sums for whole UTC days
//! ([`Store::resource_totals`]).

// Every error is SQLite's own (`rusqlite::Error`) and passes through unchanged.
#![allow(clippy::missing_errors_doc)]

use crate::history::{Span, Step, register_local_time};
use crate::meter::App;
use crate::resources::Counters;
use crate::resources::ledger::Measure as MinuteMeasure;
use crate::store::{ResourceOrder, ResourceTotal, Result, Store, u64_from_sql};
use rusqlite::{OptionalExtension, params};
use std::collections::BTreeMap;

/// The resource a History page shows.
pub type Measure = ResourceOrder;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Query {
    pub span: Span,
    /// The span to compare the total with, usually the same elapsed time one range earlier.
    pub previous: Option<Span>,
    pub step: Step,
    /// What orders the apps and measures the busiest day, the heatmap and the comparison.
    pub measure: Measure,
}

/// The Mac's resources over some hours.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Sum {
    /// Summed over the apps and hours; CPU times in nanoseconds, energy in nanojoules.
    pub counters: Counters,
    /// The apps' footprints times the seconds each was read, summed (byte-seconds).
    pub footprint_seconds: u128,
    /// The seconds the footprint was read: per hour the longest any app was read, summed.
    pub seconds: u64,
    /// The highest hourly average footprint, in bytes.
    pub peak: u64,
    /// Whether any of it came from the fallback, which leaves out other users' and root
    /// processes.
    pub fallback: bool,
}

impl Sum {
    /// The average footprint over the time read, in bytes; 0 when nothing was read.
    #[must_use]
    pub fn footprint(&self) -> u64 {
        u64::try_from(
            self.footprint_seconds
                .checked_div(u128::from(self.seconds))
                .unwrap_or(0),
        )
        .unwrap_or(u64::MAX)
    }

    /// The number `measure` compares by: CPU time, the average footprint, bytes read and
    /// written, or energy.
    #[must_use]
    pub fn value(&self, measure: Measure) -> u64 {
        let c = self.counters;
        match measure {
            Measure::Cpu => c.cpu,
            Measure::Memory => self.footprint(),
            Measure::Disk => c.read.saturating_add(c.written),
            Measure::Energy => c.energy,
        }
    }

    fn add(&mut self, other: &Self) {
        self.counters += other.counters;
        self.footprint_seconds += other.footprint_seconds;
        self.seconds += other.seconds;
        self.peak = self.peak.max(other.peak);
        self.fallback |= other.fallback;
    }
}

/// One bar of the chart: the hours of one local hour, day or month.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Bar {
    /// The first stored hour in the bar.
    pub first_hour: i64,
    pub sum: Sum,
}

/// The measure in one weekday and local hour over every such hour of the span: summed, or for
/// memory the average footprint.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cell {
    /// 0 is Sunday.
    pub weekday: u8,
    pub hour: u8,
    pub value: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Day {
    /// The first stored hour of the day.
    pub first_hour: i64,
    pub value: u64,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ResourceHistory {
    /// The earliest stored resource hour, at any time; `None` when there is none.
    pub first_hour: Option<i64>,
    pub total: Sum,
    /// The measure over [`Query::previous`].
    pub previous: Option<u64>,
    /// In time order.
    pub bars: Vec<Bar>,
    /// Largest by the measure first, then by name.
    pub apps: Vec<ResourceTotal>,
    /// The local day with the most of the measure; the earliest on a tie.
    pub busiest_day: Option<Day>,
    /// Local days in the span with resources stored.
    pub days: u32,
    /// Cells with a value, in weekday then hour order.
    pub heatmap: Vec<Cell>,
}

/// One stored hour, its apps summed, with the local bar, day and heatmap slot it falls in.
struct Hour {
    start: i64,
    bar: i64,
    day: i64,
    slot: i64,
    sum: Sum,
}

/// The History page of a resource for `query`. `zone` gives the local time zone's offset from UTC
/// in seconds at a Unix time ([`crate::day::local_offset`] for the Mac's zone).
pub fn resource_history(
    store: &Store,
    query: &Query,
    zone: fn(i64) -> i64,
) -> Result<ResourceHistory> {
    let conn = store.connection();
    register_local_time(conn, zone)?;
    let (start, end) = query.span.hours();
    let measure = query.measure;

    let first_hour =
        conn.query_row("SELECT MIN(hour) FROM resource_usage", [], |row| row.get(0))?;
    let hours = hours(store, start, end, query.step)?;

    let mut total = Sum::default();
    let mut bars: Vec<Bar> = Vec::new();
    let mut days: BTreeMap<i64, Day> = BTreeMap::new();
    let mut day_sums: BTreeMap<i64, Sum> = BTreeMap::new();
    let mut slots: BTreeMap<i64, Sum> = BTreeMap::new();
    let mut last_bar = None;
    for hour in &hours {
        total.add(&hour.sum);
        if last_bar == Some(hour.bar) {
            if let Some(bar) = bars.last_mut() {
                bar.sum.add(&hour.sum);
            }
        } else {
            last_bar = Some(hour.bar);
            bars.push(Bar {
                first_hour: hour.start,
                sum: hour.sum,
            });
        }
        days.entry(hour.day).or_insert(Day {
            first_hour: hour.start,
            value: 0,
        });
        day_sums.entry(hour.day).or_default().add(&hour.sum);
        slots.entry(hour.slot).or_default().add(&hour.sum);
    }
    let busiest_day = days
        .iter()
        .map(|(day, d)| Day {
            first_hour: d.first_hour,
            value: day_sums[day].value(measure),
        })
        // Earliest first, so `max_by_key` keeping the last maximum is reversed to keep the first.
        .rev()
        .max_by_key(|d| d.value)
        .filter(|d| d.value > 0);
    let heatmap = slots
        .iter()
        .map(|(&slot, sum)| Cell {
            weekday: u8::try_from(slot / 24).unwrap_or(0),
            hour: u8::try_from(slot % 24).unwrap_or(0),
            value: sum.value(measure),
        })
        .filter(|cell| cell.value > 0)
        .collect();

    let previous = query
        .previous
        .map(|span| {
            let (start, end) = span.hours();
            span_sum(store, start, end).map(|sum| sum.value(measure))
        })
        .transpose()?;

    Ok(ResourceHistory {
        first_hour,
        total,
        previous,
        bars,
        apps: store.resource_totals(start, end, measure)?,
        busiest_day,
        days: u32::try_from(days.len()).unwrap_or(u32::MAX),
        heatmap,
    })
}

/// Each stored hour from `start` up to `end`, its apps summed, in time order.
fn hours(store: &Store, start: i64, end: i64, step: Step) -> Result<Vec<Hour>> {
    let mut statement = store.connection().prepare(
        "SELECT hour, cpu, billed_cpu, disk_read, disk_written, energy, footprint_seconds, seconds,
             fallback, soroband_bar(hour, ?3), soroband_bar(hour, 1), soroband_slot(hour)
         FROM resource_usage_total WHERE hour >= ?1 AND hour < ?2 ORDER BY hour",
    )?;
    statement
        .query_map(params![start, end, step.code()], |row| {
            let footprint_seconds = u64_from_sql(row.get(6)?);
            let seconds = u64_from_sql(row.get(7)?);
            Ok(Hour {
                start: row.get(0)?,
                bar: row.get(9)?,
                day: row.get(10)?,
                slot: row.get(11)?,
                sum: Sum {
                    counters: Counters {
                        cpu: u64_from_sql(row.get(1)?),
                        billed: u64_from_sql(row.get(2)?),
                        read: u64_from_sql(row.get(3)?),
                        written: u64_from_sql(row.get(4)?),
                        energy: u64_from_sql(row.get(5)?),
                    },
                    footprint_seconds: u128::from(footprint_seconds),
                    seconds,
                    peak: footprint_seconds.checked_div(seconds).unwrap_or(0),
                    fallback: row.get(8)?,
                },
            })
        })?
        .collect()
}

/// The Mac's resources from `start` up to `end`. The byte-seconds are summed as a float
/// (`TOTAL`): over a long span they pass what SQLite's integer `SUM` holds (2^63, about a year of
/// 290 GB), which it reports as an error rather than a number.
fn span_sum(store: &Store, start: i64, end: i64) -> Result<Sum> {
    let mut statement = store.connection().prepare(
        "SELECT SUM(cpu), SUM(billed_cpu), SUM(disk_read), SUM(disk_written), SUM(energy),
             TOTAL(footprint_seconds), SUM(seconds), MAX(fallback)
         FROM resource_usage_total WHERE hour >= ?1 AND hour < ?2",
    )?;
    statement.query_row(params![start, end], |row| {
        let footprint_seconds: f64 = row.get(5)?;
        let int = |i| -> rusqlite::Result<u64> {
            Ok(u64_from_sql(row.get::<_, Option<i64>>(i)?.unwrap_or(0)))
        };
        Ok(Sum {
            counters: Counters {
                cpu: int(0)?,
                billed: int(1)?,
                read: int(2)?,
                written: int(3)?,
                energy: int(4)?,
            },
            // Truncates toward zero; byte-seconds are never negative.
            #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
            footprint_seconds: footprint_seconds as u128,
            seconds: int(6)?,
            peak: 0,
            fallback: row.get::<_, Option<bool>>(7)?.unwrap_or(false),
        })
    })
}

/// The system gauges of one minute of the record.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MinuteGauges {
    /// Unix time of the minute's start.
    pub minute: i64,
    pub cpu_busy: Option<f64>,
    pub memory_used: Option<u64>,
    /// The percent of memory available.
    pub memory_level: Option<u8>,
    /// The highest pressure level in the minute: 1 normal, 2 warning, 4 critical.
    pub pressure: Option<u8>,
    /// The volume asked for (the start-up disk where it was not read): free and total bytes.
    pub volume: Option<(u64, u64)>,
    pub fallback: bool,
}

/// The minute record from `from` up to `to` (Unix times), in time order, with the free space of
/// the volume mounted at `volume`, or of the start-up disk in a minute that did not read it.
pub fn minutes(store: &Store, from: i64, to: i64, volume: &str) -> Result<Vec<MinuteGauges>> {
    let mut statement = store.connection().prepare(
        "SELECT m.minute, m.cpu_busy, m.memory_used, m.memory_level, m.pressure,
             COALESCE(v.free, s.free), COALESCE(v.size, s.size), m.fallback
         FROM resource_minutes m
         LEFT JOIN resource_minute_volumes v ON v.minute = m.minute AND v.volume = ?3
         LEFT JOIN resource_minute_volumes s ON s.minute = m.minute AND s.volume = '/'
         WHERE m.minute >= ?1 AND m.minute < ?2
         ORDER BY m.minute",
    )?;
    statement
        .query_map(params![from, to, volume], |row| {
            let free: Option<i64> = row.get(5)?;
            let size: Option<i64> = row.get(6)?;
            Ok(MinuteGauges {
                minute: row.get(0)?,
                cpu_busy: row.get(1)?,
                memory_used: row.get::<_, Option<i64>>(2)?.map(u64_from_sql),
                memory_level: row.get(3)?,
                pressure: row.get(4)?,
                volume: free
                    .zip(size)
                    .map(|(f, s)| (u64_from_sql(f), u64_from_sql(s))),
                fallback: row.get(7)?,
            })
        })?
        .collect()
}

/// The earliest minute the record keeps, or `None` when it is empty.
pub fn first_minute(store: &Store) -> Result<Option<i64>> {
    store
        .connection()
        .query_row("SELECT MIN(minute) FROM resource_minutes", [], |row| {
            row.get(0)
        })
}

/// One minute's busiest apps per measure.
pub type MinuteApps = Vec<(MinuteMeasure, Vec<(App, u64)>)>;

/// The busiest apps of one minute: per measure (CPU time in nanoseconds, footprint in bytes,
/// disk bytes written), up to five, largest first. `None` when the record has no such minute.
pub fn minute_apps(store: &Store, minute: i64) -> Result<Option<MinuteApps>> {
    let conn = store.connection();
    let kept = conn
        .query_row(
            "SELECT 1 FROM resource_minutes WHERE minute = ?1",
            [minute],
            |_| Ok(()),
        )
        .optional()?;
    if kept.is_none() {
        return Ok(None);
    }
    let mut statement = conn.prepare(
        "SELECT r.measure, apps.key, apps.name, r.value FROM resource_minute_apps r
         JOIN apps ON apps.id = r.app
         WHERE r.minute = ?1 ORDER BY r.measure, r.rank",
    )?;
    let rows = statement
        .query_map([minute], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                App {
                    id: row.get(1)?,
                    name: row.get(2)?,
                },
                u64_from_sql(row.get(3)?),
            ))
        })?
        .collect::<Result<Vec<_>>>()?;
    Ok(Some(
        MinuteMeasure::ALL
            .iter()
            .map(|&measure| {
                let apps = rows
                    .iter()
                    .filter(|(code, _, _)| *code == measure.code())
                    .map(|(_, app, value)| (app.clone(), *value))
                    .collect();
                (measure, apps)
            })
            .collect(),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::resources::Volume;
    use crate::resources::ledger::{ResourceHour, ResourceMinute};
    use crate::store::DAY;
    use crate::store::tests::temp_db;

    const HOUR: i64 = 3600;

    fn app(name: &str) -> App {
        App {
            id: format!("/Applications/{name}.app"),
            name: name.into(),
        }
    }

    /// `footprint` bytes read for `seconds` of the hour.
    fn hour(at: i64, name: &str, cpu: u64, footprint: u64, seconds: u64) -> ResourceHour {
        ResourceHour {
            hour: at,
            app: app(name),
            counters: Counters {
                cpu,
                billed: 1,
                read: cpu,
                written: 2 * cpu,
                energy: 10 * cpu,
            },
            footprint_seconds: footprint * seconds,
            seconds,
            peak: footprint,
            fallback: false,
        }
    }

    fn utc(_: i64) -> i64 {
        0
    }

    /// Day 1 (1970-01-02, a Friday): at 00:00 Mail (CPU 10, 100 B all hour) and Xcode (CPU 30,
    /// 300 B for half the hour), at 01:00 Mail (CPU 5, 200 B). Day 2 at 05:00: Xcode (CPU 100,
    /// 50 B) from the fallback.
    fn fixture(name: &str) -> Store {
        let mut store = Store::open(&temp_db(name)).unwrap();
        let fallback = ResourceHour {
            fallback: true,
            ..hour(2 * DAY + 5 * HOUR, "Xcode", 100, 50, 3600)
        };
        store
            .add_resources(
                &[
                    hour(DAY, "Mail", 10, 100, 3600),
                    hour(DAY, "Xcode", 30, 300, 1800),
                    hour(DAY + HOUR, "Mail", 5, 200, 3600),
                    fallback,
                ],
                &[],
                0,
            )
            .unwrap();
        store
    }

    fn query(measure: Measure) -> Query {
        Query {
            span: Span {
                start: DAY,
                end: 3 * DAY,
            },
            previous: Some(Span { start: 0, end: DAY }),
            step: Step::Day,
            measure,
        }
    }

    #[test]
    fn a_range_sums_the_counters_and_averages_the_footprint_over_the_time_read() {
        let store = fixture("resource-history-total");
        let h = resource_history(&store, &query(Measure::Cpu), utc).unwrap();
        assert_eq!(h.first_hour, Some(DAY));
        assert_eq!(h.total.counters.cpu, 145);
        assert_eq!(h.total.counters.written, 290);
        // Hour 00:00: (100 × 3600 + 300 × 1800) / 3600 = 250, the peak; with 01:00 (200) and
        // day 2 (50), 1,800,000 byte-seconds over 10,800 s.
        assert_eq!(h.total.footprint(), 166);
        assert_eq!(h.total.peak, 250);
        assert!(h.total.fallback, "day 2 came from the fallback");
        assert_eq!(h.previous, Some(0), "nothing stored before day 1");
        assert_eq!(h.days, 2);
    }

    #[test]
    fn each_local_day_is_a_bar_with_its_own_average_and_peak() {
        let store = fixture("resource-history-bars");
        let h = resource_history(&store, &query(Measure::Memory), utc).unwrap();
        let bars: Vec<(i64, u64, u64, u64)> = h
            .bars
            .iter()
            .map(|b| {
                (
                    b.first_hour,
                    b.sum.counters.cpu,
                    b.sum.footprint(),
                    b.sum.peak,
                )
            })
            .collect();
        // Day 1: 1,620,000 byte-seconds over 7,200 s.
        assert_eq!(
            bars,
            [(DAY, 45, 225, 250), (2 * DAY + 5 * HOUR, 100, 50, 50)]
        );
        // An hour step splits day 1 into its two hours.
        let hourly = resource_history(
            &store,
            &Query {
                step: Step::Hour,
                ..query(Measure::Memory)
            },
            utc,
        )
        .unwrap();
        assert_eq!(hourly.bars.len(), 3);
        assert_eq!(hourly.bars[0].sum.footprint(), 250);
    }

    #[test]
    fn the_busiest_day_and_the_heatmap_follow_the_measure() {
        let store = fixture("resource-history-measure");
        let cpu = resource_history(&store, &query(Measure::Cpu), utc).unwrap();
        assert_eq!(
            cpu.busiest_day,
            Some(Day {
                first_hour: 2 * DAY + 5 * HOUR,
                value: 100
            })
        );
        let cells: Vec<(u8, u8, u64)> = cpu
            .heatmap
            .iter()
            .map(|c| (c.weekday, c.hour, c.value))
            .collect();
        assert_eq!(cells, [(5, 0, 40), (5, 1, 5), (6, 5, 100)]);
        let memory = resource_history(&store, &query(Measure::Memory), utc).unwrap();
        assert_eq!(
            memory.busiest_day,
            Some(Day {
                first_hour: DAY,
                value: 225
            }),
            "the day with the highest average footprint"
        );
        let cells: Vec<u64> = memory.heatmap.iter().map(|c| c.value).collect();
        assert_eq!(cells, [250, 200, 50]);
        // Disk: read plus written, 3 × CPU in the fixture.
        let disk = resource_history(&store, &query(Measure::Disk), utc).unwrap();
        assert_eq!(disk.busiest_day.unwrap().value, 300);
    }

    #[test]
    fn apps_are_ordered_by_the_measure_over_the_range() {
        let store = fixture("resource-history-apps");
        let names = |measure| -> Vec<String> {
            resource_history(&store, &query(measure), utc)
                .unwrap()
                .apps
                .into_iter()
                .map(|a| a.app.name)
                .collect()
        };
        assert_eq!(names(Measure::Cpu), ["Xcode", "Mail"]);
        // Mail averages 150 B over 7,200 s; Xcode (300 × 1,800 + 50 × 3,600) / 5,400 = 133.
        assert_eq!(names(Measure::Memory), ["Mail", "Xcode"]);
        let h = resource_history(&store, &query(Measure::Cpu), utc).unwrap();
        assert_eq!(h.apps[0].footprint, 133);
        assert!(h.apps[0].fallback && !h.apps[1].fallback);
    }

    /// The apps list reads whole UTC days from the daily sums and the hours at either end from the
    /// hourly rows: a span from 01:00 on day 1 leaves out 00:00's rows.
    #[test]
    fn a_span_starting_inside_a_day_counts_only_its_hours() {
        let store = fixture("resource-history-edge");
        let h = resource_history(
            &store,
            &Query {
                span: Span {
                    start: DAY + HOUR,
                    end: 3 * DAY,
                },
                ..query(Measure::Cpu)
            },
            utc,
        )
        .unwrap();
        let apps: Vec<(String, u64)> = h
            .apps
            .iter()
            .map(|a| (a.app.name.clone(), a.counters.cpu))
            .collect();
        assert_eq!(apps, [("Xcode".into(), 100), ("Mail".into(), 5)]);
        assert_eq!(h.total.counters.cpu, 105);
    }

    /// Two hours whose byte-seconds together pass 2^63, as a year at 290 GB summed would: the
    /// comparison is still read, where SQLite's integer `SUM` fails on the overflow.
    #[test]
    fn a_comparison_past_sixty_four_bits_of_byte_seconds_is_still_read() {
        let store = Store::open(&temp_db("resource-history-overflow")).unwrap();
        let half = i64::MAX / 2 + 1;
        for hour in [0, HOUR] {
            store
                .connection()
                .execute(
                    "INSERT INTO resource_usage_total VALUES (?1, 0, 0, 0, 0, 0, ?2, 3600, 0)",
                    rusqlite::params![hour, half],
                )
                .unwrap();
        }
        let h = resource_history(
            &store,
            &Query {
                span: Span {
                    start: DAY,
                    end: 2 * DAY,
                },
                previous: Some(Span { start: 0, end: DAY }),
                step: Step::Day,
                measure: Measure::Memory,
            },
            utc,
        )
        .unwrap();
        // 2^63 byte-seconds over 7,200 s: about 1.28 PB on average, as a float rounds it.
        #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
        let expected = (2.0_f64.powi(63) / 7200.0) as u64;
        let previous = h.previous.unwrap();
        assert!(
            previous.abs_diff(expected) < expected / 1_000_000,
            "{previous}"
        );
    }

    fn minute(start: i64, volumes: Vec<Volume>) -> ResourceMinute {
        ResourceMinute {
            minute: start,
            cpu_busy: Some(0.5),
            memory_used: Some(8 << 30),
            memory_compressed: None,
            swap_used: None,
            pressure: Some(2),
            memory_level: Some(30),
            volumes,
            top: vec![
                (
                    MinuteMeasure::Cpu,
                    vec![(app("Xcode"), 9), (app("Mail"), 4)],
                ),
                (MinuteMeasure::Written, vec![(app("Mail"), 7)]),
            ],
            fallback: false,
        }
    }

    fn volume(path: &str, free: u64) -> Volume {
        Volume {
            path: path.into(),
            free,
            size: 1000,
        }
    }

    #[test]
    fn minutes_carry_the_volume_asked_for_or_the_startup_disk() {
        let mut store = Store::open(&temp_db("resource-minutes")).unwrap();
        store
            .add_resources(
                &[],
                &[
                    minute(60, vec![volume("/", 100), volume("/Volumes/B", 7)]),
                    minute(120, vec![volume("/", 90)]),
                    minute(180, vec![]),
                ],
                0,
            )
            .unwrap();
        assert_eq!(first_minute(&store).unwrap(), Some(60));
        let read = minutes(&store, 60, 180, "/Volumes/B").unwrap();
        let volumes: Vec<(i64, Option<(u64, u64)>)> =
            read.iter().map(|m| (m.minute, m.volume)).collect();
        assert_eq!(
            volumes,
            [(60, Some((7, 1000))), (120, Some((90, 1000)))],
            "B where it was read, the start-up disk where not; 180 is outside"
        );
        assert_eq!(read[0].memory_level, Some(30));
        assert_eq!(read[0].pressure, Some(2));
        assert_eq!(read[0].cpu_busy, Some(0.5));
        assert_eq!(minutes(&store, 180, 240, "/").unwrap()[0].volume, None);
    }

    #[test]
    fn a_minutes_apps_come_per_measure_in_rank_order() {
        let mut store = Store::open(&temp_db("resource-minute-apps")).unwrap();
        store.add_resources(&[], &[minute(60, vec![])], 0).unwrap();
        let apps = minute_apps(&store, 60).unwrap().unwrap();
        let names: Vec<(MinuteMeasure, Vec<(&str, u64)>)> = apps
            .iter()
            .map(|(m, a)| {
                (
                    *m,
                    a.iter().map(|(app, v)| (app.name.as_str(), *v)).collect(),
                )
            })
            .collect();
        assert_eq!(
            names,
            [
                (MinuteMeasure::Cpu, vec![("Xcode", 9), ("Mail", 4)]),
                (MinuteMeasure::Memory, vec![]),
                (MinuteMeasure::Written, vec![("Mail", 7)]),
            ]
        );
        assert_eq!(minute_apps(&store, 120).unwrap(), None, "not in the record");
    }
}
