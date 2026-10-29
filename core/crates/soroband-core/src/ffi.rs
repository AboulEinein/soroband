//! C API for the app. `scripts/build-core.sh` turns this module into `soroband_core.h` with cbindgen.

use crate::check::Verdict;
use crate::day;
use crate::history;
use crate::meter::{Bytes, Engine, Mode, SystemHost, Waker};
use crate::service::{self, Command, Service};
use crate::settings::{self, Settings};
use crate::store::{NetworkKind, Store};
use serde_json::{Value, json};
use std::ffi::{CStr, CString, c_char};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, Once, OnceLock, PoisonError};
use std::thread;
use std::time::{Duration, Instant};

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

/// The self-check's verdict, for [`SorobandEngineStatus::check`]: nothing wrong seen.
pub const SOROBAND_CHECK_OK: u32 = 0;
/// Two 10-minute windows in a row with at least 10 MB credited too little to apps.
pub const SOROBAND_CHECK_DEGRADED: u32 = 1;
/// Apps summed to more than crossed the interfaces.
pub const SOROBAND_CHECK_OVERCOUNT: u32 = 2;

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
    /// Bytes per second across the interfaces between the last two polls.
    pub speed_rx: u64,
    pub speed_tx: u64,
    /// One of the `SOROBAND_CHECK_*` constants ([`crate::check`]).
    pub check: u32,
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
    speed_rx: 0,
    speed_tx: 0,
    check: SOROBAND_CHECK_OK,
});
static START: Once = Once::new();
/// The usage database, set by [`soroband_engine_start`] or [`soroband_database_open`]. History and
/// the network list open it read-only for each read.
static DATABASE: OnceLock<PathBuf> = OnceLock::new();
static RUNNING: OnceLock<Running> = OnceLock::new();
/// Set while the popover is open ([`soroband_engine_live`]).
static LIVE: AtomicBool = AtomicBool::new(false);
/// Today's networks and apps as JSON, published after each poll while [`LIVE`] is set.
static TODAY: Mutex<String> = Mutex::new(String::new());
static ON_POLL: Mutex<Option<extern "C" fn()>> = Mutex::new(None);

/// Seconds between polls while the popover is open, for its live speed.
const LIVE_INTERVAL: Duration = Duration::from_secs(1);

/// What the app's calls share with the engine thread.
struct Running {
    store: Arc<Mutex<Store>>,
    settings_path: PathBuf,
    commands: Mutex<Vec<Command>>,
    /// Set once the engine has started; a command sent before then waits for the first poll.
    waker: Mutex<Option<Waker>>,
    stopped: Mutex<bool>,
    stopped_changed: Condvar,
}

impl Running {
    fn send(&self, command: Command) {
        lock(&self.commands).push(command);
        self.wake();
    }

