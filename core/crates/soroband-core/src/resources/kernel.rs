//! The kernel's side of the resource meter: coalition and process reads, and the system gauges.
//!
//! `proc_listcoalitions` and `coalition_info_resource_usage` are exported by `libsystem_kernel`
//! but absent from the public SDK, so [`SystemResources`] looks them up at launch (`dlsym`) and
//! reports them missing instead of failing to link. Their buffers are larger than any layout the
//! kernel writes, so a kernel with a longer struct cannot write past them.

use super::{Gauges, ProcessUsage, RAW_WORDS, ResourceHost, Volume};
use std::ffi::{CStr, c_int, c_void};
use std::mem::{size_of, zeroed};

/// `proc_pidinfo` flavor that returns a process's coalition ids (`PROC_PIDCOALITIONINFO`).
const PROC_PIDCOALITIONINFO: c_int = 20;
/// `proc_listcoalitions` flavor listing one coalition type (`LISTCOALITIONS_SINGLE_TYPE`).
const LISTCOALITIONS_SINGLE_TYPE: c_int = 2;
/// The resource coalition type (`COALITION_TYPE_RESOURCE`), index 0 of a process's ids.
const COALITION_TYPE_RESOURCE: c_int = 0;
/// `RUSAGE_INFO_V6`.
const RUSAGE_INFO_V6: c_int = 6;

/// Words of `struct rusage_info_v6` after its UUID, by index: the ones the meter reads.
mod rusage {
    pub const USER_TIME: usize = 0;
    pub const SYSTEM_TIME: usize = 1;
    pub const PHYS_FOOTPRINT: usize = 7;
    pub const PROC_START_ABSTIME: usize = 8;
    pub const DISKIO_BYTESREAD: usize = 16;
    pub const DISKIO_BYTESWRITTEN: usize = 17;
    pub const BILLED_SYSTEM_TIME: usize = 25;
    pub const ENERGY_NJ: usize = 40;
}

/// `struct proc_pidcoalitioninfo`.
#[repr(C)]
#[derive(Default)]
struct PidCoalitionInfo {
    coalition_id: [u64; 2],
    reserved: [u64; 3],
}

/// `struct procinfo_coalinfo`, one entry of `proc_listcoalitions`.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
struct CoalitionEntry {
    id: u64,
    kind: u32,
    tasks: u32,
}

/// `struct rusage_info_v6`, with room to spare after the words the kernel writes.
#[repr(C)]
struct RusageV6 {
    uuid: [u8; 16],
    words: [u64; 64],
}

/// `struct xsw_usage` (`vm.swapusage`).
#[repr(C)]
#[derive(Default)]
struct SwapUsage {
    total: u64,
    available: u64,
    used: u64,
    page_size: u32,
    encrypted: u32,
}

type ListCoalitions = unsafe extern "C" fn(c_int, c_int, *mut c_void, c_int) -> c_int;
type CoalitionUsage = unsafe extern "C" fn(u64, *mut u64, libc::size_t) -> c_int;

/// The Mac's physical memory in bytes (`hw.memsize`).
#[must_use]
pub fn memory_total() -> Option<u64> {
    let mut bytes = 0u64;
    let mut len = size_of::<u64>();
    // SAFETY: `bytes` is writable for `len` bytes and the name is NUL-terminated.
    let status = unsafe {
        libc::sysctlbyname(
            c"hw.memsize".as_ptr(),
            (&raw mut bytes).cast(),
            &raw mut len,
            std::ptr::null_mut(),
            0,
        )
    };
    (status == 0).then_some(bytes)
}

/// The resource meter's [`ResourceHost`] on this Mac.
#[derive(Debug)]
pub struct SystemResources {
    list_coalitions: Option<ListCoalitions>,
    coalition_usage: Option<CoalitionUsage>,
    timebase: (u32, u32),
    host: libc::mach_port_t,
    pressure_mib: Vec<c_int>,
    page_size: u64,
    pids: Vec<c_int>,
    entries: Vec<CoalitionEntry>,
}

