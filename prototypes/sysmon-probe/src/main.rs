//! Spike: what does CPU, RAM and disk monitoring cost, and which kernel
//! interfaces give the most for the least?
//!
//!   sysmon-probe bench               cost of one call of each source
//!   sysmon-probe run <mode> <secs>   poll every 5 s, report own CPU and memory
//!   sysmon-probe top [secs]          top coalitions (apps with helpers) by CPU
//!   sysmon-probe energy [secs]       coalition and per-process energy, beside top's POWER
//!
//! Modes: idle, gauges, scan, coal, tiered.

#![allow(deprecated, clippy::all)]

use std::collections::HashMap;
use std::ffi::CString;
use std::mem::{size_of, zeroed};
use std::time::{Duration, Instant};

// ---- private libproc / coalition declarations (xnu, not in the public SDK) ----

const PROC_PIDCOALITIONINFO: libc::c_int = 20;
const LISTCOALITIONS_SINGLE_TYPE: libc::c_int = 2;
const COALITION_TYPE_RESOURCE: libc::c_int = 0;
const RUSAGE_INFO_V6: libc::c_int = 6;

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct ProcPidCoalitionInfo {
    coalition_id: [u64; 2],
    reserved: [u64; 3],
}

#[repr(C)]
#[derive(Clone, Copy, Default, Debug)]
struct ProcInfoCoalInfo {
    coalition_id: u64,
    coalition_type: u32,
    coalition_tasks: u32,
}

/// xnu's `struct coalition_resource_usage` (osfmk/mach/coalition.h): the
/// first twelve fields by name, the rest by index into `rest`.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
struct CoalitionUsage {
    tasks_started: u64,
    tasks_exited: u64,
    time_nonempty: u64,
    cpu_time: u64,
    interrupt_wakeups: u64,
    platform_idle_wakeups: u64,
    bytesread: u64,
    byteswritten: u64,
    gpu_time: u64,
    cpu_time_billed_to_me: u64,
    cpu_time_billed_to_others: u64,
    energy: u64, // nanojoules
    rest: [u64; 33],
}

impl Default for CoalitionUsage {
    fn default() -> Self { unsafe { zeroed() } }
}

/// `phys_footprint`, "sum of instantaneous process phys_footprint".
const COAL_PHYS_FOOTPRINT: usize = 28;
/// `gpu_energy_nj`.
const COAL_GPU_ENERGY_NJ: usize = 29;

/// `struct rusage_info_v6`, of which only the leading fields are read.
#[repr(C)]
struct RusageV6 {
    uuid: [u8; 16],
    user_time: u64,
    system_time: u64,
    pkg_idle_wkups: u64,
    interrupt_wkups: u64,
    pageins: u64,
    wired_size: u64,
    resident_size: u64,
    phys_footprint: u64,
    proc_start_abstime: u64,
    proc_exit_abstime: u64,
    child_user_time: u64,
    child_system_time: u64,
    child_pkg_idle_wkups: u64,
    child_interrupt_wkups: u64,
    child_pageins: u64,
    child_elapsed_abstime: u64,
    diskio_bytesread: u64,
    diskio_byteswritten: u64,
    rest: [u64; 60],
}

extern "C" {
    fn proc_listallpids(buffer: *mut libc::c_void, buffersize: libc::c_int) -> libc::c_int;
    fn proc_pid_rusage(pid: libc::c_int, flavor: libc::c_int, buffer: *mut libc::c_void) -> libc::c_int;
    fn proc_pidinfo(pid: libc::c_int, flavor: libc::c_int, arg: u64, buffer: *mut libc::c_void, size: libc::c_int) -> libc::c_int;
    fn proc_name(pid: libc::c_int, buffer: *mut libc::c_void, size: u32) -> libc::c_int;
    fn proc_listcoalitions(flavor: libc::c_int, coaltype: libc::c_int, buffer: *mut libc::c_void, buffersize: libc::c_int) -> libc::c_int;
    fn coalition_info_resource_usage(cid: u64, cru: *mut CoalitionUsage, sz: libc::size_t) -> libc::c_int;
}

// ---- system gauges ----

#[derive(Default, Clone, Copy)]
struct Gauges {
    cpu_ticks: [u32; 4], // user, system, idle, nice
    free_pages: u32,
    wired_pages: u32,
    compressed_pages: u32,
    pressure_level: i32,
    disk_free: u64,
}

