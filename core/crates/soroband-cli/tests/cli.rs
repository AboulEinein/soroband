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

unsafe extern "C" {
    fn notify_register_check(name: *const c_char, token: *mut c_int) -> u32;
    fn notify_check(token: c_int, check: *mut c_int) -> u32;
    fn notify_cancel(token: c_int) -> u32;
}

/// Whether the notification was posted since the last call, like the app's listener sees it.
struct Listener(c_int);

impl Listener {
    fn new(name: &str) -> Self {
        let name = CString::new(name).unwrap();
        let mut token = 0;
        // SAFETY: valid string and output pointer.
        let status = unsafe { notify_register_check(name.as_ptr(), &raw mut token) };
        assert_eq!(status, 0);
        let listener = Self(token);
        // The first check after registering always reports a post.
        listener.posted();
        listener
    }

    fn posted(&self) -> bool {
        let mut check = 0;
        // SAFETY: valid token and output pointer.
        assert_eq!(unsafe { notify_check(self.0, &raw mut check) }, 0);
        check != 0
    }
}

impl Drop for Listener {
    fn drop(&mut self) {
        // SAFETY: a token from notify_register_check.
        unsafe { notify_cancel(self.0) };
    }
}

/// Held by the tests that watch the notification, so one test's post is not seen by another.
static NOTIFICATIONS: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[test]
fn config_set_saves_the_value_and_tells_the_app() {
    let _serial = NOTIFICATIONS
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let dir = data_dir("config-set");
    // A test build of the command is a debug build, so it posts the Debug app's notification.
    let listener = Listener::new("io.github.abouleinein.soroband.debug.settings-changed");
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
    let listener = Listener::new("io.github.abouleinein.soroband.debug.settings-changed");
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
fn config_set_menu_bar_line_takes_a_word_from_its_options() {
    let _serial = NOTIFICATIONS
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let dir = data_dir("config-menu-bar");
    let described = json_of(&soroband(
        &dir,
        &["config", "get", "menu_bar_bottom", "--json"],
    ));
    assert_eq!(described["type"], "choice");
    assert_eq!(
        described["options"],
        json!([
            "total",
            "download",
            "upload",
            "speed",
            "speed_down",
            "speed_up",
            "none"
        ])
    );
    assert_eq!(described["value"], "none");

    let listener = Listener::new("io.github.abouleinein.soroband.debug.settings-changed");
    let set = soroband(&dir, &["config", "set", "menu_bar_bottom", "upload"]);
    assert!(set.status.success(), "{set:?}");
    assert_eq!(
        String::from_utf8(set.stdout).unwrap(),
        "menu_bar_bottom = upload\n"
    );
    assert!(listener.posted(), "the app was not notified");
    // Printed as typed, without JSON quotes, so scripts can compare it.
    let get = soroband(&dir, &["config", "get", "menu_bar_bottom"]);
    assert_eq!(String::from_utf8(get.stdout).unwrap(), "upload\n");
    let saved = std::fs::read_to_string(dir.join("settings.json")).unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&saved).unwrap(),
        json!({ "menu_bar_bottom": "upload" })
    );

    let bad = soroband(&dir, &["config", "set", "menu_bar_bottom", "rainbow"]);
    assert_eq!(bad.status.code(), Some(2));
    assert_eq!(
        soroband(&dir, &["config", "get", "menu_bar_bottom"]).stdout,
        b"upload\n"
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
    assert!(message.contains("Fix or delete the file"), "{message}");
    assert_eq!(
        std::fs::read_to_string(dir.join("settings.json")).unwrap(),
        "{ reset_hour: 4"
    );
}
