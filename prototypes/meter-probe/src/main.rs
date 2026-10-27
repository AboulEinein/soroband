//! Talks to the kernel's network statistics control socket directly (no framework, no nettop)
//! and books internet bytes per app per interface type. Layouts follow XNU `bsd/net/ntstat.h`.
//!
//! Usage: meter-probe <seconds> <poll interval seconds> [--domains]

use std::collections::HashMap;
use std::mem::size_of;
use std::time::{Duration, Instant};

const CTLIOCGINFO: libc::c_ulong = 0xC064_4E03;
const AF_SYS_CONTROL: u16 = 2;
const SYSPROTO_CONTROL: libc::c_int = 2;

// Message types
const MSG_SUCCESS: u32 = 0;
const MSG_ERROR: u32 = 1;
const MSG_ADD_ALL_SRCS: u32 = 1002;
const MSG_GET_UPDATE: u32 = 1007;
const MSG_SRC_REMOVED: u32 = 10002;
const MSG_SRC_UPDATE: u32 = 10006;
const MSG_SRC_EXTENDED_UPDATE: u32 = 10007;
const HDR_FLAG_CONTINUATION: u16 = 1 << 1;
const SRC_REF_ALL: u64 = u64::MAX;

// Providers
const TCP_KERNEL: u32 = 2;
const TCP_USERLAND: u32 = 3;
const UDP_KERNEL: u32 = 4;
const UDP_USERLAND: u32 = 5;
const QUIC_USERLAND: u32 = 8;

// Filter flags
const ACCEPT_CELLULAR: u64 = 0x04;
const ACCEPT_WIFI: u64 = 0x08;
const ACCEPT_WIRED: u64 = 0x10;
const USE_UPDATE_FOR_ADD: u64 = 0x0020_0000;
const PROVIDER_NOZERODELTAS: u64 = 0x0080_0000;
const SUPPRESS_BORING_POLL: u64 = 0x2000_0000;
const EXTENSION_DOMAIN_INFO: u64 = 1 << (1 + 40);

// Per-flow interface properties
const IFNET_IS_LOCAL: u32 = 0x0800;
const IFNET_IS_VPN: u32 = 0x0080;

// Layout: nstat_msg_src_update header is 152 bytes, then the provider's descriptor.
const UPDATE_HDR: usize = 152;
const TCP_DESC: usize = 360; // 344 in the macOS 26 XNU source; macOS 27 appends 16 bytes
const UDP_DESC: usize = 280;

#[repr(C)]
struct CtlInfo {
    ctl_id: u32,
    ctl_name: [u8; 96],
}

#[repr(C)]
struct SockaddrCtl {
    sc_len: u8,
    sc_family: u8,
    ss_sysaddr: u16,
    sc_id: u32,
    sc_unit: u32,
    sc_reserved: [u32; 5],
}

#[derive(Default)]
struct Flow {
    rx: u64,
    tx: u64,
    key: String,
}

#[derive(Default, Clone, Copy)]
struct Bytes {
    rx: u64,
    tx: u64,
}

struct Meter {
    fd: libc::c_int,
    flows: HashMap<u64, Flow>,
    by_app: HashMap<String, Bytes>,
    by_domain: HashMap<String, Bytes>,
    local_skipped: u64,
    layout_mismatches: u64,
    updates: u64,
    sizes: HashMap<(u32, usize), u64>,
}

fn u32_at(b: &[u8], o: usize) -> u32 {
    u32::from_ne_bytes(b[o..o + 4].try_into().unwrap())
}
fn u64_at(b: &[u8], o: usize) -> u64 {
    u64::from_ne_bytes(b[o..o + 8].try_into().unwrap())
}
fn cstr(b: &[u8]) -> String {
    let end = b.iter().position(|&c| c == 0).unwrap_or(b.len());
    String::from_utf8_lossy(&b[..end]).into_owned()
}

fn proc_name(pid: u32) -> Option<String> {
    let mut buf = [0u8; 256];
    let n = unsafe { libc::proc_name(pid as i32, buf.as_mut_ptr().cast(), buf.len() as u32) };
    (n > 0).then(|| cstr(&buf[..n as usize]))
}

