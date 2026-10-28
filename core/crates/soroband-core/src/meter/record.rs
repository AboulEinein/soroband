//! Recording a real session between the engine and the system, and replaying it.
//!
//! [`Recorder`] wraps a [`Host`] and logs everything that crosses it: messages sent and received,
//! receive timeouts, process paths and interface counters. [`Replay`] is a [`Host`] that plays the
//! log back and checks that the engine asks for the same things in the same order, so a replay
//! test fails when the engine stops sending a continuation poll or reads at the wrong moment.
//!
//! Recordings keep only what the engine reads. Each flow descriptor is zeroed except its pid,
//! effective pid, process name and interface properties (no addresses, ports or UUIDs), and the
//! home directory in process paths becomes `/Users/user`.
//!
//! Format: the line `SOROBAND-RECORDING 1`, then records of a tag byte, a little-endian `u32`
//! length and the payload.

use super::interfaces::InterfaceCounter;
use super::ntstat::{self, Descriptor};
use super::{Host, ntstat::u32_at};
use std::collections::HashMap;
use std::fmt::Write as _;
use std::io::{self, Write};
use std::time::Instant;

const MAGIC: &[u8] = b"SOROBAND-RECORDING 1\n";
const TAG_MACOS: u8 = b'V';
const TAG_SEND: u8 = b'S';
const TAG_RECV: u8 = b'R';
const TAG_TIMEOUT: u8 = b'T';
const TAG_PROCESS: u8 = b'P';
const TAG_INTERFACES: u8 = b'I';

/// One thing that crossed the [`Host`] boundary.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    MacosMajor(u32),
    Send(Vec<u8>),
    Recv(Vec<u8>),
    Timeout,
    Process { pid: u32, path: Option<String> },
    Interfaces(Vec<InterfaceCounter>),
}

impl Event {
    fn write_to(&self, out: &mut impl Write) -> io::Result<()> {
        let (tag, payload): (u8, Vec<u8>) = match self {
            Self::MacosMajor(major) => (TAG_MACOS, major.to_le_bytes().to_vec()),
            Self::Send(m) => (TAG_SEND, m.clone()),
            Self::Recv(m) => (TAG_RECV, m.clone()),
            Self::Timeout => (TAG_TIMEOUT, Vec::new()),
            Self::Process { pid, path } => {
                let mut p = pid.to_le_bytes().to_vec();
                p.extend_from_slice(path.as_deref().unwrap_or("").as_bytes());
                (TAG_PROCESS, p)
            }
            Self::Interfaces(counters) => {
                let mut text = String::new();
                for c in counters {
                    let _ = writeln!(text, "{} {} {}", c.name, c.rx, c.tx);
                }
                (TAG_INTERFACES, text.into_bytes())
            }
        };
        out.write_all(&[tag])?;
        out.write_all(
            &u32::try_from(payload.len())
                .map_err(io::Error::other)?
                .to_le_bytes(),
        )?;
        out.write_all(&payload)
    }
}

/// Reads a recording.
///
/// # Errors
/// If `bytes` is not a complete recording.
pub fn parse(bytes: &[u8]) -> io::Result<Vec<Event>> {
    let invalid = |what: &str| io::Error::new(io::ErrorKind::InvalidData, what.to_owned());
    let mut rest = bytes
        .strip_prefix(MAGIC)
        .ok_or_else(|| invalid("not a Soroband recording"))?;
    let mut events = Vec::new();
    while !rest.is_empty() {
        if rest.len() < 5 {
            return Err(invalid("truncated record"));
        }
        let tag = rest[0];
        let len = le_u32(&rest[1..5]) as usize;
        let payload = rest
            .get(5..5 + len)
            .ok_or_else(|| invalid("truncated record"))?;
        rest = &rest[5 + len..];
        events.push(match tag {
            TAG_MACOS if len == 4 => Event::MacosMajor(le_u32(payload)),
            TAG_SEND => Event::Send(payload.to_vec()),
            TAG_RECV => Event::Recv(payload.to_vec()),
            TAG_TIMEOUT => Event::Timeout,
            TAG_PROCESS if len >= 4 => {
                let path = String::from_utf8_lossy(&payload[4..]).into_owned();
                Event::Process {
                    pid: le_u32(payload),
                    path: (!path.is_empty()).then_some(path),
                }
            }
            TAG_INTERFACES => Event::Interfaces(
                String::from_utf8_lossy(payload)
                    .lines()
                    .map(|line| {
                        let mut f = line.split(' ');
                        let name = f.next().unwrap_or_default().to_owned();
                        let mut number = || f.next().and_then(|n| n.parse().ok());
                        match (number(), number()) {
                            (Some(rx), Some(tx)) => Ok(InterfaceCounter { name, rx, tx }),
                            _ => Err(invalid("bad interface line")),
                        }
                    })
                    .collect::<io::Result<_>>()?,
            ),
            _ => return Err(invalid("unknown record")),
        });
    }
    Ok(events)
}

