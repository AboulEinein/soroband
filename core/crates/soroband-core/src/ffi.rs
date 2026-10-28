//! C API for the app. `scripts/build-core.sh` turns this module into `soroband_core.h` with cbindgen.

use crate::day;
use crate::meter::{Engine, Mode, SystemHost, Waker};
use crate::service::{self, Command, Service};
use crate::settings;
use crate::store::{NetworkKind, Store};
use std::ffi::{CStr, c_char};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex, Once, OnceLock, PoisonError};
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
    /// The network bytes are booked to: an id from [`soroband_network_changed`], or 0 when none is
    /// identified (before the app named one, or after [`soroband_network_unidentified`]).
    pub network_id: i64,
    /// Unix time today started, and the reset hour that set it.
    pub today_start: i64,
    pub reset_hour: u32,
    /// Today on the current network: summed over its apps, and crossed its interfaces.
    pub today_network_app_rx: u64,
    pub today_network_app_tx: u64,
    pub today_network_interface_rx: u64,
    pub today_network_interface_tx: u64,
    /// Today on every network.
    pub today_app_rx: u64,
    pub today_app_tx: u64,
    pub today_interface_rx: u64,
    pub today_interface_tx: u64,
}

static STATUS: Mutex<SorobandEngineStatus> = Mutex::new(SorobandEngineStatus {
    state: SOROBAND_ENGINE_STARTING,
    flows: 0,
    apps: 0,
    app_rx: 0,
    app_tx: 0,
    interface_rx: 0,
    interface_tx: 0,
    network_id: 0,
    today_start: 0,
    reset_hour: 0,
    today_network_app_rx: 0,
    today_network_app_tx: 0,
    today_network_interface_rx: 0,
    today_network_interface_tx: 0,
    today_app_rx: 0,
    today_app_tx: 0,
    today_interface_rx: 0,
    today_interface_tx: 0,
});
static START: Once = Once::new();
static RUNNING: OnceLock<Running> = OnceLock::new();

/// What the app's calls share with the engine thread.
struct Running {
    store: Arc<Mutex<Store>>,
    commands: Mutex<Vec<Command>>,
    /// Set once the engine has started; a command sent before then waits for the first poll.
    waker: Mutex<Option<Waker>>,
    stopped: Mutex<bool>,
    stopped_changed: Condvar,
}

impl Running {
    fn send(&self, command: Command) {
        lock(&self.commands).push(command);
        if let Some(waker) = &*lock(&self.waker) {
            waker.wake();
        }
    }
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// File name of the usage database in the data directory.
pub const DATABASE_FILE: &str = "usage.sqlite";

/// Starts the meter engine on its own thread, polling every `interval_seconds` (at least 1), and
/// stores its usage and reads its settings in `data_dir` (created if missing). Later calls do
/// nothing. Returns false when the usage database cannot be opened; the engine does not run then.
///
/// # Safety
/// `data_dir` must be a valid NUL-terminated UTF-8 path.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn soroband_engine_start(
    interval_seconds: u32,
    data_dir: *const c_char,
) -> bool {
    let interval = Duration::from_secs(u64::from(interval_seconds.max(1)));
    // SAFETY: the caller passes a valid NUL-terminated string.
    let data_dir = PathBuf::from(
        unsafe { CStr::from_ptr(data_dir) }
            .to_string_lossy()
            .as_ref(),
    );
    START.call_once(|| match open_store(&data_dir) {
        Ok(store) => {
            let running = RUNNING.get_or_init(|| Running {
                store: Arc::new(Mutex::new(store)),
                commands: Mutex::new(Vec::new()),
                waker: Mutex::new(None),
                stopped: Mutex::new(false),
                stopped_changed: Condvar::new(),
            });
            let settings_path = data_dir.join(settings::FILE_NAME);
            let spawned = thread::Builder::new()
                .name("soroband-meter".into())
                .stack_size(256 * 1024)
                .spawn(move || {
                    if let Err(error) = meter(interval, running, settings_path) {
                        eprintln!("soroband: meter engine stopped: {error}");
                        lock(&STATUS).state = SOROBAND_ENGINE_FAILED;
                    }
                    *lock(&running.stopped) = true;
                    running.stopped_changed.notify_all();
                });
            if spawned.is_err() {
                lock(&STATUS).state = SOROBAND_ENGINE_FAILED;
            }
        }
        Err(error) => {
            eprintln!(
                "soroband: cannot open the usage database in {}: {error}",
                data_dir.display()
            );
            lock(&STATUS).state = SOROBAND_ENGINE_FAILED;
        }
    });
    RUNNING.get().is_some()
}

fn open_store(data_dir: &Path) -> Result<Store, service::Error> {
    std::fs::create_dir_all(data_dir)?;
    Ok(Store::open(&data_dir.join(DATABASE_FILE))?)
}

