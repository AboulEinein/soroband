//! What the History window shows for one range, aggregated in SQL, and the CSV export.
//!
//! Every total comes from `GROUP BY` queries over the hours of the range; no stored row is held in
//! memory. The chart, the share by network, the busiest day and the heatmap count interface bytes,
//! what crossed the network, as the menu bar does; the apps list counts app bytes, and the gap
//! between the two is the app list's "Other / overhead".
//!
//! Local days, months, weekdays and hours come from the time zone offset at the middle of each
//! stored hour, so in a time zone with a half-hour offset an hour belongs to the local day its
//! larger half falls in, as "today" does ([`crate::day`]).

// Every error is SQLite's own (`rusqlite::Error`) and passes through unchanged.
#![allow(clippy::missing_errors_doc)]

use crate::day::hour_start;
use crate::meter::{App, Bytes};
use crate::store::{DAY, Result, Store};
use rusqlite::functions::FunctionFlags;
use rusqlite::{Connection, OptionalExtension, params};
use std::collections::BTreeMap;
use std::io::Write;

const HOUR: i64 = 3600;

/// What one bar of the usage chart covers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Step {
    Hour,
    Day,
    Month,
}

impl Step {
    #[must_use]
    pub fn parse(text: &str) -> Option<Self> {
        match text {
            "hour" => Some(Self::Hour),
            "day" => Some(Self::Day),
            "month" => Some(Self::Month),
            _ => None,
        }
    }

    fn code(self) -> i64 {
        match self {
            Self::Hour => 0,
            Self::Day => 1,
            Self::Month => 2,
        }
    }
}

/// Unix times `[start, end)`. Both are rounded down to a whole hour, the unit of storage.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Span {
    pub start: i64,
    pub end: i64,
}

impl Span {
    fn hours(self) -> (i64, i64) {
        (hour_start(self.start), hour_start(self.end))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Query {
    pub span: Span,
    /// The span to compare the total with, usually the same elapsed time one range earlier.
    pub previous: Option<Span>,
    /// One network, or every network (no network, id 0, included) when `None`.
    pub network: Option<i64>,
    pub step: Step,
}

/// One network's part of one bar.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Bar {
    /// The first stored hour in the bar; the caller places it in its hour, day or month.
    pub first_hour: i64,
    pub network: i64,
    pub bytes: Bytes,
}

/// One network's totals over the span.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct NetworkShare {
    pub network: i64,
    pub interfaces: Bytes,
    pub apps: Bytes,
}

/// One app's bytes on one network over the span.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppShare {
    pub network: i64,
    pub app: App,
    pub bytes: Bytes,
}

