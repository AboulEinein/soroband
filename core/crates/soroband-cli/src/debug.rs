//! `soroband debug`: talks to a running Debug build of the app.
//!
//! The command posts a Darwin notification; the app answers by writing its state as JSON to a
//! file. `state` asks the menu bar app, `history` the History window's own process. The names must
//! match `app/Soroband/Debug/DebugCommands.swift`.

use std::ffi::{CString, c_char};
use std::path::PathBuf;
use std::process::ExitCode;
use std::thread::sleep;
use std::time::{Duration, Instant};

const DUMP_STATE_NOTIFICATION: &str = "io.github.abouleinein.soroband.debug.dump-state";
const STATE_FILE: &str = "Library/Caches/io.github.abouleinein.soroband.debug/state.json";
const DUMP_HISTORY_NOTIFICATION: &str = "io.github.abouleinein.soroband.debug.dump-history";
const HISTORY_FILE: &str = "Library/Caches/io.github.abouleinein.soroband.debug/history.json";
const ANSWER_TIMEOUT: Duration = Duration::from_secs(3);

unsafe extern "C" {
    /// `notify_post(3)` from libSystem.
    fn notify_post(name: *const c_char) -> u32;
}

pub fn run(args: &[&str]) -> ExitCode {
    match args {
        ["state", "--json"] => answer(DUMP_STATE_NOTIFICATION, STATE_FILE, "the Debug app"),
        ["history", "--json"] => answer(
            DUMP_HISTORY_NOTIFICATION,
            HISTORY_FILE,
            "the Debug app's History window",
        ),
        _ => {
            eprintln!("Usage: soroband debug state --json | history --json");
            ExitCode::from(2)
        }
    }
}

/// Posts `notification` and prints the JSON the app writes to `file` (under the home directory).
fn answer(notification: &str, file: &str, who: &str) -> ExitCode {
    let Some(home) = std::env::var_os("HOME") else {
        eprintln!("soroband: HOME is not set");
        return ExitCode::FAILURE;
    };
    let path = PathBuf::from(home).join(file);
    // A state file left by an earlier answer must not be mistaken for this one.
    match std::fs::remove_file(&path) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => {
            eprintln!("soroband: cannot remove {}: {error}", path.display());
            return ExitCode::FAILURE;
        }
    }

    let name = CString::new(notification).expect("notification name has no NUL");
    // SAFETY: `name` is a valid NUL-terminated string that outlives the call.
    let status = unsafe { notify_post(name.as_ptr()) };
    if status != 0 {
        eprintln!("soroband: notify_post failed with status {status}");
        return ExitCode::FAILURE;
    }

    let deadline = Instant::now() + ANSWER_TIMEOUT;
    while Instant::now() < deadline {
        // The app writes the file atomically, so it is complete once it exists.
        if let Ok(json) = std::fs::read_to_string(&path) {
            println!("{}", json.trim_end());
            return ExitCode::SUCCESS;
        }
        sleep(Duration::from_millis(50));
    }
    eprintln!(
        "soroband: no answer from {who} within {} s; is it running?",
        ANSWER_TIMEOUT.as_secs()
    );
    ExitCode::FAILURE
}