/// Polls once more, writes everything to the database and stops the engine. Waits up to
/// `timeout_ms` for the write; call it when the app quits.
#[unsafe(no_mangle)]
pub extern "C" fn soroband_engine_stop(timeout_ms: u32) {
    let Some(running) = RUNNING.get() else { return };
    running.send(Command::Stop);
    let stopped = lock(&running.stopped);
    let _ = running.stopped_changed.wait_timeout_while(
        stopped,
        Duration::from_millis(u64::from(timeout_ms)),
        |s| !*s,
    );
}

/// The network the app identified, and the name and kind the user sees for it.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct SorobandNetwork {
    /// Stable id: the same `key` always gives the same id.
    pub id: i64,
    /// NUL-terminated UTF-8, cut to fit.
    pub name: [c_char; 256],
    /// "wifi", "ethernet" or "hotspot", NUL-terminated.
    pub kind: [c_char; 16],
}

/// Tells the engine the Mac moved to the network identified by `key`. It polls at once, books what
/// moved so far to the previous network, writes it, and books to this one from then on.
///
/// A network seen for the first time is added with `name` and `kind`; a known one keeps its stored
/// name and kind, which `out` receives. Returns false (and leaves `out` alone) when the engine was
/// not started, `kind` is not "wifi", "ethernet" or "hotspot", or the database fails.
///
/// # Safety
/// `key`, `name` and `kind` must be valid NUL-terminated strings, and `out` valid for writing.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn soroband_network_changed(
    key: *const c_char,
    name: *const c_char,
    kind: *const c_char,
    out: *mut SorobandNetwork,
) -> bool {
    let Some(running) = RUNNING.get() else {
        return false;
    };
    // SAFETY: the caller passes valid NUL-terminated strings.
    let (key, name, kind) = unsafe { (text(key), text(name), text(kind)) };
    let Some(kind) = NetworkKind::parse(&kind) else {
        return false;
    };
    let network = match lock(&running.store).join_network(&key, &name, kind) {
        Ok(network) => network,
        Err(error) => {
            eprintln!("soroband: cannot record network {key:?}: {error}");
            return false;
        }
    };
    running.send(Command::Network(network.id));
    // SAFETY: the caller passes a pointer valid for writing.
    unsafe {
        out.write(SorobandNetwork::new(
            network.id,
            &network.name,
            network.kind,
        ));
    }
    true
}

/// Tells the engine the Mac is on a network the app cannot identify yet. It polls at once, books
/// what moved so far to the previous network, and books to no network (id 0) until the next
/// [`soroband_network_changed`].
#[unsafe(no_mangle)]
pub extern "C" fn soroband_network_unidentified() {
    if let Some(running) = RUNNING.get() {
        running.send(Command::Network(0));
    }
}

/// Renames network `id` and sets its kind, as the user chose. Returns false when there is no such
/// network, the engine was not started, or `kind` is not valid.
///
/// # Safety
/// `name` and `kind` must be valid NUL-terminated strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn soroband_network_update(
    id: i64,
    name: *const c_char,
    kind: *const c_char,
) -> bool {
    let Some(running) = RUNNING.get() else {
        return false;
    };
    // SAFETY: the caller passes valid NUL-terminated strings.
    let (name, kind) = unsafe { (text(name), text(kind)) };
    let Some(kind) = NetworkKind::parse(&kind) else {
        return false;
    };
    lock(&running.store)
        .update_network(id, &name, kind)
        .unwrap_or_else(|error| {
            eprintln!("soroband: cannot update network {id}: {error}");
            false
        })
}

/// Rereads the settings file; call when `soroband config set` posts its notification.
#[unsafe(no_mangle)]
pub extern "C" fn soroband_settings_reload() {
    if let Some(running) = RUNNING.get() {
        running.send(Command::ReloadSettings);
    }
}

impl SorobandNetwork {
    fn new(id: i64, name: &str, kind: NetworkKind) -> Self {
        let mut network = Self {
            id,
            name: [0; 256],
            kind: [0; 16],
        };
        copy_c_string(name, &mut network.name);
        copy_c_string(kind.as_str(), &mut network.kind);
        network
    }
}

/// Copies `text` into `out` with a NUL, cut at a character boundary to fit.
fn copy_c_string(text: &str, out: &mut [c_char]) {
    let mut end = text.len().min(out.len() - 1);
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    for (slot, &byte) in out.iter_mut().zip(&text.as_bytes()[..end]) {
        *slot = c_char::from_ne_bytes([byte]);
    }
    out[end] = 0;
}

/// # Safety
/// `pointer` must be a valid NUL-terminated string.
unsafe fn text(pointer: *const c_char) -> String {
    // SAFETY: as the caller promises.
    unsafe { CStr::from_ptr(pointer) }
        .to_string_lossy()
        .into_owned()
}