    fn wake(&self) {
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
            let _ = DATABASE.set(data_dir.join(DATABASE_FILE));
            let settings_path = data_dir.join(settings::FILE_NAME);
            let running = RUNNING.get_or_init(|| Running {
                store: Arc::new(Mutex::new(store)),
                settings_path: settings_path.clone(),
                commands: Mutex::new(Vec::new()),
                waker: Mutex::new(None),
                stopped: Mutex::new(false),
                stopped_changed: Condvar::new(),
            });
            let spawned = thread::Builder::new()
                .name("soroband-meter".into())
                .stack_size(256 * 1024)
                .spawn(move || {
                    if let Err(error) = meter(interval, running, settings_path) {
                        eprintln!("soroband: meter engine stopped: {error}");
                        fail();
                    }
                    *lock(&running.stopped) = true;
                    running.stopped_changed.notify_all();
                });
            if spawned.is_err() {
                fail();
            }
        }
        Err(error) => {
            eprintln!(
                "soroband: cannot open the usage database in {}: {error}",
                data_dir.display()
            );
            fail();
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
/// `former_key`, when not null, is the key the app knew this network by until now, named
/// `former_name` by default ([`Store::join_network_known_as`]): that network becomes this one,
/// its history with it.
///
/// # Safety
/// `key`, `name` and `kind` must be valid NUL-terminated strings, `former_key` and `former_name`
/// null or valid NUL-terminated strings, and `out` valid for writing.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn soroband_network_changed(
    key: *const c_char,
    name: *const c_char,
    kind: *const c_char,
    former_key: *const c_char,
    former_name: *const c_char,
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
    let joined = if former_key.is_null() || former_name.is_null() {
        lock(&running.store)
            .join_network(&key, &name, kind)
            .map(|network| (network, None))
    } else {
        // SAFETY: not null, so valid NUL-terminated strings.
        let (former_key, former_name) = unsafe { (text(former_key), text(former_name)) };
        lock(&running.store).join_network_known_as(&key, &name, kind, &former_key, &former_name)
    };
    let (network, merge) = match joined {
        Ok(joined) => joined,
        Err(error) => {
            eprintln!("soroband: cannot record network {key:?}: {error}");
            return false;
        }
    };
    running.send(Command::Network(network.id));
    if let Some(from) = merge {
        running.send(Command::Merge {
            from,
            into: network.id,
        });
    }
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

/// While `live` is true (the popover is open) the engine polls every second, for the live speed,
/// and publishes today's networks and apps for [`soroband_today_json`]; it polls at once when it
/// turns on. While false it polls at the interval it started with and publishes no lists.
#[unsafe(no_mangle)]
pub extern "C" fn soroband_engine_live(live: bool) {
    {
        // Under the lock, so a poll publishing at this moment sees the change before it stores.
        let mut today = lock(&TODAY);
        LIVE.store(live, Ordering::Relaxed);
        if !live {
            today.clear();
        }
    }
    if let Some(running) = RUNNING.get() {
        running.wake();
    }
}

/// Calls `callback` on the engine's thread after each poll's status is published, and once when
/// the engine stops on an error; `None` stops the calls. The callback must return quickly, for
/// example by scheduling work elsewhere.
#[unsafe(no_mangle)]
pub extern "C" fn soroband_engine_on_poll(callback: Option<extern "C" fn()>) {
    *lock(&ON_POLL) = callback;
}

/// Today's usage as of the last poll, as JSON:
///
/// ```json
/// {"networks": [{"network": 1, "apps": {"rx": 0, "tx": 0}, "interfaces": {"rx": 0, "tx": 0}}],
///  "apps": [{"network": 1, "id": "/Applications/Safari.app", "name": "Safari", "rx": 0, "tx": 0}]}
/// ```
///
/// `networks` holds each network that carried bytes today, `apps` each app on each network.
/// Empty lists unless [`soroband_engine_live`] is on and a poll has run since.
///
/// The caller owns the string and frees it with [`soroband_string_free`].
#[unsafe(no_mangle)]
pub extern "C" fn soroband_today_json() -> *mut c_char {
    let today = lock(&TODAY);
    owned_c_string(if today.is_empty() {
        r#"{"networks":[],"apps":[]}"#
    } else {
        &today
    })
}

/// Opens the usage database in `data_dir` for reading, without the engine, for a process that only
/// shows History. Later calls, and calls after [`soroband_engine_start`], keep the first database.
/// Returns false when the database cannot be read.
///
/// # Safety
/// `data_dir` must be a valid NUL-terminated UTF-8 path.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn soroband_database_open(data_dir: *const c_char) -> bool {
    // SAFETY: the caller passes a valid NUL-terminated string.
    let data_dir = PathBuf::from(unsafe { text(data_dir) });
    let database = DATABASE.get_or_init(|| data_dir.join(DATABASE_FILE));
    match Store::open_read_only(database) {
        Ok(_) => true,
        Err(error) => {
            eprintln!("soroband: cannot read {}: {error}", database.display());
            false
        }
    }
}

/// What the History window shows for one range, as JSON, read from its own read-only connection
/// to the database so the engine's writes never wait for it. `query` is JSON:
///
/// ```json
/// {"start": 0, "end": 0, "previous_start": 0, "previous_end": 0, "network": 1, "step": "day"}
/// ```
///
/// Unix times; `previous_*` and `network` may be null or left out (no comparison; every
/// network), `step` is "hour", "day" or "month". The answer:
///
/// ```json
/// {"first_hour": 0, "interfaces": {"rx": 0, "tx": 0}, "previous": 0,
///  "bars": [{"first_hour": 0, "network": 1, "rx": 0, "tx": 0}],
///  "networks": [{"network": 1, "interfaces": {"rx": 0, "tx": 0}, "apps": {"rx": 0, "tx": 0}}],
///  "apps": [{"network": 1, "id": "/Applications/Safari.app", "name": "Safari", "rx": 0, "tx": 0}],
///  "busiest_day": {"first_hour": 0, "bytes": 0},
///  "heatmap": [{"weekday": 0, "hour": 0, "bytes": 0}]}
/// ```
///
/// as [`crate::history::History`] describes. Null when no database is open (neither
/// [`soroband_engine_start`] nor [`soroband_database_open`] ran), the query is not valid or the
/// read fails.
///
/// The caller owns the string and frees it with [`soroband_string_free`].
///
/// # Safety
/// `query` must be a valid NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn soroband_history_json(query: *const c_char) -> *mut c_char {
    let Some(database) = DATABASE.get() else {
        return std::ptr::null_mut();
    };
    // SAFETY: the caller passes a valid NUL-terminated string.
    let query = unsafe { text(query) };
    match history_json(database, &query, day::local_offset) {
        Ok(json) => owned_c_string(&json),
        Err(error) => {
            eprintln!("soroband: cannot read history: {error}");
            std::ptr::null_mut()
        }
    }
}

