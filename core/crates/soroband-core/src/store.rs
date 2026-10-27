//! The usage database: SQLite in WAL mode, one row per (hour, network, app).
//!
//! The app writes it; the `soroband` command reads it at the same time, which WAL allows. Tables:
//!
//! - `networks`: the network registry. Each network has a stable `id`, the `key` the app
//!   identified it by (Wi‑Fi name, gateway MAC), and a name and kind the user can change.
//! - `apps`: one row per app identity ([`App::id`]) with its display name.
//! - `usage`: internet bytes per (hour, network, app), summed from the meter.
//! - `interface_usage`: bytes that crossed the interfaces per (hour, network), for the
//!   reconciliation and for Macs whose engine runs on interface totals only.
//!
//! Hours are Unix times of the start of a UTC hour ([`crate::day::hour_start`]). Network id 0
//! means no network was identified (before the app named one, or while it waits for a network's
//! router); it has no row in `networks`.

// Every error is SQLite's own (`rusqlite::Error`) and passes through unchanged.
#![allow(clippy::missing_errors_doc)]

use crate::meter::{App, Bytes};
use rusqlite::{Connection, OpenFlags, OptionalExtension, params};
use std::collections::{BTreeMap, HashMap};
use std::path::Path;

pub use rusqlite::Error;
pub type Result<T> = rusqlite::Result<T>;

const SCHEMA_VERSION: i64 = 1;
const SCHEMA: &str = "
    CREATE TABLE networks (
        id INTEGER PRIMARY KEY,
        key TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL,
        kind TEXT NOT NULL
    );
    CREATE TABLE apps (
        id INTEGER PRIMARY KEY,
        key TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL
    );
    CREATE TABLE usage (
        hour INTEGER NOT NULL,
        network INTEGER NOT NULL,
        app INTEGER NOT NULL,
        rx INTEGER NOT NULL,
        tx INTEGER NOT NULL,
        PRIMARY KEY (hour, network, app)
    ) WITHOUT ROWID;
    CREATE TABLE interface_usage (
        hour INTEGER NOT NULL,
        network INTEGER NOT NULL,
        rx INTEGER NOT NULL,
        tx INTEGER NOT NULL,
        PRIMARY KEY (hour, network)
    ) WITHOUT ROWID;
";

/// What kind of network it is. The app picks one when it first sees a network; the user can
/// change it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NetworkKind {
    Wifi,
    Ethernet,
    Hotspot,
}

impl NetworkKind {
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Wifi => "wifi",
            Self::Ethernet => "ethernet",
            Self::Hotspot => "hotspot",
        }
    }

    #[must_use]
    pub fn parse(text: &str) -> Option<Self> {
        match text {
            "wifi" => Some(Self::Wifi),
            "ethernet" => Some(Self::Ethernet),
            "hotspot" => Some(Self::Hotspot),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Network {
    pub id: i64,
    pub key: String,
    pub name: String,
    pub kind: NetworkKind,
}

/// Bytes one app moved on one network in one hour.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppUsage {
    pub hour: i64,
    pub network: i64,
    pub app: App,
    pub bytes: Bytes,
}

/// Bytes that crossed the interfaces on one network in one hour.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InterfaceUsage {
    pub hour: i64,
    pub network: i64,
    pub bytes: Bytes,
}

/// Totals of one network over a span.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct NetworkTotal {
    pub network: i64,
    /// Summed over the apps.
    pub apps: Bytes,
    /// Crossed the interfaces.
    pub interfaces: Bytes,
}

#[derive(Debug)]
pub struct Store {
    conn: Connection,
    /// Row ids of apps already in `apps`, by [`App::id`].
    app_ids: HashMap<String, i64>,
}

impl Store {
    /// Opens the database at `path` for writing, creating it and its tables if needed.
    pub fn open(path: &Path) -> Result<Self> {
        let conn = Connection::open(path)?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        // With WAL, NORMAL loses at most the last transactions on a power cut, never corrupts.
        conn.pragma_update(None, "synchronous", "NORMAL")?;
        conn.busy_timeout(std::time::Duration::from_secs(2))?;
        let version: i64 = conn.pragma_query_value(None, "user_version", |row| row.get(0))?;
        match version {
            0 => {
                conn.execute_batch(&format!(
                    "BEGIN; {SCHEMA} PRAGMA user_version = {SCHEMA_VERSION}; COMMIT;"
                ))?;
            }
            SCHEMA_VERSION => {}
            _ => return Err(newer_schema(version)),
        }
        Ok(Self {
            conn,
            app_ids: HashMap::new(),
        })
    }

