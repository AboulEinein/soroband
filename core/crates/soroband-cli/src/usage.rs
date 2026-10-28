//! `soroband today` and `soroband apps`: today's usage from the app's database.
//!
//! The app writes its counts once a minute and whenever the network changes, so these read at
//! most a minute behind what the app shows.

use crate::data;
use crate::text::{printable, size};
use serde_json::{Value, json};
use soroband_core::day;
use soroband_core::meter::Bytes;
use soroband_core::settings::{self, Settings};
use soroband_core::store::{Network, NetworkTotal, Store};
use std::fmt::Write as _;
use std::process::ExitCode;

pub const TODAY_USAGE: &str = "\
Usage: soroband today [--json]

Today's usage per network, since the reset hour (soroband config get reset_hour).
Received and Sent are what crossed the network; Apps is the part the meter
credited to apps (the rest is headers, acknowledgements and system traffic).";

pub const APPS_USAGE: &str = "\
Usage: soroband apps [--network <name or id>] [--json]

Today's usage per app, on one network or on all of them.";

/// The name shown for bytes booked to no network: before the app named one, or while it waited
/// for a network's router.
const UNKNOWN_NETWORK: &str = "Unknown network";

struct Today {
    store: Store,
    start: i64,
    reset_hour: u8,
}

impl Today {
    fn open() -> Result<Self, String> {
        let dir = data::directory()?;
        let path = dir.join(soroband_core::ffi::DATABASE_FILE);
        if !path.exists() {
            return Err(format!(
                "no usage recorded yet: {} does not exist. Is the Soroband app running?",
                path.display()
            ));
        }
        let store = Store::open_read_only(&path)
            .map_err(|e| format!("cannot read {}: {e}", path.display()))?;
        let settings_path = dir.join(settings::FILE_NAME);
        let reset_hour = match Settings::load(&settings_path) {
            Ok(settings) => settings.reset_hour(),
            Err(error) => {
                eprintln!(
                    "soroband: {}: {error}; using the default reset hour",
                    settings_path.display()
                );
                0
            }
        };
        let start = day::day_start(day::now(), reset_hour, day::local_offset);
        Ok(Self {
            store,
            start,
            reset_hour,
        })
    }

    fn networks(&self) -> Result<Vec<Network>, String> {
        self.store.networks().map_err(|e| e.to_string())
    }
}

fn bytes_json(b: Bytes) -> Value {
    json!({ "rx": b.rx, "tx": b.tx })
}

fn network_json(id: i64, network: Option<&Network>) -> Value {
    json!({
        "id": id,
        "name": network.map_or(UNKNOWN_NETWORK, |n| n.name.as_str()),
        "kind": network.map(|n| n.kind.as_str()),
    })
}

pub fn today(args: &[&str]) -> ExitCode {
    let json = match args {
        [] => false,
        ["--json"] => true,
        _ => return usage_error(TODAY_USAGE),
    };
    match today_text(json) {
        Ok(text) => {
            println!("{text}");
            ExitCode::SUCCESS
        }
        Err(message) => fail(&message),
    }
}

fn today_text(json: bool) -> Result<String, String> {
    let today = Today::open()?;
    let networks = today.networks()?;
    let totals = today
        .store
        .network_totals(today.start)
        .map_err(|e| e.to_string())?;
    let mut all = NetworkTotal::default();
    for total in &totals {
        all.apps += total.apps;
        all.interfaces += total.interfaces;
    }
    let find = |id: i64| networks.iter().find(|n| n.id == id);
    if json {
        let rows: Vec<Value> = totals
            .iter()
            .map(|t| {
                let mut row = network_json(t.network, find(t.network));
                row["apps"] = bytes_json(t.apps);
                row["interfaces"] = bytes_json(t.interfaces);
                row
            })
            .collect();
        return Ok(json!({
            "start": today.start,
            "reset_hour": today.reset_hour,
            "networks": rows,
            "total": { "apps": bytes_json(all.apps), "interfaces": bytes_json(all.interfaces) },
        })
        .to_string());
    }
    let mut text = format!(
        "Today since {:02}:00\n{:<32} {:<9} {:>10} {:>10} {:>10}\n",
        today.reset_hour, "Network", "Kind", "Received", "Sent", "Apps"
    );
    let mut line = |name: &str, kind: &str, t: &NetworkTotal| {
        let _ = writeln!(
            text,
            "{:<32} {:<9} {:>10} {:>10} {:>10}",
            printable(name),
            kind,
            size(t.interfaces.rx),
            size(t.interfaces.tx),
            size(t.apps.total())
        );
    };
    for total in &totals {
        let network = find(total.network);
        line(
            network.map_or(UNKNOWN_NETWORK, |n| n.name.as_str()),
            network.map_or("", |n| n.kind.as_str()),
            total,
        );
    }
    line("All networks", "", &all);
    Ok(text.trim_end().to_owned())
}