/// Writes the usage stored over the query's span and network to `path` as CSV
/// ([`crate::history::export_csv`]); `query` is JSON as for [`soroband_history_json`], whose
/// `previous_*` and `step` it ignores. Returns the number of rows written, or -1 when no database
/// is open, the query is not valid, or the read or write fails.
///
/// # Safety
/// `query` and `path` must be valid NUL-terminated strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn soroband_export_csv(query: *const c_char, path: *const c_char) -> i64 {
    let Some(database) = DATABASE.get() else {
        return -1;
    };
    // SAFETY: the caller passes valid NUL-terminated strings.
    let (query, path) = unsafe { (text(query), text(path)) };
    match export_csv_file(database, &query, Path::new(&path)) {
        Ok(rows) => i64::try_from(rows).unwrap_or(i64::MAX),
        Err(error) => {
            eprintln!("soroband: cannot export CSV to {path}: {error}");
            -1
        }
    }
}

fn parse_query(query: &str) -> Result<history::Query, String> {
    let value: Value = serde_json::from_str(query).map_err(|e| format!("query: {e}"))?;
    let time = |key: &str| value.get(key).and_then(Value::as_i64);
    let span = |start, end| -> Result<Option<history::Span>, String> {
        match (time(start), time(end)) {
            (Some(start), Some(end)) => Ok(Some(history::Span { start, end })),
            (None, None) => Ok(None),
            _ => Err(format!("query: {start} and {end} go together")),
        }
    };
    let step = match value.get("step") {
        None | Some(Value::Null) => history::Step::Day,
        Some(step) => step
            .as_str()
            .and_then(history::Step::parse)
            .ok_or_else(|| format!("query: unknown step {step}"))?,
    };
    let network = match value.get("network") {
        None | Some(Value::Null) => None,
        Some(id) => Some(id.as_i64().ok_or("query: network must be an id")?),
    };
    Ok(history::Query {
        span: span("start", "end")?.ok_or("query: start and end are required")?,
        previous: span("previous_start", "previous_end")?,
        network,
        step,
    })
}

/// The database opened read-only for one History read, with a 256 KB page cache instead of
/// SQLite's 2 MB: a year's query then needs about 2 MB less, at no measured cost in time, and the
/// History process stays inside its memory budget.
fn open_for_history(database: &Path) -> Result<Store, String> {
    let store = Store::open_read_only(database).map_err(|e| e.to_string())?;
    store
        .connection()
        .pragma_update(None, "cache_size", -256)
        .map_err(|e| e.to_string())?;
    Ok(store)
}

