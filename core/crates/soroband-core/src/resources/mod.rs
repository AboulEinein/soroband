//! The resource meter: each app's CPU, memory, disk and energy, beside its internet bytes.
//!
//! A [`ResourceMeter`] reads every resource coalition (the kernel's group of an app and the
//! helpers it starts) and credits each coalition's growth since the last read to its app, named
//! as the network meter names apps ([`App::from_executable`]). A coalition counts the processes
//! that already exited, and its read needs no privilege, so apps run as root are read too.
//!
//! A coalition holding processes of several apps (a terminal and the commands it runs) is shared.
//! Its members outside the leader's app (the app of its lowest process id) are read with
//! `proc_pid_rusage`, and each one's growth goes to its own app. What is left of the coalition's
//! growth is the leader's own, and what processes that exited since the last read, or that the
//! user cannot read, used. It goes first to the members that exited, in proportion to what each
//! used in the interval before and at most that rate over this interval, then the rest to the
//! leader; a process that starts and exits between two reads is therefore credited to the leader.
//! A coalition split at one read is split again at the next while a process it read is gone.
//!
//! The coalition calls are not in the public SDK. The [`guard`] checks their layout at the first
//! read and every [`CHECK_INTERVAL`] seconds; when they are missing or the check fails, the meter
//! reads the user's own processes with `proc_pid_rusage` instead ([`Source::Processes`]), which
//! leaves out other users' and root processes, and the usage processes had between their last
//! read and their exit.

pub mod guard;
pub mod kernel;
pub mod ledger;
pub mod record;
pub mod service;

use crate::meter::App;
use std::collections::{BTreeMap, HashMap};

/// Words read from a coalition: more than any layout the kernel writes.
pub const RAW_WORDS: usize = 64;

/// Seconds between the guard's checks of the coalition layout.
pub const CHECK_INTERVAL: i64 = 3600;

/// Seconds between resource reads while the Mac is quiet.
pub const READ_INTERVAL: i64 = 60;

/// CPU busy share above which every poll reads the resources.
pub const BUSY: f64 = 0.5;

/// `kern.memorystatus_vm_pressure_level` above which memory is under pressure (1 is normal, 2
/// warning, 4 critical).
pub const PRESSURE_NORMAL: u8 = 1;

/// A stored resource. [`Field::Footprint`] is a gauge; the others are counters.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Field {
    Cpu,
    Billed,
    Read,
    Written,
    Energy,
    Footprint,
}

impl Field {
    pub const ALL: [Self; 6] = [
        Self::Cpu,
        Self::Billed,
        Self::Read,
        Self::Written,
        Self::Energy,
        Self::Footprint,
    ];

    #[must_use]
    pub fn name(self) -> &'static str {
        match self {
            Self::Cpu => "CPU time",
            Self::Billed => "billed CPU time",
            Self::Read => "disk read",
            Self::Written => "disk written",
            Self::Energy => "energy",
            Self::Footprint => "memory footprint",
        }
    }
}

/// Where each stored field sits in the coalition's words (xnu's `struct coalition_resource_usage`,
/// `osfmk/mach/coalition.h`), and where its count of exited processes does.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Layout {
    pub exited: usize,
    pub cpu: usize,
    pub billed: usize,
    pub read: usize,
    pub written: usize,
    pub energy: usize,
    pub footprint: usize,
}

/// The layout on macOS 27: `tasks_exited`, `cpu_time` (Mach time units), `bytesread`,
/// `byteswritten`, `cpu_time_billed_to_me`, `energy` (nJ) and `phys_footprint` (bytes).
pub const LAYOUT: Layout = Layout {
    exited: 1,
    cpu: 3,
    read: 6,
    written: 7,
    billed: 9,
    energy: 11,
    footprint: 40,
};

impl Layout {
    #[must_use]
    pub fn index(&self, field: Field) -> usize {
        match field {
            Field::Cpu => self.cpu,
            Field::Billed => self.billed,
            Field::Read => self.read,
            Field::Written => self.written,
            Field::Energy => self.energy,
            Field::Footprint => self.footprint,
        }
    }

    fn counters(&self, raw: &[u64; RAW_WORDS]) -> Counters {
        Counters {
            cpu: raw[self.cpu],
            billed: raw[self.billed],
            read: raw[self.read],
            written: raw[self.written],
            energy: raw[self.energy],
        }
    }
}