struct GaugeReader {
    host: libc::mach_port_t,
    pressure_mib: Vec<libc::c_int>,
    data_volume: CString,
}

impl GaugeReader {
    fn new() -> Self {
        let mut mib = vec![0; 8];
        let mut len = mib.len();
        let name = CString::new("kern.memorystatus_vm_pressure_level").unwrap();
        // SAFETY: mib has room for `len` ints.
        unsafe { libc::sysctlnametomib(name.as_ptr(), mib.as_mut_ptr(), &mut len) };
        mib.truncate(len);
        Self {
            host: unsafe { libc::mach_host_self() },
            pressure_mib: mib,
            data_volume: CString::new("/System/Volumes/Data").unwrap(),
        }
    }

    fn cpu(&self, g: &mut Gauges) {
        let mut info: libc::host_cpu_load_info = unsafe { zeroed() };
        let mut count = libc::HOST_CPU_LOAD_INFO_COUNT;
        unsafe {
            libc::host_statistics(self.host, libc::HOST_CPU_LOAD_INFO, &mut info as *mut _ as *mut _, &mut count);
        }
        g.cpu_ticks = [info.cpu_ticks[0], info.cpu_ticks[1], info.cpu_ticks[2], info.cpu_ticks[3]];
    }

    fn memory(&self, g: &mut Gauges) {
        let mut vm: libc::vm_statistics64 = unsafe { zeroed() };
        let mut count = libc::HOST_VM_INFO64_COUNT;
        unsafe {
            libc::host_statistics64(self.host, libc::HOST_VM_INFO64, &mut vm as *mut _ as *mut _, &mut count);
        }
        g.free_pages = vm.free_count;
        g.wired_pages = vm.wire_count;
        g.compressed_pages = vm.compressor_page_count;
        let mut level: i32 = 0;
        let mut len = size_of::<i32>();
        unsafe {
            libc::sysctl(
                self.pressure_mib.as_ptr() as *mut _,
                self.pressure_mib.len() as u32,
                &mut level as *mut _ as *mut _,
                &mut len,
                std::ptr::null_mut(),
                0,
            );
        }
        g.pressure_level = level;
    }

    fn disk(&self, g: &mut Gauges) {
        let mut st: libc::statfs = unsafe { zeroed() };
        if unsafe { libc::statfs(self.data_volume.as_ptr(), &mut st) } == 0 {
            g.disk_free = st.f_bavail * st.f_bsize as u64;
        }
    }

    fn all(&self) -> Gauges {
        let mut g = Gauges::default();
        self.cpu(&mut g);
        self.memory(&mut g);
        self.disk(&mut g);
        g
    }
}

fn cpu_busy_fraction(a: &Gauges, b: &Gauges) -> f64 {
    let d: Vec<f64> = (0..4).map(|i| b.cpu_ticks[i].wrapping_sub(a.cpu_ticks[i]) as f64).collect();
    let total: f64 = d.iter().sum();
    if total == 0.0 { 0.0 } else { 1.0 - d[2] / total }
}

// ---- per-process scan ----

#[derive(Default, Clone, Copy)]
struct ProcSample {
    cpu: u64, // mach ticks
    footprint: u64,
    disk_read: u64,
    disk_written: u64,
}

#[derive(Default)]
struct ScanStats {
    pids: usize,
    readable: usize,
    denied: usize,
}

struct Scanner {
    pids: Vec<libc::c_int>,
}

impl Scanner {
    fn new() -> Self { Self { pids: vec![0; 8192] } }

    fn list(&mut self) -> &[libc::c_int] {
        let n = unsafe {
            proc_listallpids(self.pids.as_mut_ptr() as *mut _, (self.pids.len() * size_of::<libc::c_int>()) as libc::c_int)
        };
        &self.pids[..n.max(0) as usize]
    }

    fn scan(&mut self, out: &mut HashMap<libc::c_int, ProcSample>) -> ScanStats {
        out.clear();
        let pids: Vec<libc::c_int> = self.list().to_vec();
        let mut stats = ScanStats { pids: pids.len(), ..Default::default() };
        let mut ri: RusageV6 = unsafe { zeroed() };
        for pid in pids {
            if unsafe { proc_pid_rusage(pid, RUSAGE_INFO_V6, &mut ri as *mut _ as *mut _) } == 0 {
                stats.readable += 1;
                out.insert(pid, ProcSample {
                    cpu: ri.user_time + ri.system_time,
                    footprint: ri.phys_footprint,
                    disk_read: ri.diskio_bytesread,
                    disk_written: ri.diskio_byteswritten,
                });
            } else {
                stats.denied += 1;
            }
        }
        stats
    }
}

