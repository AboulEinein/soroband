//! The real [`Host`]: a `PF_SYSTEM` control socket connected to `com.apple.network.statistics`.

use super::Host;
use super::interfaces::{self, InterfaceCounter};
use super::process;
use std::io;
use std::mem::size_of;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::sync::Arc;
use std::time::Instant;

const CTLIOCGINFO: libc::c_ulong = 0xC064_4E03;
const AF_SYS_CONTROL: u16 = 2;
const SYSPROTO_CONTROL: libc::c_int = 2;
const CONTROL_NAME: &[u8] = b"com.apple.network.statistics";
const RECEIVE_BUFFER: libc::c_int = 1 << 20;
const AF_SYSTEM: u8 = 32;
#[allow(clippy::cast_possible_truncation)] // 32 bytes
const SOCKADDR_CTL_SC_LEN: u8 = size_of::<SockaddrCtl>() as u8;
#[allow(clippy::cast_possible_truncation)]
const SOCKADDR_CTL_LEN: libc::socklen_t = size_of::<SockaddrCtl>() as libc::socklen_t;
#[allow(clippy::cast_possible_truncation)] // 4 bytes
const C_INT_LEN: libc::socklen_t = size_of::<libc::c_int>() as libc::socklen_t;

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

/// This Mac's kernel, processes and interfaces.
#[derive(Debug)]
pub struct SystemHost {
    socket: OwnedFd,
    macos_major: u32,
    /// Read end of the pipe a [`Waker`] writes to.
    wakeup: Option<OwnedFd>,
    /// Whether `recv` returns on a wakeup now ([`Host::set_wakeable`]); a wakeup that arrives
    /// while it is false waits in the pipe.
    wakeable: bool,
}

/// Cuts short a [`SystemHost`]'s wait in `recv`, from any thread.
#[derive(Debug, Clone)]
pub struct Waker(Arc<OwnedFd>);

impl Waker {
    /// Makes the host's current or next `recv` return as if its deadline had passed.
    pub fn wake(&self) {
        let byte = 1u8;
        // SAFETY: writes one byte from a valid buffer. A full pipe (EAGAIN) already holds a wakeup.
        unsafe { libc::write(self.0.as_raw_fd(), (&raw const byte).cast(), 1) };
    }
}

impl SystemHost {
    /// Connects to the kernel's network statistics control. Needs no privileges.
    pub fn connect() -> io::Result<Self> {
        // SAFETY: plain socket(2) call; the result is checked before use.
        let fd = unsafe { libc::socket(libc::PF_SYSTEM, libc::SOCK_DGRAM, SYSPROTO_CONTROL) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: `fd` is a new socket that nothing else owns.
        let socket = unsafe { OwnedFd::from_raw_fd(fd) };
        let mut info = CtlInfo {
            ctl_id: 0,
            ctl_name: [0; 96],
        };
        info.ctl_name[..CONTROL_NAME.len()].copy_from_slice(CONTROL_NAME);
        // SAFETY: CTLIOCGINFO reads and writes a `ctl_info`, which `info` is laid out as.
        if unsafe { libc::ioctl(fd, CTLIOCGINFO, &raw mut info) } < 0 {
            return Err(io::Error::last_os_error());
        }
        let addr = SockaddrCtl {
            sc_len: SOCKADDR_CTL_SC_LEN,
            sc_family: AF_SYSTEM,
            ss_sysaddr: AF_SYS_CONTROL,
            sc_id: info.ctl_id,
            sc_unit: 0,
            sc_reserved: [0; 5],
        };
        // SAFETY: `addr` is a valid `sockaddr_ctl` of the length passed.
        let rc = unsafe { libc::connect(fd, (&raw const addr).cast(), SOCKADDR_CTL_LEN) };
        if rc < 0 {
            return Err(io::Error::last_os_error());
        }
        // A large receive buffer keeps a poll reply from overflowing it; failure only risks that.
        let size = RECEIVE_BUFFER;
        // SAFETY: the option value is a c_int of the length passed.
        unsafe {
            libc::setsockopt(
                fd,
                libc::SOL_SOCKET,
                libc::SO_RCVBUF,
                (&raw const size).cast(),
                C_INT_LEN,
            );
        }
        Ok(Self {
            socket,
            macos_major: macos_major()?,
            wakeup: None,
            wakeable: false,
        })
    }

    /// A [`Waker`] for this host. While the engine waits between polls, a wakeup makes `recv`
    /// return `None` once the socket has no datagram waiting, so the tick polls at once instead
    /// of at the end of its interval.
    pub fn waker(&mut self) -> io::Result<Waker> {
        let mut fds = [0; 2];
        // SAFETY: `fds` has room for the two descriptors pipe(2) returns.
        if unsafe { libc::pipe(fds.as_mut_ptr()) } < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: pipe(2) returned two new descriptors that nothing else owns.
        let (read, write) = unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
        for fd in [&read, &write] {
            // SAFETY: fcntl on a descriptor this function owns.
            unsafe {
                let flags = libc::fcntl(fd.as_raw_fd(), libc::F_GETFL);
                libc::fcntl(fd.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK);
                libc::fcntl(fd.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC);
            }
        }
        self.wakeup = Some(read);
        Ok(Waker(Arc::new(write)))
    }

    /// Empties the wakeup pipe.
    fn drain_wakeups(&self) {
        let Some(wakeup) = &self.wakeup else { return };
        let mut buf = [0u8; 64];
        // SAFETY: `buf` is writable for its length; the descriptor is non-blocking.
        while unsafe { libc::read(wakeup.as_raw_fd(), buf.as_mut_ptr().cast(), buf.len()) } > 0 {}
    }
}

impl Host for SystemHost {
    fn macos_major(&self) -> u32 {
        self.macos_major
    }

