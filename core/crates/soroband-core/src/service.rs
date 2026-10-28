//! The app's metering loop: the engine's bytes booked by hour and network, written to the store,
//! with today's totals kept in memory.
//!
//! Writes happen once a minute, when the network changes, when the day starts again and on
//! [`Command::Stop`]. "Today" starts at the reset hour from the settings ([`crate::day`]); its
//! totals are read from the store when the service starts or the day or reset hour changes, then
//! kept up to date from each booking, so showing them never reads the database. Each booking also
//! feeds the engine's self-check ([`crate::check`]).

// The errors are the engine's and the store's own ([`Error`]) and pass through unchanged.
#![allow(clippy::missing_errors_doc)]

use crate::check::{SelfCheck, Verdict};
use crate::day::day_start;
use crate::ledger::{Booked, Ledger};
use crate::meter::{App, Bytes, Engine, Host, Mode};
use crate::settings::Settings;
use crate::store::{self, NetworkTotal, Store};
use std::collections::BTreeMap;
use std::fmt;
use std::io;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

/// Seconds between writes while nothing else forces one.
pub const WRITE_INTERVAL: i64 = 60;

/// Something the app asks of the service between polls.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Command {
    /// The Mac moved to network `id` ([`Store::join_network`]). What was polled before belongs to
    /// the previous network.
    Network(i64),
    /// Network `from` turned out to be network `into` ([`Store::join_network_known_as`]): its
    /// bytes, stored and today's, move into `into` and it leaves the registry.
    Merge { from: i64, into: i64 },
    /// The settings file changed.
    ReloadSettings,
    /// Write everything and stop.
    Stop,
}

#[derive(Debug)]
pub enum Error {
    Io(io::Error),
    Store(store::Error),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => error.fmt(f),
            Self::Store(error) => write!(f, "usage database: {error}"),
        }
    }
}

impl std::error::Error for Error {}

impl From<io::Error> for Error {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<store::Error> for Error {
    fn from(error: store::Error) -> Self {
        Self::Store(error)
    }
}

/// Today's totals.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Today {
    /// Unix time today started.
    pub start: i64,
    pub reset_hour: u8,
    /// The current network and its totals today.
    pub network: NetworkTotal,
    /// Summed over every network.
    pub all: NetworkTotal,
}

#[derive(Debug)]
pub struct Service<H: Host> {
    engine: Engine<H>,
    store: Arc<Mutex<Store>>,
    ledger: Ledger,
    settings_path: PathBuf,
    reset_hour: u8,
    /// The local time zone's offset from UTC at a Unix time.
    zone: fn(i64) -> i64,
    day_start: i64,
    today: BTreeMap<i64, NetworkTotal>,
    /// Today's bytes per (network, app).
    today_apps: BTreeMap<(i64, App), Bytes>,
    last_booked: Booked,
    check: SelfCheck,
    last_write: i64,
}

impl<H: Host> Service<H> {
    /// A service over an engine that has just started, booking to network 0 until told the
    /// network. `now` is the current Unix time.
    pub fn new(
        engine: Engine<H>,
        store: Arc<Mutex<Store>>,
        settings_path: PathBuf,
        zone: fn(i64) -> i64,
        now: i64,
    ) -> Result<Self, Error> {
        let mut service = Self {
            engine,
            store,
            ledger: Ledger::new(0),
            settings_path,
            reset_hour: 0,
            zone,
            day_start: 0,
            today: BTreeMap::new(),
            today_apps: BTreeMap::new(),
            last_booked: Booked::default(),
            check: SelfCheck::default(),
            last_write: now,
        };
        service.reset_hour = service.load_reset_hour();
        service.read_today(now)?;
        Ok(service)
    }

    #[must_use]
    pub fn engine(&self) -> &Engine<H> {
        &self.engine
    }

    /// Waits up to `interval` and polls (see [`Engine::tick`]), books what moved at `now`, and
    /// writes when a minute has passed or a new day started.
    pub fn tick(&mut self, interval: Duration, now: i64) -> Result<(), Error> {
        self.engine.tick(interval)?;
        let snapshot = self.engine.snapshot();
        let booked = self.ledger.book(&snapshot, now);
        let network = self.ledger.network();
        let total = self.today.entry(network).or_default();
        total.network = network;
        total.apps += booked.apps;
        total.interfaces += booked.interfaces;
        for (app, bytes) in &booked.by_app {
            *self.today_apps.entry((network, app.clone())).or_default() += *bytes;
        }
        // On interface totals alone no app is credited, so there is no gap to judge.
        if snapshot.mode == Mode::PerApp {
            self.check.observe(booked.apps, booked.interfaces, now);
        }
        self.last_booked = booked;
        if day_start(now, self.reset_hour, self.zone) != self.day_start {
            self.write(now)?;
            self.read_today(now)?;
        } else if now - self.last_write >= WRITE_INTERVAL {
            self.write(now)?;
        }
        Ok(())
    }