    /// Opens an existing database for reading only, as the `soroband` command does.
    pub fn open_read_only(path: &Path) -> Result<Self> {
        let conn = Connection::open_with_flags(
            path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )?;
        conn.busy_timeout(std::time::Duration::from_secs(2))?;
        let version: i64 = conn.pragma_query_value(None, "user_version", |row| row.get(0))?;
        if version != SCHEMA_VERSION {
            return Err(newer_schema(version));
        }
        Ok(Self {
            conn,
            app_ids: HashMap::new(),
        })
    }

    /// The network identified by `key`, added with `name` and `kind` if it is new. A known
    /// network keeps the name and kind it has, which the user may have changed.
    pub fn join_network(&mut self, key: &str, name: &str, kind: NetworkKind) -> Result<Network> {
        self.conn.execute(
            "INSERT INTO networks (key, name, kind) VALUES (?1, ?2, ?3)
             ON CONFLICT (key) DO NOTHING",
            params![key, name, kind.as_str()],
        )?;
        self.conn.query_row(
            "SELECT id, key, name, kind FROM networks WHERE key = ?1",
            [key],
            network_from_row,
        )
    }

    /// Renames network `id` and sets its kind. Returns false when there is no such network.
    pub fn update_network(&mut self, id: i64, name: &str, kind: NetworkKind) -> Result<bool> {
        let changed = self.conn.execute(
            "UPDATE networks SET name = ?2, kind = ?3 WHERE id = ?1",
            params![id, name, kind.as_str()],
        )?;
        Ok(changed == 1)
    }

    pub fn network(&self, id: i64) -> Result<Option<Network>> {
        self.conn
            .query_row(
                "SELECT id, key, name, kind FROM networks WHERE id = ?1",
                [id],
                network_from_row,
            )
            .optional()
    }

    /// Every network, in the order they were first seen.
    pub fn networks(&self) -> Result<Vec<Network>> {
        let mut statement = self
            .conn
            .prepare("SELECT id, key, name, kind FROM networks ORDER BY id")?;
        statement.query_map([], network_from_row)?.collect()
    }

    /// Adds the bytes to the stored rows in one transaction.
    pub fn add(&mut self, apps: &[AppUsage], interfaces: &[InterfaceUsage]) -> Result<()> {
        let tx = self.conn.transaction()?;
        let mut new_ids = Vec::new();
        {
            let mut app_row = tx.prepare(
                "INSERT INTO apps (key, name) VALUES (?1, ?2)
                 ON CONFLICT (key) DO UPDATE SET name = excluded.name
                 RETURNING id",
            )?;
            let mut usage_row = tx.prepare(
                "INSERT INTO usage (hour, network, app, rx, tx) VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT (hour, network, app) DO UPDATE
                 SET rx = rx + excluded.rx, tx = tx + excluded.tx",
            )?;
            for row in apps {
                let app = if let Some(&id) = self.app_ids.get(&row.app.id) {
                    id
                } else {
                    let id: i64 =
                        app_row.query_row(params![row.app.id, row.app.name], |r| r.get(0))?;
                    new_ids.push((row.app.id.clone(), id));
                    id
                };
                usage_row.execute(params![
                    row.hour,
                    row.network,
                    app,
                    sql_bytes(row.bytes.rx),
                    sql_bytes(row.bytes.tx)
                ])?;
            }
            let mut interface_row = tx.prepare(
                "INSERT INTO interface_usage (hour, network, rx, tx) VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT (hour, network) DO UPDATE
                 SET rx = rx + excluded.rx, tx = tx + excluded.tx",
            )?;
            for row in interfaces {
                interface_row.execute(params![
                    row.hour,
                    row.network,
                    sql_bytes(row.bytes.rx),
                    sql_bytes(row.bytes.tx)
                ])?;
            }
        }
        tx.commit()?;
        // Only after the commit: a rolled-back insert leaves no row behind its id.
        self.app_ids.extend(new_ids);
        Ok(())
    }