/// One process's usage from `proc_pid_rusage`. CPU times are in Mach time units.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ProcessUsage {
    pub cpu: u64,
    pub billed: u64,
    pub read: u64,
    pub written: u64,
    pub energy: u64,
    pub footprint: u64,
    /// When it started, in Mach absolute time.
    pub start: u64,
}

impl ProcessUsage {
    #[must_use]
    pub fn field(&self, field: Field) -> u64 {
        match field {
            Field::Cpu => self.cpu,
            Field::Billed => self.billed,
            Field::Read => self.read,
            Field::Written => self.written,
            Field::Energy => self.energy,
            Field::Footprint => self.footprint,
        }
    }

    fn counters(&self) -> Counters {
        Counters {
            cpu: self.cpu,
            billed: self.billed,
            read: self.read,
            written: self.written,
            energy: self.energy,
        }
    }
}

/// The counted resources: CPU time and CPU time billed to it by daemons working for it (Mach
/// time units in a read, nanoseconds in a [`Reading`]), disk bytes read and written, and energy
/// in nanojoules.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Counters {
    pub cpu: u64,
    pub billed: u64,
    pub read: u64,
    pub written: u64,
    pub energy: u64,
}

impl Counters {
    fn to_array(self) -> [u64; 5] {
        [self.cpu, self.billed, self.read, self.written, self.energy]
    }

    fn from_array(a: [u64; 5]) -> Self {
        Self {
            cpu: a[0],
            billed: a[1],
            read: a[2],
            written: a[3],
            energy: a[4],
        }
    }

    #[must_use]
    pub fn saturating_sub(self, other: Self) -> Self {
        let (a, b) = (self.to_array(), other.to_array());
        Self::from_array(std::array::from_fn(|i| a[i].saturating_sub(b[i])))
    }
}

impl std::ops::AddAssign for Counters {
    fn add_assign(&mut self, other: Self) {
        let (a, b) = (self.to_array(), other.to_array());
        *self = Self::from_array(std::array::from_fn(|i| a[i].saturating_add(b[i])));
    }
}

/// What one app used between two reads, and its memory footprint at the second.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct AppResources {
    pub counters: Counters,
    pub footprint: u64,
}

/// Where the meter's numbers come from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Source {
    /// Every coalition, root and other users' processes included.
    Coalitions,
    /// The user's own processes, because the coalition calls are missing or their layout failed
    /// the guard (`reason`).
    Processes { reason: String },
}

/// One resource read: what each app used since the read before.
#[derive(Debug, Clone, PartialEq)]
pub struct Reading {
    /// Seconds since the read before; 0 for the first read, which only takes the baseline.
    pub seconds: f64,
    /// Per app, largest CPU first.
    pub apps: Vec<(App, AppResources)>,
    pub source: Source,
}

impl Reading {
    #[must_use]
    pub fn fallback(&self) -> bool {
        matches!(self.source, Source::Processes { .. })
    }
}

/// The system gauges: CPU ticks (user, system, idle, nice), memory and its pressure. Each is
/// `None` when its call failed.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Gauges {
    pub cpu_ticks: Option<[u64; 4]>,
    /// Bytes in use: app memory, wired and compressed, as Activity Monitor's Memory Used.
    pub memory_used: Option<u64>,
    pub memory_compressed: Option<u64>,
    pub swap_used: Option<u64>,
    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
    pub pressure: Option<u8>,
}

impl Gauges {
    /// The share of CPU time spent busy between `earlier` and these gauges.
    #[must_use]
    pub fn busy_since(&self, earlier: &Self) -> Option<f64> {
        let (now, then) = (self.cpu_ticks?, earlier.cpu_ticks?);
        let delta: [u64; 4] = std::array::from_fn(|i| now[i].saturating_sub(then[i]));
        let total: u64 = delta.iter().sum();
        #[allow(clippy::cast_precision_loss)] // tick counts between polls
        (total > 0).then(|| 1.0 - delta[2] as f64 / total as f64)
    }

    #[must_use]
    pub fn under_pressure(&self) -> bool {
        self.pressure.is_some_and(|p| p > PRESSURE_NORMAL)
    }
}

