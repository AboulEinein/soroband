//! The `soroband` command against a database and settings file in a temporary data directory
//! (`SOROBAND_DATA_DIR`), as the app leaves them.

use serde_json::{Value, json};
use soroband_core::day::{hour_start, now};
use soroband_core::meter::{App, Bytes};
use soroband_core::store::{AppUsage, InterfaceUsage, NetworkKind, Store};
use std::ffi::{CString, c_char, c_int};
use std::path::{Path, PathBuf};
use std::process::Output;

const H: i64 = 3600;

fn data_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("soroband-cli-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn soroband(dir: &Path, args: &[&str]) -> Output {
    std::process::Command::new(env!("CARGO_BIN_EXE_soroband"))
        .args(args)
        .env("SOROBAND_DATA_DIR", dir)
        .output()
        .unwrap()
}

fn json_of(output: &Output) -> Value {
    assert!(output.status.success(), "{output:?}");
    serde_json::from_slice(&output.stdout).unwrap()
}

fn app(name: &str) -> App {
    App {
        id: format!("/Applications/{name}.app"),
        name: name.into(),
    }
}

/// Two networks with usage in the current hour, and Home with older usage two days ago that
/// "today" must leave out whatever the reset hour.
fn seed(dir: &Path) -> (i64, i64) {
    let mut store = Store::open(&dir.join("usage.sqlite")).unwrap();
    let home = store
        .join_network("wifi:Home", "Home", NetworkKind::Wifi)
        .unwrap()
        .id;
    let phone = store
        .join_network("wifi:iPhone", "iPhone", NetworkKind::Hotspot)
        .unwrap()
        .id;
    let hour = hour_start(now());
    let row = |hour, network, name: &str, rx, tx| AppUsage {
        hour,
        network,
        app: app(name),
        bytes: Bytes { rx, tx },
    };
    store
        .add(
            &[
                row(hour, home, "Safari", 3_000, 300),
                row(hour, home, "Mail", 1_000, 100),
                row(hour, phone, "Mail", 500, 50),
                row(hour - 48 * H, home, "Safari", 9_999_999, 0),
            ],
            &[
                InterfaceUsage {
                    hour,
                    network: home,
                    bytes: Bytes { rx: 4_400, tx: 450 },
                },
                InterfaceUsage {
                    hour,
                    network: phone,
                    bytes: Bytes { rx: 560, tx: 60 },
                },
            ],
        )
        .unwrap();
    (home, phone)
}

