//! The engine against a fake kernel that fails at chosen points.
//!
//! [`Kernel`] is a [`Host`] that answers like `com.apple.network.statistics`: an update for each
//! flow on subscription, poll replies in chunks joined by continuation, unasked final updates and
//! removals for closed flows, and an `en0` counter that moves with every flow. A test scripts
//! what each flow moves and which poll replies the kernel drops or fails, so every expected
//! number comes from the script, never from the engine. After every tick the engine's invariant
//! holds: the app sum never exceeds what crossed the interface since the baseline.

mod common;

use common::{
    MAIL, MAIL_PATH, SAFARI, SAFARI_PATH, error, mail, pack, removed, safari, success, tcp_update,
};
use soroband_core::meter::interfaces::InterfaceCounter;
use soroband_core::meter::ntstat::{self, MSG_ADD_ALL_SRCS, MSG_GET_UPDATE};
use soroband_core::meter::{Bytes, Engine, Host, Mode, Snapshot};
use std::collections::{BTreeMap, HashMap, VecDeque};
use std::io;
use std::time::{Duration, Instant};

const TCP: usize = 360;
const INTERVAL: Duration = Duration::from_secs(5);

struct Flow {
    pid: u32,
    rx: u64,
    tx: u64,
}

/// What the kernel does with one poll request (the first request of a poll, or a continuation).
#[derive(Debug, Clone, Copy)]
enum Reply {
    /// The next chunk of flows, as a healthy kernel.
    Chunk,
    /// Nothing, so the engine's poll times out.
    Silence,
    /// An `ERROR` message.
    Error,
}

/// Traffic that happens while the engine waits for a reply.
#[derive(Debug, Clone, Copy)]
enum Then {
    Move { srcref: u64, rx: u64, tx: u64 },
    Close(u64),
}

struct Kernel {
    flows: BTreeMap<u64, Flow>,
    /// Flows per reply chunk.
    chunk: usize,
    /// Datagrams waiting for the engine.
    inbox: VecDeque<Vec<u8>>,
    /// A poll answered with a continuation: its context and the next flow to report.
    cursor: Option<(u64, usize)>,
    /// Scripted answers for the next poll requests; `Chunk` once exhausted.
    script: VecDeque<(Reply, Vec<Then>)>,
    /// Traffic to happen when the engine next waits.
    meanwhile: Vec<Then>,
    en0: Bytes,
    paths: HashMap<u32, String>,
    interface_reads: usize,
}

impl Kernel {
    fn new(chunk: usize) -> Self {
        Self {
            flows: BTreeMap::new(),
            chunk,
            inbox: VecDeque::new(),
            cursor: None,
            script: VecDeque::new(),
            meanwhile: Vec::new(),
            en0: Bytes::default(),
            paths: HashMap::from([
                (MAIL, MAIL_PATH.to_owned()),
                (SAFARI, SAFARI_PATH.to_owned()),
            ]),
            interface_reads: 0,
        }
    }

    /// A flow that already moved `rx` and `tx` bytes before the engine starts.
    fn open(&mut self, srcref: u64, pid: u32, rx: u64, tx: u64) {
        self.flows.insert(srcref, Flow { pid, rx, tx });
        self.en0 += Bytes { rx, tx };
    }

    /// The flow moves more bytes; they cross `en0` too.
    fn transfer(&mut self, srcref: u64, rx: u64, tx: u64) {
        let flow = self.flows.get_mut(&srcref).expect("an open flow");
        flow.rx += rx;
        flow.tx += tx;
        self.en0 += Bytes { rx, tx };
    }

    /// The flow closes: the kernel sends its final counters and its removal, unasked.
    fn close(&mut self, srcref: u64) {
        let flow = self.flows.remove(&srcref).expect("an open flow");
        self.inbox.push_back(pack(&[
            tcp_update(srcref, flow.rx, flow.tx, flow.pid, false, TCP),
            removed(srcref),
        ]));
    }

    fn reply(&mut self, reply: Reply) {
        self.script.push_back((reply, Vec::new()));
    }

    fn reply_then(&mut self, reply: Reply, then: &[Then]) {
        self.script.push_back((reply, then.to_vec()));
    }

    fn update_all(&self) -> Vec<Vec<u8>> {
        self.flows
            .iter()
            .map(|(&srcref, f)| tcp_update(srcref, f.rx, f.tx, f.pid, false, TCP))
            .collect()
    }

    fn answer_poll(&mut self, context: u64) {
        let (reply, then) = self
            .script
            .pop_front()
            .unwrap_or((Reply::Chunk, Vec::new()));
        match reply {
            Reply::Chunk => {
                let from = match self.cursor {
                    Some((c, next)) if c == context => next,
                    _ => 0,
                };
                let updates = self.update_all();
                let to = (from + self.chunk).min(updates.len());
                let mut messages = updates[from..to].to_vec();
                let more = to < updates.len();
                messages.push(success(context, more));
                self.cursor = more.then_some((context, to));
                self.inbox.push_back(pack(&messages));
            }
            Reply::Silence => self.cursor = None,
            Reply::Error => {
                self.cursor = None;
                self.inbox.push_back(pack(&[error(context)]));
            }
        }
        self.meanwhile = then;
    }
}

