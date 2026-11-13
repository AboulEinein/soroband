//! Writes a year of synthetic usage into a data directory, for timing the History window, then
//! times the History query of the year and of its last month.
//!
//! Each hour of the 365 days before now carries 40 apps (from 200) on one of 5 networks, with
//! more traffic in the day than at night, so every chart, share and heatmap cell has data. The
//! year comes to about 350,000 app rows, the size `docs/design.md` measures for a year of use.
//! Each hour also carries the resources of 120 apps (M8 measured about 120 running apps on a busy
//! Mac), about 1,050,000 rows, and the last 7 days a minute record, so History's resource pages
//! are timed on the same year.
//!
//! Usage: cargo run --release --example history-year -- <data dir>
//! The directory must not hold a database yet. Launch a Debug build on it with
//! `open -g --env SOROBAND_DATA_DIR=<data dir> -a <Soroband.app>`.

use soroband_core::day::{hour_start, local_offset, now};
use soroband_core::history::{Query, Span, Step, history};
use soroband_core::meter::{App, Bytes};
use soroband_core::resource_history::{self, Measure};
use soroband_core::resources::ledger::{Measure as MinuteMeasure, ResourceHour, ResourceMinute};
use soroband_core::resources::{Counters, Volume};
use soroband_core::store::{AppUsage, InterfaceUsage, NetworkKind, Store};
use std::time::Instant;

const HOUR: i64 = 3600;
const APPS_PER_HOUR: u64 = 40;
const RESOURCE_APPS_PER_HOUR: u64 = 120;
const GB: u64 = 1 << 30;