/// A local volume's free and total bytes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Volume {
    pub path: String,
    pub free: u64,
    pub size: u64,
}

/// The meter's view of the system. [`kernel::SystemResources`] is the real one;
/// [`record::Replay`] plays a recording back.
pub trait ResourceHost {
    /// Starts a read. A replay moves to its next recorded read.
    fn begin(&mut self) {}
    /// Mach absolute time now.
    fn now(&mut self) -> u64;
    /// Nanoseconds per Mach time unit, as a fraction.
    fn timebase(&self) -> (u32, u32);
    /// Every resource coalition's id, or `None` when the coalition calls are missing.
    fn coalition_ids(&mut self) -> Option<Vec<u64>>;
    /// A coalition's words, or `None` when it cannot be read (it ended).
    fn coalition_usage(&mut self, id: u64) -> Option<[u64; RAW_WORDS]>;
    fn pids(&mut self) -> Vec<u32>;
    /// The resource coalition `pid` belongs to.
    fn coalition_of(&mut self, pid: u32) -> Option<u64>;
    /// `None` for another user's process, or one that exited.
    fn process_usage(&mut self, pid: u32) -> Option<ProcessUsage>;
    fn executable_path(&mut self, pid: u32) -> Option<String>;
    fn gauges(&mut self) -> Gauges;
    fn volumes(&mut self) -> Vec<Volume>;
}

/// A coalition at the last read.
#[derive(Debug)]
struct CoalitionState {
    counters: Counters,
    /// Whether it held processes of several apps.
    shared: bool,
    leader: Option<App>,
    members: Vec<u32>,
}

/// A process read at the last read: a member of a shared coalition, or any process while
/// falling back.
#[derive(Debug)]
struct ProcessState {
    usage: ProcessUsage,
    app: App,
    /// What it used in the interval before the last read.
    delta: Counters,
    coalition: Option<u64>,
}

#[derive(Debug)]
struct LastRead {
    time: u64,
    /// Mach time units between the read before it and it.
    elapsed: u64,
    /// The highest coalition id: a coalition above it started after this read.
    max_id: u64,
    coalitions: HashMap<u64, CoalitionState>,
    processes: HashMap<u32, ProcessState>,
}

/// Per-app sums of one read.
#[derive(Debug, Default)]
struct Credits(BTreeMap<App, AppResources>);

impl Credits {
    fn add(&mut self, app: &App, counters: Counters, footprint: u64) {
        let entry = self.0.entry(app.clone()).or_default();
        entry.counters += counters;
        entry.footprint = entry.footprint.saturating_add(footprint);
    }
}

/// The resource meter over a [`ResourceHost`].
#[derive(Debug)]
pub struct ResourceMeter<R: ResourceHost> {
    host: R,
    layout: Layout,
    source: Source,
    /// Unix time of the guard's next check; `None` once the coalition calls were found missing.
    next_check: Option<i64>,
    last: Option<LastRead>,
    /// Each running process's coalition and app, by pid, looked up once per process: neither
    /// changes while it runs. A pid gone at one read is forgotten, so a pid reused between two
    /// reads keeps the earlier process's (pids are reused only after about 100,000 more).
    known: HashMap<u32, Known>,
}

/// What a running process was found to be, at the first read it was in.
#[derive(Debug)]
struct Known {
    coalition: Option<u64>,
    app: Option<App>,
}

impl<R: ResourceHost> ResourceMeter<R> {
    #[must_use]
    pub fn new(host: R) -> Self {
        Self::with_layout(host, LAYOUT)
    }

    /// A meter that reads coalitions with `layout`, so a test can give it a wrong one.
    #[must_use]
    pub fn with_layout(host: R, layout: Layout) -> Self {
        Self {
            host,
            layout,
            source: Source::Coalitions,
            next_check: Some(i64::MIN),
            last: None,
            known: HashMap::new(),
        }
    }

    /// A meter that reads coalitions with [`LAYOUT`] and never runs the guard: for tests of the
    /// crediting rules on reads built by hand, whose coalitions have nothing to compare.
    #[must_use]
    pub fn trusting(host: R) -> Self {
        Self {
            next_check: None,
            ..Self::new(host)
        }
    }

    #[must_use]
    pub fn source(&self) -> &Source {
        &self.source
    }

    pub fn host_mut(&mut self) -> &mut R {
        &mut self.host
    }

