//! Measures how much the usage database grows per day of use.
//!
//! Writes `days` days into a new database the way the app does: one write a minute, each with the
//! rows for the apps that moved data in that minute, on one network, with apps spread over every
//! hour. Prints the file size per day once all days are written and checkpointed.
//!
//! Usage: cargo run --release --example db-growth -- [days] [apps per hour] [networks per day]
//! (default 30 days, 40 apps an hour, 2 networks a day).

use soroband_core::meter::{App, Bytes};
use soroband_core::store::{AppUsage, InterfaceUsage, NetworkKind, Store};

fn main() {
    let args: Vec<i64> = std::env::args()
        .skip(1)
        .map(|a| a.parse().expect("a number"))
        .collect();
    let days = args.first().copied().unwrap_or(30);
    let apps_per_hour = args.get(1).copied().unwrap_or(40);
    let networks_per_day = args.get(2).copied().unwrap_or(2);

    let dir = std::env::temp_dir().join(format!("soroband-db-growth-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("usage.sqlite");
    let mut store = Store::open(&path).unwrap();
    let networks: Vec<i64> = (0..networks_per_day)
        .map(|n| {
            store
                .join_network(
                    &format!("wifi:network-{n}"),
                    &format!("Network {n}"),
                    NetworkKind::Wifi,
                )
                .unwrap()
                .id
        })
        .collect();
    // 200 distinct apps over the period; each hour uses `apps_per_hour` of them.
    let app = |i: i64| App {
        id: format!("/Applications/Some Application {i}.app"),
        name: format!("Some Application {i}"),
    };
    let start = 1_793_059_200;
    for day in 0..days {
        for hour in 0..24 {
            let hour_start = start + (day * 24 + hour) * 3600;
            // The day's networks take turns, a few hours each.
            let network = networks[usize::try_from(hour * networks_per_day / 24).unwrap()];
            for minute in 0..60 {
                // Each minute a sixth of the hour's apps move data.
                let rows: Vec<AppUsage> = (0..apps_per_hour)
                    .filter(|a| (a + minute) % 6 == 0)
                    .map(|a| AppUsage {
                        hour: hour_start,
                        network,
                        app: app((a + day * 7 + hour) % 200),
                        bytes: Bytes {
                            rx: 123_456_789,
                            tx: 12_345_678,
                        },
                    })
                    .collect();
                let interfaces = [InterfaceUsage {
                    hour: hour_start,
                    network,
                    bytes: Bytes {
                        rx: 133_456_789,
                        tx: 13_345_678,
                    },
                }];
                store.add(&rows, &interfaces).unwrap();
            }
        }
    }
    drop(store);
    // Opening and closing again checkpoints the write-ahead log into the database file.
    drop(Store::open(&path).unwrap());
    let size = std::fs::metadata(&path).unwrap().len();
    let rows = days * 24 * apps_per_hour;
    #[allow(clippy::cast_precision_loss)] // sizes and counts far below 2^52
    let (size_f, days_f, rows_f) = (size as f64, days as f64, rows as f64);
    let per_day = size_f / days_f;
    println!(
        "{days} days, {apps_per_hour} apps an hour, {networks_per_day} networks a day: \
         {rows} usage rows, {size} bytes, {:.1} KB a day, {:.0} bytes a row, {:.2} MB a year",
        per_day / 1e3,
        size_f / rows_f,
        per_day * 365.0 / 1e6
    );
    std::fs::remove_dir_all(&dir).unwrap();
}