fn header(context: u64, kind: u32, length: usize, flags: u16) -> Vec<u8> {
    let mut m = Vec::with_capacity(length);
    m.extend_from_slice(&context.to_ne_bytes());
    m.extend_from_slice(&kind.to_ne_bytes());
    m.extend_from_slice(&(length as u16).to_ne_bytes());
    m.extend_from_slice(&flags.to_ne_bytes());
    m
}

impl Meter {
    fn connect() -> std::io::Result<Self> {
        unsafe {
            let fd = libc::socket(libc::PF_SYSTEM, libc::SOCK_DGRAM, SYSPROTO_CONTROL);
            if fd < 0 {
                return Err(std::io::Error::last_os_error());
            }
            let mut info = CtlInfo { ctl_id: 0, ctl_name: [0; 96] };
            let name = b"com.apple.network.statistics";
            info.ctl_name[..name.len()].copy_from_slice(name);
            if libc::ioctl(fd, CTLIOCGINFO, &mut info) < 0 {
                return Err(std::io::Error::last_os_error());
            }
            let addr = SockaddrCtl {
                sc_len: size_of::<SockaddrCtl>() as u8,
                sc_family: libc::AF_SYSTEM as u8,
                ss_sysaddr: AF_SYS_CONTROL,
                sc_id: info.ctl_id,
                sc_unit: 0,
                sc_reserved: [0; 5],
            };
            if libc::connect(fd, (&addr as *const SockaddrCtl).cast(), size_of::<SockaddrCtl>() as u32) < 0 {
                return Err(std::io::Error::last_os_error());
            }
            let rcvbuf: libc::c_int = 1 << 20;
            libc::setsockopt(fd, libc::SOL_SOCKET, libc::SO_RCVBUF, (&rcvbuf as *const libc::c_int).cast(), 4);
            Ok(Meter {
                fd,
                flows: HashMap::new(),
                by_app: HashMap::new(),
                by_domain: HashMap::new(),
                local_skipped: 0,
                layout_mismatches: 0,
                updates: 0,
                sizes: HashMap::new(),
            })
        }
    }

    fn send(&self, msg: &[u8]) {
        unsafe { libc::send(self.fd, msg.as_ptr().cast(), msg.len(), 0) };
    }

    /// Subscribes to every flow of a provider on physical interfaces (Wi‑Fi, wired, cellular).
    /// Loopback, AWDL and VPN tunnels are excluded by the kernel.
    fn add_all(&self, provider: u32, domains: bool) {
        let quiet = if std::env::var_os("METER_QUIET").is_some() { PROVIDER_NOZERODELTAS | SUPPRESS_BORING_POLL } else { 0 };
        let filter = ACCEPT_WIFI | ACCEPT_WIRED | ACCEPT_CELLULAR | USE_UPDATE_FOR_ADD | quiet
            | if domains { EXTENSION_DOMAIN_INFO } else { 0 };
        let mut m = header(provider as u64, MSG_ADD_ALL_SRCS, 56, 0);
        m.extend_from_slice(&filter.to_ne_bytes()); // filter
        m.extend_from_slice(&0u64.to_ne_bytes()); // events
        m.extend_from_slice(&provider.to_ne_bytes());
        m.extend_from_slice(&0i32.to_ne_bytes()); // target_pid
        m.extend_from_slice(&[0u8; 16]); // target_uuid
        self.send(&m);
    }

    fn poll(&self, context: u64) {
        let mut m = header(context, MSG_GET_UPDATE, 24, HDR_FLAG_CONTINUATION);
        m.extend_from_slice(&SRC_REF_ALL.to_ne_bytes());
        self.send(&m);
    }

