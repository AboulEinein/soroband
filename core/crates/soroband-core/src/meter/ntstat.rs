//! The kernel network statistics protocol (`com.apple.network.statistics`): message layouts,
//! the requests the engine sends, and the parsing of what the kernel sends back.
//!
//! Layouts follow XNU `bsd/net/ntstat.h`, checked against a running macOS 27. Only the leading
//! descriptor fields are read (pid, effective pid, process name, interface properties), and each
//! descriptor's size is checked against [`KNOWN_LAYOUTS`] before any of them is trusted.

/// Message types.
pub const MSG_SUCCESS: u32 = 0;
pub const MSG_ERROR: u32 = 1;
pub const MSG_ADD_ALL_SRCS: u32 = 1002;
pub const MSG_GET_UPDATE: u32 = 1007;
pub const MSG_SRC_REMOVED: u32 = 10002;
pub const MSG_SRC_UPDATE: u32 = 10006;
pub const MSG_SRC_EXTENDED_UPDATE: u32 = 10007;

/// Set on a poll request, and on each `SUCCESS` that ends a chunk of the reply other than the last.
pub const HDR_FLAG_CONTINUATION: u16 = 1 << 1;
const SRC_REF_ALL: u64 = u64::MAX;

/// Providers.
pub const TCP_KERNEL: u32 = 2;
pub const TCP_USERLAND: u32 = 3;
pub const UDP_KERNEL: u32 = 4;
pub const UDP_USERLAND: u32 = 5;
pub const QUIC_USERLAND: u32 = 8;
pub const PROVIDERS: [u32; 5] = [
    TCP_KERNEL,
    TCP_USERLAND,
    UDP_KERNEL,
    UDP_USERLAND,
    QUIC_USERLAND,
];

/// Filter flags for `ADD_ALL_SRCS`.
pub const FILTER_ACCEPT_CELLULAR: u64 = 0x04;
pub const FILTER_ACCEPT_WIFI: u64 = 0x08;
pub const FILTER_ACCEPT_WIRED: u64 = 0x10;
pub const FILTER_USE_UPDATE_FOR_ADD: u64 = 0x0020_0000;
/// Never set: a flow idle at startup would get no baseline and later report its whole lifetime.
pub const FILTER_PROVIDER_NOZERODELTAS: u64 = 0x0080_0000;
/// Never set, for the same reason as [`FILTER_PROVIDER_NOZERODELTAS`].
pub const FILTER_SUPPRESS_BORING_POLL: u64 = 0x2000_0000;

/// Per-flow interface properties.
pub const IFNET_IS_LOCAL: u32 = 0x0800;

/// `nstat_msg_hdr`: context u64, type u32, length u16, flags u16.
pub const HEADER_LEN: usize = 16;
/// `nstat_msg_src_update` up to its descriptor: header, srcref, event flags, counts, provider.
pub const UPDATE_HEADER_LEN: usize = 152;
const UPDATE_SRCREF: usize = 16;
const UPDATE_RX_BYTES: usize = 40;
const UPDATE_TX_BYTES: usize = 56;
/// `counts.nstat_rxduplicatebytes`, a `u32`.
const UPDATE_RX_DUPLICATE_BYTES: usize = 112;
const UPDATE_PROVIDER: usize = 144;

/// The two descriptor layouts the providers use.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Descriptor {
    /// `nstat_tcp_descriptor`, also used by the userland TCP and QUIC providers.
    Tcp,
    /// `nstat_udp_descriptor`.
    Udp,
}

impl Descriptor {
    #[must_use]
    pub fn of_provider(provider: u32) -> Option<Self> {
        match provider {
            TCP_KERNEL | TCP_USERLAND | QUIC_USERLAND => Some(Self::Tcp),
            UDP_KERNEL | UDP_USERLAND => Some(Self::Udp),
            _ => None,
        }
    }

    /// Byte ranges of the fields the engine reads: pid, effective pid, process name, interface
    /// properties. Everything else in a descriptor (addresses, UUIDs, timestamps) is ignored.
    #[must_use]
    pub fn fields(self) -> DescriptorFields {
        match self {
            Self::Tcp => DescriptorFields {
                pid: 116,
                epid: 120,
                pname: 196..260,
                properties: 336,
            },
            Self::Udp => DescriptorFields {
                pid: 128,
                epid: 196,
                pname: 132..196,
                properties: 272,
            },
        }
    }
}

