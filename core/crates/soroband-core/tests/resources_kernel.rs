//! The resource meter's kernel reads on this Mac, checked against what the test process knows
//! about itself.

use soroband_core::resources::kernel::{SystemResources, memory_total};
use soroband_core::resources::record::{Recording, Replay, anonymize, capture};
use soroband_core::resources::{LAYOUT, ResourceHost, ResourceMeter, Source};

fn own_pid() -> u32 {
    std::process::id()
}

#[test]
fn the_test_process_is_read_in_its_coalition() {
    let mut host = SystemResources::new();
    // Burn some CPU and write a file, so the counters have something to show.
    let mut x = 0u64;
    for i in 0..20_000_000u64 {
        x = x.wrapping_mul(31).wrapping_add(i);
    }
    assert_ne!(x, 1);
    let pid = own_pid();
    assert!(host.pids().contains(&pid));
    let coalition = host.coalition_of(pid).expect("own coalition");
    let ids = host.coalition_ids().expect("coalition calls");
    assert!(
        ids.len() > 10 && ids.contains(&coalition),
        "{} coalitions",
        ids.len()
    );
    let me = host.process_usage(pid).expect("own usage");
    assert!(me.cpu > 0 && me.footprint > 1_000_000, "{me:?}");
    assert!(me.start > 0 && me.start <= host.now());
    let raw = host
        .coalition_usage(coalition)
        .expect("own coalition's words");
    // The coalition holds this process, so it has at least its footprint and CPU time.
    assert!(
        raw[LAYOUT.footprint] >= me.footprint / 2,
        "{} < {}",
        raw[LAYOUT.footprint],
        me.footprint
    );
    assert!(raw[LAYOUT.cpu] > 0);
    assert_eq!(
        host.executable_path(pid).map(std::path::PathBuf::from),
        std::env::current_exe().ok()
    );
    assert!(host.coalition_of(u32::MAX).is_none() && host.process_usage(u32::MAX).is_none());
    assert!(host.coalition_usage(u64::MAX).is_none());
    let mut unique = ids.clone();
    unique.sort_unstable();
    unique.dedup();
    assert_eq!(unique.len(), ids.len(), "each coalition once");
    assert!(!ids.contains(&0));
    // Every running process's coalition is in the list: none was cut short.
    for p in host.pids() {
        if let Some(c) = host.coalition_of(p) {
            assert!(ids.contains(&c), "coalition {c} of pid {p} is not listed");
        }
    }
    // The CPU time in Mach units, through the timebase, is what getrusage reports in time.
    let ticks = host.process_usage(pid).unwrap().cpu;
    // SAFETY: an all-zero `rusage` is valid and `getrusage` fills it.
    let mut own: libc::rusage = unsafe { std::mem::zeroed() };
    // SAFETY: as above.
    unsafe { libc::getrusage(libc::RUSAGE_SELF, &raw mut own) };
    let ns = |t: libc::timeval| {
        u64::try_from(t.tv_sec).unwrap() * 1_000_000_000 + u64::try_from(t.tv_usec).unwrap() * 1_000
    };
    let (numer, denom) = host.timebase();
    #[allow(clippy::cast_precision_loss)]
    let ratio = (ticks * u64::from(numer) / u64::from(denom)) as f64
        / (ns(own.ru_utime) + ns(own.ru_stime)) as f64;
    assert!((0.8..1.25).contains(&ratio), "{ratio}");
}

#[test]
fn every_process_is_listed() {
    let mut host = SystemResources::new();
    let pids = host.pids();
    let ps = std::process::Command::new("/bin/ps")
        .arg("-axo")
        .arg("pid=")
        .output()
        .unwrap();
    let listed = String::from_utf8(ps.stdout).unwrap().lines().count();
    assert!(pids.len() * 10 >= listed * 9, "{} of {listed}", pids.len());
    assert!(pids.contains(&1) && pids.contains(&own_pid()));
}