fn le_u32(b: &[u8]) -> u32 {
    u32::from_le_bytes([b[0], b[1], b[2], b[3]])
}

/// Wraps a [`Host`] and writes everything that crosses it to `out`.
#[derive(Debug)]
pub struct Recorder<H: Host, W: Write> {
    host: H,
    out: W,
    home: Option<String>,
}

impl<H: Host, W: Write> Recorder<H, W> {
    pub fn new(host: H, mut out: W) -> io::Result<Self> {
        out.write_all(MAGIC)?;
        Event::MacosMajor(host.macos_major()).write_to(&mut out)?;
        let home = std::env::var("HOME")
            .ok()
            .filter(|h| h.starts_with("/Users/"));
        Ok(Self { host, out, home })
    }

    /// Flushes the recording and returns the writer.
    pub fn finish(mut self) -> io::Result<W> {
        self.out.flush()?;
        Ok(self.out)
    }

    fn log(&mut self, event: &Event) -> io::Result<()> {
        event.write_to(&mut self.out)
    }
}

impl<H: Host, W: Write> Host for Recorder<H, W> {
    fn macos_major(&self) -> u32 {
        self.host.macos_major()
    }

    fn send(&mut self, message: &[u8]) -> io::Result<()> {
        self.log(&Event::Send(message.to_vec()))?;
        self.host.send(message)
    }

    fn set_wakeable(&mut self, wakeable: bool) {
        self.host.set_wakeable(wakeable);
    }

    fn recv(&mut self, buf: &mut [u8], deadline: Instant) -> io::Result<Option<usize>> {
        let n = self.host.recv(buf, deadline)?;
        let event = match n {
            Some(n) => Event::Recv(sanitize(&buf[..n])),
            None => Event::Timeout,
        };
        self.log(&event)?;
        Ok(n)
    }

    fn executable_path(&mut self, pid: u32) -> Option<String> {
        let path = self.host.executable_path(pid);
        let recorded = path.as_ref().map(|p| without_home(p, self.home.as_deref()));
        // A recording that cannot be written is caught by the next send or receive.
        let _ = self.log(&Event::Process {
            pid,
            path: recorded,
        });
        path
    }

    fn interface_counters(&mut self) -> io::Result<Vec<InterfaceCounter>> {
        let counters = self.host.interface_counters()?;
        self.log(&Event::Interfaces(counters.clone()))?;
        Ok(counters)
    }
}

/// `path` with the home directory replaced by `/Users/user`.
fn without_home(path: &str, home: Option<&str>) -> String {
    match home.and_then(|home| path.strip_prefix(home)) {
        Some(rest) if rest.starts_with('/') => format!("/Users/user{rest}"),
        _ => path.to_owned(),
    }
}

/// A copy of `datagram` with every descriptor byte the engine does not read set to zero.
#[must_use]
pub fn sanitize(datagram: &[u8]) -> Vec<u8> {
    let mut out = datagram.to_vec();
    let mut offset = 0;
    for message in ntstat::messages(datagram) {
        let start = offset;
        offset += (message.bytes.len() + 7) & !7;
        let is_update = matches!(
            message.kind,
            ntstat::MSG_SRC_UPDATE | ntstat::MSG_SRC_EXTENDED_UPDATE
        );
        if !is_update || message.bytes.len() < ntstat::UPDATE_HEADER_LEN {
            continue;
        }
        let descriptor = start + ntstat::UPDATE_HEADER_LEN;
        let end = start + message.bytes.len();
        let provider = u32_at(message.bytes, ntstat::UPDATE_HEADER_LEN - 8);
        let keep: Vec<std::ops::Range<usize>> = match Descriptor::of_provider(provider) {
            Some(d) => {
                let f = d.fields();
                vec![
                    f.pid..f.pid + 4,
                    f.epid..f.epid + 4,
                    f.pname,
                    f.properties..f.properties + 4,
                ]
            }
            None => Vec::new(),
        };
        for (i, byte) in out[descriptor..end].iter_mut().enumerate() {
            if !keep.iter().any(|r| r.contains(&i)) {
                *byte = 0;
            }
        }
    }
    out
}