fn coalition_of(pid: libc::c_int) -> Option<u64> {
    let mut ci = ProcPidCoalitionInfo::default();
    let n = unsafe {
        proc_pidinfo(pid, PROC_PIDCOALITIONINFO, 0, &mut ci as *mut _ as *mut _, size_of::<ProcPidCoalitionInfo>() as i32)
    };
    (n as usize == size_of::<ProcPidCoalitionInfo>()).then_some(ci.coalition_id[COALITION_TYPE_RESOURCE as usize])
}

fn name_of(pid: libc::c_int) -> String {
    let mut buf = [0u8; 256];
    let n = unsafe { proc_name(pid, buf.as_mut_ptr() as *mut _, buf.len() as u32) };
    if n <= 0 { return format!("pid {pid}"); }
    String::from_utf8_lossy(&buf[..n as usize]).into_owned()
}

// ---- coalitions ----

struct Coalitions {
    buf: Vec<ProcInfoCoalInfo>,
}

impl Coalitions {
    fn new() -> Self { Self { buf: vec![ProcInfoCoalInfo::default(); 4096] } }

    fn list(&mut self) -> &[ProcInfoCoalInfo] {
        let bytes = unsafe {
            proc_listcoalitions(
                LISTCOALITIONS_SINGLE_TYPE,
                COALITION_TYPE_RESOURCE,
                self.buf.as_mut_ptr() as *mut _,
                (self.buf.len() * size_of::<ProcInfoCoalInfo>()) as libc::c_int,
            )
        };
        let n = (bytes.max(0) as usize) / size_of::<ProcInfoCoalInfo>();
        &self.buf[..n]
    }

    fn usage(cid: u64) -> Option<CoalitionUsage> {
        let mut u = CoalitionUsage::default();
        let rc = unsafe { coalition_info_resource_usage(cid, &mut u, size_of::<CoalitionUsage>()) };
        (rc == 0).then_some(u)
    }

    fn sample(&mut self, out: &mut HashMap<u64, CoalitionUsage>) -> (usize, usize) {
        out.clear();
        let ids: Vec<u64> = self.list().iter().map(|c| c.coalition_id).collect();
        let (mut ok, mut denied) = (0, 0);
        for id in ids {
            match Self::usage(id) {
                Some(u) => { ok += 1; out.insert(id, u); }
                None => denied += 1,
            }
        }
        (ok, denied)
    }
}

// ---- helpers ----

fn timebase() -> f64 {
    let mut tb = libc::mach_timebase_info { numer: 0, denom: 0 };
    unsafe { libc::mach_timebase_info(&mut tb) };
    tb.numer as f64 / tb.denom as f64
}

fn own_cpu_secs() -> f64 {
    let mut ru: libc::rusage = unsafe { zeroed() };
    unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut ru) };
    let t = |tv: libc::timeval| tv.tv_sec as f64 + tv.tv_usec as f64 / 1e6;
    t(ru.ru_utime) + t(ru.ru_stime)
}

fn own_footprint_mb() -> f64 {
    let mut ri: RusageV6 = unsafe { zeroed() };
    unsafe { proc_pid_rusage(libc::getpid(), RUSAGE_INFO_V6, &mut ri as *mut _ as *mut _) };
    ri.phys_footprint as f64 / 1048576.0
}

fn bench<F: FnMut()>(label: &str, iters: u32, mut f: F) {
    f();
    let start = Instant::now();
    for _ in 0..iters { f(); }
    let us = start.elapsed().as_secs_f64() * 1e6 / iters as f64;
    println!("{label:<44} {us:>10.1} µs/call   at 5 s polls: {:.4}% CPU", us / 5e6 * 100.0);
}

// ---- modes ----