    /// Reads every app's resources at Unix time `now`, checking the coalition layout first when
    /// a check is due.
    pub fn read(&mut self, now: i64) -> Reading {
        self.host.begin();
        if self.next_check.is_some_and(|at| now >= at) {
            self.next_check = Some(now + CHECK_INTERVAL);
            self.check();
        }
        let time = self.host.now();
        let previous = self.last.take();
        let (credits, next) = match self.source {
            Source::Coalitions => {
                if let Some(ids) = self.host.coalition_ids() {
                    self.read_coalitions(&ids, time, previous.as_ref())
                } else {
                    self.missing_calls();
                    self.read_processes(time, None)
                }
            }
            Source::Processes { .. } => self.read_processes(time, previous.as_ref()),
        };
        let seconds = previous
            .as_ref()
            .map_or(0.0, |p| self.seconds(time - p.time));
        self.last = Some(next);
        let (numer, denom) = self.host.timebase();
        let mut apps: Vec<(App, AppResources)> = credits
            .0
            .into_iter()
            .map(|(app, mut r)| {
                r.counters.cpu = nanoseconds(r.counters.cpu, numer, denom);
                r.counters.billed = nanoseconds(r.counters.billed, numer, denom);
                (app, r)
            })
            .collect();
        apps.sort_by(|(a, x), (b, y)| y.counters.cpu.cmp(&x.counters.cpu).then_with(|| a.cmp(b)));
        Reading {
            seconds,
            apps,
            source: self.source.clone(),
        }
    }

    fn seconds(&self, ticks: u64) -> f64 {
        let (numer, denom) = self.host.timebase();
        #[allow(clippy::cast_precision_loss)] // nanoseconds between reads
        let seconds = nanoseconds(ticks, numer, denom) as f64 / 1e9;
        seconds
    }

    fn missing_calls(&mut self) {
        self.next_check = None;
        self.source = Source::Processes {
            reason: "the coalition calls are missing from this macOS".into(),
        };
    }

    /// Runs the guard and switches the source on its verdict. A switch starts a new baseline.
    fn check(&mut self) {
        let Some(ids) = self.host.coalition_ids() else {
            self.missing_calls();
            self.last = None;
            return;
        };
        let members = self.members();
        let mut samples = Vec::new();
        for id in ids {
            let Some(pids) = members.get(&id) else {
                continue;
            };
            let before: Vec<_> = pids.iter().map(|&p| self.host.process_usage(p)).collect();
            let Some(raw) = self.host.coalition_usage(id) else {
                continue;
            };
            let after: Vec<_> = pids.iter().map(|&p| self.host.process_usage(p)).collect();
            samples.push(guard::Sample { raw, before, after });
        }
        let source = match guard::check(&self.layout, &samples) {
            Ok(()) => Source::Coalitions,
            Err(reason) => Source::Processes {
                reason: format!("the coalition layout failed its check ({reason})"),
            },
        };
        if source != self.source {
            self.source = source;
            self.last = None;
        }
    }

    /// Each coalition's processes, lowest pid first. Forgets the processes that are gone.
    fn members(&mut self) -> BTreeMap<u64, Vec<u32>> {
        let mut pids = self.host.pids();
        pids.sort_unstable();
        self.keep_known(&pids);
        let mut members: BTreeMap<u64, Vec<u32>> = BTreeMap::new();
        for pid in pids {
            if let Some(id) = self.known(pid).coalition {
                members.entry(id).or_default().push(pid);
            }
        }
        members
    }

    /// What `pid` is, looked up at the first read it is in.
    fn known(&mut self, pid: u32) -> &Known {
        let host = &mut self.host;
        self.known.entry(pid).or_insert_with(|| Known {
            coalition: host.coalition_of(pid),
            app: host
                .executable_path(pid)
                .map(|path| App::from_executable(&path)),
        })
    }

    /// The app of `pid`.
    fn app_of(&mut self, pid: u32) -> Option<App> {
        self.known(pid).app.clone()
    }

    /// Forgets the processes that are gone.
    fn keep_known(&mut self, running: &[u32]) {
        let running: std::collections::HashSet<u32> = running.iter().copied().collect();
        self.known.retain(|pid, _| running.contains(pid));
    }