/// The engine's latest status, updated after every poll.
#[unsafe(no_mangle)]
pub extern "C" fn soroband_engine_status() -> SorobandEngineStatus {
    *lock(&STATUS)
}

fn meter(
    interval: Duration,
    running: &Running,
    settings_path: PathBuf,
) -> Result<(), service::Error> {
    let mut host = SystemHost::connect()?;
    let waker = host.waker()?;
    let engine = Engine::start(host)?;
    *lock(&running.waker) = Some(waker);
    let mut service = Service::new(
        engine,
        Arc::clone(&running.store),
        settings_path,
        day::local_offset,
        day::now(),
    )?;
    loop {
        // Commands sent during the last tick cut its wait short, so the tick has already polled:
        // what moved before a network change is booked to the previous network.
        let commands = std::mem::take(&mut *lock(&running.commands));
        for command in &commands {
            let applied = service.apply(command, day::now());
            if *command == Command::Stop {
                if let Err(error) = applied {
                    eprintln!("soroband: the last usage was not written: {error}");
                }
                return Ok(());
            }
            outlive_database_errors(applied.map(drop))?;
        }
        publish(&service);
        outlive_database_errors(service.tick(interval, day::now()))?;
    }
}

/// A failed write loses nothing (the service keeps the rows for the next write) and must not stop
/// metering, so database errors are logged and the loop goes on. Errors from the kernel socket
/// stop it.
fn outlive_database_errors(result: Result<(), service::Error>) -> Result<(), service::Error> {
    match result {
        Err(service::Error::Store(error)) => {
            eprintln!("soroband: usage database: {error}; retrying at the next write");
            Ok(())
        }
        other => other,
    }
}