fn cmd_bench() {
    let g = GaugeReader::new();
    let mut gs = Gauges::default();
    bench("host_statistics CPU load", 10_000, || g.cpu(&mut gs));
    bench("host_statistics64 VM + pressure sysctl", 10_000, || g.memory(&mut gs));
    bench("statfs data volume", 10_000, || g.disk(&mut gs));
    bench("all three system gauges", 10_000, || { std::hint::black_box(g.all()); });

    let mut s = Scanner::new();
    bench("proc_listallpids", 200, || { std::hint::black_box(s.list().len()); });
    let mut procs = HashMap::new();
    bench("full scan: proc_pid_rusage on every pid", 50, || { s.scan(&mut procs); });
    let st = s.scan(&mut procs);
    println!("    pids {}, readable {}, denied {}", st.pids, st.readable, st.denied);

    let pids: Vec<i32> = s.list().to_vec();
    bench("proc_pidinfo coalition id on every pid", 50, || {
        for &p in &pids { std::hint::black_box(coalition_of(p)); }
    });
    let mapped = pids.iter().filter(|&&p| coalition_of(p).is_some()).count();
    println!("    coalition id readable for {mapped} of {} pids", pids.len());

    let mut c = Coalitions::new();
    bench("proc_listcoalitions", 200, || { std::hint::black_box(c.list().len()); });
    let mut cs = HashMap::new();
    bench("coalition usage on every coalition", 50, || { c.sample(&mut cs); });
    let (ok, denied) = c.sample(&mut cs);
    let tasks: u32 = c.list().iter().map(|x| x.coalition_tasks).sum();
    println!("    coalitions readable {ok}, denied {denied}, holding {tasks} tasks");
}

fn cmd_run(mode: &str, secs: u64) {
    let g = GaugeReader::new();
    let mut s = Scanner::new();
    let mut c = Coalitions::new();
    let mut procs = HashMap::new();
    let mut coals = HashMap::new();
    let mut prev = g.all();
    let mut scans = 0;
    let mut last_scan = Instant::now() - Duration::from_secs(3600);
    let start = Instant::now();
    let cpu0 = own_cpu_secs();
    while start.elapsed().as_secs() < secs {
        std::thread::sleep(Duration::from_secs(5));
        match mode {
            "idle" => {}
            "gauges" => { prev = g.all(); }
            "scan" => { g.all(); s.scan(&mut procs); scans += 1; }
            "coal" => { g.all(); c.sample(&mut coals); scans += 1; }
            "tiered" => {
                // Cheap gauges every poll; the per-app read only when the Mac is
                // busy, memory is under pressure, or once a minute for history.
                let now = g.all();
                let busy = cpu_busy_fraction(&prev, &now) > 0.5;
                let pressured = now.pressure_level > 1;
                if busy || pressured || last_scan.elapsed() >= Duration::from_secs(60) {
                    c.sample(&mut coals);
                    scans += 1;
                    last_scan = Instant::now();
                }
                prev = now;
            }
            other => panic!("unknown mode {other}"),
        }
    }
    let wall = start.elapsed().as_secs_f64();
    let cpu = own_cpu_secs() - cpu0;
    println!(
        "{mode:<7} {wall:>5.0} s  CPU {:.4}%  footprint {:.1} MB  per-app reads {scans}",
        cpu / wall * 100.0,
        own_footprint_mb()
    );
}

fn cmd_top(secs: u64) {
    let tb = timebase();
    let mut s = Scanner::new();
    let mut c = Coalitions::new();
    let (mut p0, mut p1) = (HashMap::new(), HashMap::new());
    let (mut c0, mut c1) = (HashMap::new(), HashMap::new());
    s.scan(&mut p0);
    c.sample(&mut c0);
    std::thread::sleep(Duration::from_secs(secs));
    s.scan(&mut p1);
    c.sample(&mut c1);

    // Coalition membership and a name: the member with the largest footprint
    // whose name is not a helper is a good enough label for the spike.
    let mut members: HashMap<u64, Vec<i32>> = HashMap::new();
    for &pid in p1.keys() {
        if let Some(cid) = coalition_of(pid) { members.entry(cid).or_default().push(pid); }
    }
    let label = |cid: u64| -> String {
        let Some(m) = members.get(&cid) else { return format!("coalition {cid}"); };
        let leader = m.iter().copied().min().unwrap();
        format!("{} (+{} procs)", name_of(leader), m.len() - 1)
    };

    let mut rows: Vec<(u64, f64, f64, u64, u64)> = c1
        .iter()
        .filter_map(|(id, u1)| {
            let u0 = c0.get(id)?;
            let coal_cpu = (u1.cpu_time - u0.cpu_time) as f64 * tb / 1e9;
            let pid_cpu: f64 = members.get(id).map_or(0.0, |m| {
                m.iter().filter_map(|p| Some((p1.get(p)?.cpu - p0.get(p)?.cpu) as f64 * tb / 1e9)).sum()
            });
            Some((*id, coal_cpu, pid_cpu, u1.tasks_exited - u0.tasks_exited, u1.byteswritten - u0.byteswritten))
        })
        .collect();
    rows.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap());
    println!("Over {secs} s. CPU seconds from the coalition vs summed from its live pids:");
    println!("{:<44} {:>9} {:>9} {:>7} {:>11}", "app (coalition)", "coal cpu", "pid cpu", "exited", "disk write");
    for (id, cc, pc, exited, w) in rows.iter().take(15) {
        println!("{:<44} {:>8.2}s {:>8.2}s {:>7} {:>9.1}MB", label(*id), cc, pc, exited, *w as f64 / 1048576.0);
    }

    let mut mem: Vec<(u64, u64, u64)> = c1.iter().map(|(id, u)| {
        let pid_sum = members.get(id).map_or(0, |m| m.iter().filter_map(|p| p1.get(p)).map(|s| s.footprint).sum());
        (*id, u.rest[COAL_PHYS_FOOTPRINT], pid_sum)
    }).collect();
    mem.sort_by(|a, b| b.1.cmp(&a.1));
    println!("\nTop memory: the coalition's phys_footprint vs summed from its readable pids:");
    for (id, coal, pids) in mem.iter().take(10) {
        println!("  {:<44} {:>8.0} MB {:>8.0} MB", label(*id), *coal as f64 / 1048576.0, *pids as f64 / 1048576.0);
    }
}