impl Host for Kernel {
    fn macos_major(&self) -> u32 {
        27
    }

    fn send(&mut self, message: &[u8]) -> io::Result<()> {
        let m = ntstat::messages(message).next().expect("a message");
        match m.kind {
            MSG_ADD_ALL_SRCS if m.bytes[32..36] == ntstat::TCP_KERNEL.to_ne_bytes() => {
                // Every existing flow is reported once on subscription.
                self.inbox.push_back(pack(&self.update_all()));
            }
            MSG_GET_UPDATE => self.answer_poll(m.context),
            _ => {}
        }
        Ok(())
    }

    fn recv(&mut self, buf: &mut [u8], _deadline: Instant) -> io::Result<Option<usize>> {
        for action in std::mem::take(&mut self.meanwhile) {
            match action {
                Then::Move { srcref, rx, tx } => self.transfer(srcref, rx, tx),
                Then::Close(srcref) => self.close(srcref),
            }
        }
        Ok(self.inbox.pop_front().map(|d| {
            buf[..d.len()].copy_from_slice(&d);
            d.len()
        }))
    }

    fn executable_path(&mut self, pid: u32) -> Option<String> {
        self.paths.get(&pid).cloned()
    }

    fn interface_counters(&mut self) -> io::Result<Vec<InterfaceCounter>> {
        self.interface_reads += 1;
        Ok(vec![InterfaceCounter {
            name: "en0".into(),
            rx: self.en0.rx,
            tx: self.en0.tx,
        }])
    }
}

/// One poll interval, then the engine's invariant: nothing is booked to an app that did not
/// cross the interface since the baseline.
fn tick(engine: &mut Engine<Kernel>) -> Snapshot {
    engine.tick(INTERVAL).expect("tick");
    let snapshot = engine.snapshot();
    assert_eq!(snapshot.mode, Mode::PerApp);
    let apps = snapshot.apps_total();
    assert!(
        apps.rx <= snapshot.interfaces.rx && apps.tx <= snapshot.interfaces.tx,
        "apps {apps:?} exceed the interfaces {:?}",
        snapshot.interfaces
    );
    snapshot
}

#[test]
fn baseline_retry_counts_interface_bytes_from_the_completed_baseline() {
    let mut kernel = Kernel::new(10);
    kernel.open(1, MAIL, 9_000_000, 800_000);
    // Two baseline attempts get no reply; Mail moves 4,000 bytes while the engine waits for the
    // second one.
    kernel.reply(Reply::Silence);
    kernel.reply_then(
        Reply::Silence,
        &[Then::Move {
            srcref: 1,
            rx: 4_000,
            tx: 0,
        }],
    );
    kernel.reply(Reply::Chunk);
    let mut engine = Engine::start(kernel).expect("start");
    engine.host_mut().transfer(1, 700, 100);
    let snapshot = tick(&mut engine);
    // Only the 700 + 100 bytes after the completed baseline: the 4,000 bytes of the retry window
    // were not booked to Mail, so they are not interface bytes since the baseline either.
    assert_eq!(snapshot.apps, vec![(mail(), Bytes { rx: 700, tx: 100 })]);
    assert_eq!(snapshot.interfaces, Bytes { rx: 700, tx: 100 });
}

#[test]
fn flow_closing_during_a_baseline_retry_is_not_counted() {
    let mut kernel = Kernel::new(10);
    kernel.open(1, MAIL, 9_000_000, 0);
    // The flow moves 4,000 bytes and closes while the second unanswered baseline attempt waits.
    kernel.reply(Reply::Silence);
    kernel.reply_then(
        Reply::Silence,
        &[
            Then::Move {
                srcref: 1,
                rx: 4_000,
                tx: 0,
            },
            Then::Close(1),
        ],
    );
    kernel.reply(Reply::Chunk);
    let mut engine = Engine::start(kernel).expect("start");
    let snapshot = tick(&mut engine);
    // Its lifetime, including the retry window, is before the baseline: nothing on either side.
    assert_eq!(snapshot.apps, []);
    assert_eq!(snapshot.interfaces, Bytes::default());
    assert_eq!(snapshot.flows, 0);
}

#[test]
fn interfaces_are_read_once_when_the_baseline_completes() {
    let mut kernel = Kernel::new(10);
    kernel.open(1, MAIL, 100, 100);
    kernel.reply(Reply::Silence);
    kernel.reply(Reply::Silence);
    kernel.reply(Reply::Chunk);
    let engine = Engine::start(kernel).expect("start");
    // The two unanswered attempts read nothing: the first reading is the baseline's.
    assert_eq!(engine.host().interface_reads, 1);
}