fn publish(service: &Service<SystemHost>) {
    let snapshot = service.engine().snapshot();
    let total = snapshot.apps_total();
    let today = service.today();
    *lock(&STATUS) = SorobandEngineStatus {
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
        network_id: today.network.network,
        today_start: today.start,
        reset_hour: u32::from(today.reset_hour),
        today_network_app_rx: today.network.apps.rx,
        today_network_app_tx: today.network.apps.tx,
        today_network_interface_rx: today.network.interfaces.rx,
        today_network_interface_tx: today.network.interfaces.tx,
        today_app_rx: today.all.apps.rx,
        today_app_tx: today.all.apps.tx,
        today_interface_rx: today.all.interfaces.rx,
        today_interface_tx: today.all.interfaces.tx,
    };
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

    /// The whole C API in one test, because the engine is started once per process.
    #[test]
    fn engine_run_through_the_c_api_books_to_the_network_the_app_names() {
        use super::{
            DATABASE_FILE, SOROBAND_ENGINE_INTERFACE_ONLY, SOROBAND_ENGINE_PER_APP,
            SOROBAND_ENGINE_STARTING, SorobandNetwork, soroband_engine_start,
            soroband_engine_status, soroband_engine_stop, soroband_network_changed,
            soroband_network_unidentified, soroband_network_update, soroband_settings_reload,
        };
        use crate::store::{NetworkKind, Store};
        use std::ffi::CString;
        use std::time::{Duration, Instant};

        let dir = std::env::temp_dir().join(format!("soroband-ffi-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let dir_c = CString::new(dir.to_str().unwrap()).unwrap();
        // SAFETY: a valid NUL-terminated path.
        assert!(unsafe { soroband_engine_start(1, dir_c.as_ptr()) });

        let wait_for = |what: &str, done: &dyn Fn() -> bool| {
            let deadline = Instant::now() + Duration::from_secs(10);
            while !done() {
                assert!(Instant::now() < deadline, "timed out waiting for {what}");
                std::thread::sleep(Duration::from_millis(50));
            }
        };
        wait_for("the first poll", &|| {
            soroband_engine_status().state != SOROBAND_ENGINE_STARTING
        });
        let status = soroband_engine_status();
        // On a macOS version not in the layout table the engine runs on interface totals alone
        // and tracks no flows.
        match status.state {
            SOROBAND_ENGINE_PER_APP => assert!(status.flows > 0, "{status:?}"),
            SOROBAND_ENGINE_INTERFACE_ONLY => assert_eq!(status.flows, 0, "{status:?}"),
            _ => panic!("the engine did not finish a poll: {status:?}"),
        }
        assert_eq!(status.network_id, 0, "no network named yet");

        let changed = |key: &str, name: &str, kind: &str| {
            let (key, name, kind) = (
                CString::new(key).unwrap(),
                CString::new(name).unwrap(),
                CString::new(kind).unwrap(),
            );
            let mut out = SorobandNetwork::new(0, "", NetworkKind::Wifi);
            // SAFETY: valid strings and a writable output.
            let ok = unsafe {
                soroband_network_changed(key.as_ptr(), name.as_ptr(), kind.as_ptr(), &raw mut out)
            };
            ok.then(|| {
                // SAFETY: `name` holds a NUL-terminated string.
                let name = unsafe { CStr::from_ptr(out.name.as_ptr()) };
                (out.id, name.to_str().unwrap().to_owned())
            })
        };
        assert_eq!(changed("wifi:Office", "Office", "satellite"), None);
        let (office, name) = changed("wifi:Office", "Office", "wifi").unwrap();
        assert_eq!(name, "Office");
        // The engine wakes, polls and switches well before its next 1 s tick would end.
        wait_for("the switch", &|| {
            soroband_engine_status().network_id == office
        });

        let renamed = CString::new("Office 4th floor").unwrap();
        // SAFETY: valid strings.
        assert!(unsafe { soroband_network_update(office, renamed.as_ptr(), c"hotspot".as_ptr()) });
        // A known network keeps the name the user gave it.
        assert_eq!(
            changed("wifi:Office", "Office", "wifi"),
            Some((office, "Office 4th floor".to_owned()))
        );
        // A network with no stable key yet: booked to no network.
        soroband_network_unidentified();
        wait_for("no network", &|| soroband_engine_status().network_id == 0);
        let (cafe, _) = changed("wifi:Cafe", "Cafe", "wifi").unwrap();
        assert_ne!(cafe, office);
        wait_for("the second switch", &|| {
            soroband_engine_status().network_id == cafe
        });

        // `soroband config set reset_hour 7`, then the notification.
        std::fs::write(dir.join(crate::settings::FILE_NAME), r#"{"reset_hour": 7}"#).unwrap();
        soroband_settings_reload();
        wait_for("the reset hour", &|| {
            soroband_engine_status().reset_hour == 7
        });

        // Traffic of its own, so the polls book interface bytes on Cafe that no network change
        // has written yet, on any Mac.
        let download = std::process::Command::new("/usr/bin/curl")
            .args([
                "-sS",
                "-o",
                "/dev/null",
                "https://speed.cloudflare.com/__down?bytes=200000",
            ])
            .status()
            .unwrap();
        assert!(download.success(), "the download failed: {download}");
        std::thread::sleep(Duration::from_millis(1_500));
        let booked = soroband_engine_status();
        soroband_engine_stop(5_000);
        let store = Store::open_read_only(&dir.join(DATABASE_FILE)).unwrap();
        let networks = store.networks().unwrap();
        assert_eq!(networks.len(), 2);
        assert_eq!(networks[0].kind, NetworkKind::Hotspot);
        // Stopping wrote everything booked, including the final poll's bytes.
        let stored = store.network_totals(booked.today_start).unwrap();
        let stored_rx: u64 = stored.iter().map(|t| t.interfaces.rx).sum();
        assert!(booked.today_interface_rx >= 200_000, "{booked:?}");
        assert!(
            stored_rx >= booked.today_interface_rx,
            "stored {stored_rx}, booked {}",
            booked.today_interface_rx
        );
    }

    #[test]
    fn database_errors_do_not_stop_the_engine_and_socket_errors_do() {
        use super::outlive_database_errors;
        use crate::service::Error;
        let database = Error::Store(rusqlite::Error::InvalidQuery);
        assert!(outlive_database_errors(Err(database)).is_ok());
        let socket = Error::Io(std::io::Error::other("socket closed"));
        assert!(outlive_database_errors(Err(socket)).is_err());
    }

    #[test]
    fn long_names_are_cut_at_a_character_boundary() {
        use super::copy_c_string;
        let mut out = [1 as std::ffi::c_char; 6];
        // "Café" is 5 bytes; "Cafés" would be 6 and leave no room for the NUL.
        copy_c_string("Cafés", &mut out);
        // SAFETY: `out` is NUL-terminated.
        let cut = unsafe { CStr::from_ptr(out.as_ptr()) };
        assert_eq!(cut.to_str().unwrap(), "Café");
        // With 5 slots the cut at byte 4 would split "é"; the name ends before it.
        let mut out = [1 as std::ffi::c_char; 5];
        copy_c_string("Café", &mut out);
        // SAFETY: `out` is NUL-terminated.
        let cut = unsafe { CStr::from_ptr(out.as_ptr()) };
        assert_eq!(cut.to_str().unwrap(), "Caf");
    }

    #[test]
    fn c_api_returns_the_workspace_version() {
        // SAFETY: soroband_core_version returns a pointer to a static NUL-terminated string.
        let version = unsafe { CStr::from_ptr(soroband_core_version()) };
        assert_eq!(version.to_str().unwrap(), workspace_version());
    }
}