    /// Totals per network over the hours from `since` on, in network id order.
    pub fn network_totals(&self, since: i64) -> Result<Vec<NetworkTotal>> {
        let mut totals: BTreeMap<i64, NetworkTotal> = BTreeMap::new();
        let empty = |network| NetworkTotal {
            network,
            ..NetworkTotal::default()
        };
        let mut apps = self.conn.prepare(
            "SELECT network, SUM(rx), SUM(tx) FROM usage WHERE hour >= ?1 GROUP BY network",
        )?;
        for row in apps.query_map([since], bytes_by_key)? {
            let (network, bytes) = row?;
            totals.entry(network).or_insert_with(|| empty(network)).apps = bytes;
        }
        let mut interfaces = self.conn.prepare(
            "SELECT network, SUM(rx), SUM(tx) FROM interface_usage WHERE hour >= ?1
             GROUP BY network",
        )?;
        for row in interfaces.query_map([since], bytes_by_key)? {
            let (network, bytes) = row?;
            totals
                .entry(network)
                .or_insert_with(|| empty(network))
                .interfaces = bytes;
        }
        Ok(totals.into_values().collect())
    }

    /// Bytes per app over the hours from `since` on, on `network` or on all networks, largest
    /// first.
    pub fn app_totals(&self, since: i64, network: Option<i64>) -> Result<Vec<(App, Bytes)>> {
        let mut statement = self.conn.prepare(
            "SELECT apps.key, apps.name, SUM(usage.rx), SUM(usage.tx)
             FROM usage JOIN apps ON apps.id = usage.app
             WHERE usage.hour >= ?1 AND (?2 IS NULL OR usage.network = ?2)
             GROUP BY usage.app
             ORDER BY SUM(usage.rx) + SUM(usage.tx) DESC, apps.name",
        )?;
        statement
            .query_map(params![since, network], |row| {
                Ok((
                    App {
                        id: row.get(0)?,
                        name: row.get(1)?,
                    },
                    Bytes {
                        rx: u64_from_sql(row.get(2)?),
                        tx: u64_from_sql(row.get(3)?),
                    },
                ))
            })?
            .collect()
    }

    /// Bytes per network and app over the hours from `since` on, in network order and largest
    /// first within a network.
    pub fn app_network_totals(&self, since: i64) -> Result<Vec<(i64, App, Bytes)>> {
        let mut statement = self.conn.prepare(
            "SELECT usage.network, apps.key, apps.name, SUM(usage.rx), SUM(usage.tx)
             FROM usage JOIN apps ON apps.id = usage.app
             WHERE usage.hour >= ?1
             GROUP BY usage.network, usage.app
             ORDER BY usage.network, SUM(usage.rx) + SUM(usage.tx) DESC, apps.name",
        )?;
        statement
            .query_map([since], |row| {
                Ok((
                    row.get(0)?,
                    App {
                        id: row.get(1)?,
                        name: row.get(2)?,
                    },
                    Bytes {
                        rx: u64_from_sql(row.get(3)?),
                        tx: u64_from_sql(row.get(4)?),
                    },
                ))
            })?
            .collect()
    }

    /// The last hour each network carried bytes, by network id.
    pub fn last_used(&self) -> Result<BTreeMap<i64, i64>> {
        let mut statement = self
            .conn
            .prepare("SELECT network, MAX(hour) FROM interface_usage GROUP BY network")?;
        statement
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?
            .collect()
    }
}

fn newer_schema(version: i64) -> Error {
    Error::SqliteFailure(
        rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_MISMATCH),
        Some(format!(
            "the database has schema version {version}; this Soroband reads version {SCHEMA_VERSION}"
        )),
    )
}

fn network_from_row(row: &rusqlite::Row<'_>) -> Result<Network> {
    let kind: String = row.get(3)?;
    Ok(Network {
        id: row.get(0)?,
        key: row.get(1)?,
        name: row.get(2)?,
        kind: NetworkKind::parse(&kind).ok_or_else(|| {
            Error::FromSqlConversionFailure(
                3,
                rusqlite::types::Type::Text,
                format!("unknown network kind {kind:?}").into(),
            )
        })?,
    })
}

fn bytes_by_key(row: &rusqlite::Row<'_>) -> Result<(i64, Bytes)> {
    Ok((
        row.get(0)?,
        Bytes {
            rx: u64_from_sql(row.get(1)?),
            tx: u64_from_sql(row.get(2)?),
        },
    ))
}

/// SQLite integers are signed 64-bit; no real byte count comes near 2^63.
fn sql_bytes(bytes: u64) -> i64 {
    i64::try_from(bytes).unwrap_or(i64::MAX)
}