/// Bytes in one weekday and local hour, summed over every such hour of the span.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Cell {
    /// 0 is Sunday.
    pub weekday: u8,
    pub hour: u8,
    pub bytes: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Day {
    /// The first stored hour of the day.
    pub first_hour: i64,
    pub bytes: u64,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct History {
    /// The earliest hour with interface bytes on the network(s), at any time; `None` when there
    /// are none. All Time starts there.
    pub first_hour: Option<i64>,
    /// Interface bytes over the span, the range's total.
    pub interfaces: Bytes,
    /// Interface bytes over [`Query::previous`].
    pub previous: Option<u64>,
    /// In time order, then network id order.
    pub bars: Vec<Bar>,
    /// Largest interface total first.
    pub networks: Vec<NetworkShare>,
    /// Largest app first (over all its networks), then by name; each app's networks in id order.
    pub apps: Vec<AppShare>,
    /// The local day with the most interface bytes; the earliest on a tie.
    pub busiest_day: Option<Day>,
    /// Cells with bytes, in weekday then hour order.
    pub heatmap: Vec<Cell>,
}

/// The History window's numbers for `query`. `zone` gives the local time zone's offset from UTC
/// in seconds at a Unix time ([`crate::day::local_offset`] for the Mac's zone).
pub fn history(store: &Store, query: &Query, zone: fn(i64) -> i64) -> Result<History> {
    let conn = store.connection();
    register_local_time(conn, zone)?;
    let (start, end) = query.span.hours();
    let network = query.network;
    let range = params![start, end, network];

    let first_hour = conn.query_row(
        "SELECT MIN(hour) FROM interface_usage WHERE ?1 IS NULL OR network = ?1",
        [network],
        |row| row.get(0),
    )?;

    let previous = query
        .previous
        .map(|span| {
            let (start, end) = span.hours();
            conn.query_row(
                "SELECT COALESCE(SUM(rx) + SUM(tx), 0) FROM interface_usage
                 WHERE hour >= ?1 AND hour < ?2 AND (?3 IS NULL OR network = ?3)",
                params![start, end, network],
                |row| row.get(0).map(u64_from_sql),
            )
        })
        .transpose()?;

    let mut statement = conn.prepare(
        "SELECT MIN(hour), network, SUM(rx), SUM(tx) FROM interface_usage
         WHERE hour >= ?1 AND hour < ?2 AND (?3 IS NULL OR network = ?3)
         GROUP BY soroband_bar(hour, ?4), network
         ORDER BY 1, network",
    )?;
    let bars = statement
        .query_map(params![start, end, network, query.step.code()], |row| {
            Ok(Bar {
                first_hour: row.get(0)?,
                network: row.get(1)?,
                bytes: bytes(row, 2)?,
            })
        })?
        .collect::<Result<Vec<_>>>()?;

    let apps = app_shares(conn, start, end, network)?;
    let networks = network_shares(conn, start, end, network, &apps)?;
    let interfaces = networks.iter().fold(Bytes::default(), |sum, n| Bytes {
        rx: sum.rx + n.interfaces.rx,
        tx: sum.tx + n.interfaces.tx,
    });

    let busiest_day = conn
        .query_row(
            "SELECT MIN(hour), SUM(rx) + SUM(tx) AS bytes FROM interface_usage
             WHERE hour >= ?1 AND hour < ?2 AND (?3 IS NULL OR network = ?3)
             GROUP BY soroband_bar(hour, 1)
             ORDER BY bytes DESC, 1 LIMIT 1",
            range,
            |row| {
                Ok(Day {
                    first_hour: row.get(0)?,
                    bytes: u64_from_sql(row.get(1)?),
                })
            },
        )
        .optional()?;

    let heatmap = heatmap(conn, start, end, network)?;

    Ok(History {
        first_hour,
        interfaces,
        previous,
        bars,
        networks,
        apps,
        busiest_day,
        heatmap,
    })
}

/// Interface bytes per network from SQL, and app bytes per network summed from `apps`, the
/// already grouped (app, network) rows: a second pass over the stored app rows would double the
/// time a long range takes.
fn network_shares(
    conn: &Connection,
    start: i64,
    end: i64,
    network: Option<i64>,
    apps: &[AppShare],
) -> Result<Vec<NetworkShare>> {
    let mut statement = conn.prepare(
        "SELECT network, SUM(rx), SUM(tx) FROM interface_usage
         WHERE hour >= ?1 AND hour < ?2 AND (?3 IS NULL OR network = ?3)
         GROUP BY network",
    )?;
    let mut shares: BTreeMap<i64, NetworkShare> = statement
        .query_map(params![start, end, network], |row| {
            let network = row.get(0)?;
            Ok((
                network,
                NetworkShare {
                    network,
                    interfaces: bytes(row, 1)?,
                    apps: Bytes::default(),
                },
            ))
        })?
        .collect::<Result<_>>()?;
    for app in apps {
        let share = shares.entry(app.network).or_insert(NetworkShare {
            network: app.network,
            ..NetworkShare::default()
        });
        share.apps.rx += app.bytes.rx;
        share.apps.tx += app.bytes.tx;
    }
    let mut shares: Vec<NetworkShare> = shares.into_values().collect();
    // Largest first; the map gave network id order, which a stable sort keeps for equal totals.
    shares.sort_by_key(|share| std::cmp::Reverse(share.interfaces.total()));
    Ok(shares)
}

fn app_shares(
    conn: &Connection,
    start: i64,
    end: i64,
    network: Option<i64>,
) -> Result<Vec<AppShare>> {
    // Whole UTC days inside the span come from `usage_day`, the hours at either end from
    // `usage`: a year reads about 365 rows per (network, app) instead of 8,760.
    let first_day = (start + DAY - 1).div_euclid(DAY) * DAY;
    let days_from = first_day.min(end);
    let days_to = (end.div_euclid(DAY) * DAY).max(days_from);
    // Grouped before the join, so only the grouped rows look up their app's name.
    let mut statement = conn.prepare(
        "SELECT g.app, g.network, apps.key, apps.name, g.rx, g.tx
         FROM (SELECT app, network, SUM(rx) AS rx, SUM(tx) AS tx FROM (
                   SELECT app, network, rx, tx FROM usage
                   WHERE hour >= ?1 AND hour < ?4 AND (?3 IS NULL OR network = ?3)
                   UNION ALL
                   SELECT app, network, rx, tx FROM usage_day
                   WHERE day >= ?4 AND day < ?5 AND (?3 IS NULL OR network = ?3)
                   UNION ALL
                   SELECT app, network, rx, tx FROM usage
                   WHERE hour >= ?5 AND hour < ?2 AND (?3 IS NULL OR network = ?3))
               GROUP BY app, network) AS g
         JOIN apps ON apps.id = g.app",
    )?;
    let mut rows = statement
        .query_map(params![start, end, network, days_from, days_to], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                AppShare {
                    network: row.get(1)?,
                    app: App {
                        id: row.get(2)?,
                        name: row.get(3)?,
                    },
                    bytes: bytes(row, 4)?,
                },
            ))
        })?
        .collect::<Result<Vec<_>>>()?;
    // Ordered here rather than by SQL's window function, which took a fifth of a year's read: the
    // rows are already one per (app, network), a few thousand at most.
    let mut totals: BTreeMap<i64, u64> = BTreeMap::new();
    for (app, share) in &rows {
        *totals.entry(*app).or_default() += share.bytes.total();
    }
    rows.sort_by(|(a, x), (b, y)| {
        totals[b]
            .cmp(&totals[a])
            .then_with(|| x.app.name.cmp(&y.app.name))
            .then_with(|| x.app.id.cmp(&y.app.id))
            .then_with(|| x.network.cmp(&y.network))
    });
    Ok(rows.into_iter().map(|(_, share)| share).collect())
}