/// An empty `SOROBAND_DATA_DIR` is unset, as the app reads it: the command uses the Debug app's
/// directory under `HOME`, not the working directory.
#[test]
fn an_empty_data_dir_variable_means_the_default_directory() {
    let home = data_dir("empty-dir-home");
    let cwd = data_dir("empty-dir-cwd");
    let default = home.join("Library/Application Support/Soroband Debug");
    std::fs::create_dir_all(&default).unwrap();
    std::fs::write(default.join("settings.json"), r#"{ "reset_hour": 4 }"#).unwrap();
    std::fs::write(cwd.join("settings.json"), r#"{ "reset_hour": 9 }"#).unwrap();
    let get = std::process::Command::new(env!("CARGO_BIN_EXE_soroband"))
        .args(["config", "get", "reset_hour"])
        .env("SOROBAND_DATA_DIR", "")
        .env("HOME", &home)
        .current_dir(&cwd)
        .output()
        .unwrap();
    assert_eq!(String::from_utf8_lossy(&get.stdout), "4\n", "{get:?}");
}

#[test]
fn today_reports_each_network_and_the_total() {
    let dir = data_dir("today");
    let (home, phone) = seed(&dir);
    let today = json_of(&soroband(&dir, &["today", "--json"]));
    assert_eq!(today["reset_hour"], 0);
    assert_eq!(
        today["networks"],
        json!([
            { "id": home, "name": "Home", "kind": "wifi",
              "apps": { "rx": 4_000, "tx": 400 }, "interfaces": { "rx": 4_400, "tx": 450 } },
            { "id": phone, "name": "iPhone", "kind": "hotspot",
              "apps": { "rx": 500, "tx": 50 }, "interfaces": { "rx": 560, "tx": 60 } },
        ])
    );
    assert_eq!(
        today["total"],
        json!({ "apps": { "rx": 4_500, "tx": 450 }, "interfaces": { "rx": 4_960, "tx": 510 } })
    );
    let text = soroband(&dir, &["today"]);
    assert!(text.status.success());
    let text = String::from_utf8(text.stdout).unwrap();
    assert!(text.contains("iPhone"), "{text}");
    assert!(text.contains("All networks"), "{text}");
}

#[test]
fn apps_lists_todays_apps_on_the_named_network() {
    let dir = data_dir("apps");
    let (home, _) = seed(&dir);
    let apps = json_of(&soroband(&dir, &["apps", "--network", "home", "--json"]));
    assert_eq!(
        apps["network"],
        json!({ "id": home, "name": "Home", "kind": "wifi" })
    );
    assert_eq!(
        apps["apps"],
        json!([
            { "id": "/Applications/Safari.app", "name": "Safari", "rx": 3_000, "tx": 300 },
            { "id": "/Applications/Mail.app", "name": "Mail", "rx": 1_000, "tx": 100 },
        ])
    );
    // Without --network: every network, Mail's two rows summed.
    let all = json_of(&soroband(&dir, &["apps", "--json"]));
    assert_eq!(all["network"], Value::Null);
    assert_eq!(
        all["apps"][1],
        json!({ "id": "/Applications/Mail.app", "name": "Mail", "rx": 1_500, "tx": 150 })
    );

    // Bytes booked while no network was identified.
    let mut store = Store::open(&dir.join("usage.sqlite")).unwrap();
    let row = AppUsage {
        hour: hour_start(now()),
        network: 0,
        app: app("Mail"),
        bytes: Bytes { rx: 70, tx: 7 },
    };
    store.add(&[row], &[]).unwrap();
    let nowhere = json_of(&soroband(&dir, &["apps", "--network", "0", "--json"]));
    assert_eq!(
        nowhere["network"],
        json!({ "id": 0, "name": "Unknown network", "kind": null })
    );
    assert_eq!(
        nowhere["apps"],
        json!([{ "id": "/Applications/Mail.app", "name": "Mail", "rx": 70, "tx": 7 }])
    );

    let unknown = soroband(&dir, &["apps", "--network", "Cafe"]);
    assert!(!unknown.status.success());
    let message = String::from_utf8(unknown.stderr).unwrap();
    assert!(
        message.contains(r#"known networks: "Home", "iPhone""#),
        "{message}"
    );
}

#[test]
fn today_without_a_database_says_the_app_has_not_run() {
    let dir = data_dir("empty");
    let output = soroband(&dir, &["today", "--json"]);
    assert_eq!(output.status.code(), Some(1));
    let message = String::from_utf8(output.stderr).unwrap();
    assert!(message.contains("no usage recorded yet"), "{message}");
}

#[test]
fn today_and_apps_refuse_an_unreadable_settings_file() {
    // The running app keeps the reset hour it last read, so guessing hour 0 would count a
    // different day from the one the app shows.
    let dir = data_dir("usage-unreadable");
    seed(&dir);
    std::fs::write(dir.join("settings.json"), "{ reset_hour: 4").unwrap();
    for args in [&["today", "--json"][..], &["apps", "--json"]] {
        let output = soroband(&dir, args);
        assert_eq!(output.status.code(), Some(1), "{args:?}: {output:?}");
        assert!(output.stdout.is_empty(), "{args:?}: {output:?}");
        let message = String::from_utf8(output.stderr).unwrap();
        assert!(
            message.contains("set each value again with `soroband config set`"),
            "{message}"
        );
    }
}

unsafe extern "C" {
    fn notify_register_check(name: *const c_char, token: *mut c_int) -> u32;
    fn notify_check(token: c_int, check: *mut c_int) -> u32;
    fn notify_cancel(token: c_int) -> u32;
    fn notify_post(name: *const c_char) -> u32;
}

/// Whether the notification was posted since the last call, like the app's listener sees it.
///
/// `notify_post` only queues a post for `notifyd`, so a command can exit before its post is
/// delivered. Each check first posts a fence of the listener's own and waits until it is
/// delivered: `notifyd` delivers posts in the order they were queued, so every post queued
/// before the fence has been delivered too.
struct Listener {
    token: c_int,
    fence_name: CString,
    fence: c_int,
}

fn register(name: &CString) -> c_int {
    let mut token = 0;
    // SAFETY: valid string and output pointer.
    let status = unsafe { notify_register_check(name.as_ptr(), &raw mut token) };
    assert_eq!(status, 0);
    // The first check after registering always reports a post.
    check(token);
    token
}

fn check(token: c_int) -> bool {
    let mut check = 0;
    // SAFETY: valid token and output pointer.
    assert_eq!(unsafe { notify_check(token, &raw mut check) }, 0);
    check != 0
}

impl Listener {
    fn new(name: &str) -> Self {
        let fence_name = CString::new(format!("{name}.test-fence.{}", std::process::id())).unwrap();
        Self {
            token: register(&CString::new(name).unwrap()),
            fence: register(&fence_name),
            fence_name,
        }
    }

    fn posted(&self) -> bool {
        // SAFETY: valid string.
        assert_eq!(unsafe { notify_post(self.fence_name.as_ptr()) }, 0);
        // Only bounds a hang: a delivered fence ends the wait, within milliseconds.
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while !check(self.fence) {
            assert!(
                std::time::Instant::now() < deadline,
                "notifyd did not deliver the fence"
            );
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        check(self.token)
    }
}

impl Drop for Listener {
    fn drop(&mut self) {
        // SAFETY: tokens from notify_register_check.
        unsafe {
            notify_cancel(self.token);
            notify_cancel(self.fence);
        }
    }
}

/// The notification a test build of the command (a debug build) posts for data directory `dir`:
/// its own name, so a test run never reaches a running Debug app.
fn settings_changed(dir: &Path) -> String {
    format!(
        "io.github.abouleinein.soroband.debug.settings-changed:{}",
        dir.display()
    )
}

/// Held by the tests that watch the notification, so one test's post is not seen by another.
static NOTIFICATIONS: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[test]
fn config_set_saves_the_value_and_tells_the_app() {
    let _serial = NOTIFICATIONS
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let dir = data_dir("config-set");
    let listener = Listener::new(&settings_changed(&dir));
    let set = soroband(&dir, &["config", "set", "reset_hour", "4"]);
    assert!(set.status.success(), "{set:?}");
    assert_eq!(String::from_utf8(set.stdout).unwrap(), "reset_hour = 4\n");
    assert!(listener.posted(), "the app was not notified");
    let saved = std::fs::read_to_string(dir.join("settings.json")).unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&saved).unwrap(),
        json!({ "reset_hour": 4 })
    );

    let get = soroband(&dir, &["config", "get", "reset_hour"]);
    assert_eq!(String::from_utf8(get.stdout).unwrap(), "4\n");
    let described = json_of(&soroband(&dir, &["config", "get", "reset_hour", "--json"]));
    assert_eq!(described["value"], 4);
    assert_eq!(described["is_default"], false);
    assert_eq!(described["default"], 0);
    assert_eq!(
        (described["min"].clone(), described["max"].clone()),
        (json!(0), json!(23))
    );
    // `today` counts from the new reset hour.
    seed(&dir);
    assert_eq!(
        json_of(&soroband(&dir, &["today", "--json"]))["reset_hour"],
        4
    );
}

#[test]
fn config_set_refuses_a_bad_value_and_leaves_the_file_alone() {
    let _serial = NOTIFICATIONS
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let dir = data_dir("config-bad");
    assert!(
        soroband(&dir, &["config", "set", "reset_hour", "6"])
            .status
            .success()
    );
    let listener = Listener::new(&settings_changed(&dir));
    for (args, expected) in [
        (["config", "set", "reset_hour", "24"], "24 is outside 0-23"),
        (
            ["config", "set", "reset_hour", "noon"],
            "is not a whole number",
        ),
        (["config", "set", "reset_houre", "4"], "unknown setting"),
    ] {
        let output = soroband(&dir, &args);
        assert_eq!(output.status.code(), Some(2), "{args:?}");
        let message = String::from_utf8(output.stderr).unwrap();
        assert!(message.contains(expected), "{args:?}: {message}");
    }
    assert!(!listener.posted(), "a refused value notified the app");
    assert_eq!(
        soroband(&dir, &["config", "get", "reset_hour"]).stdout,
        b"6\n"
    );
}

#[test]
fn config_set_menu_bar_readings_takes_words_from_its_options() {
    let _serial = NOTIFICATIONS
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let dir = data_dir("config-menu-bar");
    let described = json_of(&soroband(
        &dir,
        &["config", "get", "menu_bar_readings", "--json"],
    ));
    assert_eq!(described["type"], "list");
    assert_eq!(
        described["options"],
        json!(["total", "download", "upload", "speed_down", "speed_up"])
    );
    assert_eq!(described["max"], 4);
    assert_eq!(described["value"], "total");

    let listener = Listener::new(&settings_changed(&dir));
    let set = soroband(
        &dir,
        &["config", "set", "menu_bar_readings", "download, upload"],
    );
    assert!(set.status.success(), "{set:?}");
    assert_eq!(
        String::from_utf8(set.stdout).unwrap(),
        "menu_bar_readings = download,upload\n"
    );
    assert!(listener.posted(), "the app was not notified");
    // Printed as typed, without JSON quotes, so scripts can compare it.
    let get = soroband(&dir, &["config", "get", "menu_bar_readings"]);
    assert_eq!(String::from_utf8(get.stdout).unwrap(), "download,upload\n");
    let saved = std::fs::read_to_string(dir.join("settings.json")).unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&saved).unwrap(),
        json!({ "menu_bar_readings": "download,upload" })
    );

    let bad = soroband(&dir, &["config", "set", "menu_bar_readings", "rainbow"]);
    assert_eq!(bad.status.code(), Some(2));
    assert_eq!(
        soroband(&dir, &["config", "get", "menu_bar_readings"]).stdout,
        b"download,upload\n"
    );
}

