//! Writes 60 days of made-up usage by well-known apps into a data directory, for the README's
//! screenshots, so they show no one's real usage.
//!
//! Five networks: Home (the network `soroband-debug://simulate-network?id=Home` books to, so the
//! popover shows today on it), Office Wi-Fi, an iPhone hotspot, a desk dock and a café. Each app
//! keeps its share of every hour, with more traffic in the day than at night.
//!
//! Usage: cargo run --release --example screenshot-data -- <data dir>
//! The directory must not hold a database yet. Launch a Debug build on it with
//! `open -g --env SOROBAND_DATA_DIR=<data dir> -a <Soroband.app>`, then send it
//! `soroband-debug://simulate-network?id=Home`.

use soroband_core::day::{hour_start, local_offset, now};
use soroband_core::meter::{App, Bytes};
use soroband_core::store::{AppUsage, InterfaceUsage, NetworkKind, Store};

const HOUR: i64 = 3600;

/// Each app's id (its bundle path, for its icon) and its share of an hour, in thousandths.
const APPS: [(&str, u64); 15] = [
    ("/Applications/zoom.us.app", 170),
    ("/Applications/Google Chrome.app", 150),
    ("/Applications/Firefox.app", 120),
    ("/Applications/Spotify.app", 90),
    ("/Applications/Slack.app", 70),
    ("/Applications/Xcode.app", 60),
    ("macOS & Services", 60),
    ("/System/Applications/Music.app", 50),
    ("/System/Applications/App Store.app", 50),
    ("/System/Applications/Photos.app", 40),
    ("/System/Applications/Mail.app", 30),
    ("/System/Applications/Messages.app", 30),
    ("/Applications/Figma.app", 30),
    ("/Applications/Discord.app", 30),
    ("/Applications/Docker.app", 20),
];

#[allow(clippy::cast_sign_loss, clippy::cast_possible_wrap)] // times after 1970, small counts
fn main() {
    let dir = std::path::PathBuf::from(
        std::env::args()
            .nth(1)
            .expect("usage: screenshot-data <data dir>"),
    );
    let path = dir.join("usage.sqlite");
    assert!(!path.exists(), "{} already exists", path.display());
    std::fs::create_dir_all(&dir).unwrap();
    let mut store = Store::open(&path).unwrap();
    let networks: Vec<i64> = [
        ("simulated:Home", "Home", NetworkKind::Wifi),
        ("wifi:Office Wi-Fi", "Office Wi-Fi", NetworkKind::Wifi),
        ("wifi:iPhone", "iPhone", NetworkKind::Hotspot),
        ("ethernet:desk", "Desk Dock", NetworkKind::Ethernet),
        ("wifi:Cafe Lounge", "Café Lounge", NetworkKind::Wifi),
    ]
    .iter()
    .map(|(key, name, kind)| store.join_network(key, name, *kind).unwrap().id)
    .collect();
    let apps: Vec<App> = APPS
        .iter()
        .map(|(id, _)| App {
            id: (*id).to_owned(),
            name: id
                .rsplit('/')
                .next()
                .unwrap()
                .trim_end_matches(".app")
                .replace("zoom.us", "Zoom"),
        })
        .collect();

    let end = hour_start(now()) + HOUR;
    let start = end - 60 * 24 * HOUR;
    let today = end - 24 * HOUR;
    for (n, hour) in (start..end).step_by(3600).enumerate() {
        let n = n as u64;
        let local = hour + local_offset(hour);
        let day = local.div_euclid(24 * HOUR) as u64;
        let local_hour = (local.rem_euclid(24 * HOUR) / HOUR) as u64;
        // Weekdays at the office from 9 to 17, the phone on Saturday afternoons, the dock and the
        // café now and then, home otherwise, and home all of today. Day 0 of the epoch was a
        // Thursday, so (day + 3) % 7 counts from Monday.
        let network = match ((day + 3) % 7, local_hour) {
            _ if hour >= today => networks[0],
            (0..=4, 9..=16) if day % 9 == 3 => networks[3],
            (0..=4, 9..=16) => networks[1],
            (5, 13..=17) => networks[2],
            (6, 10..=12) if day % 3 == 0 => networks[4],
            _ => networks[0],
        };
        // From about 3 MB an hour at night to about 600 MB on a busy evening.
        let megabytes = match local_hour {
            0..=6 => 3,
            7..=17 => 150,
            _ => 300,
        } * (2 + (day * 5 + local_hour) % 3)
            / 2;
        let usage: Vec<AppUsage> = apps
            .iter()
            .zip(APPS)
            .enumerate()
            .map(|(a, (app, (_, share)))| {
                // Shares drift from hour to hour, so apps trade places now and then.
                let share = share * (8 + (n + a as u64 * 3) % 5) / 10;
                let bytes = megabytes * 1_000_000 * share / 1000;
                AppUsage {
                    hour,
                    network,
                    app: app.clone(),
                    bytes: Bytes {
                        rx: bytes * 85 / 100,
                        tx: bytes * 15 / 100,
                    },
                }
            })
            .collect();
        let sum = usage.iter().fold(Bytes::default(), |s, a| Bytes {
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
        store.add(&usage, &interfaces).unwrap();
    }
    drop(store);
    // Opening again checkpoints the write-ahead log into the database file.
    drop(Store::open(&path).unwrap());
    println!("wrote 60 days of usage to {}", path.display());
}