/// A provider's name, for messages.
#[must_use]
pub fn provider_name(provider: u32) -> String {
    match provider {
        TCP_KERNEL => "kernel TCP".into(),
        TCP_USERLAND => "userland TCP".into(),
        UDP_KERNEL => "kernel UDP".into(),
        UDP_USERLAND => "userland UDP".into(),
        QUIC_USERLAND => "userland QUIC".into(),
        other => format!("provider {other}"),
    }
}

#[derive(Debug, Clone)]
pub struct DescriptorFields {
    pub pid: usize,
    pub epid: usize,
    pub pname: std::ops::Range<usize>,
    pub properties: usize,
}

/// Descriptor sizes observed from the kernel, by macOS major version and provider. The protocol
/// is versioned only by struct size, so a size listed here is one seen on a real Mac, never one
/// read from the XNU source (macOS 26's source says 344 bytes for TCP; macOS 27 sends 360). The
/// userland providers sent nothing on the Mac that recorded macOS 27, so they are not listed.
pub const KNOWN_LAYOUTS: &[(u32, u32, usize)] = &[(27, TCP_KERNEL, 360), (27, UDP_KERNEL, 280)];

#[must_use]
pub fn known_size(macos_major: u32, provider: u32) -> Option<usize> {
    KNOWN_LAYOUTS
        .iter()
        .find(|&&(major, p, _)| major == macos_major && p == provider)
        .map(|&(_, _, size)| size)
}

/// One message from the kernel.
#[derive(Debug, Clone, Copy)]
pub struct Message<'a> {
    pub context: u64,
    pub kind: u32,
    pub flags: u16,
    pub bytes: &'a [u8],
}

/// Splits a datagram into its messages. Each message starts on an 8-byte boundary; a truncated
/// or malformed length ends the datagram.
pub fn messages(datagram: &[u8]) -> impl Iterator<Item = Message<'_>> {
    let mut offset = 0;
    std::iter::from_fn(move || {
        let rest = datagram.get(offset..)?;
        if rest.len() < HEADER_LEN {
            return None;
        }
        let len = usize::from(u16_at(rest, 12));
        if len < HEADER_LEN || len > rest.len() {
            return None;
        }
        let bytes = &rest[..len];
        offset += (len + 7) & !7;
        Some(Message {
            context: u64_at(bytes, 0),
            kind: u32_at(bytes, 8),
            flags: u16_at(bytes, 14),
            bytes,
        })
    })
}

/// A flow's counters and owner from a `SRC_UPDATE` message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FlowUpdate {
    pub srcref: u64,
    /// Lifetime bytes received and sent by the flow.
    pub rx: u64,
    pub tx: u64,
    /// Lifetime bytes received twice because of retransmission, counted in `rx` too.
    pub rx_duplicate: u32,
    pub pid: u32,
    pub epid: u32,
    pub pname: String,
    pub local: bool,
}

/// Why an update could not be read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UpdateError {
    /// Shorter than the update header.
    Truncated,
    /// From a provider the engine does not subscribe to; skipped.
    UnknownProvider(u32),
    /// The descriptor size is not in [`KNOWN_LAYOUTS`] for this macOS version.
    UnknownLayout { provider: u32, size: usize },
}

/// Reads a `SRC_UPDATE` or `SRC_EXTENDED_UPDATE` message. A plain update's descriptor must have
/// exactly the known size; an extended update appends extension items after it.
pub fn parse_update(message: &Message, macos_major: u32) -> Result<FlowUpdate, UpdateError> {
    let bytes = message.bytes;
    if bytes.len() < UPDATE_HEADER_LEN {
        return Err(UpdateError::Truncated);
    }
    let provider = u32_at(bytes, UPDATE_PROVIDER);
    let descriptor =
        Descriptor::of_provider(provider).ok_or(UpdateError::UnknownProvider(provider))?;
    let d = &bytes[UPDATE_HEADER_LEN..];
    let fits = match known_size(macos_major, provider) {
        Some(size) if message.kind == MSG_SRC_EXTENDED_UPDATE => d.len() >= size,
        Some(size) => d.len() == size,
        None => false,
    };
    if !fits {
        return Err(UpdateError::UnknownLayout {
            provider,
            size: d.len(),
        });
    }
    let f = descriptor.fields();
    Ok(FlowUpdate {
        srcref: u64_at(bytes, UPDATE_SRCREF),
        rx: u64_at(bytes, UPDATE_RX_BYTES),
        tx: u64_at(bytes, UPDATE_TX_BYTES),
        rx_duplicate: u32_at(bytes, UPDATE_RX_DUPLICATE_BYTES),
        pid: u32_at(d, f.pid),
        epid: u32_at(d, f.epid),
        pname: c_string(&d[f.pname]),
        local: u32_at(d, f.properties) & IFNET_IS_LOCAL != 0,
    })
}