/// Index of `ri_energy_nj` in `RusageV6::rest`, counted from the SDK header.
const RI_ENERGY_NJ: usize = 22;

fn cmd_energy(secs: u64) {
    let mut c = Coalitions::new();
    let (mut c0, mut c1) = (HashMap::new(), HashMap::new());
    let mut s = Scanner::new();
    let pids: Vec<i32> = s.list().to_vec();
    let energy_of = |pid: i32| -> Option<u64> {
        let mut ri: RusageV6 = unsafe { zeroed() };
        (unsafe { proc_pid_rusage(pid, RUSAGE_INFO_V6, &mut ri as *mut _ as *mut _) } == 0).then_some(ri.rest[RI_ENERGY_NJ])
    };
    let e0: HashMap<i32, u64> = pids.iter().filter_map(|&p| Some((p, energy_of(p)?))).collect();
    c.sample(&mut c0);
    std::thread::sleep(Duration::from_secs(secs));
    c.sample(&mut c1);
    let e1: HashMap<i32, u64> = pids.iter().filter_map(|&p| Some((p, energy_of(p)?))).collect();

    let mut members: HashMap<u64, Vec<i32>> = HashMap::new();
    for &pid in &pids {
        if let Some(cid) = coalition_of(pid) { members.entry(cid).or_default().push(pid); }
    }
    let mut rows: Vec<(u64, f64, f64)> = c1.iter().filter_map(|(id, u1)| {
        let u0 = c0.get(id)?;
        let coal_w = (u1.energy - u0.energy) as f64 / 1e9 / secs as f64;
        let _gpu_w = (u1.rest[COAL_GPU_ENERGY_NJ] - u0.rest[COAL_GPU_ENERGY_NJ]) as f64 / 1e9 / secs as f64;
        let pid_w: f64 = members.get(id).map_or(0.0, |m| m.iter()
            .filter_map(|p| Some((e1.get(p)? - e0.get(p)?) as f64 / 1e9 / secs as f64)).sum());
        Some((*id, coal_w, pid_w))
    }).collect();
    rows.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap());
    println!("Over {secs} s, average watts (energy fields read as nJ):");
    println!("{:<40} {:>10} {:>12}", "app (coalition leader)", "coalition", "ri_energy_nj");
    for (id, cw, pw) in rows.iter().take(12) {
        let name = members.get(id).and_then(|m| m.iter().min()).map_or(format!("coalition {id}"), |&p| name_of(p));
        println!("{name:<40} {cw:>9.3}W {pw:>11.3}W");
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("bench") => cmd_bench(),
        Some("run") => cmd_run(&args[2], args[3].parse().unwrap()),
        Some("energy") => cmd_energy(args.get(2).map_or(10, |s| s.parse().unwrap())),
        Some("top") => cmd_top(args.get(2).map_or(10, |s| s.parse().unwrap())),
        _ => eprintln!("usage: sysmon-probe bench | run <idle|gauges|scan|coal|tiered> <secs> | top [secs] | energy [secs]"),
    }
}