/// A [`Host`] that plays a recording back.
///
/// Sends, receives and interface readings must come in the recorded order; anything else panics
/// with what the recording expected. Process paths are looked up by pid in any order.
#[derive(Debug)]
pub struct Replay {
    macos_major: u32,
    events: Vec<Event>,
    next: usize,
    paths: HashMap<u32, Option<String>>,
    /// Every message the engine sent, in order.
    pub sent: Vec<Vec<u8>>,
}

impl Replay {
    /// # Panics
    /// If the recording does not start with its macOS version.
    #[must_use]
    pub fn new(events: Vec<Event>) -> Self {
        let Some(Event::MacosMajor(macos_major)) = events.first() else {
            panic!("a recording starts with its macOS version");
        };
        let mut paths = HashMap::new();
        for event in &events {
            if let Event::Process { pid, path } = event {
                let known: &mut Option<String> = paths.entry(*pid).or_default();
                if known.is_none() {
                    known.clone_from(path);
                }
            }
        }
        Self {
            macos_major: *macos_major,
            events,
            next: 1,
            paths,
            sent: Vec::new(),
        }
    }

    /// Replays the recording as if it came from a Mac running `macos_major`.
    #[must_use]
    pub fn as_macos(mut self, macos_major: u32) -> Self {
        self.macos_major = macos_major;
        self
    }

    /// Whether every recorded send, receive and interface reading has been played.
    #[must_use]
    pub fn finished(&self) -> bool {
        self.events[self.next..]
            .iter()
            .all(|e| matches!(e, Event::Process { .. }))
    }

    fn next_event(&mut self, wanted: &str) -> Event {
        while let Some(event) = self.events.get(self.next) {
            self.next += 1;
            if !matches!(event, Event::Process { .. }) {
                return event.clone();
            }
        }
        panic!("the engine asked to {wanted} after the end of the recording");
    }
}

impl Host for Replay {
    fn macos_major(&self) -> u32 {
        self.macos_major
    }

    fn send(&mut self, message: &[u8]) -> io::Result<()> {
        match self.next_event("send") {
            Event::Send(recorded) => {
                let header = ntstat::HEADER_LEN.min(recorded.len());
                // Kind and context must match; the context identifies which poll is continued.
                assert_eq!(
                    message.get(..header),
                    Some(&recorded[..header]),
                    "event {}: the engine sent a different message than recorded",
                    self.next - 1
                );
                self.sent.push(message.to_vec());
                Ok(())
            }
            other => panic!(
                "event {}: the engine sent a message, the recording has {}",
                self.next - 1,
                describe(&other)
            ),
        }
    }

    fn recv(&mut self, buf: &mut [u8], deadline: Instant) -> io::Result<Option<usize>> {
        // The recorder waited until its deadline; a deadline already past would never wait.
        assert!(
            deadline > Instant::now(),
            "event {}: the engine waited with a past deadline",
            self.next
        );
        match self.next_event("receive") {
            Event::Recv(data) => {
                buf[..data.len()].copy_from_slice(&data);
                Ok(Some(data.len()))
            }
            Event::Timeout => Ok(None),
            other => panic!(
                "event {}: the engine waited to receive, the recording has {}",
                self.next - 1,
                describe(&other)
            ),
        }
    }

    fn executable_path(&mut self, pid: u32) -> Option<String> {
        self.paths.get(&pid).cloned().flatten()
    }

    fn interface_counters(&mut self) -> io::Result<Vec<InterfaceCounter>> {
        match self.next_event("read interface counters") {
            Event::Interfaces(counters) => Ok(counters),
            other => panic!(
                "event {}: the engine read interface counters, the recording has {}",
                self.next - 1,
                describe(&other)
            ),
        }
    }
}

