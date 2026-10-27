//! `soroband live`: internet bytes per app since the command started, printed every interval.

use soroband_core::meter::record::Recorder;
use soroband_core::meter::{Bytes, Engine, Host, Mode, Snapshot, SystemHost};
use std::fmt::Write as _;
use std::fs::File;
use std::io::{BufWriter, Write as _};
use std::process::ExitCode;
use std::time::{Duration, Instant};

pub const USAGE: &str = "\
Usage: soroband live [--interval <seconds>] [--for <seconds>] [--json] [--record <file>]

  --interval   Seconds between updates (default 5)
  --for        Stop after this many seconds (default: run until interrupted)
  --json       One JSON object per update
  --record     Write everything the engine exchanges with the kernel to <file>, as a
               test fixture (needs --for)";

#[derive(Debug)]
struct Options {
    interval: Duration,
    limit: Option<Duration>,
    json: bool,
    record: Option<String>,
}

fn parse(args: &[&str]) -> Result<Options, String> {
    let mut options = Options {
        interval: Duration::from_secs(5),
        limit: None,
        json: false,
        record: None,
    };
    let mut args = args.iter();
    let seconds = |value: Option<&&str>, flag: &str| {
        value
            .and_then(|v| v.parse::<u64>().ok())
            .filter(|&s| s > 0)
            .map(Duration::from_secs)
            .ok_or(format!("{flag} needs a whole number of seconds above 0"))
    };
    while let Some(&arg) = args.next() {
        match arg {
            "--interval" => options.interval = seconds(args.next(), arg)?,
            "--for" => options.limit = Some(seconds(args.next(), arg)?),
            "--json" => options.json = true,
            "--record" => {
                options.record = Some(args.next().ok_or("--record needs a file")?.to_string());
            }
            _ => return Err(format!("unknown option {arg}")),
        }
    }
    if options.record.is_some() && options.limit.is_none() {
        return Err("--record needs --for, so the recording ends cleanly".into());
    }
    Ok(options)
}

pub fn run(args: &[&str]) -> ExitCode {
    let options = match parse(args) {
        Ok(options) => options,
        Err(message) => {
            eprintln!("soroband live: {message}\n\n{USAGE}");
            return ExitCode::from(2);
        }
    };
    let result = SystemHost::connect().and_then(|host| match &options.record {
        Some(path) => {
            let recorder = Recorder::new(host, BufWriter::new(File::create(path)?))?;
            meter(recorder, &options)?.finish().map(drop)
        }
        None => meter(host, &options).map(drop),
    });
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("soroband live: {error}");
            ExitCode::FAILURE
        }
    }
}

fn meter<H: Host>(host: H, options: &Options) -> std::io::Result<H> {
    let started = Instant::now();
    let mut engine = Engine::start(host)?;
    let mut out = std::io::stdout().lock();
    loop {
        engine.tick(options.interval)?;
        let elapsed = started.elapsed();
        let snapshot = engine.snapshot();
        let text = if options.json {
            json(&snapshot, elapsed)
        } else {
            table(&snapshot, elapsed)
        };
        writeln!(out, "{text}")?;
        out.flush()?;
        if options.limit.is_some_and(|limit| elapsed >= limit) {
            return Ok(engine.into_host());
        }
    }
}

fn table(s: &Snapshot, elapsed: Duration) -> String {
    let total = s.apps_total();
    let mut text = format!(
        "{:>5} s  internet ↓ {} ↑ {}   interfaces ↓ {} ↑ {}   local {}   {} flows\n",
        elapsed.as_secs(),
        size(total.rx),
        size(total.tx),
        size(s.interfaces.rx),
        size(s.interfaces.tx),
        size(s.local.total()),
        s.flows
    );
    if let Mode::InterfaceOnly { reason } = &s.mode {
        let _ = writeln!(text, "  per-app counting is off: {reason}");
    }
    for (app, bytes) in s.apps.iter().take(15) {
        let _ = writeln!(
            text,
            "  {:<40} ↓ {:>10}  ↑ {:>10}",
            printable(&app.name),
            size(bytes.rx),
            size(bytes.tx)
        );
    }
    text
}

/// `name` with control characters replaced, so a process name cannot drive the terminal.
fn printable(name: &str) -> String {
    name.chars()
        .map(|c| if c.is_control() { '\u{FFFD}' } else { c })
        .collect()
}