#[test]
fn engine_does_not_start_when_no_baseline_attempt_is_answered() {
    let mut kernel = Kernel::new(10);
    kernel.open(1, MAIL, 100, 100);
    for _ in 0..3 {
        kernel.reply(Reply::Silence);
    }
    let Err(error) = Engine::start(kernel) else {
        panic!("the engine started without a baseline");
    };
    assert_eq!(error.kind(), io::ErrorKind::TimedOut);
}

#[test]
fn poll_that_times_out_loses_nothing() {
    let mut kernel = Kernel::new(10);
    kernel.open(1, MAIL, 1_000, 0);
    kernel.open(2, SAFARI, 2_000, 0);
    let mut engine = Engine::start(kernel).expect("start");
    engine.host_mut().transfer(1, 1_000, 10);
    engine.host_mut().transfer(2, 2_000, 20);
    engine.host_mut().reply(Reply::Silence);
    let snapshot = tick(&mut engine);
    // The kernel never answered: the interfaces moved 3,000 + 30 bytes, no app is credited yet.
    assert_eq!(snapshot.apps, []);
    assert_eq!(snapshot.interfaces, Bytes { rx: 3_000, tx: 30 });
    engine.host_mut().transfer(1, 500, 0);
    let snapshot = tick(&mut engine);
    // The next poll books everything since the baseline, once.
    assert_eq!(
        snapshot.apps,
        vec![
            (safari(), Bytes { rx: 2_000, tx: 20 }),
            (mail(), Bytes { rx: 1_500, tx: 10 }),
        ]
    );
    assert_eq!(snapshot.interfaces, Bytes { rx: 3_500, tx: 30 });
}

#[test]
fn error_reply_is_recovered_by_the_next_poll() {
    let mut kernel = Kernel::new(10);
    kernel.open(1, MAIL, 1_000, 0);
    let mut engine = Engine::start(kernel).expect("start");
    engine.host_mut().transfer(1, 1_000, 0);
    engine.host_mut().reply(Reply::Error);
    let snapshot = tick(&mut engine);
    assert_eq!(snapshot.apps, []);
    assert_eq!(snapshot.interfaces, Bytes { rx: 1_000, tx: 0 });
    let snapshot = tick(&mut engine);
    assert_eq!(snapshot.apps, vec![(mail(), Bytes { rx: 1_000, tx: 0 })]);
}

#[test]
fn dropped_continuation_chunk_is_booked_by_the_next_poll_once() {
    let mut kernel = Kernel::new(1);
    kernel.open(1, MAIL, 1_000, 0);
    kernel.open(2, SAFARI, 2_000, 0);
    kernel.open(3, MAIL, 3_000, 0);
    let mut engine = Engine::start(kernel).expect("start");
    engine.host_mut().transfer(1, 100, 0);
    engine.host_mut().transfer(2, 200, 0);
    engine.host_mut().transfer(3, 300, 0);
    // The first chunk (flow 1) arrives; the continuation for flows 2 and 3 never does.
    engine.host_mut().reply(Reply::Chunk);
    engine.host_mut().reply(Reply::Silence);
    let snapshot = tick(&mut engine);
    assert_eq!(snapshot.apps, vec![(mail(), Bytes { rx: 100, tx: 0 })]);
    let snapshot = tick(&mut engine);
    // Flow 1 is reported again with the same counters and books nothing twice.
    assert_eq!(
        snapshot.apps,
        vec![
            (mail(), Bytes { rx: 400, tx: 0 }),
            (safari(), Bytes { rx: 200, tx: 0 }),
        ]
    );
    assert_eq!(snapshot.interfaces, Bytes { rx: 600, tx: 0 });
}

#[test]
fn flow_closing_during_a_failed_poll_is_booked_from_its_final_update() {
    let mut kernel = Kernel::new(1);
    kernel.open(1, MAIL, 1_000, 0);
    kernel.open(2, SAFARI, 2_000, 0);
    let mut engine = Engine::start(kernel).expect("start");
    engine.host_mut().transfer(1, 100, 0);
    engine.host_mut().transfer(2, 5_000, 50);
    engine.host_mut().reply(Reply::Chunk);
    // Safari's flow moves 300 more bytes and closes while the continuation goes unanswered.
    engine.host_mut().reply_then(
        Reply::Silence,
        &[
            Then::Move {
                srcref: 2,
                rx: 300,
                tx: 0,
            },
            Then::Close(2),
        ],
    );
    let snapshot = tick(&mut engine);
    // 5,000 + 300 from the final update the kernel sent on its own; the flow is then forgotten.
    assert_eq!(
        snapshot.apps,
        vec![
            (safari(), Bytes { rx: 5_300, tx: 50 }),
            (mail(), Bytes { rx: 100, tx: 0 }),
        ]
    );
    assert_eq!(snapshot.flows, 1);
    let snapshot = tick(&mut engine);
    assert_eq!(
        snapshot.apps,
        vec![
            (safari(), Bytes { rx: 5_300, tx: 50 }),
            (mail(), Bytes { rx: 100, tx: 0 }),
        ]
    );
}