impl Default for SystemResources {
    fn default() -> Self {
        Self::new()
    }
}

impl SystemResources {
    /// Looks up the coalition calls; [`ResourceHost::coalition_ids`] answers `None` if either is
    /// missing.
    #[must_use]
    pub fn new() -> Self {
        Self::with_symbols(c"proc_listcoalitions", c"coalition_info_resource_usage")
    }

    /// As [`SystemResources::new`] with other symbol names, so a test can see a lookup fail.
    #[must_use]
    pub fn with_symbols(list: &CStr, usage: &CStr) -> Self {
        // SAFETY: `dlsym` with `RTLD_DEFAULT` and a NUL-terminated name only reads the name.
        let list = unsafe { libc::dlsym(libc::RTLD_DEFAULT, list.as_ptr()) };
        // SAFETY: as above.
        let usage = unsafe { libc::dlsym(libc::RTLD_DEFAULT, usage.as_ptr()) };
        #[allow(deprecated)] // libc points at the `mach2` crate, which adds nothing needed here
        let mut timebase = libc::mach_timebase_info { numer: 0, denom: 0 };
        // SAFETY: `timebase` is a valid out-pointer.
        #[allow(deprecated)]
        unsafe {
            libc::mach_timebase_info(&raw mut timebase)
        };
        let mut mib = vec![0; 8];
        let mut len = mib.len();
        // SAFETY: `mib` holds `len` ints and the name is NUL-terminated.
        let found = unsafe {
            libc::sysctlnametomib(
                c"kern.memorystatus_vm_pressure_level".as_ptr(),
                mib.as_mut_ptr(),
                &raw mut len,
            )
        } == 0;
        mib.truncate(if found { len } else { 0 });
        // SAFETY: `sysconf` has no preconditions.
        let page_size = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
        Self {
            // SAFETY: the symbols have these signatures in xnu's `libsystem_kernel`
            // (`proc_listcoalitions`, `coalition_info_resource_usage`).
            list_coalitions: (!list.is_null())
                .then(|| unsafe { std::mem::transmute::<*mut c_void, ListCoalitions>(list) }),
            // SAFETY: as above.
            coalition_usage: (!usage.is_null())
                .then(|| unsafe { std::mem::transmute::<*mut c_void, CoalitionUsage>(usage) }),
            #[allow(deprecated)]
            timebase: (timebase.numer, timebase.denom),
            // SAFETY: `mach_host_self` has no preconditions.
            #[allow(deprecated)]
            host: unsafe { libc::mach_host_self() },
            pressure_mib: mib,
            page_size: u64::try_from(page_size).unwrap_or(4096),
            // Grown to fit at the first read, and kept.
            pids: vec![0; 256],
            entries: vec![CoalitionEntry::default(); 64],
        }
    }
}

impl ResourceHost for SystemResources {
    fn now(&mut self) -> u64 {
        // SAFETY: no preconditions.
        #[allow(deprecated)]
        unsafe {
            libc::mach_absolute_time()
        }
    }

    fn timebase(&self) -> (u32, u32) {
        self.timebase
    }

    fn coalition_ids(&mut self) -> Option<Vec<u64>> {
        let list = self.list_coalitions?;
        self.coalition_usage?;
        loop {
            let size = c_int::try_from(self.entries.len() * size_of::<CoalitionEntry>()).ok()?;
            // SAFETY: `entries` is writable for `size` bytes.
            let bytes = unsafe {
                list(
                    LISTCOALITIONS_SINGLE_TYPE,
                    COALITION_TYPE_RESOURCE,
                    self.entries.as_mut_ptr().cast(),
                    size,
                )
            };
            let bytes = usize::try_from(bytes).ok()?;
            let count = bytes / size_of::<CoalitionEntry>();
            // A full buffer may have cut the list short: grow it and ask again.
            if count < self.entries.len() {
                return Some(self.entries[..count].iter().map(|e| e.id).collect());
            }
            let grown = self.entries.len() * 2;
            self.entries.resize(grown, CoalitionEntry::default());
        }
    }

