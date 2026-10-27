//! The engine against this Mac's kernel.

use soroband_core::meter::ntstat::{TCP_KERNEL, known_size};
use soroband_core::meter::{Engine, Host, Mode, SystemHost};
use std::time::Duration;

fn sw_vers_major() -> u32 {
    let out = std::process::Command::new("sw_vers")
        .arg("-productVersion")
        .output()
        .unwrap();
    String::from_utf8(out.stdout)
        .unwrap()
        .trim()
        .split('.')
        .next()
        .unwrap()
        .parse()
        .unwrap()
}

#[test]
fn system_host_reads_processes_and_interfaces() {
    let mut host = SystemHost::connect().expect("connect to com.apple.network.statistics");
    assert_eq!(host.macos_major(), sw_vers_major());
    let own = host.executable_path(std::process::id()).expect("own path");
    assert_eq!(std::path::Path::new(&own), std::env::current_exe().unwrap());
    let counters = host.interface_counters().expect("interface counters");
    assert!(counters.iter().any(|c| c.name == "lo0"), "{counters:?}");
}

#[test]
fn engine_tracks_this_macs_flows() {
    let mut engine = Engine::start(SystemHost::connect().unwrap()).expect("start");
    engine.tick(Duration::from_secs(1)).expect("tick");
    let snapshot = engine.snapshot();
    if known_size(sw_vers_major(), TCP_KERNEL).is_some() {
        assert_eq!(snapshot.mode, Mode::PerApp);
        // Any Mac running tests has flows on its internet interfaces (at least the CI runner's own).
        assert!(snapshot.flows > 0, "{snapshot:?}");
    } else {
        // macOS versions without recorded layouts fall back to interface totals and say why.
        assert!(
            matches!(&snapshot.mode, Mode::InterfaceOnly { reason } if reason.contains("is not known for macOS")),
            "{snapshot:?}"
        );
    }
}