    /// Reads until the poll identified by `context` completes, or until `timeout` with no data.
    fn drain(&mut self, context: Option<u64>, timeout: Duration) {
        let mut buf = vec![0u8; 1 << 17];
        let deadline = Instant::now() + timeout;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return;
            }
            let mut pfd = libc::pollfd { fd: self.fd, events: libc::POLLIN, revents: 0 };
            if unsafe { libc::poll(&mut pfd, 1, left.as_millis() as i32) } <= 0 {
                return;
            }
            let n = unsafe { libc::recv(self.fd, buf.as_mut_ptr().cast(), buf.len(), 0) };
            if n <= 0 {
                return;
            }
            let mut off = 0;
            let mut done = false;
            while off + 16 <= n as usize {
                let len = u16::from_ne_bytes(buf[off + 12..off + 14].try_into().unwrap()) as usize;
                if len < 16 || off + len > n as usize {
                    break;
                }
                let msg = &buf[off..off + len];
                let kind = u32_at(msg, 8);
                let ctx = u64_at(msg, 0);
                let flags = u16::from_ne_bytes(msg[14..16].try_into().unwrap());
                if std::env::var_os("METER_DEBUG").is_some() && (kind < 10000 || flags != 0) && context.is_some() && self.updates < 400 {
                    println!("ctl kind {kind} ctx {ctx} flags {flags:#x} len {len}");
                }
                match kind {
                    MSG_SRC_UPDATE | MSG_SRC_EXTENDED_UPDATE => {
                        if std::env::var_os("METER_DEBUG").is_some() && !self.flows.contains_key(&u64_at(msg, 16)) {
                            let total = u64_at(msg, 40) + u64_at(msg, 56);
                            if total > 1_000_000 {
                                println!("first sight srcref {} ctx {ctx} lifetime {} pname {}", u64_at(msg, 16), mb(total), cstr(&msg[UPDATE_HDR + 196..UPDATE_HDR + 260]));
                            }
                        }
                        self.update(msg, kind == MSG_SRC_EXTENDED_UPDATE)
                    }
                    MSG_SRC_REMOVED => {
                        self.flows.remove(&u64_at(msg, 16));
                    }
                    // A poll reply arrives in chunks; each ends in SUCCESS, flagged CONTINUATION until the last.
                    MSG_SUCCESS if Some(ctx) == context && flags & HDR_FLAG_CONTINUATION != 0 => self.poll(ctx),
                    MSG_SUCCESS | MSG_ERROR if Some(ctx) == context => {
                        if kind == MSG_ERROR {
                            eprintln!("poll error {}", u32_at(msg, 16));
                        }
                        done = true;
                    }
                    MSG_ERROR => eprintln!("kernel error {} for context {ctx}", u32_at(msg, 16)),
                    _ => {}
                }
                off += (len + 7) & !7;
            }
            if done {
                return;
            }
        }
    }

    fn update(&mut self, msg: &[u8], extended: bool) {
        self.updates += 1;
        let srcref = u64_at(msg, 16);
        let rx = u64_at(msg, 32 + 8);
        let tx = u64_at(msg, 32 + 24);
        let provider = u32_at(msg, 144);
        let d = &msg[UPDATE_HDR..];
        *self.sizes.entry((provider, d.len())).or_default() += 1;
        let (desc_len, pid, epid, pname, props) = match provider {
            TCP_KERNEL | TCP_USERLAND | QUIC_USERLAND if d.len() >= TCP_DESC => {
                (TCP_DESC, u32_at(d, 116), u32_at(d, 120), cstr(&d[196..260]), u32_at(d, 336))
            }
            UDP_KERNEL | UDP_USERLAND if d.len() >= UDP_DESC => {
                (UDP_DESC, u32_at(d, 128), u32_at(d, 196), cstr(&d[132..196]), u32_at(d, 272))
            }
            _ => {
                self.layout_mismatches += 1;
                return;
            }
        };
        if !extended && d.len() != desc_len {
            self.layout_mismatches += 1;
        }

        let flow = self.flows.entry(srcref).or_default();
        let (drx, dtx) = (rx.saturating_sub(flow.rx), tx.saturating_sub(flow.tx));
        flow.rx = flow.rx.max(rx);
        flow.tx = flow.tx.max(tx);
        if flow.key.is_empty() {
            // Daemons acting for an app (nsurlsessiond, App Store) carry the app as the effective pid.
            let owner = if epid != 0 && epid != pid { proc_name(epid) } else { None };
            flow.key = match owner {
                Some(owner) if owner != pname => format!("{owner} (via {pname})"),
                _ => pname.clone(),
            };
            if props & IFNET_IS_VPN != 0 {
                flow.key.push_str(" [vpn]");
            }
        }
        if props & IFNET_IS_LOCAL != 0 {
            self.local_skipped += drx + dtx;
            return;
        }
        let entry = self.by_app.entry(flow.key.clone()).or_default();
        entry.rx += drx;
        entry.tx += dtx;

        if extended && d.len() >= desc_len + 8 + 256 {
            let item = &d[desc_len..];
            if u32_at(item, 0) == 1 {
                let domain = cstr(&item[8..8 + 256]);
                let owner = cstr(&item[8 + 256..8 + 512]);
                let label = if owner.is_empty() { domain } else { format!("{domain} ({owner})") };
                let e = self.by_domain.entry(label).or_default();
                e.rx += drx;
                e.tx += dtx;
            }
        }
    }
}

