//! The meter engine: counts internet bytes per app from the kernel's network statistics.
//!
//! [`Engine`] subscribes to every TCP and UDP flow on Wi‑Fi, wired and cellular interfaces, takes
//! a baseline poll, then polls every flow at each [`Engine::tick`] and books each flow's new bytes
//! to its app. It talks to the system only through a [`Host`], so a recording of a real session
//! replays through the same code ([`record`]).

// The errors in this module are the system's own (`std::io::Error`) and pass through unchanged.
#![allow(clippy::missing_errors_doc)]

pub mod interfaces;
pub mod ntstat;
pub mod process;
pub mod record;
mod socket;

pub use process::App;
pub use socket::SystemHost;

use interfaces::{InterfaceCounter, InterfaceTotals};
use ntstat::{Message, UpdateError};
use std::collections::HashMap;
use std::io;
use std::time::{Duration, Instant};

/// Bytes received and sent.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct Bytes {
    pub rx: u64,
    pub tx: u64,
}

impl Bytes {
    #[must_use]
    pub fn total(self) -> u64 {
        self.rx + self.tx
    }
}

impl std::ops::AddAssign for Bytes {
    fn add_assign(&mut self, other: Self) {
        self.rx += other.rx;
        self.tx += other.tx;
    }
}

/// What the engine can count.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Mode {
    /// Per-app bytes from the kernel's flows.
    PerApp,
    /// A descriptor had a size not known for this macOS version, so flow fields cannot be trusted.
    /// Only interface totals are counted from then on.
    InterfaceOnly { reason: String },
}

/// The engine's view of the system: the kernel statistics socket, process paths and interface
/// counters. [`SystemHost`] is the real one; [`record::Replay`] plays a recording back.
pub trait Host {
    /// macOS major version, which selects the descriptor layouts.
    fn macos_major(&self) -> u32;
    fn send(&mut self, message: &[u8]) -> io::Result<()>;
    /// Waits for one datagram until `deadline`; `None` when the deadline passes first.
    fn recv(&mut self, buf: &mut [u8], deadline: Instant) -> io::Result<Option<usize>>;
    fn executable_path(&mut self, pid: u32) -> Option<String>;
    fn interface_counters(&mut self) -> io::Result<Vec<InterfaceCounter>>;
}

/// How long the engine waits for the subscriptions' first updates, and for a poll's reply.
const SETTLE: Duration = Duration::from_millis(300);
const POLL_TIMEOUT: Duration = Duration::from_secs(2);
/// Baseline polls tried before the engine gives up starting.
const BASELINE_ATTEMPTS: usize = 3;
/// Large enough for the biggest chunk the kernel sends.
const RECV_BUFFER: usize = 1 << 17;
/// Poll contexts start above the subscription contexts, which are provider numbers.
const FIRST_POLL_CONTEXT: u64 = 1 << 32;

#[derive(Debug)]
struct Flow {
    rx: u64,
    tx: u64,
    rx_duplicate: u32,
    app: App,
}

/// Per-flow accounting. Fed one kernel message at a time by [`Engine`].
#[derive(Debug)]
struct Meter {
    macos_major: u32,
    flows: HashMap<u64, Flow>,
    apps: HashMap<App, Bytes>,
    /// Received bytes per app that were duplicates from retransmission, also in `apps`.
    rx_duplicates: HashMap<App, u64>,
    local: Bytes,
    /// False until the baseline poll completes: flows seen before then only set their starting
    /// counters, so bytes moved before the engine started are never booked.
    counting: bool,
    mode: Mode,
}

impl Meter {
    fn new(macos_major: u32) -> Self {
        Self {
            macos_major,
            flows: HashMap::new(),
            apps: HashMap::new(),
            rx_duplicates: HashMap::new(),
            local: Bytes::default(),
            counting: false,
            mode: Mode::PerApp,
        }
    }