#[allow(clippy::too_many_lines, clippy::cast_precision_loss)] // one script; sizes far below 2^52
fn main() {
    let dir = std::path::PathBuf::from(
        std::env::args()
            .nth(1)
            .expect("usage: history-year <data dir>"),
    );
    let path = dir.join("usage.sqlite");
    assert!(!path.exists(), "{} already exists", path.display());
    std::fs::create_dir_all(&dir).unwrap();
    let mut store = Store::open(&path).unwrap();
    let networks: Vec<i64> = [
        ("wifi:Home-5G", "Home-5G", NetworkKind::Wifi),
        ("wifi:Office Wi-Fi", "Office Wi-Fi", NetworkKind::Wifi),
        ("wifi:iPhone", "iPhone Hotspot", NetworkKind::Hotspot),
        ("ethernet:desk", "Desk Dock", NetworkKind::Ethernet),
        ("wifi:Cafe Lounge", "Café Lounge", NetworkKind::Wifi),
    ]
    .iter()
    .map(|(key, name, kind)| store.join_network(key, name, *kind).unwrap().id)
    .collect();
    let app = |i: u64| App {
        id: format!("/Applications/Synthetic App {i}.app"),
        name: format!("Synthetic App {i}"),
    };

    let end = hour_start(now());
    let start = end - 365 * 24 * HOUR;
    let started = Instant::now();
    let mut rows = 0;
    let mut resource_rows = 0;
    for (n, hour) in (start..end).step_by(3600).enumerate() {
        let n = n as u64;
        let day = n / 24;
        let local_hour = (n + 8) % 24;
        // Weekdays at the office from 9 to 17, the phone on Saturdays, the dock and the café now
        // and then, home otherwise.
        let network = match (day % 7, local_hour) {
            (0..=4, 9..=16) if day % 11 == 3 => networks[3],
            (0..=4, 9..=16) => networks[1],
            (5, 10..=15) => networks[2],
            (6, 14..=16) if day % 3 == 0 => networks[4],
            _ => networks[0],
        };
        // From about 0.3 MB an hour at night to 250 MB on a busy evening.
        let scale = match local_hour {
            0..=6 => 2,
            7..=17 => 120,
            _ => 300,
        } * (1 + (day * 7 + local_hour) % 5);
        let apps: Vec<AppUsage> = (0..APPS_PER_HOUR)
            .map(|a| {
                let weight = APPS_PER_HOUR - a;
                AppUsage {
                    hour,
                    network,
                    app: app((a * 5 + day) % 200),
                    bytes: Bytes {
                        rx: scale * weight * 180,
                        tx: scale * weight * 30,
                    },
                }
            })
            .collect();
        let sum = apps.iter().fold(Bytes::default(), |s, a| Bytes {
            rx: s.rx + a.bytes.rx,
            tx: s.tx + a.bytes.tx,
        });
        // The interfaces carry about 9% more than the apps: headers and acknowledgements.
        let interfaces = [InterfaceUsage {
            hour,
            network,
            bytes: Bytes {
                rx: sum.rx * 109 / 100,
                tx: sum.tx * 109 / 100,
            },
        }];
        store.add(&apps, &interfaces).unwrap();
        rows += apps.len();
        // CPU from about 2 to 60 minutes an hour, the busiest app a tenth of it; footprints from
        // 50 MB to 2 GB.
        let busy = 2 + scale % 59;
        let resources: Vec<ResourceHour> = (0..RESOURCE_APPS_PER_HOUR)
            .map(|a| {
                let weight = RESOURCE_APPS_PER_HOUR - a;
                let cpu = busy * 60_000_000_000 * weight / 1200;
                ResourceHour {
                    hour,
                    app: app((a * 3 + day) % 200),
                    counters: Counters {
                        cpu,
                        billed: cpu / 20,
                        read: weight * 1_000_000,
                        written: weight * scale * 10_000,
                        energy: cpu / 4,
                    },
                    footprint_seconds: (50_000_000 + weight * 16_000_000) * 3600,
                    seconds: 3600,
                    peak: 50_000_000 + weight * 20_000_000,
                    fallback: false,
                }
            })
            .collect();
        let minutes: Vec<ResourceMinute> = if hour >= end - 7 * 24 * HOUR {
            (0..60)
                .map(|m| ResourceMinute {
                    minute: hour + m * 60,
                    cpu_busy: Some(((busy + m.unsigned_abs() % 7) % 100) as f64 / 100.0),
                    memory_used: Some(18 * GB + (busy % 9) * GB),
                    memory_compressed: Some(2 * GB),
                    swap_used: Some(0),
                    pressure: Some(1),
                    memory_level: Some(40),
                    volumes: vec![Volume {
                        path: "/".into(),
                        free: 212 * GB,
                        size: 994 * GB,
                    }],
                    top: [
                        MinuteMeasure::Cpu,
                        MinuteMeasure::Memory,
                        MinuteMeasure::Written,
                    ]
                    .iter()
                    .map(|&measure| {
                        let apps = (0..5)
                            .map(|r| (app((r * 3 + day) % 200), (5 - r) * 1_000_000_000))
                            .collect();
                        (measure, apps)
                    })
                    .collect(),
                    fallback: false,
                })
                .collect()
        } else {
            Vec::new()
        };
        store.add_resources(&resources, &minutes, start).unwrap();
        resource_rows += resources.len();
    }
    drop(store);
    // Opening again checkpoints the write-ahead log into the database file.
    drop(Store::open(&path).unwrap());
    println!(
        "wrote {rows} app rows and {resource_rows} resource rows over 365 days in {:.1} s; {:.1} MB",
        started.elapsed().as_secs_f64(),
        std::fs::metadata(&path).unwrap().len() as f64 / 1e6
    );

    let store = Store::open_read_only(&path).unwrap();
    for (name, span, step) in [
        ("year", Span { start, end }, Step::Month),
        (
            "month",
            Span {
                start: end - 30 * 24 * HOUR,
                end,
            },
            Step::Day,
        ),
    ] {
        let query = Query {
            span,
            previous: Some(Span {
                start: span.start - (span.end - span.start),
                end: span.start,
            }),
            network: None,
            step,
        };
        let started = Instant::now();
        let h = history(&store, &query, local_offset).unwrap();
        println!(
            "{name}: {:.1} ms, {} bars, {} app rows, {} heatmap cells",
            started.elapsed().as_secs_f64() * 1000.0,
            h.bars.len(),
            h.apps.len(),
            h.heatmap.len()
        );
        for measure in [Measure::Cpu, Measure::Memory] {
            let started = Instant::now();
            let r = resource_history::resource_history(
                &store,
                &resource_history::Query {
                    span: query.span,
                    previous: query.previous,
                    step,
                    measure,
                },
                local_offset,
            )
            .unwrap();
            println!(
                "{name} {measure:?}: {:.1} ms, {} bars, {} apps, {} heatmap cells",
                started.elapsed().as_secs_f64() * 1000.0,
                r.bars.len(),
                r.apps.len(),
                r.heatmap.len()
            );
        }
    }
    let started = Instant::now();
    let day = resource_history::minutes(&store, end - 24 * HOUR, end, "/").unwrap();
    println!(
        "a day's minutes: {:.1} ms, {} minutes",
        started.elapsed().as_secs_f64() * 1000.0,
        day.len()
    );
}
