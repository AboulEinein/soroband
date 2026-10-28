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

#[test]
fn waker_cuts_the_wait_for_the_next_poll_short() {
    let mut engine = Engine::start(SystemHost::connect().unwrap()).expect("start");
    let waker = engine.host_mut().waker().expect("waker");
    let started = std::time::Instant::now();
    let thread = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(200));
        waker.wake();
    });
    // Without the wakeup this tick would wait 30 s before polling.
    engine.tick(Duration::from_secs(30)).expect("tick");
    thread.join().unwrap();
    assert!(
        started.elapsed() < Duration::from_secs(5),
        "the tick took {:?}",
        started.elapsed()
    );
}

#[test]
fn wakeup_waits_while_the_engine_is_not_between_polls() {
    // No subscription, so the socket stays silent and only the deadline or a wakeup ends `recv`.
    let mut host = SystemHost::connect().unwrap();
    let waker = host.waker().unwrap();
    let mut buf = vec![0; 1024];
    waker.wake();
    // During a poll's reply the wakeup must not end the wait.
    let started = std::time::Instant::now();
    let got = host
        .recv(&mut buf, started + Duration::from_millis(500))
        .unwrap();
    assert_eq!(got, None);
    assert!(
        started.elapsed() >= Duration::from_millis(450),
        "{:?}",
        started.elapsed()
    );
    // Between polls the waiting wakeup ends the wait at once.
    host.set_wakeable(true);
    let started = std::time::Instant::now();
    assert_eq!(
        host.recv(&mut buf, started + Duration::from_secs(5))
            .unwrap(),
        None
    );
    assert!(
        started.elapsed() < Duration::from_secs(1),
        "{:?}",
        started.elapsed()
    );
}