fn size(bytes: u64) -> String {
    #[allow(clippy::cast_precision_loss)]
    let b = bytes as f64;
    match bytes {
        0..1_000 => format!("{bytes} B"),
        1_000..1_000_000 => format!("{:.1} KB", b / 1e3),
        1_000_000..1_000_000_000 => format!("{:.2} MB", b / 1e6),
        _ => format!("{:.2} GB", b / 1e9),
    }
}

/// One line: `{"elapsed": s, "mode": "per_app" | "interface_only", "reason"?, "apps": [{"id",
/// "name", "rx", "tx", "rx_duplicate"}], "total", "interfaces", "local": {"rx", "tx"}, "flows"}`.
fn json(s: &Snapshot, elapsed: Duration) -> String {
    let bytes = |b: Bytes| format!(r#"{{"rx":{},"tx":{}}}"#, b.rx, b.tx);
    let mode = match &s.mode {
        Mode::PerApp => r#""mode":"per_app""#.to_owned(),
        Mode::InterfaceOnly { reason } => {
            format!(r#""mode":"interface_only","reason":{}"#, string(reason))
        }
    };
    let apps: Vec<String> = s
        .apps
        .iter()
        .map(|(app, b)| {
            format!(
                r#"{{"id":{},"name":{},"rx":{},"tx":{},"rx_duplicate":{}}}"#,
                string(&app.id),
                string(&app.name),
                b.rx,
                b.tx,
                s.rx_duplicate(app)
            )
        })
        .collect();
    format!(
        r#"{{"elapsed":{},{mode},"apps":[{}],"total":{},"interfaces":{},"local":{},"flows":{}}}"#,
        elapsed.as_secs(),
        apps.join(","),
        bytes(s.apps_total()),
        bytes(s.interfaces),
        bytes(s.local),
        s.flows
    )
}

/// A JSON string literal.
fn string(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 2);
    out.push('"');
    for c in value.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            c if u32::from(c) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", u32::from(c));
            }
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use soroband_core::meter::App;

    #[test]
    fn json_escapes_quotes_backslashes_and_control_characters() {
        assert_eq!(string("a\"b\\c\nd"), r#""a\"b\\c\u000ad""#);
    }

    #[test]
    fn json_line_carries_apps_and_reconciliation_totals() {
        let curl = App {
            id: "/usr/bin/curl".into(),
            name: "curl".into(),
        };
        let snapshot = Snapshot {
            mode: Mode::PerApp,
            apps: vec![(
                curl.clone(),
                Bytes {
                    rx: 20_000_000,
                    tx: 4_000,
                },
            )],
            local: Bytes { rx: 7, tx: 8 },
            interfaces: Bytes {
                rx: 21_000_000,
                tx: 9_000,
            },
            flows: 3,
            rx_duplicates: vec![(curl.clone(), 1_200)],
        };
        assert_eq!(
            json(&snapshot, Duration::from_secs(60)),
            r#"{"elapsed":60,"mode":"per_app","apps":[{"id":"/usr/bin/curl","name":"curl","rx":20000000,"tx":4000,"rx_duplicate":1200}],"total":{"rx":20000000,"tx":4000},"interfaces":{"rx":21000000,"tx":9000},"local":{"rx":7,"tx":8},"flows":3}"#
        );
    }

    #[test]
    fn interface_only_mode_states_its_reason() {
        let snapshot = Snapshot {
            mode: Mode::InterfaceOnly {
                reason: "TCP descriptor of 344 bytes is not known for macOS 26".into(),
            },
            apps: vec![],
            local: Bytes::default(),
            interfaces: Bytes { rx: 5, tx: 6 },
            flows: 0,
            rx_duplicates: vec![],
        };
        let line = json(&snapshot, Duration::from_secs(5));
        assert!(line.contains(r#""mode":"interface_only","reason":"TCP descriptor of 344 bytes is not known for macOS 26""#), "{line}");
    }

    #[test]
    fn table_replaces_control_characters_in_names() {
        assert_eq!(
            printable("evil\u{1b}]0;title\u{7}\u{9b}2J"),
            "evil\u{FFFD}]0;title\u{FFFD}\u{FFFD}2J"
        );
    }

    #[test]
    fn record_requires_a_time_limit() {
        assert!(parse(&["--record", "x.rec"]).is_err());
        assert!(parse(&["--record", "x.rec", "--for", "60"]).is_ok());
    }
}
