//! The usage database: SQLite in WAL mode, one row per (hour, network, app).
//!
//! The app writes it; the `soroband` command reads it at the same time, which WAL allows. Tables:
//!
//! - `networks`: the network registry. Each network has a stable `id`, the `key` the app
//!   identified it by (Wi‑Fi name, gateway MAC), and a name and kind the user can change.
//! - `apps`: one row per app identity ([`App::id`]) with its display name.
//! - `usage`: internet bytes per (hour, network, app), summed from the meter.
//! - `usage_day`: the same bytes per (UTC day, network, app), written with `usage`, so a long
//!   History range reads one row per day instead of 24 ([`crate::history`]).
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

const SCHEMA_VERSION: i64 = 3;
/// The tables as of version 2; [`NETWORK_COLOR`] brings them to the current version.
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
    CREATE TABLE usage_day (
        day INTEGER NOT NULL,
        network INTEGER NOT NULL,
        app INTEGER NOT NULL,
        rx INTEGER NOT NULL,
        tx INTEGER NOT NULL,
        PRIMARY KEY (day, network, app)
    ) WITHOUT ROWID;
    CREATE TABLE interface_usage (
        hour INTEGER NOT NULL,
        network INTEGER NOT NULL,
        rx INTEGER NOT NULL,
        tx INTEGER NOT NULL,
        PRIMARY KEY (hour, network)
    ) WITHOUT ROWID;
";

/// From version 1: adds `usage_day`, summed from the hours already stored.
const DAY_ROLLUP: &str = "
    CREATE TABLE usage_day (
        day INTEGER NOT NULL,
        network INTEGER NOT NULL,
        app INTEGER NOT NULL,
        rx INTEGER NOT NULL,
        tx INTEGER NOT NULL,
        PRIMARY KEY (day, network, app)
    ) WITHOUT ROWID;
    INSERT INTO usage_day (day, network, app, rx, tx)
        SELECT hour - hour % 86400, network, app, SUM(rx), SUM(tx) FROM usage
        GROUP BY hour - hour % 86400, network, app;
";

/// From version 2: the color the user picked for a network, a slot of the app's palette; NULL
/// while the network takes the slot of its place in the registry.
const NETWORK_COLOR: &str = "ALTER TABLE networks ADD COLUMN color INTEGER;";

