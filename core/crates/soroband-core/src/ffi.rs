//! C API for the app. `scripts/build-core.sh` turns this module into `soroband_core.h` with cbindgen.

use crate::meter::{Engine, Mode, SystemHost};
use std::ffi::c_char;
use std::sync::{Mutex, Once, PoisonError};
use std::thread;
use std::time::Duration;

/// The core's version as a NUL-terminated UTF-8 string.
///
/// The string is static: the caller must not free it.
#[unsafe(no_mangle)]
pub extern "C" fn soroband_core_version() -> *const c_char {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr().cast()
}

/// What the engine is doing, for [`SorobandEngineStatus::state`].
pub const SOROBAND_ENGINE_STARTING: u32 = 0;
/// Counting internet bytes per app.
pub const SOROBAND_ENGINE_PER_APP: u32 = 1;
/// A flow descriptor had an unknown layout; only interface totals are counted.
pub const SOROBAND_ENGINE_INTERFACE_ONLY: u32 = 2;
/// Stopped by an error from the system.
pub const SOROBAND_ENGINE_FAILED: u32 = 3;

/// The engine's health and totals since it started.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SorobandEngineStatus {
    /// One of the `SOROBAND_ENGINE_*` constants.
    pub state: u32,
    /// Flows currently tracked.
    pub flows: u32,
    /// Apps with internet bytes.
    pub apps: u32,
    /// Internet bytes summed over all apps.
    pub app_rx: u64,
    pub app_tx: u64,
    /// Bytes that crossed the internet interfaces.
    pub interface_rx: u64,
    pub interface_tx: u64,
}

static STATUS: Mutex<SorobandEngineStatus> = Mutex::new(SorobandEngineStatus {
    state: SOROBAND_ENGINE_STARTING,
    flows: 0,
    apps: 0,
    app_rx: 0,
    app_tx: 0,
    interface_rx: 0,
    interface_tx: 0,
});
static START: Once = Once::new();

/// Starts the meter engine on its own thread, polling every `interval_seconds` (at least 1).
/// Later calls do nothing.
#[unsafe(no_mangle)]
pub extern "C" fn soroband_engine_start(interval_seconds: u32) {
    let interval = Duration::from_secs(u64::from(interval_seconds.max(1)));
    START.call_once(|| {
        let spawned = thread::Builder::new()
            .name("soroband-meter".into())
            .stack_size(256 * 1024)
            .spawn(move || {
                if let Err(error) = meter(interval) {
                    eprintln!("soroband: meter engine stopped: {error}");
                }
                STATUS.lock().unwrap_or_else(PoisonError::into_inner).state =
                    SOROBAND_ENGINE_FAILED;
            });
        if spawned.is_err() {
            STATUS.lock().unwrap_or_else(PoisonError::into_inner).state = SOROBAND_ENGINE_FAILED;
        }
    });
}

/// The engine's latest status, updated after every poll.
#[unsafe(no_mangle)]
pub extern "C" fn soroband_engine_status() -> SorobandEngineStatus {
    *STATUS.lock().unwrap_or_else(PoisonError::into_inner)
}

fn meter(interval: Duration) -> std::io::Result<()> {
    let mut engine = Engine::start(SystemHost::connect()?)?;
    loop {
        engine.tick(interval)?;
        let snapshot = engine.snapshot();
        let total = snapshot.apps_total();
        *STATUS.lock().unwrap_or_else(PoisonError::into_inner) = SorobandEngineStatus {
            state: match snapshot.mode {
                Mode::PerApp => SOROBAND_ENGINE_PER_APP,
                Mode::InterfaceOnly { .. } => SOROBAND_ENGINE_INTERFACE_ONLY,
            },
            flows: u32::try_from(snapshot.flows).unwrap_or(u32::MAX),
            apps: u32::try_from(snapshot.apps.len()).unwrap_or(u32::MAX),
            app_rx: total.rx,
            app_tx: total.tx,
            interface_rx: snapshot.interfaces.rx,
            interface_tx: snapshot.interfaces.tx,
        };
    }
}

#[cfg(test)]
mod tests {
    use super::soroband_core_version;
    use std::ffi::CStr;

    /// The workspace version, read from `core/Cargo.toml` rather than from the compiled crate.
    fn workspace_version() -> String {
        let manifest = concat!(env!("CARGO_MANIFEST_DIR"), "/../../Cargo.toml");
        let text = std::fs::read_to_string(manifest).expect("read core/Cargo.toml");
        let package = text
            .split("[workspace.package]")
            .nth(1)
            .expect("[workspace.package] section");
        package
            .lines()
            .find_map(|line| line.trim().strip_prefix("version = "))
            .map(|value| value.trim_matches('"').to_owned())
            .expect("version in [workspace.package]")
    }

    #[test]
    fn engine_started_through_the_c_api_reports_its_first_poll() {
        use super::{
            SOROBAND_ENGINE_INTERFACE_ONLY, SOROBAND_ENGINE_PER_APP, SOROBAND_ENGINE_STARTING,
            soroband_engine_start, soroband_engine_status,
        };
        soroband_engine_start(1);
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while soroband_engine_status().state == SOROBAND_ENGINE_STARTING
            && std::time::Instant::now() < deadline
        {
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
        let status = soroband_engine_status();
        // On a macOS version not in the layout table the engine runs on interface totals alone
        // and tracks no flows.
        match status.state {
            SOROBAND_ENGINE_PER_APP => assert!(status.flows > 0, "{status:?}"),
            SOROBAND_ENGINE_INTERFACE_ONLY => assert_eq!(status.flows, 0, "{status:?}"),
            _ => panic!("the engine did not finish a poll: {status:?}"),
        }
    }

    #[test]
    fn c_api_returns_the_workspace_version() {
        // SAFETY: soroband_core_version returns a pointer to a static NUL-terminated string.
        let version = unsafe { CStr::from_ptr(soroband_core_version()) };
        assert_eq!(version.to_str().unwrap(), workspace_version());
    }
}