    fn read_coalitions(
        &mut self,
        ids: &[u64],
        time: u64,
        previous: Option<&LastRead>,
    ) -> (Credits, LastRead) {
        let members = self.members();
        let mut credits = Credits::default();
        let mut next = LastRead {
            time,
            elapsed: previous.map_or(0, |p| time.saturating_sub(p.time)),
            max_id: ids.iter().copied().max().unwrap_or(0),
            coalitions: HashMap::new(),
            processes: HashMap::new(),
        };
        for &id in ids {
            let Some(raw) = self.host.coalition_usage(id) else {
                continue;
            };
            let counters = self.layout.counters(&raw);
            let footprint = raw[self.layout.footprint];
            let pids = members.get(&id).cloned().unwrap_or_default();
            let known = previous.and_then(|p| p.coalitions.get(&id));
            let grown = match (previous, known) {
                (_, Some(state)) => counters.saturating_sub(state.counters),
                // Coalition ids only grow: one above the last read's highest started since.
                (Some(p), None) if id > p.max_id => counters,
                _ => Counters::default(),
            };
            let member_apps: Vec<(u32, App)> = pids
                .iter()
                .filter_map(|&pid| self.app_of(pid).map(|app| (pid, app)))
                .collect();
            let leader = member_apps
                .first()
                .map(|(_, app)| app.clone())
                .or_else(|| known.and_then(|s| s.leader.clone()));
            // A coalition split at the last read is split again while a process read then is
            // gone, so what it used before it exited stays its own.
            let shared = member_apps
                .iter()
                .any(|(_, app)| Some(app) != leader.as_ref())
                || known.is_some_and(|s| s.shared && s.members.iter().any(|p| !pids.contains(p)));
            if shared {
                self.split(
                    id,
                    grown,
                    footprint,
                    &member_apps,
                    leader.as_ref(),
                    previous,
                    &mut next,
                    &mut credits,
                );
            } else if let Some(app) = &leader {
                credits.add(app, grown, footprint);
            }
            next.coalitions.insert(
                id,
                CoalitionState {
                    counters,
                    shared,
                    leader,
                    members: pids,
                },
            );
        }
        (credits, next)
    }

    /// Splits a shared coalition's growth among its members' apps (see the module's docs).
    #[allow(clippy::too_many_arguments)]
    fn split(
        &mut self,
        id: u64,
        grown: Counters,
        footprint: u64,
        member_apps: &[(u32, App)],
        leader: Option<&App>,
        previous: Option<&LastRead>,
        next: &mut LastRead,
        credits: &mut Credits,
    ) {
        let mut members_grown = Counters::default();
        let mut members_footprint = 0u64;
        // The leader's own processes are not read: what they used is part of what is left.
        for (pid, app) in member_apps.iter().filter(|(_, app)| Some(app) != leader) {
            let Some(usage) = self.host.process_usage(*pid) else {
                continue;
            };
            let delta = process_growth(*pid, &usage, Some(id), previous);
            members_grown += delta;
            members_footprint = members_footprint.saturating_add(usage.footprint);
            credits.add(app, delta, usage.footprint);
            next.processes.insert(
                *pid,
                ProcessState {
                    usage,
                    app: app.clone(),
                    delta,
                    coalition: Some(id),
                },
            );
        }
        let mut left = grown.saturating_sub(members_grown).to_array();
        if let Some(previous) = previous {
            let exited: Vec<&ProcessState> = previous
                .coalitions
                .get(&id)
                .map(|c| c.members.as_slice())
                .unwrap_or_default()
                .iter()
                .filter(|pid| !member_apps.iter().any(|(p, _)| p == *pid))
                .filter_map(|pid| previous.processes.get(pid))
                .filter(|p| p.coalition == Some(id))
                .collect();
            for field in 0..left.len() {
                let rates: Vec<u64> = exited.iter().map(|p| p.delta.to_array()[field]).collect();
                let total: u64 = rates.iter().sum();
                if total == 0 {
                    continue;
                }
                let pool = left[field];
                for (process, rate) in exited.iter().zip(&rates) {
                    let share = scale(pool, *rate, total)
                        .min(scale(*rate, next.elapsed, previous.elapsed))
                        .min(left[field]);
                    left[field] -= share;
                    let mut counters = [0; 5];
                    counters[field] = share;
                    credits.add(&process.app, Counters::from_array(counters), 0);
                }
            }
        }
        if let Some(leader) = leader {
            credits.add(
                leader,
                Counters::from_array(left),
                footprint.saturating_sub(members_footprint),
            );
        }
    }

