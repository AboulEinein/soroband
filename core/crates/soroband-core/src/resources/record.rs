//! Recording what the resource meter reads, and replaying it.
//!
//! [`capture`] takes one whole read of a [`ResourceHost`]: every process with its coalition, path
//! and usage (read before and after the coalitions, as the guard reads them), every coalition's
//! words, the gauges and the volumes. [`Replay`] answers a [`ResourceHost`]'s calls from a list of
//! them, one per [`ResourceHost::begin`], so a test runs the meter over a real session. A
//! process's usage answers its first call with the read before the coalitions and every later one
//! with the read after.
//!
//! The format is JSON: `{"format": "soroband-resources 1", "timebase": [n, d], "reads": [...]}`.
//! [`anonymize`] replaces every path outside macOS's own directories with a made-up one, keeping
//! which processes share an app.

use super::{Gauges, ProcessUsage, RAW_WORDS, ResourceHost, Volume};
use serde_json::{Value, json};
use std::collections::HashMap;

const FORMAT: &str = "soroband-resources 1";

/// A process in a recorded read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecordedProcess {
    pub pid: u32,
    pub coalition: Option<u64>,
    pub path: Option<String>,
    /// Its usage before and after the coalitions were read; empty when it could not be read.
    pub usage: Vec<ProcessUsage>,
}

/// One whole read of the system.
#[derive(Debug, Clone, PartialEq)]
pub struct RecordedRead {
    pub time: u64,
    pub coalitions: Option<Vec<(u64, [u64; RAW_WORDS])>>,
    pub processes: Vec<RecordedProcess>,
    pub gauges: Gauges,
    pub volumes: Vec<Volume>,
}

/// A recorded session.
#[derive(Debug, Clone, PartialEq)]
pub struct Recording {
    pub timebase: (u32, u32),
    pub reads: Vec<RecordedRead>,
}

/// Reads everything `host` can tell about the system now.
pub fn capture(host: &mut impl ResourceHost) -> RecordedRead {
    let pids = host.pids();
    let mut processes: Vec<RecordedProcess> = pids
        .iter()
        .map(|&pid| RecordedProcess {
            pid,
            coalition: host.coalition_of(pid),
            path: host.executable_path(pid),
            usage: host.process_usage(pid).into_iter().collect(),
        })
        .collect();
    let time = host.now();
    let coalitions = host.coalition_ids().map(|ids| {
        ids.into_iter()
            .filter_map(|id| host.coalition_usage(id).map(|raw| (id, raw)))
            .collect()
    });
    for process in &mut processes {
        match host.process_usage(process.pid) {
            Some(after) if !process.usage.is_empty() => process.usage.push(after),
            _ => process.usage.clear(),
        }
    }
    RecordedRead {
        time,
        coalitions,
        processes,
        gauges: host.gauges(),
        volumes: host.volumes(),
    }
}

/// Directories whose paths are macOS's own, kept as they are by [`anonymize`].
const KEPT: [&str; 6] = [
    "/System/",
    "/usr/",
    "/bin/",
    "/sbin/",
    "/Library/Apple/",
    "/private/var/db/",
];

/// Replaces each path outside macOS's own directories: an app bundle's with
/// `/Applications/App <n>.app/Contents/MacOS/App <n>`, any other with `/Users/user/bin/tool-<n>`,
/// numbered in order of first appearance.
pub fn anonymize(recording: &mut Recording) {
    let mut names: HashMap<String, String> = HashMap::new();
    let (mut apps, mut tools) = (0, 0);
    for read in &mut recording.reads {
        for process in &mut read.processes {
            let Some(path) = &process.path else { continue };
            if KEPT.iter().any(|dir| path.starts_with(dir)) {
                continue;
            }
            let bundle = path.find(".app/").map(|end| path[..end + 4].to_owned());
            let is_bundle = bundle.is_some();
            let key = bundle.unwrap_or_else(|| path.clone());
            let made_up = names.entry(key).or_insert_with(|| {
                if is_bundle {
                    apps += 1;
                    format!("/Applications/App {apps}.app/Contents/MacOS/App {apps}")
                } else {
                    tools += 1;
                    format!("/Users/user/bin/tool-{tools}")
                }
            });
            process.path = Some(made_up.clone());
        }
    }
}

fn usage_json(u: &ProcessUsage) -> Value {
    json!([
        u.cpu,
        u.billed,
        u.read,
        u.written,
        u.energy,
        u.footprint,
        u.start
    ])
}

fn gauges_json(g: &Gauges) -> Value {
    json!({
        "cpu_ticks": g.cpu_ticks,
        "memory_used": g.memory_used,
        "memory_compressed": g.memory_compressed,
        "swap_used": g.swap_used,
        "pressure": g.pressure,
    })
}

