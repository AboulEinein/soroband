//! Kernel messages built by hand for the synthetic sessions in `replay.rs` and `faults.rs`.

#![allow(dead_code)] // Each test file uses its own subset.

use soroband_core::meter::App;
use soroband_core::meter::ntstat::{self, MSG_ERROR, MSG_SRC_REMOVED, MSG_SRC_UPDATE, MSG_SUCCESS};

pub const MAIL: u32 = 501;
pub const SAFARI: u32 = 502;
pub const MAIL_PATH: &str = "/System/Applications/Mail.app/Contents/MacOS/Mail";
pub const SAFARI_PATH: &str = "/Applications/Safari.app/Contents/MacOS/Safari";

/// A `SRC_UPDATE` from the kernel TCP provider with a descriptor of `size` bytes (360 on macOS 27).
pub fn tcp_update(srcref: u64, rx: u64, tx: u64, pid: u32, local: bool, size: usize) -> Vec<u8> {
    let mut m = vec![0u8; 152 + size];
    let len = u16::try_from(m.len()).unwrap();
    m[8..12].copy_from_slice(&MSG_SRC_UPDATE.to_ne_bytes());
    m[12..14].copy_from_slice(&len.to_ne_bytes());
    m[16..24].copy_from_slice(&srcref.to_ne_bytes());
    m[40..48].copy_from_slice(&rx.to_ne_bytes()); // counts.rxbytes
    m[56..64].copy_from_slice(&tx.to_ne_bytes()); // counts.txbytes
    m[144..148].copy_from_slice(&ntstat::TCP_KERNEL.to_ne_bytes());
    let d = &mut m[152..];
    d[116..120].copy_from_slice(&pid.to_ne_bytes());
    d[120..124].copy_from_slice(&pid.to_ne_bytes());
    d[196..200].copy_from_slice(b"proc");
    if local {
        d[336..340].copy_from_slice(&ntstat::IFNET_IS_LOCAL.to_ne_bytes());
    }
    m
}

pub fn removed(srcref: u64) -> Vec<u8> {
    let mut m = vec![0u8; 24];
    m[8..12].copy_from_slice(&MSG_SRC_REMOVED.to_ne_bytes());
    m[12..14].copy_from_slice(&24u16.to_ne_bytes());
    m[16..24].copy_from_slice(&srcref.to_ne_bytes());
    m
}

pub fn success(context: u64, continuation: bool) -> Vec<u8> {
    let mut m = reply(context, MSG_SUCCESS);
    let flags = if continuation {
        ntstat::HDR_FLAG_CONTINUATION
    } else {
        0
    };
    m[14..16].copy_from_slice(&flags.to_ne_bytes());
    m
}

pub fn error(context: u64) -> Vec<u8> {
    reply(context, MSG_ERROR)
}

fn reply(context: u64, kind: u32) -> Vec<u8> {
    let mut m = vec![0u8; 16];
    m[..8].copy_from_slice(&context.to_ne_bytes());
    m[8..12].copy_from_slice(&kind.to_ne_bytes());
    m[12..14].copy_from_slice(&16u16.to_ne_bytes());
    m
}

/// Messages packed into one datagram, each on an 8-byte boundary.
pub fn pack(messages: &[Vec<u8>]) -> Vec<u8> {
    let mut d = Vec::new();
    for m in messages {
        d.extend_from_slice(m);
        d.resize(d.len().next_multiple_of(8), 0);
    }
    d
}

pub fn mail() -> App {
    App {
        id: "/System/Applications/Mail.app".into(),
        name: "Mail".into(),
    }
}

pub fn safari() -> App {
    App {
        id: "/Applications/Safari.app".into(),
        name: "Safari".into(),
    }
}