fn history_json(database: &Path, query: &str, zone: fn(i64) -> i64) -> Result<String, String> {
    let query = parse_query(query)?;
    let store = open_for_history(database)?;
    let h = history::history(&store, &query, zone).map_err(|e| e.to_string())?;
    let bytes = |b: Bytes| json!({"rx": b.rx, "tx": b.tx});
    Ok(json!({
        "first_hour": h.first_hour,
        "interfaces": bytes(h.interfaces),
        "previous": h.previous,
        "bars": h.bars.iter().map(|b| json!({
            "first_hour": b.first_hour, "network": b.network, "rx": b.bytes.rx, "tx": b.bytes.tx,
        })).collect::<Vec<_>>(),
        "networks": h.networks.iter().map(|n| json!({
            "network": n.network, "interfaces": bytes(n.interfaces), "apps": bytes(n.apps),
        })).collect::<Vec<_>>(),
        "apps": h.apps.iter().map(|a| json!({
            "network": a.network, "id": a.app.id, "name": a.app.name,
            "rx": a.bytes.rx, "tx": a.bytes.tx,
        })).collect::<Vec<_>>(),
        "busiest_day": h.busiest_day.map(|d| json!({"first_hour": d.first_hour, "bytes": d.bytes})),
        "heatmap": h.heatmap.iter().map(|c| json!({
            "weekday": c.weekday, "hour": c.hour, "bytes": c.bytes,
        })).collect::<Vec<_>>(),
    })
    .to_string())
}

fn export_csv_file(database: &Path, query: &str, path: &Path) -> Result<u64, String> {
    let query = parse_query(query)?;
    let store = open_for_history(database)?;
    let file = std::fs::File::create(path).map_err(|e| e.to_string())?;
    let mut out = std::io::BufWriter::new(file);
    let rows = history::export_csv(&store, query.span, query.network, &mut out)
        .map_err(|e| e.to_string())?;
    std::io::Write::flush(&mut out).map_err(|e| e.to_string())?;
    Ok(rows)
}

/// Every network in the registry as a JSON array of
/// `{"id", "key", "name", "kind", "last_used": Unix time of the last hour it carried bytes, or null}`,
/// in the order they were first seen. Reads the database; null when no database is open (neither
/// [`soroband_engine_start`] nor [`soroband_database_open`] ran) or the read fails.
///
/// The caller owns the string and frees it with [`soroband_string_free`].
#[unsafe(no_mangle)]
pub extern "C" fn soroband_networks_json() -> *mut c_char {
    let read = if let Some(running) = RUNNING.get() {
        let store = lock(&running.store);
        store.networks().and_then(|n| Ok((n, store.last_used()?)))
    } else if let Some(database) = DATABASE.get() {
        Store::open_read_only(database)
            .and_then(|store| Ok((store.networks()?, store.last_used()?)))
    } else {
        return std::ptr::null_mut();
    };
    match read {
        Ok((networks, last_used)) => owned_c_string(&networks_json(&networks, &last_used)),
        Err(error) => {
            eprintln!("soroband: cannot read the networks: {error}");
            std::ptr::null_mut()
        }
    }
}

fn networks_json(
    networks: &[crate::store::Network],
    last_used: &std::collections::BTreeMap<i64, i64>,
) -> String {
    Value::Array(
        networks
            .iter()
            .map(|n| {
                json!({
                    "id": n.id,
                    "key": n.key,
                    "name": n.name,
                    "kind": n.kind.as_str(),
                    "last_used": last_used.get(&n.id),
                })
            })
            .collect(),
    )
    .to_string()
}

