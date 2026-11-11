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
    let (numer, denom) = host.timebase();
    assert!(numer > 0 && denom > 0);
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
    assert!(startup.free > 0 && startup.free < startup.size && startup.size > 10 << 30);
    assert!(
        host.volumes()
            .iter()
            .all(|v| !v.path.starts_with("/System/Volumes/"))
    );
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