fn u64_from_sql(value: i64) -> u64 {
    u64::try_from(value).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::{AppUsage, InterfaceUsage, NetworkKind, NetworkTotal, Store};
    use crate::meter::{App, Bytes};
    use std::path::PathBuf;

    pub(crate) fn temp_db(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("soroband-store-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("usage.sqlite")
    }

    fn app(name: &str) -> App {
        App {
            id: format!("/Applications/{name}.app"),
            name: name.into(),
        }
    }

    fn usage(hour: i64, network: i64, name: &str, rx: u64, tx: u64) -> AppUsage {
        AppUsage {
            hour,
            network,
            app: app(name),
            bytes: Bytes { rx, tx },
        }
    }

    #[test]
    fn rows_for_the_same_hour_network_and_app_add_up() {
        let mut store = Store::open(&temp_db("add-up")).unwrap();
        store
            .add(&[usage(3600, 1, "Safari", 100, 10)], &[])
            .unwrap();
        store
            .add(
                &[
                    usage(3600, 1, "Safari", 50, 5),
                    usage(7200, 1, "Safari", 7, 0),
                ],
                &[],
            )
            .unwrap();
        assert_eq!(
            store.app_totals(3600, Some(1)).unwrap(),
            [(app("Safari"), Bytes { rx: 157, tx: 15 })]
        );
        // Only the 7200 hour is from 7200 on.
        assert_eq!(
            store.app_totals(7200, Some(1)).unwrap(),
            [(app("Safari"), Bytes { rx: 7, tx: 0 })]
        );
    }

    #[test]
    fn data_survives_reopening_the_database() {
        let path = temp_db("reopen");
        {
            let mut store = Store::open(&path).unwrap();
            let office = store
                .join_network("wifi:Office", "Office", NetworkKind::Wifi)
                .unwrap();
            store
                .add(
                    &[usage(3600, office.id, "Mail", 1_000, 200)],
                    &[InterfaceUsage {
                        hour: 3600,
                        network: office.id,
                        bytes: Bytes { rx: 1_100, tx: 230 },
                    }],
                )
                .unwrap();
        }
        let mut store = Store::open(&path).unwrap();
        let office = store
            .join_network("wifi:Office", "ignored", NetworkKind::Hotspot)
            .unwrap();
        assert_eq!(
            (office.name.as_str(), office.kind),
            ("Office", NetworkKind::Wifi)
        );
        assert_eq!(
            store.network_totals(0).unwrap(),
            [NetworkTotal {
                network: office.id,
                apps: Bytes { rx: 1_000, tx: 200 },
                interfaces: Bytes { rx: 1_100, tx: 230 },
            }]
        );
        // The app row is found again after the reopen instead of being added twice.
        store
            .add(&[usage(3600, office.id, "Mail", 1, 1)], &[])
            .unwrap();
        assert_eq!(
            store.app_totals(0, None).unwrap(),
            [(app("Mail"), Bytes { rx: 1_001, tx: 201 })]
        );
        let read_only = Store::open_read_only(&path).unwrap();
        assert_eq!(read_only.networks().unwrap(), [office]);
    }

    #[test]
    fn network_ids_are_stable_and_user_edits_are_kept() {
        let mut store = Store::open(&temp_db("registry")).unwrap();
        let home = store
            .join_network("wifi:Home", "Home", NetworkKind::Wifi)
            .unwrap();
        let phone = store
            .join_network("wifi:Sam's iPhone", "Sam's iPhone", NetworkKind::Hotspot)
            .unwrap();
        assert_ne!(home.id, phone.id);
        assert!(
            store
                .update_network(home.id, "Flat", NetworkKind::Hotspot)
                .unwrap()
        );
        let again = store
            .join_network("wifi:Home", "Home", NetworkKind::Wifi)
            .unwrap();
        assert_eq!(again.id, home.id);
        assert_eq!(
            (again.name.as_str(), again.kind),
            ("Flat", NetworkKind::Hotspot)
        );
        assert!(
            !store
                .update_network(999, "Nowhere", NetworkKind::Wifi)
                .unwrap()
        );
        assert_eq!(store.network(phone.id).unwrap(), Some(phone));
        assert_eq!(store.network(999).unwrap(), None);
    }

    #[test]
    fn totals_are_split_by_network_and_start_at_since() {
        let mut store = Store::open(&temp_db("totals")).unwrap();
        store
            .add(
                &[
                    usage(0, 1, "Mail", 1, 1),
                    usage(3600, 1, "Mail", 10, 1),
                    usage(3600, 2, "Mail", 20, 2),
                    usage(3600, 2, "Safari", 300, 3),
                ],
                &[InterfaceUsage {
                    hour: 3600,
                    network: 3,
                    bytes: Bytes { rx: 9, tx: 9 },
                }],
            )
            .unwrap();
        assert_eq!(
            store.network_totals(3600).unwrap(),
            [
                NetworkTotal {
                    network: 1,
                    apps: Bytes { rx: 10, tx: 1 },
                    interfaces: Bytes::default(),
                },
                NetworkTotal {
                    network: 2,
                    apps: Bytes { rx: 320, tx: 5 },
                    interfaces: Bytes::default(),
                },
                NetworkTotal {
                    network: 3,
                    apps: Bytes::default(),
                    interfaces: Bytes { rx: 9, tx: 9 },
                },
            ]
        );
        assert_eq!(
            store.app_totals(3600, Some(2)).unwrap(),
            [
                (app("Safari"), Bytes { rx: 300, tx: 3 }),
                (app("Mail"), Bytes { rx: 20, tx: 2 })
            ]
        );
        assert_eq!(
            store.app_totals(3600, None).unwrap(),
            [
                (app("Safari"), Bytes { rx: 300, tx: 3 }),
                (app("Mail"), Bytes { rx: 30, tx: 3 })
            ]
        );
    }

    #[test]
    fn every_network_kind_is_stored_and_read_back() {
        let mut store = Store::open(&temp_db("kinds")).unwrap();
        for kind in [
            NetworkKind::Wifi,
            NetworkKind::Ethernet,
            NetworkKind::Hotspot,
        ] {
            let network = store.join_network(kind.as_str(), "n", kind).unwrap();
            assert_eq!(store.network(network.id).unwrap().unwrap().kind, kind);
        }
        assert_eq!(NetworkKind::parse("satellite"), None);
    }

    #[test]
    fn a_database_from_a_newer_soroband_is_refused() {
        let path = temp_db("newer");
        drop(Store::open(&path).unwrap());
        let conn = rusqlite::Connection::open(&path).unwrap();
        conn.pragma_update(None, "user_version", 2).unwrap();
        drop(conn);
        let error = Store::open(&path).unwrap_err().to_string();
        assert!(error.contains("schema version 2"), "{error}");
        assert!(Store::open_read_only(&path).is_err());
    }

    #[test]
    fn database_uses_write_ahead_logging() {
        let path = temp_db("wal");
        let store = Store::open(&path).unwrap();
        let mode: String = store
            .conn
            .pragma_query_value(None, "journal_mode", |row| row.get(0))
            .unwrap();
        assert_eq!(mode, "wal");
    }

    #[test]
    fn app_totals_per_network_split_one_app_across_networks() {
        let mut store = Store::open(&temp_db("per-network")).unwrap();
        store
            .add(
                &[
                    usage(3600, 1, "Safari", 100, 10),
                    usage(3600, 2, "Safari", 40, 0),
                    usage(3600, 1, "Mail", 300, 0),
                    // Before `since`: left out.
                    usage(0, 1, "Mail", 9, 9),
                    usage(7200, 1, "Safari", 5, 0),
                ],
                &[],
            )
            .unwrap();
        assert_eq!(
            store.app_network_totals(3600).unwrap(),
            [
                (1, app("Mail"), Bytes { rx: 300, tx: 0 }),
                (1, app("Safari"), Bytes { rx: 105, tx: 10 }),
                (2, app("Safari"), Bytes { rx: 40, tx: 0 }),
            ]
        );
    }

    #[test]
    fn last_used_is_the_latest_hour_with_bytes_on_each_network() {
        let mut store = Store::open(&temp_db("last-used")).unwrap();
        let interface = |hour, network| InterfaceUsage {
            hour,
            network,
            bytes: Bytes { rx: 1, tx: 0 },
        };
        store
            .add(
                &[],
                &[interface(3600, 1), interface(10_800, 1), interface(7200, 2)],
            )
            .unwrap();
        let last = store.last_used().unwrap();
        assert_eq!(last.get(&1), Some(&10_800));
        assert_eq!(last.get(&2), Some(&7200));
        assert_eq!(last.get(&3), None, "never used");
    }
}
