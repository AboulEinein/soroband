//! The resource meter in the engine's loop: the gauges at every poll, a resource read when one is
//! due ([`super::read_due`]), the startup volume's free space once a minute, and a write to the
//! store once a minute and when the engine stops.

use super::ledger::ResourceLedger;
use super::{Gauges, ResourceHost, ResourceMeter, Source, read_due};
use crate::service::WRITE_INTERVAL;
use crate::store::{self, DAY, Store};
use std::sync::{Arc, Mutex, PoisonError};

/// Seconds between reads of the volumes' free space.
const VOLUME_INTERVAL: i64 = 60;

/// The startup volume, whose free space the minute record keeps.
const STARTUP_VOLUME: &str = "/";

#[derive(Debug)]
pub struct ResourceService<R: ResourceHost> {
    meter: ResourceMeter<R>,
    ledger: ResourceLedger,
    store: Arc<Mutex<Store>>,
    gauges: Option<Gauges>,
    last_read: Option<i64>,
    last_volumes: Option<i64>,
    last_write: i64,
    minutes_days: u32,
}

impl<R: ResourceHost> ResourceService<R> {
    /// A service writing to `store`, keeping the minute record `minutes_days` days. `now` is the
    /// current Unix time.
    pub fn new(
        meter: ResourceMeter<R>,
        store: Arc<Mutex<Store>>,
        minutes_days: u32,
        now: i64,
    ) -> Self {
        Self {
            meter,
            ledger: ResourceLedger::default(),
            store,
            gauges: None,
            last_read: None,
            last_volumes: None,
            last_write: now,
            minutes_days,
        }
    }

    pub fn set_minutes_days(&mut self, days: u32) {
        self.minutes_days = days;
    }

    #[must_use]
    pub fn source(&self) -> &Source {
        self.meter.source()
    }

    /// The gauges at the last poll.
    #[must_use]
    pub fn gauges(&self) -> Option<Gauges> {
        self.gauges
    }

    /// Reads the gauges at Unix time `now`, the resources when a read is due, and writes once a
    /// minute has passed since the last write.
    ///
    /// # Errors
    /// When the write fails; its rows are kept for the next one.
    pub fn poll(&mut self, now: i64) -> Result<(), store::Error> {
        let gauges = self.meter.host_mut().gauges();
        let busy = self.gauges.and_then(|before| gauges.busy_since(&before));
        self.gauges = Some(gauges);
        self.ledger.poll(gauges, now);
        if self
            .last_volumes
            .is_none_or(|last| now - last >= VOLUME_INTERVAL)
        {
            self.last_volumes = Some(now);
            let volumes = self.meter.host_mut().volumes();
            if let Some(startup) = volumes.iter().find(|v| v.path == STARTUP_VOLUME) {
                self.ledger.disk_free(startup.free, now);
            }
        }
        if read_due(now, self.last_read, busy, &gauges) {
            self.last_read = Some(now);
            let reading = self.meter.read(now);
            self.ledger.book(&reading, now);
        }
        if now - self.last_write >= WRITE_INTERVAL {
            self.write(now, false)?;
        }
        Ok(())
    }

    /// Writes every hour row and the finished minutes (all of them when `all`), and drops the
    /// minutes older than the days kept.
    ///
    /// # Errors
    /// When the write fails; its rows are kept for the next one.
    pub fn write(&mut self, now: i64, all: bool) -> Result<(), store::Error> {
        self.last_write = now;
        if self.ledger.is_empty() {
            return Ok(());
        }
        let (hours, minutes) = self.ledger.take(now, all);
        let keep_since = now - i64::from(self.minutes_days) * DAY;
        let result = self
            .store
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .add_resources(&hours, &minutes, keep_since);
        if let Err(error) = result {
            self.ledger.restore(hours, minutes);
            return Err(error);
        }
        Ok(())
    }
}