    fn coalition_usage(&mut self, id: u64) -> Option<[u64; RAW_WORDS]> {
        let usage = self.coalition_usage?;
        let mut words = [0u64; RAW_WORDS];
        // SAFETY: `words` is writable for the size passed, which the kernel never exceeds.
        let status = unsafe { usage(id, words.as_mut_ptr(), size_of::<[u64; RAW_WORDS]>()) };
        (status == 0).then_some(words)
    }

    fn pids(&mut self) -> Vec<u32> {
        loop {
            let size = c_int::try_from(self.pids.len() * size_of::<c_int>()).unwrap_or(c_int::MAX);
            // SAFETY: `pids` is writable for `size` bytes.
            let count = unsafe { libc::proc_listallpids(self.pids.as_mut_ptr().cast(), size) };
            let count = usize::try_from(count).unwrap_or(0);
            if count < self.pids.len() {
                return self.pids[..count]
                    .iter()
                    .filter_map(|&p| u32::try_from(p).ok())
                    .collect();
            }
            let grown = self.pids.len() * 2;
            self.pids.resize(grown, 0);
        }
    }

    fn coalition_of(&mut self, pid: u32) -> Option<u64> {
        let pid = c_int::try_from(pid).ok()?;
        let mut info = PidCoalitionInfo::default();
        let size = size_of::<PidCoalitionInfo>();
        // SAFETY: `info` is writable for `size` bytes.
        let n = unsafe {
            libc::proc_pidinfo(
                pid,
                PROC_PIDCOALITIONINFO,
                0,
                (&raw mut info).cast(),
                c_int::try_from(size).ok()?,
            )
        };
        let id = info.coalition_id[COALITION_TYPE_RESOURCE as usize];
        (usize::try_from(n).ok() == Some(size) && id != 0).then_some(id)
    }

    fn process_usage(&mut self, pid: u32) -> Option<ProcessUsage> {
        let pid = c_int::try_from(pid).ok()?;
        // SAFETY: an all-zero `RusageV6` is valid.
        let mut info: RusageV6 = unsafe { zeroed() };
        // SAFETY: `info` is larger than `struct rusage_info_v6`, which the kernel writes.
        let status = unsafe { libc::proc_pid_rusage(pid, RUSAGE_INFO_V6, (&raw mut info).cast()) };
        if status != 0 {
            return None;
        }
        let w = &info.words;
        Some(ProcessUsage {
            cpu: w[rusage::USER_TIME] + w[rusage::SYSTEM_TIME],
            billed: w[rusage::BILLED_SYSTEM_TIME],
            read: w[rusage::DISKIO_BYTESREAD],
            written: w[rusage::DISKIO_BYTESWRITTEN],
            energy: w[rusage::ENERGY_NJ],
            footprint: w[rusage::PHYS_FOOTPRINT],
            start: w[rusage::PROC_START_ABSTIME],
        })
    }

    fn executable_path(&mut self, pid: u32) -> Option<String> {
        crate::meter::process::executable_path(pid)
    }

