//! Where the app keeps its data, and how to tell it the settings changed.
//!
//! These must match the app (`Core.dataDirectory` in `app/Soroband/Core.swift`, and
//! `SettingsListener`): a Release build uses
//! `~/Library/Application Support/Soroband`, a Debug build `Soroband Debug`, so a Debug app and its
//! `soroband` command never touch the installed app's data. `SOROBAND_DATA_DIR` overrides the
//! directory, for tests.

use std::ffi::{CString, c_char};
use std::path::PathBuf;

#[cfg(not(debug_assertions))]
const DIRECTORY: &str = "Library/Application Support/Soroband";
#[cfg(debug_assertions)]
const DIRECTORY: &str = "Library/Application Support/Soroband Debug";

/// The app's bundle identifier followed by `.settings-changed`.
#[cfg(not(debug_assertions))]
pub const SETTINGS_CHANGED: &str = "io.github.abouleinein.soroband.settings-changed";
#[cfg(debug_assertions)]
pub const SETTINGS_CHANGED: &str = "io.github.abouleinein.soroband.debug.settings-changed";

pub fn directory() -> Result<PathBuf, String> {
    if let Some(dir) = std::env::var_os("SOROBAND_DATA_DIR") {
        return Ok(PathBuf::from(dir));
    }
    let home = std::env::var_os("HOME").ok_or("HOME is not set")?;
    Ok(PathBuf::from(home).join(DIRECTORY))
}

unsafe extern "C" {
    /// `notify_post(3)` from libSystem.
    fn notify_post(name: *const c_char) -> u32;
}

/// Posts the Darwin notification the app rereads its settings on.
pub fn post_settings_changed() -> Result<(), String> {
    let name = CString::new(SETTINGS_CHANGED).expect("notification name has no NUL");
    // SAFETY: `name` is a valid NUL-terminated string that outlives the call.
    match unsafe { notify_post(name.as_ptr()) } {
        0 => Ok(()),
        status => Err(format!("notify_post failed with status {status}")),
    }
}