#[test]
fn config_list_shows_every_setting_with_its_schema() {
    let dir = data_dir("config-list");
    let list = json_of(&soroband(&dir, &["config", "list", "--json"]));
    let keys: Vec<&str> = list
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s["key"].as_str().unwrap())
        .collect();
    assert_eq!(
        keys,
        soroband_core::settings::SCHEMA
            .iter()
            .map(|s| s.key)
            .collect::<Vec<_>>()
    );
    for setting in list.as_array().unwrap() {
        assert!(
            setting["description"]
                .as_str()
                .is_some_and(|d| !d.is_empty())
        );
        assert_eq!(setting["is_default"], true);
    }
}

#[test]
fn config_reports_an_unreadable_settings_file_without_replacing_it() {
    let dir = data_dir("config-unreadable");
    std::fs::write(dir.join("settings.json"), "{ reset_hour: 4").unwrap();
    let output = soroband(&dir, &["config", "set", "reset_hour", "5"]);
    assert_eq!(output.status.code(), Some(1));
    let message = String::from_utf8(output.stderr).unwrap();
    assert!(
        message.contains("set each value again with `soroband config set`"),
        "{message}"
    );
    assert_eq!(
        std::fs::read_to_string(dir.join("settings.json")).unwrap(),
        "{ reset_hour: 4"
    );
}

