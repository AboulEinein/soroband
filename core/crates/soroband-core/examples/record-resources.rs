//! Records the resource meter's reads of this Mac for the replay tests.
//!
//! It takes three whole reads, one second apart and then two: before a `yes` and a `dd` writing
//! 64 MB it starts, while `yes` runs (`dd` has usually finished by then: a command that starts and
//! exits between two reads), and after `yes` exited. The recording ends with the CPU time
//! `yes` and `dd` used by their own account (their rusage from `wait4`), under `"expect"`, and its
//! paths made up outside macOS's own directories.
//!
//! Run it as a launchd job, so its coalition holds only it and its two commands; a coalition shared
//! with a terminal or an agent also holds their short-lived commands:
//!
//! ```zsh
//! cargo build -p soroband-core --example record-resources
//! launchctl submit -l soroband.record -- "$PWD/target/debug/examples/record-resources" <file>
//! # once <file> exists:
//! launchctl remove soroband.record
//! ```

use serde_json::{Value, json};
use soroband_core::resources::ResourceHost;
use soroband_core::resources::kernel::SystemResources;
use soroband_core::resources::record::{Recording, anonymize, capture};
use std::process::{Child, Command, Stdio};
use std::thread::sleep;
use std::time::Duration;

/// Waits for `child` and returns its CPU time in nanoseconds, as the kernel accounted it at its
/// exit, and its `wait4` status.
fn reap(child: &Child) -> (u64, i32) {
    let pid = i32::try_from(child.id()).expect("pid");
    // SAFETY: an all-zero `rusage` is valid.
    let mut usage: libc::rusage = unsafe { std::mem::zeroed() };
    let mut status = 0;
    // SAFETY: the pointers are valid for the call.
    let reaped = unsafe { libc::wait4(pid, &raw mut status, 0, &raw mut usage) };
    assert_eq!(reaped, pid, "wait4");
    let ns = |t: libc::timeval| {
        u64::try_from(t.tv_sec).unwrap() * 1_000_000_000 + u64::try_from(t.tv_usec).unwrap() * 1_000
    };
    (ns(usage.ru_utime) + ns(usage.ru_stime), status)
}

// Both children are reaped with `wait4`, which `Child::wait` would not report the rusage of.
#[allow(clippy::zombie_processes)]
fn main() {
    let out = std::env::args()
        .nth(1)
        .expect("usage: record-resources <file>");
    let mut host = SystemResources::new();
    let mut reads = vec![capture(&mut host)];
    let scratch = std::env::temp_dir().join(format!("record-resources-{}", std::process::id()));
    let dd = Command::new("/bin/dd")
        .args(["if=/dev/zero", "bs=1m", "count=64"])
        .arg(format!("of={}", scratch.display()))
        .stderr(Stdio::null())
        .spawn()
        .expect("dd");
    // Started after `dd`, so a `dd` that fails to start leaves no `yes` running.
    let mut yes = Command::new("/usr/bin/yes")
        .stdout(Stdio::null())
        .spawn()
        .expect("yes");
    sleep(Duration::from_secs(1));
    reads.push(capture(&mut host));
    sleep(Duration::from_secs(1));
    yes.kill().expect("kill yes");
    let (yes_cpu, yes_status) = reap(&yes);
    assert!(
        libc::WIFSIGNALED(yes_status) && libc::WTERMSIG(yes_status) == libc::SIGKILL,
        "yes ended other than by the kill"
    );
    let (dd_cpu, dd_status) = reap(&dd);
    // A `dd` cut short (a full disk) would record less than the 64 MB the replay expects.
    assert!(
        libc::WIFEXITED(dd_status) && libc::WEXITSTATUS(dd_status) == 0,
        "dd failed"
    );
    let _ = std::fs::remove_file(&scratch);
    sleep(Duration::from_secs(1));
    reads.push(capture(&mut host));
    let mut recording = Recording {
        timebase: host.timebase(),
        reads,
    };
    anonymize(&mut recording);
    let mut value: Value = serde_json::from_str(&recording.to_json()).expect("json");
    value["expect"] = json!({
        "yes_cpu_ns": yes_cpu,
        "dd_cpu_ns": dd_cpu,
    });
    std::fs::write(&out, value.to_string()).expect("write");
    println!("wrote {out}: yes {yes_cpu} ns, dd {dd_cpu} ns");
}