#[test]
fn the_gauges_and_volumes_are_plausible() {
    let mut host = SystemResources::new();
    let g = host.gauges();
    let total = memory_total().expect("hw.memsize");
    assert!(total >= 4 << 30, "{total}");
    let used = g.memory_used.expect("memory used");
    assert!(used > 1 << 30 && used < total, "{used} of {total}");
    assert!(g.memory_compressed.expect("compressed") < total);
    assert!(g.swap_used.is_some());
    assert!([1, 2, 4].contains(&g.pressure.expect("pressure")));
    let ticks = g.cpu_ticks.expect("ticks");
    assert!(
        ticks[2] > ticks[0],
        "idle exceeds user since boot: {ticks:?}"
    );
    let startup = host
        .volumes()
        .into_iter()
        .find(|v| v.path == "/")
        .expect("startup volume");
    assert!(startup.free > 100 << 20 && startup.free < startup.size && startup.size > 10 << 30);
    assert!(
        host.volumes()
            .iter()
            .all(|v| !v.path.starts_with("/System/Volumes/"))
    );
}

/// Memory used is app memory (anonymous less purgeable), wired and compressed, as `vm_stat`
/// counts them a moment later.
#[test]
fn memory_used_adds_up_as_activity_monitor_does() {
    let used = SystemResources::new().gauges().memory_used.unwrap();
    let out = std::process::Command::new("/usr/bin/vm_stat")
        .output()
        .unwrap();
    let text = String::from_utf8(out.stdout).unwrap();
    let page: u64 = text
        .split("page size of ")
        .nth(1)
        .and_then(|t| t.split(' ').next())
        .and_then(|n| n.parse().ok())
        .unwrap();
    let pages = |label: &str| -> u64 {
        let line = text.lines().find(|l| l.starts_with(label)).unwrap();
        line.rsplit(' ')
            .next()
            .unwrap()
            .trim_end_matches('.')
            .parse()
            .unwrap()
    };
    let want = (pages("Anonymous pages") - pages("Pages purgeable")
        + pages("Pages wired down")
        + pages("Pages occupied by compressor"))
        * page;
    #[allow(clippy::cast_precision_loss)]
    let ratio = used as f64 / want as f64;
    assert!((0.95..1.05).contains(&ratio), "{used} against {want}");
}

#[test]
fn missing_symbols_mean_no_coalition_calls() {
    let mut host =
        SystemResources::with_symbols(c"soroband_no_such_call", c"coalition_info_resource_usage");
    assert!(host.coalition_ids().is_none());
    let mut host = SystemResources::with_symbols(c"proc_listcoalitions", c"soroband_no_such_call");
    assert!(host.coalition_ids().is_none() && host.coalition_usage(1).is_none());
    let mut meter = ResourceMeter::new(host);
    meter.read(0);
    assert!(matches!(meter.source(), Source::Processes { .. }));
}

#[test]
fn a_capture_replays_and_its_paths_are_made_up() {
    let mut host = SystemResources::new();
    let read = capture(&mut host);
    let me = read
        .processes
        .iter()
        .find(|p| p.pid == own_pid())
        .expect("own process");
    assert_eq!(me.usage.len(), 2, "read before and after the coalitions");
    assert!(me.usage[1].cpu >= me.usage[0].cpu);
    let mut recording = Recording {
        timebase: host.timebase(),
        reads: vec![read],
    };
    anonymize(&mut recording);
    let paths: Vec<&str> = recording.reads[0]
        .processes
        .iter()
        .filter_map(|p| p.path.as_deref())
        .collect();
    assert!(paths.iter().all(|p| p.starts_with("/System/")
        || p.starts_with("/usr/")
        || p.starts_with("/bin/")
        || p.starts_with("/sbin/")
        || p.starts_with("/Library/Apple/")
        || p.starts_with("/private/var/db/")
        || p.starts_with("/Applications/App ")
        || p.starts_with("/Users/user/bin/tool-")));
    let text = recording.to_json();
    let parsed = Recording::parse(&text).expect("parses");
    assert_eq!(parsed, recording);
    let mut replay = Replay::new(parsed);
    replay.begin();
    assert_eq!(replay.now(), recording.reads[0].time);
    assert_eq!(replay.gauges(), recording.reads[0].gauges);
    assert_eq!(replay.volumes(), recording.reads[0].volumes);
}
