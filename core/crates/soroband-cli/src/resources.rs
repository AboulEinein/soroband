//! `soroband system`, `soroband top` and `soroband apps --by`: the system gauges and each app's
//! CPU, memory, disk and energy.
//!
//! `system` and `top` read the system themselves, with the same resource meter as the app, so
//! they work while the app is not running. `apps --by` reads what the app stored.

use crate::text::{printable, size};
use crate::usage::Today;
use serde_json::{Value, json};
use soroband_core::day::{self, hour_start};
use soroband_core::resources::kernel::{self, SystemResources};
use soroband_core::resources::{
    AppResources, Gauges, Reading, ResourceHost, ResourceMeter, Source,
};
use soroband_core::store::{ResourceOrder, ResourceTotal};
use std::fmt::Write as _;
use std::process::ExitCode;
use std::thread::sleep;
use std::time::Duration;

pub const SYSTEM_USAGE: &str = "\
Usage: soroband system [--json]

The system gauges now: CPU busy share over one second, memory used, compressed and swapped,
memory pressure, and the free space of each local volume.";

pub const TOP_USAGE: &str = "\
Usage: soroband top [--by cpu|memory|disk|energy] [--for <seconds>] [--json]

The busiest apps now, measured over --for seconds (default 2, at most 60), by CPU (default),
memory footprint, disk bytes read and written, or energy. CPU is a share of one core.";

/// Apps the text of `top` lists.
const TOP_ROWS: usize = 15;

fn order(word: &str) -> Option<ResourceOrder> {
    match word {
        "cpu" => Some(ResourceOrder::Cpu),
        "memory" => Some(ResourceOrder::Memory),
        "disk" => Some(ResourceOrder::Disk),
        "energy" => Some(ResourceOrder::Energy),
        _ => None,
    }
}

const PRESSURE_NAMES: [(u8, &str); 3] = [(1, "normal"), (2, "warning"), (4, "critical")];

fn pressure_name(level: Option<u8>) -> &'static str {
    level
        .and_then(|l| PRESSURE_NAMES.iter().find(|(n, _)| *n == l))
        .map_or("unknown", |(_, name)| name)
}

#[allow(clippy::cast_precision_loss)] // shown with one decimal
fn percent(part: f64) -> String {
    format!("{:.1}%", part * 100.0)
}

pub fn system(args: &[&str]) -> ExitCode {
    let json = match args {
        [] => false,
        ["--json"] => true,
        _ => return usage_error(SYSTEM_USAGE),
    };
    let mut host = SystemResources::new();
    let before = host.gauges();
    sleep(Duration::from_secs(1));
    let gauges = host.gauges();
    let busy = gauges.busy_since(&before);
    let total = kernel::memory_total();
    let volumes = host.volumes();
    if json {
        let volumes: Vec<Value> = volumes
            .iter()
            .map(|v| json!({ "path": v.path, "free": v.free, "size": v.size }))
            .collect();
        println!(
            "{}",
            json!({
                "cpu_busy": busy,
                "memory_total": total,
                "memory_used": gauges.memory_used,
                "memory_compressed": gauges.memory_compressed,
                "swap_used": gauges.swap_used,
                "pressure": gauges.pressure,
                "volumes": volumes,
            })
        );
        return ExitCode::SUCCESS;
    }
    println!("{}", system_text(busy, total, &gauges, &volumes));
    ExitCode::SUCCESS
}

fn system_text(
    busy: Option<f64>,
    total: Option<u64>,
    gauges: &Gauges,
    volumes: &[soroband_core::resources::Volume],
) -> String {
    let unknown = || "unknown".to_owned();
    let mut text = String::new();
    let _ = writeln!(
        text,
        "CPU busy           {}",
        busy.map_or_else(unknown, percent)
    );
    let _ = writeln!(
        text,
        "Memory used        {}{}",
        gauges.memory_used.map_or_else(unknown, size),
        total.map_or(String::new(), |t| format!(" of {}", size(t)))
    );
    let _ = writeln!(
        text,
        "Compressed         {}",
        gauges.memory_compressed.map_or_else(unknown, size)
    );
    let _ = writeln!(
        text,
        "Swap used          {}",
        gauges.swap_used.map_or_else(unknown, size)
    );
    let _ = writeln!(
        text,
        "Memory pressure    {}",
        pressure_name(gauges.pressure)
    );
    for v in volumes {
        let _ = writeln!(
            text,
            "{:<18} {} free of {}",
            printable(&v.path),
            size(v.free),
            size(v.size)
        );
    }
    text.trim_end().to_owned()
}