impl Recording {
    #[must_use]
    pub fn to_json(&self) -> String {
        let reads: Vec<Value> = self
            .reads
            .iter()
            .map(|r| {
                json!({
                    "time": r.time,
                    "coalitions": r.coalitions.as_ref().map(|list| list
                        .iter()
                        .map(|(id, raw)| {
                            // Trailing zero words are left out.
                            let len = raw.iter().rposition(|&w| w != 0).map_or(0, |i| i + 1);
                            json!([id, &raw[..len]])
                        })
                        .collect::<Vec<_>>()),
                    "processes": r.processes.iter().map(|p| json!({
                        "pid": p.pid,
                        "coalition": p.coalition,
                        "path": p.path,
                        "usage": p.usage.iter().map(usage_json).collect::<Vec<_>>(),
                    })).collect::<Vec<_>>(),
                    "gauges": gauges_json(&r.gauges),
                    "volumes": r.volumes.iter().map(|v| json!({
                        "path": v.path, "free": v.free, "size": v.size,
                    })).collect::<Vec<_>>(),
                })
            })
            .collect();
        json!({
            "format": FORMAT,
            "timebase": [self.timebase.0, self.timebase.1],
            "reads": reads,
        })
        .to_string()
    }

    /// Reads a recording.
    ///
    /// # Errors
    /// When `text` is not a recording in this format.
    pub fn parse(text: &str) -> Result<Self, String> {
        let value: Value = serde_json::from_str(text).map_err(|e| e.to_string())?;
        if value["format"] != FORMAT {
            return Err(format!("not a {FORMAT:?} recording"));
        }
        let timebase = (
            int(&value["timebase"][0]).and_then(|n| u32::try_from(n).ok()),
            int(&value["timebase"][1]).and_then(|n| u32::try_from(n).ok()),
        );
        let (Some(numer), Some(denom)) = timebase else {
            return Err("no timebase".into());
        };
        let reads = value["reads"]
            .as_array()
            .ok_or("no reads")?
            .iter()
            .map(read_from_json)
            .collect::<Option<Vec<_>>>()
            .ok_or("a read is malformed")?;
        Ok(Self {
            timebase: (numer, denom),
            reads,
        })
    }
}

fn int(value: &Value) -> Option<u64> {
    value.as_u64()
}

fn read_from_json(value: &Value) -> Option<RecordedRead> {
    let coalitions = match &value["coalitions"] {
        Value::Null => None,
        list => Some(
            list.as_array()?
                .iter()
                .map(|entry| {
                    let mut raw = [0u64; RAW_WORDS];
                    for (i, word) in entry[1].as_array()?.iter().enumerate() {
                        *raw.get_mut(i)? = word.as_u64()?;
                    }
                    Some((entry[0].as_u64()?, raw))
                })
                .collect::<Option<Vec<_>>>()?,
        ),
    };
    let processes = value["processes"]
        .as_array()?
        .iter()
        .map(|p| {
            Some(RecordedProcess {
                pid: u32::try_from(p["pid"].as_u64()?).ok()?,
                coalition: p["coalition"].as_u64(),
                path: p["path"].as_str().map(str::to_owned),
                usage: p["usage"]
                    .as_array()?
                    .iter()
                    .map(|u| {
                        let w: Vec<u64> = u
                            .as_array()?
                            .iter()
                            .map(Value::as_u64)
                            .collect::<Option<_>>()?;
                        Some(ProcessUsage {
                            cpu: *w.first()?,
                            billed: *w.get(1)?,
                            read: *w.get(2)?,
                            written: *w.get(3)?,
                            energy: *w.get(4)?,
                            footprint: *w.get(5)?,
                            start: *w.get(6)?,
                        })
                    })
                    .collect::<Option<_>>()?,
            })
        })
        .collect::<Option<Vec<_>>>()?;
    let g = &value["gauges"];
    let ticks = g["cpu_ticks"].as_array().and_then(|t| {
        let t: Vec<u64> = t.iter().map(Value::as_u64).collect::<Option<_>>()?;
        t.try_into().ok()
    });
    Some(RecordedRead {
        time: value["time"].as_u64()?,
        coalitions,
        processes,
        gauges: Gauges {
            cpu_ticks: ticks,
            memory_used: g["memory_used"].as_u64(),
            memory_compressed: g["memory_compressed"].as_u64(),
            swap_used: g["swap_used"].as_u64(),
            pressure: g["pressure"].as_u64().and_then(|p| u8::try_from(p).ok()),
        },
        volumes: value["volumes"]
            .as_array()?
            .iter()
            .map(|v| {
                Some(Volume {
                    path: v["path"].as_str()?.to_owned(),
                    free: v["free"].as_u64()?,
                    size: v["size"].as_u64()?,
                })
            })
            .collect::<Option<_>>()?,
    })
}

/// A [`ResourceHost`] that answers from a [`Recording`]. Before the first
/// [`ResourceHost::begin`] and after the last read it answers from the first and last read.
#[derive(Debug)]
pub struct Replay {
    recording: Recording,
    index: usize,
    started: bool,
    /// How many times each pid's usage was asked for in the current read.
    asked: HashMap<u32, usize>,
}