/// The value of setting `key` as `soroband config get` prints it (`4`, `speed`), or null for an
/// unknown key or when the engine was not started. An unreadable settings file gives the default.
///
/// The caller owns the string and frees it with [`soroband_string_free`].
///
/// # Safety
/// `key` must be a valid NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn soroband_setting_get(key: *const c_char) -> *mut c_char {
    let Some(running) = RUNNING.get() else {
        return std::ptr::null_mut();
    };
    // SAFETY: the caller passes a valid NUL-terminated string.
    let key = unsafe { text(key) };
    let settings = Settings::load(&running.settings_path).unwrap_or_default();
    match settings.get(&key) {
        Ok(current) => owned_c_string(&settings::plain(&current.value)),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Sets `key` to `value` as `soroband config set` would, saves the settings file and applies it.
/// Returns false, saving nothing, for an unknown key, a value outside its type or range, an
/// unreadable settings file, or when the engine was not started.
///
/// # Safety
/// `key` and `value` must be valid NUL-terminated strings.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn soroband_setting_set(key: *const c_char, value: *const c_char) -> bool {
    let Some(running) = RUNNING.get() else {
        return false;
    };
    // SAFETY: the caller passes valid NUL-terminated strings.
    let (key, value) = unsafe { (text(key), text(value)) };
    let path = &running.settings_path;
    let saved = Settings::load(path).and_then(|mut settings| {
        settings.set(&key, &value)?;
        Ok(settings.save(path)?)
    });
    if let Err(error) = saved {
        eprintln!("soroband: cannot set {key} to {value:?}: {error}");
        return false;
    }
    running.send(Command::ReloadSettings);
    true
}

/// Frees a string returned by this API. Null does nothing.
///
/// # Safety
/// `string` must be null or a string from this API not yet freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn soroband_string_free(string: *mut c_char) {
    if !string.is_null() {
        // SAFETY: the string came from `CString::into_raw` in `owned_c_string`.
        drop(unsafe { CString::from_raw(string) });
    }
}

/// JSON text has no NUL bytes; any other text is cut at its first.
fn owned_c_string(text: &str) -> *mut c_char {
    let text = text.split('\0').next().unwrap_or_default();
    CString::new(text).unwrap_or_default().into_raw()
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
    let mut speed = Bytes::default();
    let mut last_poll = Instant::now();
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
        publish(&service, speed);
        let wait = if LIVE.load(Ordering::Relaxed) {
            LIVE_INTERVAL.min(interval)
        } else {
            interval
        };
        outlive_database_errors(service.tick(wait, day::now()))?;
        let polled = Instant::now();
        speed = per_second(service.last_booked().interfaces, polled - last_poll);
        last_poll = polled;
    }
}