/// Runs git in `dir`.
fn git_in(dir: &Path, args: &[&str]) -> String {
    let output = std::process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .unwrap();
    assert!(output.status.success(), "git {args:?}: {output:?}");
    String::from_utf8(output.stdout).unwrap().trim().to_owned()
}

/// Runs git in the repository the command was built from.
fn git(args: &[&str]) -> String {
    git_in(Path::new(env!("CARGO_MANIFEST_DIR")), args)
}

#[test]
fn version_names_the_commit_the_command_was_built_from() {
    // The user compares this with `git rev-parse --short origin/main` to tell which build runs.
    let output = soroband(&data_dir("version"), &["version"]);
    assert!(output.status.success(), "{output:?}");
    let printed = String::from_utf8(output.stdout).unwrap();
    let rest = printed
        .strip_prefix(&format!("soroband {} (", soroband_core::version()))
        .unwrap_or_else(|| panic!("{printed}"));
    let (build, stamp) = rest
        .split_once(") · ")
        .unwrap_or_else(|| panic!("{printed}"));
    assert!(build.parse::<u64>().is_ok(), "{printed}");
    let expected = [
        git(&["rev-parse", "--short", "HEAD"]),
        git(&["branch", "--show-current"]),
    ]
    .into_iter()
    .filter(|part| !part.is_empty())
    .collect::<Vec<_>>()
    .join(" ");
    assert_eq!(stamp.trim_end(), expected);
}