/// Seconds in a UTC day, the unit of `usage_day`.
pub const DAY: i64 = 86_400;

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
                    "BEGIN; {SCHEMA} {NETWORK_COLOR} PRAGMA user_version = {SCHEMA_VERSION}; COMMIT;"
                ))?;
            }
            1 => {
                conn.execute_batch(&format!(
                    "BEGIN; {DAY_ROLLUP} {NETWORK_COLOR} PRAGMA user_version = {SCHEMA_VERSION}; COMMIT;"
                ))?;
            }
            2 => {
                conn.execute_batch(&format!(
                    "BEGIN; {NETWORK_COLOR} PRAGMA user_version = {SCHEMA_VERSION}; COMMIT;"
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
        if version < SCHEMA_VERSION {
            return Err(older_schema(version));
        }
        if version > SCHEMA_VERSION {
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

    /// The network identified by `key`, as [`Store::join_network`], where it may be one the app
    /// knew by `former` until now (a Wi‑Fi network known by its router before its name was
    /// readable).
    ///
    /// - No network has `key` yet: the one known by `former` takes `key`, keeping its id and
    ///   history, and takes `name` unless the user renamed it from `former_name`.
    /// - Both exist: returns the network with `key` and the id of the one known by `former`,
    ///   whose usage the caller then moves into it with [`Store::merge_network`] once nothing
    ///   unwritten is booked to it.
    pub fn join_network_known_as(
        &mut self,
        key: &str,
        name: &str,
        kind: NetworkKind,
        former: &str,
        former_name: &str,
    ) -> Result<(Network, Option<i64>)> {
        let lookup = |conn: &Connection, key: &str| {
            conn.query_row(
                "SELECT id, key, name, kind FROM networks WHERE key = ?1",
                [key],
                network_from_row,
            )
            .optional()
        };
        let Some(old) = lookup(&self.conn, former)? else {
            return Ok((self.join_network(key, name, kind)?, None));
        };
        if let Some(network) = lookup(&self.conn, key)? {
            return Ok((network, Some(old.id)));
        }
        let name = if old.name == former_name {
            name
        } else {
            &old.name
        };
        self.conn.execute(
            "UPDATE networks SET key = ?2, name = ?3 WHERE id = ?1",
            params![old.id, key, name],
        )?;
        Ok((
            Network {
                key: key.to_owned(),
                name: name.to_owned(),
                ..old
            },
            None,
        ))
    }

    /// Moves every byte booked to network `from` into network `into` and removes `from` from
    /// the registry, in one transaction. `into` takes the color picked for `from` when it has
    /// none of its own.
    pub fn merge_network(&mut self, from: i64, into: i64) -> Result<()> {
        let tx = self.conn.transaction()?;
        // `WHERE true` keeps SQLite from reading `ON CONFLICT` as part of a join.
        for (table, columns) in [
            ("usage", "hour, network, app"),
            ("usage_day", "day, network, app"),
            ("interface_usage", "hour, network"),
        ] {
            let select = columns.replace("network", "?2");
            tx.execute(
                &format!(
                    "INSERT INTO {table} ({columns}, rx, tx)
                     SELECT {select}, rx, tx FROM {table} WHERE network = ?1 AND true
                     ON CONFLICT ({columns}) DO UPDATE SET rx = rx + excluded.rx, tx = tx + excluded.tx"
                ),
                params![from, into],
            )?;
            tx.execute(&format!("DELETE FROM {table} WHERE network = ?1"), [from])?;
        }
        tx.execute(
            "UPDATE networks SET color = (SELECT color FROM networks WHERE id = ?1)
             WHERE id = ?2 AND color IS NULL",
            params![from, into],
        )?;
        tx.execute("DELETE FROM networks WHERE id = ?1", [from])?;
        tx.commit()
    }

    /// Renames network `id` and sets its kind. Returns false when there is no such network.
    pub fn update_network(&mut self, id: i64, name: &str, kind: NetworkKind) -> Result<bool> {
        let changed = self.conn.execute(
            "UPDATE networks SET name = ?2, kind = ?3 WHERE id = ?1",
            params![id, name, kind.as_str()],
        )?;
        Ok(changed == 1)
    }

    /// Sets the color slot of network `id`, or gives it back the slot of its place in the
    /// registry with `None`. Returns false when there is no such network.
    pub fn set_network_color(&mut self, id: i64, color: Option<u8>) -> Result<bool> {
        let changed = self.conn.execute(
            "UPDATE networks SET color = ?2 WHERE id = ?1",
            params![id, color],
        )?;
        Ok(changed == 1)
    }

    /// The color slot the user picked for each network that has one, by network id.
    pub fn network_colors(&self) -> Result<BTreeMap<i64, u8>> {
        let mut statement = self
            .conn
            .prepare("SELECT id, color FROM networks WHERE color IS NOT NULL")?;
        statement
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?
            .collect()
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
            let mut day_row = tx.prepare(
                "INSERT INTO usage_day (day, network, app, rx, tx) VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT (day, network, app) DO UPDATE
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
                day_row.execute(params![
                    row.hour.div_euclid(DAY) * DAY,
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

    pub(crate) fn connection(&self) -> &Connection {
        &self.conn
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

fn older_schema(version: i64) -> Error {
    Error::SqliteFailure(
        rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_MISMATCH),
        Some(format!(
            "the database has schema version {version}; open the Soroband app once to update it to version {SCHEMA_VERSION}"
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

    /// Before Location access a Wi‑Fi network is known by its router and named "Wi-Fi"; once its
    /// name is readable it must not stay behind under that generic name.
    #[test]
    fn a_network_known_by_its_router_takes_its_name_when_it_becomes_readable() {
        let mut store = Store::open(&temp_db("known-as")).unwrap();
        let router = store
            .join_network("wifi-router:2:0:0:1:2:3", "Wi-Fi", NetworkKind::Wifi)
            .unwrap();
        store
            .add(&[usage(3600, router.id, "Safari", 700, 70)], &[])
            .unwrap();
        let (named, merge) = store
            .join_network_known_as(
                "wifi:Home",
                "Home",
                NetworkKind::Wifi,
                "wifi-router:2:0:0:1:2:3",
                "Wi-Fi",
            )
            .unwrap();
        assert_eq!(merge, None);
        assert_eq!(named.id, router.id, "same network, same history");
        assert_eq!(
            (named.key.as_str(), named.name.as_str()),
            ("wifi:Home", "Home")
        );
        assert_eq!(store.networks().unwrap(), std::slice::from_ref(&named));
        assert_eq!(
            store.network_totals(0).unwrap()[0].apps,
            Bytes { rx: 700, tx: 70 }
        );
        // Known by its name from now on.
        let (again, merge) = store
            .join_network_known_as(
                "wifi:Home",
                "Home",
                NetworkKind::Wifi,
                "wifi-router:2:0:0:1:2:3",
                "Wi-Fi",
            )
            .unwrap();
        assert_eq!((again, merge), (named, None));

        // A name the user gave it stays.
        let renamed = store
            .join_network("wifi-router:2:0:0:9:9:9", "Wi-Fi", NetworkKind::Wifi)
            .unwrap();
        store
            .update_network(renamed.id, "Studio", NetworkKind::Wifi)
            .unwrap();
        let (studio, _) = store
            .join_network_known_as(
                "wifi:Studio5G",
                "Studio5G",
                NetworkKind::Wifi,
                "wifi-router:2:0:0:9:9:9",
                "Wi-Fi",
            )
            .unwrap();
        assert_eq!((studio.id, studio.name.as_str()), (renamed.id, "Studio"));
    }

    /// The name was readable on an earlier visit, so both networks exist: the router's moves into
    /// the named one, adding up where both have the same hour and app.
    #[test]
    fn merging_a_network_adds_its_usage_into_the_other_and_removes_it() {
        let mut store = Store::open(&temp_db("merge")).unwrap();
        let named = store
            .join_network("wifi:Home", "Home", NetworkKind::Wifi)
            .unwrap();
        let router = store
            .join_network("wifi-router:2:0:0:1:2:3", "Wi-Fi", NetworkKind::Wifi)
            .unwrap();
        let other = store
            .join_network("wifi:Cafe", "Cafe", NetworkKind::Wifi)
            .unwrap();
        store
            .add(
                &[
                    usage(3600, named.id, "Safari", 100, 10),
                    usage(3600, router.id, "Safari", 700, 70),
                    usage(7200, router.id, "Mail", 5, 1),
                    usage(3600, other.id, "Safari", 9, 9),
                ],
                &[
                    InterfaceUsage {
                        hour: 3600,
                        network: named.id,
                        bytes: Bytes { rx: 200, tx: 20 },
                    },
                    InterfaceUsage {
                        hour: 3600,
                        network: router.id,
                        bytes: Bytes { rx: 800, tx: 80 },
                    },
                ],
            )
            .unwrap();
        let (found, merge) = store
            .join_network_known_as(
                "wifi:Home",
                "Home",
                NetworkKind::Wifi,
                "wifi-router:2:0:0:1:2:3",
                "Wi-Fi",
            )
            .unwrap();
        assert_eq!((found.id, merge), (named.id, Some(router.id)));
        store.merge_network(router.id, named.id).unwrap();

        assert_eq!(store.networks().unwrap(), [named.clone(), other.clone()]);
        let totals = store.network_totals(0).unwrap();
        let home = totals.iter().find(|t| t.network == named.id).unwrap();
        assert_eq!(home.apps, Bytes { rx: 805, tx: 81 });
        assert_eq!(home.interfaces, Bytes { rx: 1000, tx: 100 });
        let cafe = totals.iter().find(|t| t.network == other.id).unwrap();
        assert_eq!(
            cafe.apps,
            Bytes { rx: 9, tx: 9 },
            "other networks are untouched"
        );
        let days: i64 = store
            .connection()
            .query_row(
                "SELECT SUM(rx) FROM usage_day WHERE network = ?1",
                [named.id],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(days, 805, "daily sums move too");
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
        conn.pragma_update(None, "user_version", 4).unwrap();
        drop(conn);
        let error = Store::open(&path).unwrap_err().to_string();
        assert!(error.contains("schema version 4"), "{error}");
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

    #[test]
    fn a_version_1_database_gains_its_daily_sums() {
        let path = temp_db("migrate");
        {
            // Version 1: everything but `usage_day`.
            let conn = rusqlite::Connection::open(&path).unwrap();
            let v1: String = super::SCHEMA
                .split("CREATE TABLE")
                .filter(|t| !t.trim_start().starts_with("usage_day"))
                .collect::<Vec<_>>()
                .join("CREATE TABLE");
            conn.execute_batch(&format!("{v1} PRAGMA user_version = 1;"))
                .unwrap();
            conn.execute_batch(
                "INSERT INTO apps (id, key, name) VALUES (1, '/Applications/Mail.app', 'Mail');
                 INSERT INTO usage VALUES (3600, 1, 1, 10, 1), (7200, 1, 1, 20, 2),
                                          (90000, 1, 1, 5, 0), (3600, 2, 1, 7, 7);",
            )
            .unwrap();
        }
        assert!(
            Store::open_read_only(&path)
                .unwrap_err()
                .to_string()
                .contains("open the Soroband app once"),
            "the command waits for the app to update it"
        );
        let mut store = Store::open(&path).unwrap();
        let days = |store: &Store| -> Vec<(i64, i64, i64, i64)> {
            let mut statement = store
                .conn
                .prepare("SELECT day, network, rx, tx FROM usage_day ORDER BY day, network")
                .unwrap();
            statement
                .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
                .unwrap()
                .collect::<rusqlite::Result<_>>()
                .unwrap()
        };
        // 1 January 1970: 30 + 3 on network 1, 7 + 7 on network 2; 2 January: 5.
        assert_eq!(
            days(&store),
            [(0, 1, 30, 3), (0, 2, 7, 7), (86_400, 1, 5, 0)]
        );
        // New hours add to their day.
        store.add(&[usage(10_800, 1, "Mail", 100, 0)], &[]).unwrap();
        assert_eq!(days(&store)[0], (0, 1, 130, 3));
        assert!(Store::open_read_only(&path).is_ok());
        assert!(store.network_colors().unwrap().is_empty());
    }

    /// A network keeps the color the user picked through renames and merges into it, and goes
    /// back to its place's color when the pick is cleared.
    #[test]
    fn a_picked_color_is_kept_until_cleared() {
        let path = temp_db("color");
        {
            // Version 2: before colors.
            let conn = rusqlite::Connection::open(&path).unwrap();
            conn.execute_batch(&format!("{} PRAGMA user_version = 2;", super::SCHEMA))
                .unwrap();
        }
        let mut store = Store::open(&path).unwrap();
        let home = store
            .join_network("wifi:Home", "Home", NetworkKind::Wifi)
            .unwrap();
        let cafe = store
            .join_network("wifi:Cafe", "Cafe", NetworkKind::Wifi)
            .unwrap();
        assert!(store.set_network_color(home.id, Some(3)).unwrap());
        store
            .update_network(home.id, "Flat", NetworkKind::Wifi)
            .unwrap();
        assert_eq!(
            store.network_colors().unwrap(),
            [(home.id, 3)].into_iter().collect()
        );
        store.merge_network(cafe.id, home.id).unwrap();
        assert_eq!(store.network_colors().unwrap().get(&home.id), Some(&3));
        // A network known by its router, colored before its name was readable, passes its color
        // on when it merges into the named one, unless that one has its own.
        let router = store
            .join_network("wifi-router:2:0:0:1:2:3", "Wi-Fi", NetworkKind::Wifi)
            .unwrap();
        let office = store
            .join_network("wifi:Office", "Office", NetworkKind::Wifi)
            .unwrap();
        store.set_network_color(router.id, Some(1)).unwrap();
        store.merge_network(router.id, office.id).unwrap();
        assert_eq!(store.network_colors().unwrap().get(&office.id), Some(&1));
        let router = store
            .join_network("wifi-router:2:0:0:4:5:6", "Wi-Fi", NetworkKind::Wifi)
            .unwrap();
        store.set_network_color(router.id, Some(2)).unwrap();
        store.merge_network(router.id, home.id).unwrap();
        assert_eq!(store.network_colors().unwrap().get(&home.id), Some(&3));
        store.set_network_color(office.id, None).unwrap();
        assert!(store.set_network_color(home.id, None).unwrap());
        assert!(store.network_colors().unwrap().is_empty());
        assert!(
            !store.set_network_color(999, Some(1)).unwrap(),
            "no such network"
        );
    }
}
