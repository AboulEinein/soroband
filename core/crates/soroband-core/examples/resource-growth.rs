//! Measures how much the resource tables add to the usage database.
//!
//! Writes `days` days into a new database the way the app does: one write a minute, each with an
//! hour row for every running app (an app holding memory has a row every hour, whether it used
//! CPU or not) and the finished minute with its five busiest apps per measure. Prints the growth
//! per day of the hour and day rows, which are kept forever, and the size the minute record
//! settles at once it holds `resource_minutes_days` (7) days.
//!
//! Usage: cargo run --release --example resource-growth -- [days] [running apps]
//! (default 14 days, 120 running apps).

use soroband_core::meter::App;
use soroband_core::resources::Counters;
use soroband_core::resources::ledger::{Measure, ResourceHour, ResourceMinute};
use soroband_core::store::Store;

const MINUTES_DAYS: i64 = 7;

fn size(path: &std::path::Path) -> u64 {
    // Opening and closing again checkpoints the write-ahead log into the database file.
    drop(Store::open(path).unwrap());
    std::fs::metadata(path).unwrap().len()
}

fn main() {
    let args: Vec<i64> = std::env::args()
        .skip(1)
        .map(|a| a.parse().expect("a number"))
        .collect();
    let days = args.first().copied().unwrap_or(14);
    let running = args.get(1).copied().unwrap_or(120);
    let dir = std::env::temp_dir().join(format!("soroband-resource-growth-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("usage.sqlite");
    let app = |i: i64| App {
        id: format!("/Applications/Some Application {i}.app"),
        name: format!("Some Application {i}"),
    };
    let start = 1_793_059_200;
    let empty = size(&path);
    let mut store = Store::open(&path).unwrap();
    for minute in 0..days * 1440 {
        let now = start + minute * 60;
        let hour = now - now % 3600;
        let hours: Vec<ResourceHour> = (0..running)
            .map(|a| ResourceHour {
                hour,
                app: app(a),
                counters: Counters {
                    cpu: 1_234_567_890,
                    billed: 12_345_678,
                    read: 12_345_678,
                    written: 23_456_789,
                    energy: 3_456_789_012,
                },
                footprint_seconds: 123_456_789 * 60,
                seconds: 60,
                peak: 123_456_789,
                fallback: false,
            })
            .collect();
        let top = |offset: i64| -> Vec<(App, u64)> {
            (0..5)
                .map(|r| (app((minute + offset + r) % running), 987_654_321))
                .collect()
        };
        let finished = ResourceMinute {
            minute: now - 60,
            cpu_busy: Some(0.123),
            memory_used: Some(27_000_000_000),
            memory_compressed: Some(11_000_000_000),
            swap_used: Some(1_000_000_000),
            pressure: Some(1),
            disk_free: Some(120_000_000_000),
            top: vec![
                (Measure::Cpu, top(0)),
                (Measure::Memory, top(7)),
                (Measure::Written, top(13)),
            ],
            fallback: false,
        };
        store
            .add_resources(&hours, &[finished], now - MINUTES_DAYS * 86_400)
            .unwrap();
    }
    drop(store);
    let full = size(&path);
    let conn = rusqlite_count(&path);
    #[allow(clippy::cast_precision_loss)] // sizes far below 2^52
    let (full_f, empty_f, days_f) = (full as f64, empty as f64, days as f64);
    println!(
        "{days} days, {running} running apps: {full} bytes ({} hour rows, {} minutes kept); \
         {:.1} KB a day after the minute record is full",
        conn.0,
        conn.1,
        (full_f - empty_f - conn.2) / days_f / 1e3,
    );
    println!(
        "minute record at {MINUTES_DAYS} days: about {:.2} MB",
        conn.2 / 1e6
    );
    std::fs::remove_dir_all(&dir).unwrap();
}

/// Hour rows, minutes kept, and the bytes the minute tables take (from `dbstat`, when SQLite has
/// it, else 0).
fn rusqlite_count(path: &std::path::Path) -> (i64, i64, f64) {
    let output = std::process::Command::new("/usr/bin/sqlite3")
        .arg(path)
        .arg(
            "SELECT (SELECT COUNT(*) FROM resource_usage), (SELECT COUNT(*) FROM resource_minutes), \
             (SELECT COALESCE(SUM(pgsize), 0) FROM dbstat WHERE name LIKE 'resource_minute%' \
             OR name LIKE 'sqlite_autoindex_resource_minute%');",
        )
        .output()
        .unwrap();
    let text = String::from_utf8(output.stdout).unwrap();
    let parts: Vec<&str> = text.trim().split('|').collect();
    (
        parts[0].parse().unwrap(),
        parts[1].parse().unwrap(),
        parts[2].parse().unwrap(),
    )
}