    fn update(&mut self, message: &Message, path_of: &mut impl FnMut(u32) -> Option<String>) {
        if self.mode != Mode::PerApp {
            return;
        }
        let update = match ntstat::parse_update(message, self.macos_major) {
            Ok(update) => update,
            Err(UpdateError::UnknownProvider(_) | UpdateError::Truncated) => return,
            Err(UpdateError::UnknownLayout { provider, size }) => {
                self.mode = Mode::InterfaceOnly {
                    reason: format!(
                        "{} descriptor of {size} bytes is not known for macOS {}",
                        ntstat::provider_name(provider),
                        self.macos_major
                    ),
                };
                self.flows.clear();
                self.apps.clear();
                self.rx_duplicates.clear();
                self.local = Bytes::default();
                return;
            }
        };
        let flow = self.flows.entry(update.srcref).or_insert_with(|| Flow {
            rx: 0,
            tx: 0,
            rx_duplicate: 0,
            app: process::attribute(update.pid, update.epid, &update.pname, path_of),
        });
        let delta = Bytes {
            rx: update.rx.saturating_sub(flow.rx),
            tx: update.tx.saturating_sub(flow.tx),
        };
        let rx_duplicate = update.rx_duplicate.saturating_sub(flow.rx_duplicate);
        flow.rx = flow.rx.max(update.rx);
        flow.tx = flow.tx.max(update.tx);
        flow.rx_duplicate = flow.rx_duplicate.max(update.rx_duplicate);
        if !self.counting {
            return;
        }
        if update.local {
            self.local += delta;
        } else {
            *self.apps.entry(flow.app.clone()).or_default() += delta;
            if rx_duplicate > 0 {
                *self.rx_duplicates.entry(flow.app.clone()).or_default() += u64::from(rx_duplicate);
            }
        }
    }

    fn removed(&mut self, message: &Message) {
        if let Some(srcref) = ntstat::removed_srcref(message) {
            self.flows.remove(&srcref);
        }
    }
}

/// Totals since the baseline.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Snapshot {
    pub mode: Mode,
    /// Internet bytes per app, largest first. Empty in [`Mode::InterfaceOnly`].
    pub apps: Vec<(App, Bytes)>,
    /// Bytes of flows to the local network, which are not internet traffic and not booked.
    pub local: Bytes,
    /// Bytes that crossed the internet interfaces, for reconciliation.
    pub interfaces: Bytes,
    /// Flows currently tracked.
    pub flows: usize,
    /// Received bytes per app that were duplicates from retransmission. They are part of the
    /// app's bytes in `apps`: they crossed the interface, so they are usage.
    pub rx_duplicates: Vec<(App, u64)>,
}

impl Snapshot {
    /// Received bytes of `app` that were duplicates from retransmission.
    #[must_use]
    pub fn rx_duplicate(&self, app: &App) -> u64 {
        self.rx_duplicates
            .iter()
            .find(|(a, _)| a == app)
            .map_or(0, |&(_, b)| b)
    }

    /// Internet bytes summed over all apps.
    #[must_use]
    pub fn apps_total(&self) -> Bytes {
        let mut total = Bytes::default();
        for (_, bytes) in &self.apps {
            total += *bytes;
        }
        total
    }
}

/// The meter engine over a [`Host`].
#[derive(Debug)]
pub struct Engine<H: Host> {
    host: H,
    meter: Meter,
    interfaces: InterfaceTotals,
    next_context: u64,
    buf: Vec<u8>,
}

impl<H: Host> Engine<H> {
    /// Subscribes to every flow and takes the baseline: only bytes moved after this returns are
    /// counted, by the apps and by the interfaces alike. A baseline poll whose reply does not
    /// complete is repeated, because a flow missing from the baseline would later book its whole
    /// lifetime; the interface counters are first read once the baseline completes, so the two
    /// counts start at the same moment.
    pub fn start(host: H) -> io::Result<Self> {
        let meter = Meter::new(host.macos_major());
        let mut engine = Self {
            host,
            meter,
            interfaces: InterfaceTotals::default(),
            next_context: FIRST_POLL_CONTEXT,
            buf: vec![0; RECV_BUFFER],
        };
        for provider in ntstat::PROVIDERS {
            engine.host.send(&ntstat::add_all_sources(provider))?;
        }
        engine.receive(None, SETTLE)?;
        for _ in 0..BASELINE_ATTEMPTS {
            if engine.poll()? {
                engine.read_interfaces()?;
                engine.meter.counting = true;
                return Ok(engine);
            }
        }
        Err(io::Error::new(
            io::ErrorKind::TimedOut,
            "the kernel did not complete a baseline poll",
        ))
    }

