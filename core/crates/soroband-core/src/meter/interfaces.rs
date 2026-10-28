//! Interface byte counters from the interface MIB's 64-bit statistics, used to reconcile the per-app sum against what crossed the network interfaces.

use super::Bytes;
use super::ntstat::{c_string, u64_at};
use std::collections::HashMap;
use std::mem::{offset_of, size_of, size_of_val};

/// One interface's lifetime counters.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InterfaceCounter {
    pub name: String,
    pub rx: u64,
    pub tx: u64,
}

/// Whether an interface carries internet traffic: Wi‑Fi and wired (`en*`) and cellular
/// (`pdp_ip*`), the same kinds the engine's kernel filter accepts. Loopback, AWDL (`awdl*`,
/// `llw*`), VPN tunnels (`utun*`), bridges and the coprocessor link (`anpi*`) are left out.
#[must_use]
pub fn is_internet_interface(name: &str) -> bool {
    let unit = |prefix: &str| {
        name.strip_prefix(prefix)
            .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
    };
    unit("en") || unit("pdp_ip")
}

// `struct ifmibdata` from <net/if_mib.h>: name[16], pcount, flags, snd_len, snd_maxlen,
// snd_drops, filler[4] (all u32), then a 4-byte packed `if_data64`.
const IFMIBDATA_NAME_LEN: usize = 16;
const IFMIBDATA_DATA: usize = 52;
const NETLINK_GENERIC: libc::c_int = 0;
const IFMIB_SYSTEM: libc::c_int = 1;
const IFMIB_IFCOUNT: libc::c_int = 1;
const IFMIB_IFDATA: libc::c_int = 2;
const IFDATA_GENERAL: libc::c_int = 1;

/// Reads one `struct ifmibdata`.
#[must_use]
pub fn parse_ifmibdata(buf: &[u8]) -> Option<InterfaceCounter> {
    let ibytes = IFMIBDATA_DATA + offset_of!(libc::if_data64, ifi_ibytes);
    let obytes = IFMIBDATA_DATA + offset_of!(libc::if_data64, ifi_obytes);
    if buf.len() < IFMIBDATA_DATA + size_of::<libc::if_data64>() {
        return None;
    }
    Some(InterfaceCounter {
        name: c_string(&buf[..IFMIBDATA_NAME_LEN]),
        rx: u64_at(buf, ibytes),
        tx: u64_at(buf, obytes),
    })
}

/// Reads every interface's counters from the interface MIB (`net.link.generic`).
///
/// The routing socket's `NET_RT_IFLIST2` looks like the natural source, but on macOS 27 it gives
/// an unprivileged process counters wrapped to 32 bits and rounded down to whole kilobytes. The
/// MIB's `if_data64` matches `netstat -ib` to the byte.
pub fn read_counters() -> std::io::Result<Vec<InterfaceCounter>> {
    let mut count: u32 = 0;
    let mut mib = [
        libc::CTL_NET,
        libc::PF_LINK,
        NETLINK_GENERIC,
        IFMIB_SYSTEM,
        IFMIB_IFCOUNT,
    ];
    sysctl(&mut mib, std::slice::from_mut(&mut count))?;
    let mut buf = [0u8; 256];
    let mut counters = Vec::new();
    for index in 1..=count {
        let index = libc::c_int::try_from(index).map_err(std::io::Error::other)?;
        let mut mib = [
            libc::CTL_NET,
            libc::PF_LINK,
            NETLINK_GENERIC,
            IFMIB_IFDATA,
            index,
            IFDATA_GENERAL,
        ];
        // Interface indexes can have gaps where an interface was removed.
        if let Ok(len) = sysctl(&mut mib, &mut buf) {
            counters.extend(parse_ifmibdata(&buf[..len]));
        }
    }
    Ok(counters)
}

/// `sysctl(3)` into `out`, returning the number of bytes written.
fn sysctl<T>(mib: &mut [libc::c_int], out: &mut [T]) -> std::io::Result<usize> {
    let mut len = size_of_val(out);
    // SAFETY: `out` is writable for `len` bytes; sysctl writes at most that and updates `len`.
    let rc = unsafe {
        libc::sysctl(
            mib.as_mut_ptr(),
            u32::try_from(mib.len()).map_err(std::io::Error::other)?,
            out.as_mut_ptr().cast(),
            &raw mut len,
            std::ptr::null_mut(),
            0,
        )
    };
    if rc == 0 {
        Ok(len)
    } else {
        Err(std::io::Error::last_os_error())
    }
}