/// `bytes` moved over `elapsed`, as bytes per second.
fn per_second(bytes: Bytes, elapsed: Duration) -> Bytes {
    let millis = elapsed.as_millis().max(1);
    let rate = |b: u64| u64::try_from(u128::from(b) * 1000 / millis).unwrap_or(u64::MAX);
    Bytes {
        rx: rate(bytes.rx),
        tx: rate(bytes.tx),
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

fn publish(service: &Service<SystemHost>, speed: Bytes) {
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
        speed_rx: speed.rx,
        speed_tx: speed.tx,
        check: match service.check() {
            Verdict::Ok => SOROBAND_CHECK_OK,
            Verdict::Degraded => SOROBAND_CHECK_DEGRADED,
            Verdict::Overcount => SOROBAND_CHECK_OVERCOUNT,
        },
    };
    if LIVE.load(Ordering::Relaxed) {
        let json = today_json(service);
        let mut today = lock(&TODAY);
        // The popover may have closed while the lists were built: keep nothing then.
        if LIVE.load(Ordering::Relaxed) {
            *today = json;
        }
    }
    notify();
}

/// Marks the engine stopped and tells the app, which otherwise waits for a poll that never comes.
fn fail() {
    lock(&STATUS).state = SOROBAND_ENGINE_FAILED;
    notify();
}

/// Calls the app's [`soroband_engine_on_poll`] callback, if any.
fn notify() {
    let callback = *lock(&ON_POLL);
    if let Some(callback) = callback {
        callback();
    }
}

fn today_json(service: &Service<SystemHost>) -> String {
    let bytes = |b: Bytes| json!({ "rx": b.rx, "tx": b.tx });
    let networks: Vec<Value> = service
        .today_networks()
        .map(|total| {
            json!({
                "network": total.network,
                "apps": bytes(total.apps),
                "interfaces": bytes(total.interfaces),
            })
        })
        .collect();
    let apps: Vec<Value> = service
        .today_apps()
        .map(|(network, app, b)| {
            json!({
                "network": network,
                "id": app.id,
                "name": app.name,
                "rx": b.rx,
                "tx": b.tx,
            })
        })
        .collect();
    json!({ "networks": networks, "apps": apps }).to_string()
}

#[cfg(test)]
mod tests {
    use super::soroband_core_version;
    use std::ffi::CStr;
    use std::time::{Duration, Instant};

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

    fn wait_for(what: &str, done: &dyn Fn() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(10);
        while !done() {
            assert!(Instant::now() < deadline, "timed out waiting for {what}");
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    /// Takes a string from the API, freeing it.
    fn take(string: *mut std::ffi::c_char) -> Option<String> {
        if string.is_null() {
            return None;
        }
        // SAFETY: a NUL-terminated string from the API, freed once below.
        let text = unsafe { CStr::from_ptr(string) }
            .to_str()
            .unwrap()
            .to_owned();
        // SAFETY: as above.
        unsafe { super::soroband_string_free(string) };
        Some(text)
    }

    fn json(string: *mut std::ffi::c_char) -> serde_json::Value {
        serde_json::from_str(&take(string).expect("a string")).unwrap()
    }

    /// Part of the C API test below, with the engine running and the reset hour at 7.
    fn app_settings_take_the_same_checks_as_config_set() {
        use super::{soroband_engine_status, soroband_setting_get, soroband_setting_set};
        // SAFETY: valid strings.
        let setting = |key: &CStr| take(unsafe { soroband_setting_get(key.as_ptr()) });
        // SAFETY: valid strings.
        let set = |key: &CStr, value: &CStr| unsafe {
            soroband_setting_set(key.as_ptr(), value.as_ptr())
        };
        assert_eq!(setting(c"menu_bar_top").as_deref(), Some("total"));
        assert!(set(c"menu_bar_top", c"speed"));
        assert_eq!(setting(c"menu_bar_top").as_deref(), Some("speed"));
        assert!(!set(c"menu_bar_top", c"rainbow"));
        assert!(!set(c"reset_hour", c"24"));
        assert_eq!(setting(c"menu_bar_top").as_deref(), Some("speed"));
        assert_eq!(setting(c"reset_hour").as_deref(), Some("7"));
        assert_eq!(setting(c"no_such_setting"), None);
        // Applied without the notification `soroband config set` posts.
        assert!(set(c"reset_hour", c"0"));
        wait_for("the reset hour set by the app", &|| {
            soroband_engine_status().reset_hour == 0
        });
    }

    /// Part of the C API test below, in live mode after a 200,000-byte download on network `cafe`,
    /// with "Office 4th floor" (a hotspot) seen before it.
    fn popover_lists_come_from_the_engine(cafe: i64, per_app: bool) {
        use super::{soroband_engine_live, soroband_networks_json, soroband_today_json};
        let today = json(soroband_today_json());
        let cafe_total = today["networks"]
            .as_array()
            .unwrap()
            .iter()
            .find(|n| n["network"] == cafe)
            .expect("Cafe carried bytes today")
            .clone();
        assert!(
            cafe_total["interfaces"]["rx"].as_u64().unwrap() >= 200_000,
            "{today}"
        );
        let apps_on_cafe: u64 = today["apps"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|a| a["network"] == cafe)
            .map(|a| a["rx"].as_u64().unwrap())
            .sum();
        if per_app {
            assert!(apps_on_cafe >= 200_000, "{today}");
            assert_eq!(cafe_total["apps"]["rx"].as_u64(), Some(apps_on_cafe));
        }
        // Closing the popover stops publishing the lists.
        soroband_engine_live(false);
        assert_eq!(
            take(soroband_today_json()).as_deref(),
            Some(r#"{"networks":[],"apps":[]}"#)
        );
        let networks = json(soroband_networks_json());
        assert_eq!(networks[0]["name"], "Office 4th floor");
        assert_eq!(networks[0]["kind"], "hotspot");
        assert_eq!(networks[1]["key"], "wifi:Cafe");
    }

    /// The whole C API in one test, because the engine is started once per process.
    #[test]
    #[allow(clippy::too_many_lines)]
    fn engine_run_through_the_c_api_books_to_the_network_the_app_names() {
        use super::{
            DATABASE_FILE, SOROBAND_ENGINE_INTERFACE_ONLY, SOROBAND_ENGINE_PER_APP,
            SOROBAND_ENGINE_STARTING, SorobandNetwork, soroband_engine_live,
            soroband_engine_on_poll, soroband_engine_start, soroband_engine_status,
            soroband_engine_stop, soroband_network_changed, soroband_network_unidentified,
            soroband_network_update, soroband_settings_reload,
        };
        use crate::store::{NetworkKind, Store};
        use std::ffi::CString;

        use std::sync::atomic::{AtomicUsize, Ordering};
        static POLLS: AtomicUsize = AtomicUsize::new(0);
        extern "C" fn polled() {
            POLLS.fetch_add(1, Ordering::Relaxed);
        }

        let dir = std::env::temp_dir().join(format!("soroband-ffi-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let dir_c = CString::new(dir.to_str().unwrap()).unwrap();
        soroband_engine_on_poll(Some(polled));
        // A 5 s interval, which live mode shortens to 1 s.
        // SAFETY: a valid NUL-terminated path.
        assert!(unsafe { soroband_engine_start(5, dir_c.as_ptr()) });

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
        assert!(POLLS.load(Ordering::Relaxed) >= 1, "the poll callback ran");
        // The poll ran once at the start; live mode polls again every second from now on.
        soroband_engine_live(true);
        let before = POLLS.load(Ordering::Relaxed);
        wait_for("three live polls", &|| {
            POLLS.load(Ordering::Relaxed) >= before + 3
        });

        let changed = |key: &str, name: &str, kind: &str| {
            let (key, name, kind) = (
                CString::new(key).unwrap(),
                CString::new(name).unwrap(),
                CString::new(kind).unwrap(),
            );
            let mut out = SorobandNetwork::new(0, "", NetworkKind::Wifi);
            // SAFETY: valid strings and a writable output.
            let ok = unsafe {
                soroband_network_changed(
                    key.as_ptr(),
                    name.as_ptr(),
                    kind.as_ptr(),
                    std::ptr::null(),
                    std::ptr::null(),
                    &raw mut out,
                )
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
        app_settings_take_the_same_checks_as_config_set();

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
        popover_lists_come_from_the_engine(cafe, booked.state == SOROBAND_ENGINE_PER_APP);
        soroband_engine_stop(5_000);
        // The list reads when each network was last used from the database, which now holds
        // Cafe's download.
        let networks = json(super::soroband_networks_json());
        assert!(networks[1]["last_used"].is_i64(), "{networks}");
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

        // History reads the same database through its own connection.
        let query = CString::new(format!(
            r#"{{"start": {}, "end": {}, "network": {cafe}, "step": "hour"}}"#,
            booked.today_start,
            crate::day::now() + 3600
        ))
        .unwrap();
        // SAFETY: a valid NUL-terminated string.
        let history = json(unsafe { super::soroband_history_json(query.as_ptr()) });
        assert!(
            history["interfaces"]["rx"].as_u64().unwrap() >= 200_000,
            "{history}"
        );
        assert_eq!(history["networks"][0]["network"], cafe, "{history}");
        let csv = dir.join("export.csv");
        let csv_c = CString::new(csv.to_str().unwrap()).unwrap();
        // SAFETY: valid NUL-terminated strings.
        let rows = unsafe { super::soroband_export_csv(query.as_ptr(), csv_c.as_ptr()) };
        let text = std::fs::read_to_string(&csv).unwrap();
        assert_eq!(
            usize::try_from(rows).unwrap(),
            text.lines().count() - 1,
            "{text}"
        );
        // SAFETY: a valid NUL-terminated string.
        assert!(unsafe { super::soroband_history_json(c"{}".as_ptr()) }.is_null());
    }

    #[test]
    fn history_queries_are_read_from_json_and_answered_as_json() {
        use super::{history_json, parse_query};
        use crate::history::{Query, Span, Step};
        use crate::meter::{App, Bytes};
        use crate::store::{AppUsage, InterfaceUsage, Store};

        assert_eq!(
            parse_query(r#"{"start": 10, "end": 20}"#),
            Ok(Query {
                span: Span { start: 10, end: 20 },
                previous: None,
                network: None,
                step: Step::Day,
            })
        );
        assert_eq!(
            parse_query(
                r#"{"start": 10, "end": 20, "previous_start": 0, "previous_end": 10,
                    "network": 3, "step": "month"}"#
            ),
            Ok(Query {
                span: Span { start: 10, end: 20 },
                previous: Some(Span { start: 0, end: 10 }),
                network: Some(3),
                step: Step::Month,
            })
        );
        for bad in [
            r#"{"end": 20}"#,
            r#"{"start": 10, "end": 20, "previous_start": 0}"#,
            r#"{"start": 10, "end": 20, "step": "week"}"#,
            r#"{"start": 10, "end": 20, "network": "Home"}"#,
            "not json",
        ] {
            assert!(parse_query(bad).is_err(), "{bad}");
        }

        let dir =
            std::env::temp_dir().join(format!("soroband-history-json-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("usage.sqlite");
        let mut store = Store::open(&path).unwrap();
        store
            .add(
                &[AppUsage {
                    hour: 3600,
                    network: 1,
                    app: App {
                        id: "/Applications/Mail.app".into(),
                        name: "Mail".into(),
                    },
                    bytes: Bytes { rx: 30, tx: 3 },
                }],
                &[InterfaceUsage {
                    hour: 3600,
                    network: 1,
                    bytes: Bytes { rx: 40, tx: 4 },
                }],
            )
            .unwrap();
        // Thursday 1 January 1970, 01:00 UTC.
        let answer: serde_json::Value = serde_json::from_str(
            &history_json(
                &path,
                r#"{"start": 0, "end": 7200, "previous_start": 0, "previous_end": 1}"#,
                |_| 0,
            )
            .unwrap(),
        )
        .unwrap();
        assert_eq!(
            answer,
            serde_json::json!({
                "first_hour": 3600,
                "interfaces": {"rx": 40, "tx": 4},
                "previous": 0,
                "bars": [{"first_hour": 3600, "network": 1, "rx": 40, "tx": 4}],
                "networks": [{"network": 1, "interfaces": {"rx": 40, "tx": 4},
                              "apps": {"rx": 30, "tx": 3}}],
                "apps": [{"network": 1, "id": "/Applications/Mail.app", "name": "Mail",
                          "rx": 30, "tx": 3}],
                "busiest_day": {"first_hour": 3600, "bytes": 44},
                "heatmap": [{"weekday": 4, "hour": 1, "bytes": 44}],
            })
        );
        assert!(
            history_json(
                &dir.join("missing.sqlite"),
                r#"{"start": 0, "end": 1}"#,
                |_| 0
            )
            .is_err()
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
    fn speed_is_bytes_over_the_time_between_polls() {
        use super::per_second;
        use crate::meter::Bytes;
        let bytes = Bytes {
            rx: 3_000_000,
            tx: 50_000,
        };
        // 3 MB in 1.5 s is 2 MB/s.
        assert_eq!(
            per_second(bytes, Duration::from_millis(1_500)),
            Bytes {
                rx: 2_000_000,
                tx: 33_333
            }
        );
        // A poll right after another does not divide by zero.
        assert_eq!(per_second(bytes, Duration::ZERO).rx, 3_000_000_000);
    }

    #[test]
    fn networks_list_carries_when_each_was_last_used() {
        use super::networks_json;
        use crate::store::{Network, NetworkKind};
        let network = |id, name: &str| Network {
            id,
            key: format!("wifi:{name}"),
            name: name.into(),
            kind: NetworkKind::Wifi,
        };
        let last_used = [(1, 7200)].into_iter().collect();
        let json: serde_json::Value = serde_json::from_str(&networks_json(
            &[network(1, "Home"), network(2, "Cafe")],
            &last_used,
        ))
        .unwrap();
        assert_eq!(
            json,
            serde_json::json!([
                {"id": 1, "key": "wifi:Home", "name": "Home", "kind": "wifi", "last_used": 7200},
                {"id": 2, "key": "wifi:Cafe", "name": "Cafe", "kind": "wifi", "last_used": null},
            ])
        );
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