fn heatmap(conn: &Connection, start: i64, end: i64, network: Option<i64>) -> Result<Vec<Cell>> {
    let mut statement = conn.prepare(
        "SELECT soroband_slot(hour) AS slot, SUM(rx) + SUM(tx) FROM interface_usage
         WHERE hour >= ?1 AND hour < ?2 AND (?3 IS NULL OR network = ?3)
         GROUP BY slot ORDER BY slot",
    )?;
    statement
        .query_map(params![start, end, network], |row| {
            let slot: i64 = row.get(0)?;
            Ok(Cell {
                weekday: u8::try_from(slot / 24).unwrap_or(0),
                hour: u8::try_from(slot % 24).unwrap_or(0),
                bytes: u64_from_sql(row.get(1)?),
            })
        })?
        .filter(|cell| !matches!(cell, Ok(Cell { bytes: 0, .. })))
        .collect()
}

/// Registers the local-time functions the queries group by:
/// - `soroband_bar(hour, step)`: the local hour, day or month the hour falls in, as a number that
///   grows with time;
/// - `soroband_slot(hour)`: weekday × 24 + local hour, 0 being Sunday 00:00.
fn register_local_time(conn: &Connection, zone: fn(i64) -> i64) -> Result<()> {
    let flags = FunctionFlags::SQLITE_UTF8 | FunctionFlags::SQLITE_DETERMINISTIC;
    conn.create_scalar_function("soroband_bar", 2, flags, move |ctx| {
        let local = local_time(ctx.get(0)?, zone);
        Ok(match ctx.get::<i64>(1)? {
            0 => local.div_euclid(HOUR),
            1 => local.div_euclid(DAY),
            _ => {
                let (year, month, _) = civil(local.div_euclid(DAY));
                year * 12 + i64::from(month)
            }
        })
    })?;
    conn.create_scalar_function("soroband_slot", 1, flags, move |ctx| {
        let local = local_time(ctx.get(0)?, zone);
        let weekday = weekday(local.div_euclid(DAY));
        Ok(weekday * 24 + local.rem_euclid(DAY) / HOUR)
    })
}

/// Seconds since the Unix epoch on the local clock, at the middle of the hour starting at `hour`.
fn local_time(hour: i64, zone: fn(i64) -> i64) -> i64 {
    let middle = hour + HOUR / 2;
    middle + zone(middle)
}

/// Day of the week of day `days` since 1970-01-01 (a Thursday); 0 is Sunday.
fn weekday(days: i64) -> i64 {
    (days + 4).rem_euclid(7)
}

/// Year, month (1–12) and day of the month of day `days` since 1970-01-01, in the proleptic
/// Gregorian calendar: Howard Hinnant's `civil_from_days`.
fn civil(days: i64) -> (i64, u8, u8) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let day_of_era = z.rem_euclid(146_097);
    let year_of_era =
        (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    // Months counted from March, so the leap day is the last of the year.
    let march_month = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * march_month + 2) / 5 + 1;
    let month = if march_month < 10 {
        march_month + 3
    } else {
        march_month - 9
    };
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    (
        year,
        u8::try_from(month).unwrap_or(1),
        u8::try_from(day).unwrap_or(1),
    )
}

/// Writes the stored usage over `span`, on `network` or every network, as CSV: a header, then one
/// line per (hour, network, app) in time order:
///
/// ```text
/// hour,network_id,network,network_kind,app,app_id,received_bytes,sent_bytes
/// 2026-10-27T09:00:00Z,1,Home-5G,wifi,Safari,/Applications/Safari.app,1200,300
/// ```
///
/// `hour` is the start of the UTC hour. Usage booked to no network has `network_id` 0 and empty
/// `network` and `network_kind`. Rows are written as SQLite returns them, never all held at once.
/// Returns the number of rows written.
pub fn export_csv(
    store: &Store,
    span: Span,
    network: Option<i64>,
    out: &mut impl Write,
) -> std::result::Result<u64, ExportError> {
    let (start, end) = span.hours();
    let mut statement = store.connection().prepare(
        "SELECT usage.hour, usage.network, networks.name, networks.kind, apps.name, apps.key,
                usage.rx, usage.tx
         FROM usage JOIN apps ON apps.id = usage.app
         LEFT JOIN networks ON networks.id = usage.network
         WHERE usage.hour >= ?1 AND usage.hour < ?2 AND (?3 IS NULL OR usage.network = ?3)
         ORDER BY usage.hour, usage.network, usage.rx + usage.tx DESC, apps.name",
    )?;
    out.write_all(b"hour,network_id,network,network_kind,app,app_id,received_bytes,sent_bytes\n")?;
    let mut rows = statement.query(params![start, end, network])?;
    let mut count = 0;
    while let Some(row) = rows.next()? {
        let hour: i64 = row.get(0)?;
        let network: i64 = row.get(1)?;
        let name: Option<String> = row.get(2)?;
        let kind: Option<String> = row.get(3)?;
        let app: String = row.get(4)?;
        let app_id: String = row.get(5)?;
        let rx: i64 = row.get(6)?;
        let tx: i64 = row.get(7)?;
        writeln!(
            out,
            "{},{network},{},{},{},{},{},{}",
            utc_hour(hour),
            csv_field(name.as_deref().unwrap_or("")),
            csv_field(kind.as_deref().unwrap_or("")),
            csv_field(&app),
            csv_field(&app_id),
            u64_from_sql(rx),
            u64_from_sql(tx),
        )?;
        count += 1;
    }
    Ok(count)
}