/// Bytes that crossed the internet interfaces since the first reading.
///
/// Counters are accumulated per interface between readings, so an interface that appears later
/// (joining a hotspot) counts from its first reading, and one whose counter restarts (an interface
/// torn down and recreated) counts from zero again instead of going negative.
#[derive(Debug, Default)]
pub struct InterfaceTotals {
    last: HashMap<String, (u64, u64)>,
    total: Bytes,
}

impl InterfaceTotals {
    pub fn update(&mut self, counters: &[InterfaceCounter]) {
        for c in counters.iter().filter(|c| is_internet_interface(&c.name)) {
            if let Some((rx, tx)) = self.last.insert(c.name.clone(), (c.rx, c.tx)) {
                self.total.rx += if c.rx >= rx { c.rx - rx } else { c.rx };
                self.total.tx += if c.tx >= tx { c.tx - tx } else { c.tx };
            }
        }
    }

    #[must_use]
    pub fn total(&self) -> Bytes {
        self.total
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn counter(name: &str, rx: u64, tx: u64) -> InterfaceCounter {
        InterfaceCounter {
            name: name.into(),
            rx,
            tx,
        }
    }

    #[test]
    fn internet_interfaces_are_wifi_wired_and_cellular() {
        for name in ["en0", "en7", "pdp_ip0"] {
            assert!(is_internet_interface(name), "{name}");
        }
        for name in [
            "lo0", "awdl0", "llw0", "utun3", "bridge0", "anpi0", "ap1", "gif0", "en", "enx",
        ] {
            assert!(!is_internet_interface(name), "{name}");
        }
    }

    #[test]
    fn totals_count_only_what_crossed_internet_interfaces_after_the_first_reading() {
        let mut totals = InterfaceTotals::default();
        totals.update(&[counter("en0", 1_000, 500), counter("lo0", 9_000, 9_000)]);
        totals.update(&[counter("en0", 1_600, 700), counter("lo0", 99_000, 99_000)]);
        // en0 moved 600 down and 200 up; loopback is ignored.
        assert_eq!(totals.total(), Bytes { rx: 600, tx: 200 });
    }

    #[test]
    fn interface_appearing_later_counts_from_its_first_reading() {
        let mut totals = InterfaceTotals::default();
        totals.update(&[counter("en0", 100, 100)]);
        totals.update(&[
            counter("en0", 150, 120),
            counter("pdp_ip0", 5_000_000, 1_000),
        ]);
        totals.update(&[
            counter("en0", 150, 120),
            counter("pdp_ip0", 5_000_300, 1_040),
        ]);
        // en0: 50 + 0 down, 20 + 0 up; pdp_ip0: 300 down, 40 up after its first reading.
        assert_eq!(totals.total(), Bytes { rx: 350, tx: 60 });
    }

    #[test]
    fn truncated_mib_entry_is_skipped() {
        assert_eq!(parse_ifmibdata(&[0; 100]), None);
    }

    #[test]
    fn restarted_counter_counts_from_zero() {
        let mut totals = InterfaceTotals::default();
        totals.update(&[counter("en5", 10_000, 10_000)]);
        totals.update(&[counter("en5", 400, 30)]);
        assert_eq!(totals.total(), Bytes { rx: 400, tx: 30 });
    }

    /// Checks the parsed offsets against `netstat`, which reads the same counters its own way:
    /// en0's byte counts from `netstat -ibn` lie between two readings taken around it. en0 rather
    /// than lo0, whose received and sent counts are equal and would hide swapped offsets.
    #[test]
    fn parsed_counters_match_netstat() {
        let en0 = |counters: Vec<InterfaceCounter>| {
            counters.into_iter().find(|c| c.name == "en0").expect("en0")
        };
        let before = en0(read_counters().expect("sysctl"));
        let out = std::process::Command::new("netstat")
            .args(["-ibn", "-I", "en0"])
            .output()
            .unwrap();
        let after = en0(read_counters().expect("sysctl"));
        let text = String::from_utf8(out.stdout).unwrap();
        // Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll; the link row has
        // no address, so take the first row and count columns from the right.
        let row: Vec<&str> = text.lines().nth(1).unwrap().split_whitespace().collect();
        let n = row.len();
        let (ibytes, obytes): (u64, u64) =
            (row[n - 5].parse().unwrap(), row[n - 2].parse().unwrap());
        assert!(
            (before.rx..=after.rx).contains(&ibytes),
            "{before:?} {ibytes} {after:?}"
        );
        assert!(
            (before.tx..=after.tx).contains(&obytes),
            "{before:?} {obytes} {after:?}"
        );
    }
}