    /// Carries out `command`. Returns false after [`Command::Stop`].
    pub fn apply(&mut self, command: &Command, now: i64) -> Result<bool, Error> {
        match *command {
            Command::Network(id) => {
                if id != self.ledger.network() {
                    // Switch even when the write fails: the unwritten rows keep their network
                    // and go out with the next write.
                    let written = self.write(now);
                    self.ledger.switch(id);
                    written?;
                }
            }
            Command::Merge { from, into } => {
                // Nothing still booked to `from` may be written after it is gone, and a
                // failed write keeps it for the next change.
                self.write(now)?;
                self.store
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .merge_network(from, into)?;
                self.read_today(now)?;
            }
            Command::ReloadSettings => {
                let reset_hour = self.load_reset_hour();
                if reset_hour != self.reset_hour {
                    self.reset_hour = reset_hour;
                    self.write(now)?;
                    self.read_today(now)?;
                }
            }
            Command::Stop => {
                self.write(now)?;
                return Ok(false);
            }
        }
        Ok(true)
    }

    /// Writes everything booked to the store in one transaction.
    pub fn write(&mut self, now: i64) -> Result<(), Error> {
        self.last_write = now;
        if self.ledger.is_empty() {
            return Ok(());
        }
        let (apps, interfaces) = self.ledger.take();
        let result = self
            .store
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .add(&apps, &interfaces);
        if let Err(error) = result {
            self.ledger.restore(apps, interfaces);
            return Err(error.into());
        }
        Ok(())
    }

    #[must_use]
    pub fn today(&self) -> Today {
        let network = self.ledger.network();
        let mut all = NetworkTotal::default();
        for total in self.today.values() {
            all.apps += total.apps;
            all.interfaces += total.interfaces;
        }
        Today {
            start: self.day_start,
            reset_hour: self.reset_hour,
            network: self.today.get(&network).copied().unwrap_or(NetworkTotal {
                network,
                ..NetworkTotal::default()
            }),
            all,
        }
    }

    /// Today's totals on each network that carried bytes, in network order.
    pub fn today_networks(&self) -> impl Iterator<Item = &NetworkTotal> {
        self.today.values()
    }

    /// Today's bytes per app on each network, in network order.
    pub fn today_apps(&self) -> impl Iterator<Item = (i64, &App, Bytes)> {
        self.today_apps
            .iter()
            .map(|((network, app), bytes)| (*network, app, *bytes))
    }

    /// What the last poll booked to the current network.
    #[must_use]
    pub fn last_booked(&self) -> &Booked {
        &self.last_booked
    }

    /// The self-check's verdict on the bytes booked so far.
    #[must_use]
    pub fn check(&self) -> Verdict {
        self.check.verdict()
    }

    /// Reads today's totals from the store; call with nothing booked but unwritten.
    fn read_today(&mut self, now: i64) -> Result<(), Error> {
        // The start is kept only once the read succeeds, so a failed read is retried next tick.
        let start = day_start(now, self.reset_hour, self.zone);
        let store = self.store.lock().unwrap_or_else(PoisonError::into_inner);
        let totals = store.network_totals(start)?;
        let apps = store.app_network_totals(start)?;
        drop(store);
        self.day_start = start;
        self.today = totals.into_iter().map(|t| (t.network, t)).collect();
        self.today_apps = apps
            .into_iter()
            .map(|(network, app, bytes)| ((network, app), bytes))
            .collect();
        Ok(())
    }

    /// The reset hour from the settings file; an unreadable file keeps the current one.
    fn load_reset_hour(&self) -> u8 {
        match Settings::load(&self.settings_path) {
            Ok(settings) => settings.reset_hour(),
            Err(error) => {
                eprintln!(
                    "soroband: {}: {error}; keeping the current settings",
                    self.settings_path.display()
                );
                self.reset_hour
            }
        }
    }
}