    /// Receives for `interval` (closed flows send their final update unasked), then polls every
    /// flow, books what moved and reads the interface counters.
    pub fn tick(&mut self, interval: Duration) -> io::Result<()> {
        self.receive(None, interval)?;
        // An incomplete poll loses nothing: every flow already has its baseline, and the next
        // poll books what this one missed.
        self.poll()?;
        self.read_interfaces()
    }

    #[must_use]
    pub fn host(&self) -> &H {
        &self.host
    }

    pub fn host_mut(&mut self) -> &mut H {
        &mut self.host
    }

    /// Ends metering and returns the host.
    pub fn into_host(self) -> H {
        self.host
    }

    #[must_use]
    pub fn snapshot(&self) -> Snapshot {
        let mut apps: Vec<(App, Bytes)> = match self.meter.mode {
            Mode::PerApp => self
                .meter
                .apps
                .iter()
                .map(|(a, b)| (a.clone(), *b))
                .collect(),
            Mode::InterfaceOnly { .. } => Vec::new(),
        };
        apps.retain(|(_, b)| b.total() > 0);
        apps.sort_by(|(a, x), (b, y)| y.total().cmp(&x.total()).then_with(|| a.cmp(b)));
        let mut rx_duplicates: Vec<(App, u64)> = match self.meter.mode {
            Mode::PerApp => self
                .meter
                .rx_duplicates
                .iter()
                .map(|(a, &b)| (a.clone(), b))
                .collect(),
            Mode::InterfaceOnly { .. } => Vec::new(),
        };
        rx_duplicates.sort();
        Snapshot {
            mode: self.meter.mode.clone(),
            apps,
            local: self.meter.local,
            interfaces: self.interfaces.total(),
            flows: self.meter.flows.len(),
            rx_duplicates,
        }
    }

    /// Polls every flow and waits for the whole chunked reply. Returns whether the reply completed.
    fn poll(&mut self) -> io::Result<bool> {
        let context = self.next_context;
        self.next_context += 1;
        self.host.send(&ntstat::poll_all(context))?;
        self.receive(Some(context), POLL_TIMEOUT)
    }

    fn read_interfaces(&mut self) -> io::Result<()> {
        let counters = self.host.interface_counters()?;
        self.interfaces.update(&counters);
        Ok(())
    }

    /// Handles messages until the poll `awaiting` completes, or until `timeout` passes. Returns
    /// whether the poll completed: its last chunk ended with `SUCCESS`.
    fn receive(&mut self, awaiting: Option<u64>, timeout: Duration) -> io::Result<bool> {
        let deadline = Instant::now() + timeout;
        loop {
            let Some(n) = self.host.recv(&mut self.buf, deadline)? else {
                return Ok(false);
            };
            let mut done = None;
            let mut again = false;
            let host = &mut self.host;
            let mut path_of = |pid| host.executable_path(pid);
            for message in ntstat::messages(&self.buf[..n]) {
                match message.kind {
                    ntstat::MSG_SRC_UPDATE | ntstat::MSG_SRC_EXTENDED_UPDATE => {
                        self.meter.update(&message, &mut path_of);
                    }
                    ntstat::MSG_SRC_REMOVED => self.meter.removed(&message),
                    ntstat::MSG_SUCCESS | ntstat::MSG_ERROR
                        if Some(message.context) == awaiting =>
                    {
                        if message.kind == ntstat::MSG_ERROR {
                            done = Some(false);
                        } else if message.flags & ntstat::HDR_FLAG_CONTINUATION != 0 {
                            again = true;
                        } else {
                            done = Some(true);
                        }
                    }
                    _ => {}
                }
            }
            if again {
                // The reply continues: ask for the next chunk with the same context.
                self.host
                    .send(&ntstat::poll_all(awaiting.expect("awaiting a poll")))?;
            }
            if let Some(complete) = done {
                return Ok(complete);
            }
        }
    }
}