/// Runs a copy of `scripts/build-stamp.sh` placed in `root`, which stamps the checkout at `root`.
fn build_stamp(root: &Path) -> String {
    let script = root.join("scripts/build-stamp.sh");
    let output = std::process::Command::new(&script).output().unwrap();
    assert!(output.status.success(), "{output:?}");
    String::from_utf8(output.stdout).unwrap()
}

#[test]
fn build_stamp_is_unknown_outside_this_checkout_and_dirty_with_untracked_files() {
    // A source archive, alone or extracted inside another project's checkout, still builds, and
    // does not take that project's commit.
    let outer = data_dir("build-stamp");
    let root = outer.join("soroband");
    std::fs::create_dir_all(root.join("scripts")).unwrap();
    std::fs::copy(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../scripts/build-stamp.sh"),
        root.join("scripts/build-stamp.sh"),
    )
    .unwrap();
    let unknown = "build=0\ncommit=unknown\nbranch=\n";
    assert_eq!(build_stamp(&root), unknown);
    git_in(&outer, &["init", "-q"]);
    git_in(
        &outer,
        &[
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "commit",
            "-q",
            "--allow-empty",
            "-m",
            "outer",
        ],
    );
    assert_eq!(build_stamp(&root), unknown);

    // In this project's checkout, an untracked file marks the app's stamp dirty, also when git is
    // set to hide untracked files.
    let git_root = |args: &[&str]| {
        let mut all = vec!["-c", "user.name=t", "-c", "user.email=t@t"];
        all.extend_from_slice(args);
        git_in(&root, &all)
    };
    git_root(&["init", "-q", "-b", "trunk"]);
    git_root(&["add", "-A"]);
    git_root(&["commit", "-q", "-m", "one"]);
    git_root(&["config", "status.showUntrackedFiles", "no"]);
    let head = git_root(&["rev-parse", "--short", "HEAD"]);
    assert_eq!(
        build_stamp(&root),
        format!("build=1\ncommit={head}\nbranch=trunk\n")
    );
    std::fs::write(root.join("new"), "x").unwrap();
    assert_eq!(
        build_stamp(&root),
        format!("build=1\ncommit={head}-dirty\nbranch=trunk\n")
    );
}