pub fn apps(args: &[&str]) -> ExitCode {
    let (network, json) = match args {
        [] => (None, false),
        ["--json"] => (None, true),
        ["--network", name] => (Some(*name), false),
        ["--network", name, "--json"] | ["--json", "--network", name] => (Some(*name), true),
        _ => return usage_error(APPS_USAGE),
    };
    match apps_text(network, json) {
        Ok(text) => {
            println!("{text}");
            ExitCode::SUCCESS
        }
        Err(message) => fail(&message),
    }
}

fn apps_text(wanted: Option<&str>, json: bool) -> Result<String, String> {
    let today = Today::open()?;
    let networks = today.networks()?;
    let found = wanted.map(|w| find_network(&networks, w)).transpose()?;
    let apps = today
        .store
        .app_totals(today.start, found.map(|(id, _)| id))
        .map_err(|e| e.to_string())?;
    if json {
        let rows: Vec<Value> = apps
            .iter()
            .map(|(app, b)| json!({ "id": app.id, "name": app.name, "rx": b.rx, "tx": b.tx }))
            .collect();
        return Ok(json!({
            "start": today.start,
            "reset_hour": today.reset_hour,
            "network": found.map(|(id, network)| network_json(id, network)),
            "apps": rows,
        })
        .to_string());
    }
    let mut text = format!(
        "Today since {:02}:00 on {}\n{:<40} {:>10} {:>10}\n",
        today.reset_hour,
        found.map_or("all networks".to_owned(), |(_, network)| {
            printable(network.map_or(UNKNOWN_NETWORK, |n| n.name.as_str()))
        }),
        "App",
        "Received",
        "Sent"
    );
    for (app, b) in &apps {
        let _ = writeln!(
            text,
            "{:<40} {:>10} {:>10}",
            printable(&app.name),
            size(b.rx),
            size(b.tx)
        );
    }
    Ok(text.trim_end().to_owned())
}

/// The id of the network named `wanted` (any letter case), or with id `wanted`, and its registry
/// entry. Id 0, also named [`UNKNOWN_NETWORK`], holds bytes booked while no network was
/// identified; it has no entry.
fn find_network<'a>(
    networks: &'a [Network],
    wanted: &str,
) -> Result<(i64, Option<&'a Network>), String> {
    let matches: Vec<&Network> = networks
        .iter()
        .filter(|n| n.name.to_lowercase() == wanted.to_lowercase() || n.id.to_string() == wanted)
        .collect();
    match matches.as_slice() {
        [network] => Ok((network.id, Some(network))),
        [] if wanted == "0" || wanted.to_lowercase() == UNKNOWN_NETWORK.to_lowercase() => {
            Ok((0, None))
        }
        [] => {
            let names: Vec<String> = networks.iter().map(|n| format!("{:?}", n.name)).collect();
            Err(format!(
                "no network named {wanted:?}; known networks: {}",
                if names.is_empty() {
                    "none yet".to_owned()
                } else {
                    names.join(", ")
                }
            ))
        }
        several => {
            let ids: Vec<String> = several.iter().map(|n| n.id.to_string()).collect();
            Err(format!(
                "{} networks are named {wanted:?}; pass an id instead: {}",
                several.len(),
                ids.join(", ")
            ))
        }
    }
}

fn usage_error(usage: &str) -> ExitCode {
    eprintln!("{usage}");
    ExitCode::from(2)
}

fn fail(message: &str) -> ExitCode {
    eprintln!("soroband: {message}");
    ExitCode::FAILURE
}

#[cfg(test)]
mod tests {
    use super::find_network;
    use soroband_core::store::{Network, NetworkKind};

    fn network(id: i64, name: &str) -> Network {
        Network {
            id,
            key: format!("wifi:{name}"),
            name: name.into(),
            kind: NetworkKind::Wifi,
        }
    }

    #[test]
    fn network_is_found_by_name_in_any_case_or_by_id() {
        let networks = [
            network(1, "Home"),
            network(2, "Office"),
            network(3, "office"),
        ];
        assert_eq!(find_network(&networks, "home").unwrap().0, 1);
        assert_eq!(find_network(&networks, "2").unwrap().0, 2);
        let error = find_network(&networks, "Office").unwrap_err();
        assert!(error.contains("pass an id instead: 2, 3"), "{error}");
        // Id 0 is the bytes booked to no network, which `soroband today` lists as "Unknown network".
        assert_eq!(find_network(&networks, "0").unwrap(), (0, None));
        assert_eq!(
            find_network(&networks, "unknown network").unwrap(),
            (0, None)
        );
        let error = find_network(&networks, "Cafe").unwrap_err();
        assert!(
            error.contains(r#"known networks: "Home", "Office", "office""#),
            "{error}"
        );
    }
}