fn cpu_seconds() -> f64 {
    let mut ru: libc::rusage = unsafe { std::mem::zeroed() };
    unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut ru) };
    let t = |tv: libc::timeval| tv.tv_sec as f64 + tv.tv_usec as f64 / 1e6;
    t(ru.ru_utime) + t(ru.ru_stime)
}

fn mb(b: u64) -> String {
    format!("{:.2} MB", b as f64 / 1e6)
}

fn print_top(title: &str, map: &HashMap<String, Bytes>) {
    let mut rows: Vec<_> = map.iter().filter(|(_, b)| b.rx + b.tx > 0).collect();
    rows.sort_by_key(|(_, b)| std::cmp::Reverse(b.rx + b.tx));
    println!("\n{title}:");
    for (name, b) in rows.iter().take(12) {
        println!("  {:<44} ↓ {:>10}  ↑ {:>10}", name, mb(b.rx), mb(b.tx));
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let seconds: u64 = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(30);
    let interval: u64 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(5);
    let domains = args.iter().any(|a| a == "--domains");

    let mut meter = Meter::connect().expect("connect to com.apple.network.statistics");
    for p in [TCP_KERNEL, TCP_USERLAND, UDP_KERNEL, UDP_USERLAND, QUIC_USERLAND] {
        meter.add_all(p, domains);
    }
    // Initial snapshot sets per-flow baselines; only bytes after it are counted.
    meter.drain(None, Duration::from_millis(300));
    meter.poll(1);
    meter.drain(Some(1), Duration::from_secs(2));
    if std::env::var_os("METER_DEBUG").is_some() {
        println!("baseline flows {}", meter.flows.len());
    }
    meter.by_app.clear();
    meter.by_domain.clear();
    meter.local_skipped = 0;
    let baseline_cpu = cpu_seconds();

    let start = Instant::now();
    let mut context = 2;
    while start.elapsed() < Duration::from_secs(seconds) {
        // Between polls the socket still delivers final updates for closed flows.
        meter.drain(None, Duration::from_secs(interval));
        meter.poll(context);
        meter.drain(Some(context), Duration::from_secs(2));
        context += 1;
    }

    let total = meter.by_app.values().fold(Bytes::default(), |a, b| Bytes { rx: a.rx + b.rx, tx: a.tx + b.tx });
    let cpu = cpu_seconds() - baseline_cpu;
    let mut ru: libc::rusage = unsafe { std::mem::zeroed() };
    unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut ru) };
    println!("window {seconds}s, poll every {interval}s, updates {}, live flows {}", meter.updates, meter.flows.len());
    println!("cpu {:.3}s ({:.3}% avg) after setup, max rss {:.1} MB", cpu, cpu / seconds as f64 * 100.0, ru.ru_maxrss as f64 / 1048576.0);
    println!("layout mismatches {}", meter.layout_mismatches);
    if std::env::var_os("METER_DEBUG").is_some() {
        println!("descriptor sizes (provider, bytes) -> count: {:?}", meter.sizes);
    }
    println!("internet total ↓ {}  ↑ {}   (local skipped {})", mb(total.rx), mb(total.tx), mb(meter.local_skipped));
    print_top("by app", &meter.by_app);
    if domains {
        print_top("by domain", &meter.by_domain);
    }
}