fn describe(event: &Event) -> String {
    match event {
        Event::Send(m) if m.len() >= ntstat::HEADER_LEN => format!(
            "a sent message of kind {} with context {:#x}",
            u32_at(m, 8),
            ntstat::u64_at(m, 0)
        ),
        Event::Recv(_) => "a received datagram".into(),
        Event::Timeout => "a receive timeout".into(),
        Event::Interfaces(_) => "an interface reading".into(),
        other => format!("{other:?}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn home_directory_is_removed_from_recorded_paths() {
        let home = Some("/Users/ada");
        assert_eq!(
            without_home("/Users/ada/bin/tool", home),
            "/Users/user/bin/tool"
        );
        assert_eq!(
            without_home("/Users/adaline/bin/tool", home),
            "/Users/adaline/bin/tool"
        );
        assert_eq!(without_home("/usr/bin/curl", home), "/usr/bin/curl");
    }

    #[test]
    fn sanitize_keeps_only_the_fields_the_engine_reads() {
        // A UDP update followed by a SUCCESS, every byte set.
        let mut update = vec![0xAB; ntstat::UPDATE_HEADER_LEN + 280];
        update[8..12].copy_from_slice(&ntstat::MSG_SRC_UPDATE.to_ne_bytes());
        let len = u16::try_from(update.len()).unwrap();
        update[12..14].copy_from_slice(&len.to_ne_bytes());
        update[144..148].copy_from_slice(&ntstat::UDP_KERNEL.to_ne_bytes());
        let mut success = vec![0xCD; 16];
        success[8..12].copy_from_slice(&ntstat::MSG_SUCCESS.to_ne_bytes());
        success[12..14].copy_from_slice(&16u16.to_ne_bytes());
        let datagram = [update.clone(), success.clone()].concat();

        let clean = sanitize(&datagram);
        // The header (counters, srcref, provider) and the next message are untouched.
        assert_eq!(
            clean[..ntstat::UPDATE_HEADER_LEN],
            update[..ntstat::UPDATE_HEADER_LEN]
        );
        assert_eq!(clean[update.len()..], success[..]);
        // UDP descriptor: pid 128..132, name 132..196, epid 196..200, properties 272..276.
        let d = &clean[ntstat::UPDATE_HEADER_LEN..update.len()];
        for (i, &byte) in d.iter().enumerate() {
            let kept = (128..200).contains(&i) || (272..276).contains(&i);
            assert_eq!(byte, if kept { 0xAB } else { 0 }, "descriptor byte {i}");
        }
    }

    #[test]
    fn recording_a_replay_reproduces_the_recording() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/curl-20mb.rec");
        let original = std::fs::read(path).unwrap();
        let events = parse(&original).unwrap();
        let recorder = Recorder::new(Replay::new(events), Vec::new()).unwrap();
        let mut engine = super::super::Engine::start(recorder).unwrap();
        while !engine.host().host.finished() {
            engine.tick(std::time::Duration::from_secs(5)).unwrap();
        }
        let rerecorded = engine.into_host().finish().unwrap();
        assert!(
            rerecorded == original,
            "the re-recorded session differs from the fixture"
        );
    }

    #[test]
    fn truncated_recordings_are_rejected() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/curl-20mb.rec");
        let original = std::fs::read(path).unwrap();
        assert!(parse(&original[..original.len() - 1]).is_err());
        assert!(parse(&original[..MAGIC.len() + 3]).is_err());
        assert!(parse(b"something else").is_err());
        let record = |tag: u8, payload: &[u8]| {
            let mut r = MAGIC.to_vec();
            r.push(tag);
            r.extend_from_slice(&u32::try_from(payload.len()).unwrap().to_le_bytes());
            r.extend_from_slice(payload);
            r
        };
        assert_eq!(parse(&record(TAG_TIMEOUT, &[])).unwrap(), [Event::Timeout]);
        assert!(parse(&record(TAG_MACOS, &[27, 0, 0])).is_err());
        assert!(parse(&record(TAG_PROCESS, &[1, 0])).is_err());
    }

    #[test]
    fn sanitize_leaves_other_messages_and_short_updates_alone() {
        let message = |kind: u32, len: u16| {
            let mut m = vec![0xEE; usize::from(len)];
            m[8..12].copy_from_slice(&kind.to_ne_bytes());
            m[12..14].copy_from_slice(&len.to_ne_bytes());
            m
        };
        for m in [
            message(ntstat::MSG_ERROR, 200),
            message(ntstat::MSG_SRC_UPDATE, 104),
        ] {
            assert_eq!(sanitize(&m), m);
        }
    }
}