/// The srcref of a `SRC_REMOVED` message.
#[must_use]
pub fn removed_srcref(message: &Message) -> Option<u64> {
    (message.bytes.len() >= UPDATE_SRCREF + 8).then(|| u64_at(message.bytes, UPDATE_SRCREF))
}

/// Filter for every subscription: flows on Wi‑Fi, wired and cellular interfaces only, so loopback,
/// AWDL and VPN tunnels never reach the engine; each flow reported once by an update when added.
pub const SUBSCRIPTION_FILTER: u64 =
    FILTER_ACCEPT_WIFI | FILTER_ACCEPT_WIRED | FILTER_ACCEPT_CELLULAR | FILTER_USE_UPDATE_FOR_ADD;

/// `nstat_msg_add_all_srcs`: subscribes to every flow of `provider`. The context is the provider.
#[must_use]
pub fn add_all_sources(provider: u32) -> Vec<u8> {
    let mut m = header(u64::from(provider), MSG_ADD_ALL_SRCS, 56, 0);
    m.extend_from_slice(&SUBSCRIPTION_FILTER.to_ne_bytes());
    m.extend_from_slice(&0u64.to_ne_bytes()); // events
    m.extend_from_slice(&provider.to_ne_bytes());
    m.extend_from_slice(&0i32.to_ne_bytes()); // target pid
    m.extend_from_slice(&[0u8; 16]); // target uuid
    m
}

/// `nstat_msg_query_src_req` for every source. The kernel answers in chunks; each chunk but the
/// last ends with a `SUCCESS` flagged [`HDR_FLAG_CONTINUATION`], answered by this same request.
#[must_use]
pub fn poll_all(context: u64) -> Vec<u8> {
    let mut m = header(context, MSG_GET_UPDATE, 24, HDR_FLAG_CONTINUATION);
    m.extend_from_slice(&SRC_REF_ALL.to_ne_bytes());
    m
}

fn header(context: u64, kind: u32, length: u16, flags: u16) -> Vec<u8> {
    let mut m = Vec::with_capacity(usize::from(length));
    m.extend_from_slice(&context.to_ne_bytes());
    m.extend_from_slice(&kind.to_ne_bytes());
    m.extend_from_slice(&length.to_ne_bytes());
    m.extend_from_slice(&flags.to_ne_bytes());
    m
}

pub(crate) fn u16_at(b: &[u8], o: usize) -> u16 {
    u16::from_ne_bytes(b[o..o + 2].try_into().expect("2 bytes"))
}
pub(crate) fn u32_at(b: &[u8], o: usize) -> u32 {
    u32::from_ne_bytes(b[o..o + 4].try_into().expect("4 bytes"))
}
pub(crate) fn u64_at(b: &[u8], o: usize) -> u64 {
    u64::from_ne_bytes(b[o..o + 8].try_into().expect("8 bytes"))
}

