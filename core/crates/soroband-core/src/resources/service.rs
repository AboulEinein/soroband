//! The resource meter in the engine's loop: the gauges at every poll, a resource read when one is
//! due ([`super::read_due`]), each local volume's free space once a minute, and a write to the
//! store once a minute and when the engine stops.

use super::ledger::ResourceLedger;
use super::{Gauges, ResourceHost, ResourceMeter, Source, read_due};
use crate::service::WRITE_INTERVAL;
use crate::store::{self, DAY, Store};
use std::sync::{Arc, Mutex, PoisonError};

/// Seconds between reads of the volumes' free space.
const VOLUME_INTERVAL: i64 = 60;

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
    /// Resource reads made, and the time they took.
    reads: u64,
    read_time: std::time::Duration,
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
            reads: 0,
            read_time: std::time::Duration::ZERO,
        }
    }

    pub fn set_minutes_days(&mut self, days: u32) {
        self.minutes_days = days;
    }

    #[must_use]
    pub fn source(&self) -> &Source {
        self.meter.source()
    }

    /// Resource reads made since the service started, and the time they took.
    #[must_use]
    pub fn reads(&self) -> (u64, std::time::Duration) {
        (self.reads, self.read_time)
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
            self.ledger.volumes(volumes, now);
        }
        if read_due(now, self.last_read, busy, &gauges) {
            self.last_read = Some(now);
            let started = std::time::Instant::now();
            let reading = self.meter.read(now);
            self.reads += 1;
            self.read_time += started.elapsed();
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::resources::Volume;
    use crate::resources::record::{RecordedRead, Recording, Replay};

    fn read(time: u64, pressure: u8, free: u64) -> RecordedRead {
        RecordedRead {
            time,
            coalitions: Some(Vec::new()),
            processes: Vec::new(),
            gauges: Gauges {
                pressure: Some(pressure),
                ..Gauges::default()
            },
            volumes: vec![
                Volume {
                    path: "/Volumes/Backup".into(),
                    free: 1,
                    size: 2,
                },
                Volume {
                    path: "/".into(),
                    free,
                    size: free * 2,
                },
            ],
        }
    }

    fn minutes(store: &Mutex<Store>) -> Vec<(i64, Option<i64>)> {
        let store = store.lock().unwrap();
        let mut statement = store
            .connection()
            .prepare(
                "SELECT minute, free FROM resource_minutes
                 LEFT JOIN resource_minute_volumes USING (minute)
                 WHERE volume IS NULL OR volume = '/' ORDER BY minute",
            )
            .unwrap();
        statement
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap()
            .collect::<rusqlite::Result<_>>()
            .unwrap()
    }

    #[test]
    fn polls_read_the_volumes_once_a_minute_and_write_once_a_minute() {
        let path = crate::store::tests::temp_db("resource-service");
        let store = Arc::new(Mutex::new(Store::open(&path).unwrap()));
        let reads = (0..6).map(|i| read(i, 1, 100 + i)).collect();
        let meter = ResourceMeter::trusting(Replay::new(Recording {
            timebase: (1, 1),
            reads,
        }));
        let mut service = ResourceService::new(meter, Arc::clone(&store), 7, 0);
        assert_eq!(service.gauges(), None);
        // Quiet: the first poll reads; the next reads come a minute on.
        for now in [0, 30, 59, 60, 61, 125] {
            service.poll(now).unwrap();
        }
        assert_eq!(service.gauges().unwrap().pressure, Some(1));
        // Written at 60 (the minute from 0) and at 125 (the minute from 60). The volumes were read
        // at 0, 60 and 125, each before that poll's resource read moved the replay on: at 0 and 60
        // from its first read, at 125 from its second.
        assert_eq!(minutes(&store), [(0, Some(100)), (60, Some(100))]);
        service.write(130, true).unwrap();
        assert_eq!(
            minutes(&store),
            [(0, Some(100)), (60, Some(100)), (120, Some(101))]
        );
    }

    #[test]
    fn nothing_is_written_before_a_minute_has_passed() {
        let path = crate::store::tests::temp_db("resource-first-minute");
        let store = Arc::new(Mutex::new(Store::open(&path).unwrap()));
        let meter = ResourceMeter::trusting(Replay::new(Recording {
            timebase: (1, 1),
            reads: vec![read(0, 1, 100)],
        }));
        let mut service = ResourceService::new(meter, Arc::clone(&store), 7, 1_000);
        service.poll(1_000).unwrap();
        service.poll(1_059).unwrap();
        assert_eq!(minutes(&store), []);
        service.poll(1_060).unwrap();
        assert_eq!(minutes(&store), [(960, Some(100))]);
    }

    #[test]
    fn the_minute_record_keeps_the_days_set() {
        let path = crate::store::tests::temp_db("resource-days");
        let store = Arc::new(Mutex::new(Store::open(&path).unwrap()));
        let reads = (0..3).map(|i| read(i, 1, 100)).collect();
        let meter = ResourceMeter::trusting(Replay::new(Recording {
            timebase: (1, 1),
            reads,
        }));
        let mut service = ResourceService::new(meter, Arc::clone(&store), 7, 0);
        service.poll(0).unwrap();
        service.write(60, false).unwrap();
        assert_eq!(minutes(&store).len(), 1);
        // Two days on, with one day kept: the minute from 0 goes.
        service.set_minutes_days(1);
        service.poll(2 * DAY).unwrap();
        service.write(2 * DAY + 60, false).unwrap();
        assert_eq!(minutes(&store), [(2 * DAY, Some(100))]);
    }
}