#[derive(Debug)]
pub enum ExportError {
    Store(rusqlite::Error),
    Io(std::io::Error),
}

impl std::fmt::Display for ExportError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Store(error) => write!(f, "usage database: {error}"),
            Self::Io(error) => error.fmt(f),
        }
    }
}

impl std::error::Error for ExportError {}

impl From<rusqlite::Error> for ExportError {
    fn from(error: rusqlite::Error) -> Self {
        Self::Store(error)
    }
}

impl From<std::io::Error> for ExportError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}

/// `2026-10-27T09:00:00Z` for the hour starting at Unix time `hour`.
fn utc_hour(hour: i64) -> String {
    let (year, month, day) = civil(hour.div_euclid(DAY));
    format!(
        "{year:04}-{month:02}-{day:02}T{:02}:00:00Z",
        hour.rem_euclid(DAY) / HOUR
    )
}

/// A CSV field: quoted when it holds a comma, quote or line break. A field a spreadsheet would
/// read as a formula (starting with `=`, `+`, `-`, `@`, tab or carriage return) gets a leading
/// `'`, because network names come from Wi‑Fi names anyone nearby can choose.
fn csv_field(text: &str) -> String {
    let guarded = if text.starts_with(['=', '+', '-', '@', '\t', '\r']) {
        format!("'{text}")
    } else {
        text.to_owned()
    };
    if guarded.contains([',', '"', '\n', '\r']) {
        format!("\"{}\"", guarded.replace('"', "\"\""))
    } else {
        guarded
    }
}

fn bytes(row: &rusqlite::Row<'_>, first: usize) -> Result<Bytes> {
    Ok(Bytes {
        rx: u64_from_sql(row.get(first)?),
        tx: u64_from_sql(row.get(first + 1)?),
    })
}