impl Replay {
    #[must_use]
    pub fn new(recording: Recording) -> Self {
        Self {
            recording,
            index: 0,
            started: false,
            asked: HashMap::new(),
        }
    }

    fn read(&self) -> &RecordedRead {
        &self.recording.reads[self.index]
    }

    fn process(&self, pid: u32) -> Option<&RecordedProcess> {
        self.read().processes.iter().find(|p| p.pid == pid)
    }
}

impl ResourceHost for Replay {
    fn begin(&mut self) {
        if self.started && self.index + 1 < self.recording.reads.len() {
            self.index += 1;
        }
        self.started = true;
        self.asked.clear();
    }

    fn now(&mut self) -> u64 {
        self.read().time
    }

    fn timebase(&self) -> (u32, u32) {
        self.recording.timebase
    }

    fn coalition_ids(&mut self) -> Option<Vec<u64>> {
        Some(
            self.read()
                .coalitions
                .as_ref()?
                .iter()
                .map(|(id, _)| *id)
                .collect(),
        )
    }

    fn coalition_usage(&mut self, id: u64) -> Option<[u64; RAW_WORDS]> {
        self.read()
            .coalitions
            .as_ref()?
            .iter()
            .find(|(c, _)| *c == id)
            .map(|(_, raw)| *raw)
    }

    fn pids(&mut self) -> Vec<u32> {
        self.read().processes.iter().map(|p| p.pid).collect()
    }

    fn coalition_of(&mut self, pid: u32) -> Option<u64> {
        self.process(pid)?.coalition
    }

    fn process_usage(&mut self, pid: u32) -> Option<ProcessUsage> {
        let asked = self.asked.entry(pid).or_default();
        let call = *asked;
        *asked += 1;
        let usage = &self.process(pid)?.usage;
        usage.get(call.min(usage.len().checked_sub(1)?)).copied()
    }

    fn executable_path(&mut self, pid: u32) -> Option<String> {
        self.process(pid)?.path.clone()
    }

    fn gauges(&mut self) -> Gauges {
        self.read().gauges
    }

    fn volumes(&mut self) -> Vec<Volume> {
        self.read().volumes.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn process(pid: u32, path: &str, usage: Vec<ProcessUsage>) -> RecordedProcess {
        RecordedProcess {
            pid,
            coalition: Some(1),
            path: Some(path.into()),
            usage,
        }
    }

    fn read(time: u64, processes: Vec<RecordedProcess>) -> RecordedRead {
        RecordedRead {
            time,
            coalitions: Some(Vec::new()),
            processes,
            gauges: Gauges::default(),
            volumes: Vec::new(),
        }
    }

    #[test]
    fn paths_outside_macos_are_made_up_keeping_which_processes_share_an_app() {
        let mut recording = Recording {
            timebase: (1, 1),
            reads: vec![read(
                0,
                vec![
                    process(1, "/Applications/Chat.app/Contents/MacOS/Chat", vec![]),
                    process(
                        2,
                        "/Applications/Chat.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper",
                        vec![],
                    ),
                    process(3, "/opt/homebrew/bin/node", vec![]),
                    process(4, "/Users/sam/bin/sync", vec![]),
                    process(5, "/usr/libexec/logd", vec![]),
                    process(6, "/Applications/Mail.app/Contents/MacOS/Mail", vec![]),
                ],
            )],
        };
        anonymize(&mut recording);
        let paths: Vec<&str> = recording.reads[0]
            .processes
            .iter()
            .map(|p| p.path.as_deref().unwrap())
            .collect();
        assert_eq!(
            paths,
            [
                "/Applications/App 1.app/Contents/MacOS/App 1",
                "/Applications/App 1.app/Contents/MacOS/App 1",
                "/Users/user/bin/tool-1",
                "/Users/user/bin/tool-2",
                "/usr/libexec/logd",
                "/Applications/App 2.app/Contents/MacOS/App 2",
            ]
        );
    }

    #[test]
    fn a_replay_answers_each_read_in_turn_and_a_process_before_then_after() {
        let usage = |cpu| ProcessUsage {
            cpu,
            ..ProcessUsage::default()
        };
        let mut replay = Replay::new(Recording {
            timebase: (1, 1),
            reads: vec![
                read(10, vec![process(7, "/bin/zsh", vec![usage(1), usage(2)])]),
                read(20, vec![process(7, "/bin/zsh", vec![usage(3), usage(4)])]),
            ],
        });
        assert_eq!(replay.now(), 10, "before the first read: the first");
        replay.begin();
        assert_eq!(replay.now(), 10);
        let cpu = |r: &mut Replay| r.process_usage(7).unwrap().cpu;
        assert_eq!(
            [cpu(&mut replay), cpu(&mut replay), cpu(&mut replay)],
            [1, 2, 2]
        );
        replay.begin();
        assert_eq!(replay.now(), 20);
        assert_eq!(cpu(&mut replay), 3, "each read starts over");
        replay.begin();
        assert_eq!(replay.now(), 20, "after the last read: the last");
    }
}