fn fallback_note(source: &Source) -> Option<String> {
    match source {
        Source::Coalitions => None,
        Source::Processes { reason } => Some(format!(
            "These numbers come from your own processes only, leaving out other users' and root \
             processes: {reason}."
        )),
    }
}

/// `value` of `r` that `by` ranks apps on.
fn rank(r: &AppResources, by: ResourceOrder) -> u64 {
    match by {
        ResourceOrder::Cpu => r.counters.cpu,
        ResourceOrder::Memory => r.footprint,
        ResourceOrder::Disk => r.counters.read.saturating_add(r.counters.written),
        ResourceOrder::Energy => r.counters.energy,
    }
}

pub fn top(args: &[&str]) -> ExitCode {
    let mut by = ResourceOrder::Cpu;
    let mut seconds = 2u64;
    let mut json = false;
    let mut rest = args.iter();
    while let Some(arg) = rest.next() {
        match *arg {
            "--json" => json = true,
            "--by" => match rest.next().and_then(|w| order(w)) {
                Some(o) => by = o,
                None => return usage_error(TOP_USAGE),
            },
            "--for" => match rest.next().and_then(|n| n.parse().ok()) {
                Some(n @ 1..=60) => seconds = n,
                _ => return usage_error(TOP_USAGE),
            },
            _ => return usage_error(TOP_USAGE),
        }
    }
    let mut meter = ResourceMeter::new(SystemResources::new());
    meter.read(day::now());
    sleep(Duration::from_secs(seconds));
    let mut reading = meter.read(day::now());
    reading
        .apps
        .sort_by(|(a, x), (b, y)| rank(y, by).cmp(&rank(x, by)).then_with(|| a.cmp(b)));
    if json {
        println!("{}", top_json(&reading));
    } else {
        println!("{}", top_text(&reading));
    }
    ExitCode::SUCCESS
}

fn top_json(reading: &Reading) -> Value {
    let apps: Vec<Value> = reading
        .apps
        .iter()
        .map(|(app, r)| {
            json!({
                "id": app.id,
                "name": app.name,
                "cpu_ns": r.counters.cpu,
                "billed_cpu_ns": r.counters.billed,
                "disk_read": r.counters.read,
                "disk_written": r.counters.written,
                "energy_nj": r.counters.energy,
                "footprint": r.footprint,
            })
        })
        .collect();
    let (source, reason) = match &reading.source {
        Source::Coalitions => ("coalitions", None),
        Source::Processes { reason } => ("processes", Some(reason.as_str())),
    };
    json!({
        "seconds": reading.seconds,
        "source": source,
        "reason": reason,
        "apps": apps,
    })
}

#[allow(
    clippy::cast_precision_loss,
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss
)] // rates shown with one decimal
fn top_text(reading: &Reading) -> String {
    let seconds = reading.seconds.max(0.001);
    let energy = reading.apps.iter().any(|(_, r)| r.counters.energy > 0);
    let mut text = format!(
        "Over {:.1} s\n{:<36} {:>7} {:>10} {:>12} {:>12} {:>9}\n",
        reading.seconds, "App", "CPU", "Memory", "Disk read/s", "Written/s", "Power"
    );
    for (app, r) in reading.apps.iter().take(TOP_ROWS) {
        let rate = |b: u64| size((b as f64 / seconds) as u64);
        let _ = writeln!(
            text,
            "{:<36} {:>7} {:>10} {:>12} {:>12} {:>9}",
            printable(&app.name),
            percent(r.counters.cpu as f64 / 1e9 / seconds),
            size(r.footprint),
            rate(r.counters.read),
            rate(r.counters.written),
            if energy {
                format!("{:.2} W", r.counters.energy as f64 / 1e9 / seconds)
            } else {
                "–".to_owned()
            }
        );
    }
    if !energy {
        text.push_str("Energy is not counted on this Mac.\n");
    }
    if let Some(note) = fallback_note(&reading.source) {
        text.push_str(&note);
    }
    text.trim_end().to_owned()
}