    /// Reads the user's own processes, one by one.
    fn read_processes(&mut self, time: u64, previous: Option<&LastRead>) -> (Credits, LastRead) {
        let pids = self.host.pids();
        self.keep_known(&pids);
        let mut credits = Credits::default();
        let mut next = LastRead {
            time,
            elapsed: previous.map_or(0, |p| time.saturating_sub(p.time)),
            max_id: 0,
            coalitions: HashMap::new(),
            processes: HashMap::new(),
        };
        for pid in pids {
            let Some(usage) = self.host.process_usage(pid) else {
                continue;
            };
            let Some(app) = self.app_of(pid) else {
                continue;
            };
            let delta = process_growth(pid, &usage, None, previous);
            credits.add(&app, delta, usage.footprint);
            next.processes.insert(
                pid,
                ProcessState {
                    usage,
                    app,
                    delta,
                    coalition: None,
                },
            );
        }
        (credits, next)
    }
}

/// What process `pid` used since the last read: its growth if it was read then (in the same
/// coalition, and the same process, by its start time), all of it if it started since, and
/// nothing at the first read.
fn process_growth(
    pid: u32,
    usage: &ProcessUsage,
    coalition: Option<u64>,
    previous: Option<&LastRead>,
) -> Counters {
    let Some(previous) = previous else {
        return Counters::default();
    };
    match previous.processes.get(&pid) {
        Some(state) if state.coalition == coalition && state.usage.start == usage.start => {
            usage.counters().saturating_sub(state.usage.counters())
        }
        _ if usage.start >= previous.time => usage.counters(),
        _ => Counters::default(),
    }
}

/// `value * numerator / denominator`, rounded down; `value` when the denominator is 0.
fn scale(value: u64, numerator: u64, denominator: u64) -> u64 {
    if denominator == 0 {
        return value;
    }
    u64::try_from(u128::from(value) * u128::from(numerator) / u128::from(denominator))
        .unwrap_or(u64::MAX)
}

/// Mach time units in nanoseconds.
fn nanoseconds(ticks: u64, numer: u32, denom: u32) -> u64 {
    scale(ticks, u64::from(numer), u64::from(denom.max(1)))
}

/// Whether a resource read is due at Unix time `now`: once [`READ_INTERVAL`] has passed since
/// `last` (Unix time of the last read, `None` before the first), and at every poll while the CPU
/// is busier than [`BUSY`] or memory is under pressure.
#[must_use]
pub fn read_due(now: i64, last: Option<i64>, busy: Option<f64>, gauges: &Gauges) -> bool {
    last.is_none_or(|last| now - last >= READ_INTERVAL)
        || busy.is_some_and(|b| b > BUSY)
        || gauges.under_pressure()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gauges(pressure: u8) -> Gauges {
        Gauges {
            pressure: Some(pressure),
            ..Gauges::default()
        }
    }

    #[test]
    fn a_read_is_due_once_a_minute_and_at_every_poll_under_load() {
        let quiet = gauges(1);
        assert!(read_due(100, None, None, &quiet), "the first poll reads");
        assert!(!read_due(159, Some(100), Some(0.5), &quiet));
        assert!(read_due(160, Some(100), Some(0.1), &quiet));
        assert!(read_due(105, Some(100), Some(0.51), &quiet), "busy");
        assert!(read_due(105, Some(100), Some(0.1), &gauges(2)), "pressure");
        assert!(read_due(105, Some(100), None, &gauges(4)), "critical");
    }

    #[test]
    fn busy_share_is_the_non_idle_part_of_the_ticks_between_two_polls() {
        let at = |user, system, idle, nice| Gauges {
            cpu_ticks: Some([user, system, idle, nice]),
            ..Gauges::default()
        };
        assert_eq!(at(30, 10, 130, 0).busy_since(&at(10, 0, 100, 0)), Some(0.5));
        assert_eq!(at(10, 0, 100, 0).busy_since(&at(10, 0, 100, 0)), None);
        assert_eq!(Gauges::default().busy_since(&at(1, 1, 1, 1)), None);
    }
}