    fn gauges(&mut self) -> Gauges {
        // SAFETY: an all-zero `host_cpu_load_info` is valid.
        let mut cpu: libc::host_cpu_load_info = unsafe { zeroed() };
        let mut count = libc::HOST_CPU_LOAD_INFO_COUNT;
        // SAFETY: `cpu` is writable for `count` integers.
        let cpu_ok = unsafe {
            libc::host_statistics(
                self.host,
                libc::HOST_CPU_LOAD_INFO,
                (&raw mut cpu).cast(),
                &raw mut count,
            )
        } == libc::KERN_SUCCESS;
        // SAFETY: an all-zero `vm_statistics64` is valid.
        let mut vm: libc::vm_statistics64 = unsafe { zeroed() };
        let mut count = libc::HOST_VM_INFO64_COUNT;
        // SAFETY: `vm` is writable for `count` integers.
        let vm_ok = unsafe {
            libc::host_statistics64(
                self.host,
                libc::HOST_VM_INFO64,
                (&raw mut vm).cast(),
                &raw mut count,
            )
        } == libc::KERN_SUCCESS;
        let page = self.page_size;
        let pages = |n: u32| u64::from(n) * page;
        let mut swap = SwapUsage::default();
        let mut len = size_of::<SwapUsage>();
        // SAFETY: `swap` is writable for `len` bytes and the name is NUL-terminated.
        let swap_ok = unsafe {
            libc::sysctlbyname(
                c"vm.swapusage".as_ptr(),
                (&raw mut swap).cast(),
                &raw mut len,
                std::ptr::null_mut(),
                0,
            )
        } == 0;
        let mut pressure: c_int = 0;
        let mut len = size_of::<c_int>();
        // SAFETY: `pressure` is writable for `len` bytes; the mib came from `sysctlnametomib`.
        let pressure_ok = !self.pressure_mib.is_empty()
            && unsafe {
                libc::sysctl(
                    self.pressure_mib.as_mut_ptr(),
                    u32::try_from(self.pressure_mib.len()).unwrap_or(0),
                    (&raw mut pressure).cast(),
                    &raw mut len,
                    std::ptr::null_mut(),
                    0,
                )
            } == 0;
        Gauges {
            cpu_ticks: cpu_ok.then_some([
                u64::from(cpu.cpu_ticks[libc::CPU_STATE_USER as usize]),
                u64::from(cpu.cpu_ticks[libc::CPU_STATE_SYSTEM as usize]),
                u64::from(cpu.cpu_ticks[libc::CPU_STATE_IDLE as usize]),
                u64::from(cpu.cpu_ticks[libc::CPU_STATE_NICE as usize]),
            ]),
            // Activity Monitor's Memory Used: app memory, wired and compressed.
            memory_used: vm_ok.then(|| {
                pages(vm.internal_page_count.saturating_sub(vm.purgeable_count))
                    + pages(vm.wire_count)
                    + pages(vm.compressor_page_count)
            }),
            memory_compressed: vm_ok.then(|| pages(vm.compressor_page_count)),
            swap_used: swap_ok.then_some(swap.used),
            pressure: pressure_ok.then(|| u8::try_from(pressure).unwrap_or(u8::MAX)),
        }
    }

    fn volumes(&mut self) -> Vec<Volume> {
        // SAFETY: a null buffer asks only for the count.
        let count = unsafe { libc::getfsstat(std::ptr::null_mut(), 0, libc::MNT_NOWAIT) };
        let Ok(count) = usize::try_from(count) else {
            return Vec::new();
        };
        // SAFETY: an all-zero `statfs` is valid.
        let mut stats: Vec<libc::statfs> = vec![unsafe { zeroed() }; count + 4];
        let size = c_int::try_from(stats.len() * size_of::<libc::statfs>()).unwrap_or(c_int::MAX);
        // SAFETY: `stats` is writable for `size` bytes.
        let count = unsafe { libc::getfsstat(stats.as_mut_ptr(), size, libc::MNT_NOWAIT) };
        stats.truncate(usize::try_from(count).unwrap_or(0));
        stats
            .iter()
            // Local volumes a person sees in the Finder: not the system's hidden ones
            // (`/System/Volumes/*` carry `MNT_DONTBROWSE`).
            .filter(|s| s.f_flags & libc::MNT_LOCAL as u32 != 0)
            .filter(|s| s.f_flags & libc::MNT_DONTBROWSE as u32 == 0)
            .map(|s| {
                // SAFETY: `f_mntonname` is NUL-terminated by the kernel.
                let path = unsafe { CStr::from_ptr(s.f_mntonname.as_ptr()) };
                let block = u64::from(s.f_bsize);
                Volume {
                    path: path.to_string_lossy().into_owned(),
                    free: s.f_bavail * block,
                    size: s.f_blocks * block,
                }
            })
            .collect()
    }
}