/// `soroband apps --by <resource>` and its range options, after `apps`.
pub fn apps_by(args: &[&str]) -> ExitCode {
    let mut by = None;
    let mut from = None;
    let mut to = None;
    let mut json = false;
    let mut rest = args.iter();
    while let Some(arg) = rest.next() {
        match *arg {
            "--json" => json = true,
            "--by" => match rest.next().and_then(|w| order(w)) {
                Some(o) => by = Some(o),
                None => return usage_error(crate::usage::APPS_USAGE),
            },
            "--from" => match rest.next().and_then(|d| parse_date(d)) {
                Some(d) => from = Some(d),
                None => return usage_error(crate::usage::APPS_USAGE),
            },
            "--to" => match rest.next().and_then(|d| parse_date(d)) {
                Some(d) => to = Some(d),
                None => return usage_error(crate::usage::APPS_USAGE),
            },
            _ => return usage_error(crate::usage::APPS_USAGE),
        }
    }
    let Some(by) = by else {
        return usage_error(crate::usage::APPS_USAGE);
    };
    match apps_by_text(by, from, to, json) {
        Ok(text) => {
            println!("{text}");
            ExitCode::SUCCESS
        }
        Err(message) => {
            eprintln!("soroband: {message}");
            ExitCode::FAILURE
        }
    }
}

/// Days since 1970-01-01 of a `YYYY-MM-DD` date.
fn parse_date(text: &str) -> Option<i64> {
    let mut parts = text.splitn(3, '-');
    let year: i64 = parts.next()?.parse().ok()?;
    let month: i64 = parts.next()?.parse().ok()?;
    let day: i64 = parts.next()?.parse().ok()?;
    let days_in_month = match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 => 29,
        2 => 28,
        _ => return None,
    };
    if !(1..=days_in_month).contains(&day) || text.len() != 10 {
        return None;
    }
    // Howard Hinnant's days_from_civil.
    let y = if month <= 2 { year - 1 } else { year };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (month + if month > 2 { -3 } else { 9 }) + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    Some(era * 146_097 + doe - 719_468)
}

/// Unix time of local midnight starting the day `days` after 1970-01-01, rounded down to a UTC
/// hour as the stored hours are. Where the clocks skip midnight, the day starts when they land.
fn local_midnight(days: i64, offset_at: impl Fn(i64) -> i64) -> i64 {
    let local = days * 86_400;
    let mut start = local - offset_at(local - offset_at(local));
    // A skipped midnight: that instant is still the day before on the clock, so the day starts at
    // the same local time under the offset before the change.
    if start + offset_at(start) < local {
        start = local - offset_at(start);
    }
    hour_start(start)
}

fn apps_by_text(
    by: ResourceOrder,
    from: Option<i64>,
    to: Option<i64>,
    json: bool,
) -> Result<String, String> {
    let today = Today::open()?;
    let start = from.map_or(today.start, |d| local_midnight(d, day::local_offset));
    let end = to.map_or(i64::MAX, |d| local_midnight(d + 1, day::local_offset));
    if end <= start {
        return Err(if from.is_some() {
            "--to is before --from".into()
        } else {
            "--to is before today; give --from too".into()
        });
    }
    let totals = today
        .store
        .resource_totals(start, end, by)
        .map_err(|e| e.to_string())?;
    let fallback = totals.iter().any(|t| t.fallback);
    if json {
        let apps: Vec<Value> = totals.iter().map(total_json).collect();
        return Ok(json!({
            "start": start,
            "end": (end != i64::MAX).then_some(end),
            "fallback": fallback,
            "apps": apps,
        })
        .to_string());
    }
    let energy = totals.iter().any(|t| t.counters.energy > 0);
    let mut text = format!(
        "{}\n{:<36} {:>10} {:>10} {:>10} {:>10} {:>10} {:>10}\n",
        match (from, to) {
            (None, None) => format!("Today since {:02}:00", today.reset_hour),
            _ => "From the dates asked".to_owned(),
        },
        "App",
        "CPU time",
        "Memory",
        "Peak",
        "Read",
        "Written",
        "Energy"
    );
    for t in &totals {
        let _ = writeln!(
            text,
            "{:<36} {:>10} {:>10} {:>10} {:>10} {:>10} {:>10}",
            printable(&t.app.name),
            duration(t.counters.cpu),
            size(t.footprint),
            size(t.peak),
            size(t.counters.read),
            size(t.counters.written),
            if energy {
                joules(t.counters.energy)
            } else {
                "–".to_owned()
            }
        );
    }
    if !energy && !totals.is_empty() {
        text.push_str("Energy is not counted on this Mac.\n");
    }
    if fallback {
        text.push_str(
            "Some of these numbers come from your own processes only, leaving out other users' \
             and root processes (soroband debug state says why).\n",
        );
    }
    Ok(text.trim_end().to_owned())
}