pub(crate) fn c_string(b: &[u8]) -> String {
    let end = b.iter().position(|&c| c == 0).unwrap_or(b.len());
    String::from_utf8_lossy(&b[..end]).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tcp_update(kind: u32, descriptor_len: usize) -> Vec<u8> {
        let mut m = vec![0u8; UPDATE_HEADER_LEN + descriptor_len];
        let len = u16::try_from(m.len()).unwrap();
        m[8..12].copy_from_slice(&kind.to_ne_bytes());
        m[12..14].copy_from_slice(&len.to_ne_bytes());
        m[UPDATE_PROVIDER..UPDATE_PROVIDER + 4].copy_from_slice(&TCP_KERNEL.to_ne_bytes());
        m
    }

    fn parse(bytes: &[u8]) -> Result<FlowUpdate, UpdateError> {
        parse_update(&messages(bytes).next().expect("one message"), 27)
    }

    #[test]
    fn subscription_counts_physical_interfaces_and_reports_idle_flows() {
        let filter = u64::from_ne_bytes(add_all_sources(TCP_KERNEL)[16..24].try_into().unwrap());
        for accepted in [
            FILTER_ACCEPT_WIFI,
            FILTER_ACCEPT_WIRED,
            FILTER_ACCEPT_CELLULAR,
        ] {
            assert_ne!(filter & accepted, 0, "{accepted:#x}");
        }
        assert_ne!(filter & FILTER_USE_UPDATE_FOR_ADD, 0);
        // Either flag would let a flow idle at startup skip its baseline (see the gotchas).
        assert_eq!(
            filter & (FILTER_PROVIDER_NOZERODELTAS | FILTER_SUPPRESS_BORING_POLL),
            0
        );
    }

    #[test]
    fn malformed_lengths_end_the_datagram() {
        let mut zero = vec![0u8; 32];
        zero[12..14].copy_from_slice(&0u16.to_ne_bytes());
        assert_eq!(messages(&zero).count(), 0);
        let mut overlong = vec![0u8; 32];
        overlong[12..14].copy_from_slice(&64u16.to_ne_bytes());
        assert_eq!(messages(&overlong).count(), 0);
    }

    #[test]
    fn update_shorter_than_its_header_is_skipped() {
        let mut m = vec![0u8; 100];
        m[8..12].copy_from_slice(&MSG_SRC_UPDATE.to_ne_bytes());
        m[12..14].copy_from_slice(&100u16.to_ne_bytes());
        assert_eq!(parse(&m), Err(UpdateError::Truncated));
    }

    #[test]
    fn unobserved_provider_has_an_unknown_layout_even_at_a_known_size() {
        let mut m = tcp_update(MSG_SRC_UPDATE, 360);
        m[UPDATE_PROVIDER..UPDATE_PROVIDER + 4].copy_from_slice(&TCP_USERLAND.to_ne_bytes());
        assert_eq!(
            parse(&m),
            Err(UpdateError::UnknownLayout {
                provider: TCP_USERLAND,
                size: 360
            })
        );
    }

    #[test]
    fn update_reads_the_received_duplicate_bytes() {
        let mut m = tcp_update(MSG_SRC_UPDATE, 360);
        m[112..116].copy_from_slice(&139_152u32.to_ne_bytes());
        assert_eq!(parse(&m).unwrap().rx_duplicate, 139_152);
    }

    #[test]
    fn update_without_a_descriptor_has_an_unknown_layout() {
        assert_eq!(
            parse(&tcp_update(MSG_SRC_UPDATE, 0)),
            Err(UpdateError::UnknownLayout {
                provider: TCP_KERNEL,
                size: 0
            })
        );
    }

    #[test]
    fn plain_update_needs_the_exact_descriptor_size() {
        assert!(parse(&tcp_update(MSG_SRC_UPDATE, 360)).is_ok());
        assert_eq!(
            parse(&tcp_update(MSG_SRC_UPDATE, 368)),
            Err(UpdateError::UnknownLayout {
                provider: TCP_KERNEL,
                size: 368
            })
        );
    }

    #[test]
    fn extended_update_carries_extensions_after_the_descriptor() {
        assert!(parse(&tcp_update(MSG_SRC_EXTENDED_UPDATE, 360 + 264)).is_ok());
        assert_eq!(
            parse(&tcp_update(MSG_SRC_EXTENDED_UPDATE, 352)),
            Err(UpdateError::UnknownLayout {
                provider: TCP_KERNEL,
                size: 352
            })
        );
    }

    #[test]
    fn removal_without_a_srcref_is_ignored() {
        let mut m = vec![0u8; 16];
        m[8..12].copy_from_slice(&MSG_SRC_REMOVED.to_ne_bytes());
        m[12..14].copy_from_slice(&16u16.to_ne_bytes());
        assert_eq!(removed_srcref(&messages(&m).next().unwrap()), None);
    }
}