    fn send(&mut self, message: &[u8]) -> io::Result<()> {
        // SAFETY: `message` is readable for its length.
        let n = unsafe {
            libc::send(
                self.socket.as_raw_fd(),
                message.as_ptr().cast(),
                message.len(),
                0,
            )
        };
        if n < 0 {
            Err(io::Error::last_os_error())
        } else {
            Ok(())
        }
    }

    fn recv(&mut self, buf: &mut [u8], deadline: Instant) -> io::Result<Option<usize>> {
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return Ok(None);
            }
            let mut pfds = [self.socket.as_raw_fd(), -1].map(|fd| libc::pollfd {
                fd,
                events: libc::POLLIN,
                revents: 0,
            });
            if let Some(wakeup) = self.wakeup.as_ref().filter(|_| self.wakeable) {
                pfds[1].fd = wakeup.as_raw_fd();
            }
            let millis = i32::try_from(left.as_millis().max(1)).unwrap_or(i32::MAX);
            // SAFETY: two valid pollfds; poll(2) ignores the one with a negative descriptor.
            let ready = unsafe { libc::poll(pfds.as_mut_ptr(), 2, millis) };
            if ready < 0 {
                let error = io::Error::last_os_error();
                if error.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(error);
            }
            if ready == 0 {
                return Ok(None);
            }
            if pfds[0].revents == 0 {
                // Only the wakeup pipe is ready.
                self.drain_wakeups();
                return Ok(None);
            }
            // SAFETY: `buf` is writable for its length.
            let n = unsafe {
                libc::recv(
                    self.socket.as_raw_fd(),
                    buf.as_mut_ptr().cast(),
                    buf.len(),
                    0,
                )
            };
            if n < 0 {
                let error = io::Error::last_os_error();
                // ENOBUFS: the kernel dropped messages because the buffer was full; keep reading.
                if matches!(error.raw_os_error(), Some(libc::EINTR | libc::ENOBUFS)) {
                    continue;
                }
                return Err(error);
            }
            return Ok(usize::try_from(n).ok());
        }
    }

    fn set_wakeable(&mut self, wakeable: bool) {
        self.wakeable = wakeable;
    }

    fn executable_path(&mut self, pid: u32) -> Option<String> {
        process::executable_path(pid)
    }

    fn interface_counters(&mut self) -> io::Result<Vec<InterfaceCounter>> {
        interfaces::read_counters()
    }
}

/// The major version from `kern.osproductversion` ("27.0.1" gives 27).
fn macos_major() -> io::Result<u32> {
    let mut buf = [0u8; 32];
    let mut len = buf.len();
    // SAFETY: `buf` is writable for `len` bytes and the name is NUL-terminated.
    let rc = unsafe {
        libc::sysctlbyname(
            c"kern.osproductversion".as_ptr(),
            buf.as_mut_ptr().cast(),
            &raw mut len,
            std::ptr::null_mut(),
            0,
        )
    };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    let version = super::ntstat::c_string(&buf[..len]);
    version
        .split('.')
        .next()
        .and_then(|major| major.parse().ok())
        .ok_or_else(|| io::Error::other(format!("unreadable macOS version {version:?}")))
}

#[cfg(test)]
mod tests {
    #[test]
    fn macos_major_matches_sw_vers() {
        let out = std::process::Command::new("sw_vers")
            .arg("-productVersion")
            .output()
            .unwrap();
        let text = String::from_utf8(out.stdout).unwrap();
        let expected: u32 = text.trim().split('.').next().unwrap().parse().unwrap();
        assert_eq!(super::macos_major().unwrap(), expected);
    }
}