fn total_json(t: &ResourceTotal) -> Value {
    json!({
        "id": t.app.id,
        "name": t.app.name,
        "cpu_ns": t.counters.cpu,
        "billed_cpu_ns": t.counters.billed,
        "disk_read": t.counters.read,
        "disk_written": t.counters.written,
        "energy_nj": t.counters.energy,
        "footprint": t.footprint,
        "footprint_peak": t.peak,
        "fallback": t.fallback,
    })
}

/// Nanoseconds as `h:mm:ss`.
fn duration(ns: u64) -> String {
    let s = ns / 1_000_000_000;
    format!("{}:{:02}:{:02}", s / 3600, s / 60 % 60, s % 60)
}

#[allow(clippy::cast_precision_loss)] // shown with one decimal
fn joules(nj: u64) -> String {
    let j = nj as f64 / 1e9;
    if j < 1_000.0 {
        format!("{j:.1} J")
    } else {
        format!("{:.1} kJ", j / 1e3)
    }
}

fn usage_error(usage: &str) -> ExitCode {
    eprintln!("{usage}");
    ExitCode::from(2)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dates_are_days_since_1970() {
        assert_eq!(parse_date("1970-01-01"), Some(0));
        assert_eq!(parse_date("2026-11-12"), Some(20_769));
        assert_eq!(parse_date("2024-02-29"), Some(19_782));
        for bad in [
            "2025-02-29",
            "2026-13-01",
            "2026-1-01",
            "2026-04-31",
            "yesterday",
        ] {
            assert_eq!(parse_date(bad), None, "{bad}");
        }
    }

    #[test]
    fn a_date_starts_at_local_midnight() {
        // UTC+2: midnight local is 22:00 UTC the day before.
        assert_eq!(local_midnight(1, |_| 7_200), 86_400 - 7_200);
        // UTC+5:30 rounds down to the UTC hour, as "today" does.
        assert_eq!(local_midnight(1, |_| 19_800), 86_400 - 21_600);
    }

    #[test]
    fn a_day_whose_midnight_is_skipped_starts_when_the_clocks_land() {
        // UTC-4 until 04:00 UTC on day 1, then UTC-3: local midnight never happens, the clocks
        // go from 23:59:59 to 01:00. The day starts at 04:00 UTC (01:00 local), not at 03:00 UTC,
        // which is 23:00 the day before.
        let change = 86_400 + 4 * 3_600;
        let offset = |t: i64| if t < change { -4 * 3_600 } else { -3 * 3_600 };
        assert_eq!(local_midnight(1, offset), change);
        // A day with a midnight is unchanged on either side of the change.
        assert_eq!(local_midnight(0, offset), 4 * 3_600);
        assert_eq!(local_midnight(2, offset), 2 * 86_400 + 3 * 3_600);
    }

    #[test]
    fn cpu_time_reads_as_hours_minutes_and_seconds() {
        assert_eq!(duration(3_723_400_000_000), "1:02:03");
        assert_eq!(joules(2_500_000_000), "2.5 J");
        assert_eq!(joules(12_345_000_000_000), "12.3 kJ");
    }
}