fn u64_from_sql(value: i64) -> u64 {
    u64::try_from(value).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::{
        AppShare, Bar, Cell, Day, NetworkShare, Query, Span, Step, civil, csv_field, export_csv,
        history, utc_hour, weekday,
    };
    use crate::meter::{App, Bytes};
    use crate::store::{AppUsage, InterfaceUsage, NetworkKind, Store};

    // 2026-10-27 00:00:00 UTC, a Tuesday.
    const D: i64 = 1_793_059_200;
    const H: i64 = 3600;

    fn utc(_: i64) -> i64 {
        0
    }

    fn app(name: &str) -> App {
        App {
            id: format!("/Applications/{name}.app"),
            name: name.into(),
        }
    }

    fn b(rx: u64, tx: u64) -> Bytes {
        Bytes { rx, tx }
    }

    fn open(name: &str) -> Store {
        let dir =
            std::env::temp_dir().join(format!("soroband-history-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        Store::open(&dir.join("usage.sqlite")).unwrap()
    }

    /// Two days of usage worked out by hand, with a day before and a week after:
    ///
    /// | Hour (UTC)       | Network      | Interfaces | Apps                              |
    /// | ---------------- | ------------ | ---------- | --------------------------------- |
    /// | Mon 26 Oct 10:00 | 1 Home       | 1000 / 100 | Safari 900 / 90                   |
    /// | Tue 27 Oct 09:00 | 1 Home       | 5000 / 500 | Safari 4000 / 400, Mail 600 / 50  |
    /// | Tue 27 Oct 09:00 | 2 Phone      | 2000 / 0   | Safari 1500 / 0                   |
    /// | Tue 27 Oct 10:00 | 0 no network | 100 / 0    |                                   |
    /// | Tue 27 Oct 23:00 | 1 Home       | 300 / 30   | Mail 250 / 25                     |
    /// | Wed 28 Oct 01:00 | 2 Phone      | 700 / 70   | Mail 600 / 60                     |
    /// | Mon 2 Nov 12:00  | 1 Home       | 40 / 4     |                                   |
    fn fixture(name: &str) -> Store {
        let mut store = open(name);
        let home = store
            .join_network("wifi:Home", "Home", NetworkKind::Wifi)
            .unwrap();
        let phone = store
            .join_network("wifi:Phone", "Phone", NetworkKind::Hotspot)
            .unwrap();
        assert_eq!((home.id, phone.id), (1, 2));
        let usage = |hour, network, name: &str, rx, tx| AppUsage {
            hour,
            network,
            app: app(name),
            bytes: b(rx, tx),
        };
        let interface = |hour, network, rx, tx| InterfaceUsage {
            hour,
            network,
            bytes: b(rx, tx),
        };
        store
            .add(
                &[
                    usage(D - 14 * H, 1, "Safari", 900, 90),
                    usage(D + 9 * H, 1, "Safari", 4000, 400),
                    usage(D + 9 * H, 1, "Mail", 600, 50),
                    usage(D + 9 * H, 2, "Safari", 1500, 0),
                    usage(D + 23 * H, 1, "Mail", 250, 25),
                    usage(D + 25 * H, 2, "Mail", 600, 60),
                ],
                &[
                    interface(D - 14 * H, 1, 1000, 100),
                    interface(D + 9 * H, 1, 5000, 500),
                    interface(D + 9 * H, 2, 2000, 0),
                    interface(D + 10 * H, 0, 100, 0),
                    interface(D + 23 * H, 1, 300, 30),
                    interface(D + 25 * H, 2, 700, 70),
                    interface(D + 6 * 24 * H + 12 * H, 1, 40, 4),
                ],
            )
            .unwrap();
        store
    }

    /// Tuesday and Wednesday, compared with Monday.
    fn two_days(network: Option<i64>, step: Step) -> Query {
        Query {
            span: Span {
                start: D,
                end: D + 48 * H,
            },
            previous: Some(Span {
                start: D - 24 * H,
                end: D,
            }),
            network,
            step,
        }
    }

    #[test]
    #[allow(clippy::too_many_lines)] // one table of expected values
    fn two_days_on_all_networks_add_up_to_the_hand_checked_totals() {
        let store = fixture("all");
        let h = history(&store, &two_days(None, Step::Day), utc).unwrap();
        // Interfaces: Home 5500 + 330, Phone 2000 + 770, no network 100.
        assert_eq!(h.interfaces, b(8100, 600));
        assert_eq!(h.previous, Some(1100), "Monday on Home");
        assert_eq!(
            h.first_hour,
            Some(D - 14 * H),
            "Monday 10:00, before the span"
        );
        assert_eq!(
            h.bars,
            [
                Bar {
                    first_hour: D + 9 * H,
                    network: 1,
                    bytes: b(5300, 530)
                },
                Bar {
                    first_hour: D + 9 * H,
                    network: 2,
                    bytes: b(2000, 0)
                },
                Bar {
                    first_hour: D + 10 * H,
                    network: 0,
                    bytes: b(100, 0)
                },
                Bar {
                    first_hour: D + 25 * H,
                    network: 2,
                    bytes: b(700, 70)
                },
            ]
        );
        assert_eq!(
            h.networks,
            [
                NetworkShare {
                    network: 1,
                    interfaces: b(5300, 530),
                    apps: b(4850, 475)
                },
                NetworkShare {
                    network: 2,
                    interfaces: b(2700, 70),
                    apps: b(2100, 60)
                },
                NetworkShare {
                    network: 0,
                    interfaces: b(100, 0),
                    apps: b(0, 0)
                },
            ]
        );
        // Safari 5900 in all comes before Mail 1585, each split by network.
        assert_eq!(
            h.apps,
            [
                AppShare {
                    network: 1,
                    app: app("Safari"),
                    bytes: b(4000, 400)
                },
                AppShare {
                    network: 2,
                    app: app("Safari"),
                    bytes: b(1500, 0)
                },
                AppShare {
                    network: 1,
                    app: app("Mail"),
                    bytes: b(850, 75)
                },
                AppShare {
                    network: 2,
                    app: app("Mail"),
                    bytes: b(600, 60)
                },
            ]
        );
        assert_eq!(
            h.busiest_day,
            Some(Day {
                first_hour: D + 9 * H,
                bytes: 7930
            })
        );
        // Tuesday is weekday 2, Wednesday 3.
        assert_eq!(
            h.heatmap,
            [
                Cell {
                    weekday: 2,
                    hour: 9,
                    bytes: 7500
                },
                Cell {
                    weekday: 2,
                    hour: 10,
                    bytes: 100
                },
                Cell {
                    weekday: 2,
                    hour: 23,
                    bytes: 330
                },
                Cell {
                    weekday: 3,
                    hour: 1,
                    bytes: 770
                },
            ]
        );
    }

    #[test]
    fn one_network_counts_only_its_own_bytes() {
        let store = fixture("one");
        let h = history(&store, &two_days(Some(2), Step::Day), utc).unwrap();
        assert_eq!(h.interfaces, b(2700, 70));
        assert_eq!(h.previous, Some(0), "Phone was not used on Monday");
        assert_eq!(h.first_hour, Some(D + 9 * H));
        assert_eq!(
            h.bars
                .iter()
                .map(|b| (b.first_hour, b.network))
                .collect::<Vec<_>>(),
            [(D + 9 * H, 2), (D + 25 * H, 2)]
        );
        assert_eq!(
            h.apps
                .iter()
                .map(|a| (a.app.name.as_str(), a.bytes))
                .collect::<Vec<_>>(),
            [("Safari", b(1500, 0)), ("Mail", b(600, 60))]
        );
        assert_eq!(h.networks.len(), 1);
        assert_eq!(h.busiest_day.unwrap().bytes, 2000);
    }

    #[test]
    fn apps_over_part_days_add_the_edge_hours_to_the_whole_days() {
        let store = fixture("part-days");
        // Monday 10:00 to Wednesday 02:00: Monday's and Wednesday's hours from `usage`, all of
        // Tuesday from `usage_day`.
        let query = Query {
            span: Span {
                start: D - 14 * H,
                end: D + 26 * H,
            },
            previous: None,
            network: None,
            step: Step::Day,
        };
        let h = history(&store, &query, utc).unwrap();
        assert_eq!(
            h.apps
                .iter()
                .map(|a| (a.app.name.as_str(), a.network, a.bytes))
                .collect::<Vec<_>>(),
            [
                ("Safari", 1, b(4900, 490)),
                ("Safari", 2, b(1500, 0)),
                ("Mail", 1, b(850, 75)),
                ("Mail", 2, b(600, 60)),
            ]
        );
        // Ending at 01:00 on Wednesday leaves out Wednesday's 01:00 hour.
        let earlier = Query {
            span: Span {
                start: D - 14 * H,
                end: D + 25 * H,
            },
            ..query
        };
        let h = history(&store, &earlier, utc).unwrap();
        assert_eq!(h.apps.iter().filter(|a| a.network == 2).count(), 1);
    }

    #[test]
    fn whole_days_come_from_the_daily_sums_and_the_ends_from_the_hours() {
        let store = open("tables");
        // Rows written to one table only, so the answer shows which table each part was read
        // from: the app writes both alike.
        store
            .connection()
            .execute_batch(&format!(
                "INSERT INTO apps (id, key, name) VALUES (1, 'a', 'Hourly'), (2, 'b', 'Daily');
                 INSERT INTO usage VALUES ({}, 1, 1, 1, 0), ({}, 1, 1, 10, 0), ({}, 1, 1, 100, 0);
                 INSERT INTO usage_day VALUES ({D}, 1, 2, 1000, 0), ({}, 1, 2, 10000, 0);",
                D - 3 * H,
                D + 5 * H,
                D + 24 * H + 2 * H,
                D + 24 * H,
            ))
            .unwrap();
        let apps = |start, end| {
            let query = Query {
                span: Span { start, end },
                previous: None,
                network: None,
                step: Step::Day,
            };
            history(&store, &query, utc)
                .unwrap()
                .apps
                .iter()
                .map(|a| (a.app.name.clone(), a.bytes.rx))
                .collect::<Vec<_>>()
        };
        // Monday 21:00 to Wednesday 03:00: the hours before Tuesday and after Wednesday's start,
        // and Tuesday whole.
        assert_eq!(
            apps(D - 3 * H, D + 27 * H),
            [("Daily".to_owned(), 1000), ("Hourly".to_owned(), 101)]
        );
        // Exactly Tuesday and Wednesday: both days from the daily sums.
        assert_eq!(apps(D, D + 48 * H), [("Daily".to_owned(), 11_000)]);
        // Within Tuesday: hours only.
        assert_eq!(apps(D + H, D + 23 * H), [("Hourly".to_owned(), 10)]);
    }

    #[test]
    fn hour_bars_split_a_day_by_hour() {
        let store = fixture("hours");
        let query = Query {
            span: Span {
                start: D,
                end: D + 24 * H,
            },
            ..two_days(Some(1), Step::Hour)
        };
        let h = history(&store, &query, utc).unwrap();
        assert_eq!(
            h.bars
                .iter()
                .map(|b| (b.first_hour, b.bytes.total()))
                .collect::<Vec<_>>(),
            [(D + 9 * H, 5500), (D + 23 * H, 330)]
        );
    }

    #[test]
    fn month_bars_follow_the_calendar() {
        let store = fixture("months");
        // 1 October to 1 December 2026, UTC.
        let query = Query {
            span: Span {
                start: D - 26 * 24 * H,
                end: D + 35 * 24 * H,
            },
            previous: None,
            network: None,
            step: Step::Month,
        };
        let h = history(&store, &query, utc).unwrap();
        assert_eq!(
            h.bars
                .iter()
                .map(|b| (b.first_hour, b.network, b.bytes.total()))
                .collect::<Vec<_>>(),
            [
                (D - 14 * H, 1, 1100 + 5830),
                (D + 9 * H, 2, 2770),
                (D + 10 * H, 0, 100),
                (D + 6 * 24 * H + 12 * H, 1, 44),
            ]
        );
        assert_eq!(h.previous, None);
    }

    #[test]
    fn the_same_month_of_another_year_is_another_bar() {
        let mut store = open("years");
        let interface = |hour, rx| InterfaceUsage {
            hour,
            network: 1,
            bytes: b(rx, 0),
        };
        // 10 October and 10 December 2026, 10 October and 10 November 2027, UTC.
        let hours = [1_791_590_400, 1_796_860_800, 1_823_126_400, 1_825_804_800];
        store
            .add(
                &[],
                &hours.iter().map(|&h| interface(h, 1)).collect::<Vec<_>>(),
            )
            .unwrap();
        let query = Query {
            span: Span {
                start: 0,
                end: 1_830_000_000,
            },
            previous: None,
            network: None,
            step: Step::Month,
        };
        let h = history(&store, &query, utc).unwrap();
        assert_eq!(
            h.bars.iter().map(|b| b.first_hour).collect::<Vec<_>>(),
            hours,
            "four months, none merged with another"
        );
    }

    #[test]
    fn a_network_with_app_bytes_and_no_interface_bytes_has_its_share() {
        let mut store = open("apps-only");
        store
            .add(
                &[AppUsage {
                    hour: D,
                    network: 5,
                    app: app("Mail"),
                    bytes: b(7, 1),
                }],
                &[],
            )
            .unwrap();
        let h = history(&store, &two_days(None, Step::Day), utc).unwrap();
        assert_eq!(
            h.networks,
            [NetworkShare {
                network: 5,
                interfaces: b(0, 0),
                apps: b(7, 1)
            }]
        );
    }

    #[test]
    fn local_days_and_hours_follow_the_time_zone() {
        let mut store = open("zones");
        store
            .add(
                &[],
                &[
                    // 22:00 UTC on Tuesday is 00:00 on Wednesday at UTC+2.
                    InterfaceUsage {
                        hour: D + 22 * H,
                        network: 1,
                        bytes: b(10, 0),
                    },
                    InterfaceUsage {
                        hour: D + 21 * H,
                        network: 1,
                        bytes: b(1, 0),
                    },
                ],
            )
            .unwrap();
        let h = history(&store, &two_days(None, Step::Day), |_| 2 * H).unwrap();
        assert_eq!(
            h.heatmap
                .iter()
                .map(|c| (c.weekday, c.hour, c.bytes))
                .collect::<Vec<_>>(),
            [(2, 23, 1), (3, 0, 10)]
        );
        assert_eq!(
            h.bars.iter().map(|b| b.first_hour).collect::<Vec<_>>(),
            [D + 21 * H, D + 22 * H],
            "two local days"
        );
        assert_eq!(
            h.busiest_day,
            Some(Day {
                first_hour: D + 22 * H,
                bytes: 10
            })
        );
    }

    #[test]
    fn a_half_hour_zone_puts_an_hour_where_most_of_it_falls() {
        let mut store = open("half-hour");
        let interface = |hour, rx| InterfaceUsage {
            hour,
            network: 1,
            bytes: b(rx, 0),
        };
        // At UTC+5:30, 17:00–18:00 UTC is 22:30–23:30 on Tuesday and 18:00–19:00 UTC is
        // 23:30–00:30, mostly Wednesday.
        store
            .add(&[], &[interface(D + 17 * H, 1), interface(D + 18 * H, 2)])
            .unwrap();
        let h = history(&store, &two_days(None, Step::Day), |_| 5 * H + 30 * 60).unwrap();
        assert_eq!(
            h.heatmap
                .iter()
                .map(|c| (c.weekday, c.hour, c.bytes))
                .collect::<Vec<_>>(),
            [(2, 23, 1), (3, 0, 2)]
        );
        assert_eq!(h.bars.len(), 2, "two local days");
    }

    #[test]
    fn a_daylight_saving_jump_skips_a_local_hour() {
        // UTC+1 until 01:00 UTC on Tuesday, then UTC+2: 00:00 UTC is 01:00 local, 01:00 UTC is
        // 03:00 local.
        fn zone(t: i64) -> i64 {
            if t >= D + H { 2 * H } else { H }
        }
        let mut store = open("dst");
        let interface = |hour, rx| InterfaceUsage {
            hour,
            network: 1,
            bytes: b(rx, 0),
        };
        store
            .add(&[], &[interface(D, 1), interface(D + H, 2)])
            .unwrap();
        let h = history(&store, &two_days(None, Step::Hour), zone).unwrap();
        assert_eq!(
            h.heatmap
                .iter()
                .map(|c| (c.hour, c.bytes))
                .collect::<Vec<_>>(),
            [(1, 1), (3, 2)]
        );
        assert_eq!(h.bars.len(), 2);
    }

    #[test]
    fn spans_are_rounded_down_to_whole_hours() {
        let store = fixture("rounding");
        // From 09:30 to 23:30 on Tuesday: the 09:00 hour is in, the 23:00 hour is out.
        let query = Query {
            span: Span {
                start: D + 9 * H + 1800,
                end: D + 23 * H + 1800,
            },
            previous: None,
            network: Some(1),
            step: Step::Day,
        };
        let h = history(&store, &query, utc).unwrap();
        assert_eq!(h.interfaces, b(5000, 500));
    }

    #[test]
    fn an_empty_database_has_no_history() {
        let store = open("empty");
        let h = history(&store, &two_days(None, Step::Day), utc).unwrap();
        assert_eq!(h.first_hour, None);
        assert_eq!(h.interfaces, b(0, 0));
        assert_eq!(h.previous, Some(0));
        assert!(h.bars.is_empty() && h.apps.is_empty() && h.heatmap.is_empty());
        assert_eq!(h.busiest_day, None);
    }

    #[test]
    fn calendar_dates_match_hand_counted_days() {
        // Days since 1970-01-01, counted with Python's datetime.
        assert_eq!(civil(0), (1970, 1, 1));
        assert_eq!(civil(-1), (1969, 12, 31));
        assert_eq!(civil(20_753), (2026, 10, 27));
        assert_eq!(civil(19_782), (2024, 2, 29));
        assert_eq!(civil(19_783), (2024, 3, 1));
        assert_eq!(civil(11_016), (2000, 2, 29));
        assert_eq!(civil(20_818), (2026, 12, 31));
        assert_eq!(civil(20_819), (2027, 1, 1));
        // Century years, which leap only every 400 years.
        assert_eq!(civil(-25_509), (1900, 2, 28));
        assert_eq!(civil(-25_508), (1900, 3, 1));
        assert_eq!(civil(47_540), (2100, 2, 28));
        assert_eq!(civil(47_541), (2100, 3, 1));
        assert_eq!(civil(157_113), (2400, 2, 29));
        assert_eq!(civil(-135_080), (1600, 3, 1));
        assert_eq!(civil(10_956), (1999, 12, 31));
        assert_eq!(weekday(20_753), 2, "Tuesday");
        assert_eq!(weekday(-1), 3, "Wednesday");
        assert_eq!(weekday(20_819), 5, "Friday");
    }

    #[test]
    fn csv_lists_each_stored_bucket_with_its_network() {
        let store = fixture("csv");
        let mut out = Vec::new();
        let rows = export_csv(
            &store,
            Span {
                start: D,
                end: D + 24 * H,
            },
            None,
            &mut out,
        )
        .unwrap();
        assert_eq!(rows, 4);
        assert_eq!(
            String::from_utf8(out).unwrap(),
            "hour,network_id,network,network_kind,app,app_id,received_bytes,sent_bytes\n\
             2026-10-27T09:00:00Z,1,Home,wifi,Safari,/Applications/Safari.app,4000,400\n\
             2026-10-27T09:00:00Z,1,Home,wifi,Mail,/Applications/Mail.app,600,50\n\
             2026-10-27T09:00:00Z,2,Phone,hotspot,Safari,/Applications/Safari.app,1500,0\n\
             2026-10-27T23:00:00Z,1,Home,wifi,Mail,/Applications/Mail.app,250,25\n"
        );
        let mut out = Vec::new();
        export_csv(
            &store,
            Span {
                start: D,
                end: D + 48 * H,
            },
            Some(2),
            &mut out,
        )
        .unwrap();
        assert_eq!(String::from_utf8(out).unwrap().lines().count(), 3);
    }

    #[test]
    fn a_failed_write_says_what_failed() {
        struct Full;
        impl std::io::Write for Full {
            fn write(&mut self, _: &[u8]) -> std::io::Result<usize> {
                Err(std::io::Error::other("disk full"))
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        let store = fixture("csv-full");
        let error = export_csv(
            &store,
            Span {
                start: D,
                end: D + H,
            },
            None,
            &mut Full,
        )
        .unwrap_err();
        assert_eq!(error.to_string(), "disk full");
        let error = super::ExportError::from(rusqlite::Error::InvalidQuery);
        assert!(error.to_string().starts_with("usage database: "), "{error}");
    }

    #[test]
    fn csv_quotes_separators_and_disarms_formulas() {
        assert_eq!(csv_field("Home-5G"), "Home-5G");
        assert_eq!(csv_field("Café, upstairs"), "\"Café, upstairs\"");
        assert_eq!(csv_field("Sam's \"phone\""), "\"Sam's \"\"phone\"\"\"");
        assert_eq!(csv_field("=HYPERLINK(1)"), "'=HYPERLINK(1)");
        assert_eq!(csv_field("-1+1"), "'-1+1");
        assert_eq!(csv_field("@x,y"), "\"'@x,y\"");
        assert_eq!(csv_field("a\nb"), "\"a\nb\"");
        assert_eq!(utc_hour(D + 9 * H), "2026-10-27T09:00:00Z");
        assert_eq!(utc_hour(-H), "1969-12-31T23:00:00Z");
    }

    #[test]
    fn unknown_steps_are_refused() {
        assert_eq!(Step::parse("day"), Some(Step::Day));
        assert_eq!(Step::parse("hour"), Some(Step::Hour));
        assert_eq!(Step::parse("month"), Some(Step::Month));
        assert_eq!(Step::parse("week"), None);
    }
}
