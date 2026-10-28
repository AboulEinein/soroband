//! The C API as the History process uses it: the database opened read-only, no engine.
//!
//! A test binary of its own, because the C API keeps one database and one engine per process.

use soroband_core::ffi::{
    SOROBAND_ENGINE_STARTING, soroband_database_open, soroband_engine_status, soroband_export_csv,
    soroband_history_json, soroband_networks_json, soroband_string_free,
};
use soroband_core::meter::{App, Bytes};
use soroband_core::store::{AppUsage, InterfaceUsage, NetworkKind, Store};
use std::ffi::{CStr, CString, c_char};

fn take(string: *mut c_char) -> serde_json::Value {
    assert!(!string.is_null(), "the API returned null");
    // SAFETY: a NUL-terminated string from the API, freed once below.
    let text = unsafe { CStr::from_ptr(string) }
        .to_str()
        .unwrap()
        .to_owned();
    // SAFETY: as above.
    unsafe { soroband_string_free(string) };
    serde_json::from_str(&text).unwrap()
}

#[test]
fn history_reads_the_database_without_the_engine() {
    let dir = std::env::temp_dir().join(format!("soroband-reader-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let dir_c = CString::new(dir.to_str().unwrap()).unwrap();
    assert!(
        // SAFETY: a valid NUL-terminated path.
        !unsafe { soroband_database_open(dir_c.as_ptr()) },
        "no database there yet"
    );
    // SAFETY: a valid NUL-terminated string.
    assert!(unsafe { soroband_history_json(c"{\"start\": 0, \"end\": 1}".as_ptr()) }.is_null());

    // The app's engine writes the database; this process only reads it.
    std::fs::create_dir_all(&dir).unwrap();
    let mut store = Store::open(&dir.join("usage.sqlite")).unwrap();
    let home = store
        .join_network("wifi:Home", "Home", NetworkKind::Wifi)
        .unwrap();
    store
        .add(
            &[AppUsage {
                hour: 7200,
                network: home.id,
                app: App {
                    id: "/Applications/Mail.app".into(),
                    name: "Mail".into(),
                },
                bytes: Bytes { rx: 30, tx: 3 },
            }],
            &[InterfaceUsage {
                hour: 7200,
                network: home.id,
                bytes: Bytes { rx: 40, tx: 4 },
            }],
        )
        .unwrap();

    // SAFETY: a valid NUL-terminated path.
    assert!(unsafe { soroband_database_open(dir_c.as_ptr()) });
    let networks = take(soroband_networks_json());
    assert_eq!(networks[0]["name"], "Home", "{networks}");
    assert_eq!(networks[0]["last_used"], 7200, "{networks}");
    let query = CString::new(r#"{"start": 0, "end": 86400, "step": "hour"}"#).unwrap();
    // SAFETY: a valid NUL-terminated string.
    let history = take(unsafe { soroband_history_json(query.as_ptr()) });
    assert_eq!(
        history["interfaces"],
        serde_json::json!({"rx": 40, "tx": 4})
    );
    assert_eq!(history["apps"][0]["name"], "Mail");

    let csv = dir.join("export.csv");
    let csv_c = CString::new(csv.to_str().unwrap()).unwrap();
    assert_eq!(
        // SAFETY: valid NUL-terminated strings.
        unsafe { soroband_export_csv(query.as_ptr(), csv_c.as_ptr()) },
        1
    );
    assert!(
        std::fs::read_to_string(&csv)
            .unwrap()
            .ends_with("1970-01-01T02:00:00Z,1,Home,wifi,Mail,/Applications/Mail.app,30,3\n")
    );
    assert_eq!(
        soroband_engine_status().state,
        SOROBAND_ENGINE_STARTING,
        "reading never starts the engine"
    );
}
