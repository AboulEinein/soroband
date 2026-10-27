//! `soroband debug`: talks to a running Debug build of the app.
//!
//! The command posts a Darwin notification; the app answers by writing its state as JSON to a
//! file. Both names must match `app/Soroband/Debug/DebugCommands.swift`.

use std::ffi::{CString, c_char};
use std::path::PathBuf;
use std::process::ExitCode;
use std::thread::sleep;
use std::time::{Duration, Instant};

const DUMP_STATE_NOTIFICATION: &str = "io.github.abouleinein.soroband.debug.dump-state";
const STATE_FILE: &str = "Library/Caches/io.github.abouleinein.soroband.debug/state.json";
const ANSWER_TIMEOUT: Duration = Duration::from_secs(3);

unsafe extern "C" {
    /// `notify_post(3)` from libSystem.
    fn notify_post(name: *const c_char) -> u32;
}

pub fn run(args: &[&str]) -> ExitCode {
    if let ["state", "--json"] = args {
        state()
    } else {
        eprintln!("Usage: soroband debug state --json");
        ExitCode::from(2)
    }
}

fn state() -> ExitCode {
    let Some(home) = std::env::var_os("HOME") else {
        eprintln!("soroband: HOME is not set");
        return ExitCode::FAILURE;
    };
    let path = PathBuf::from(home).join(STATE_FILE);
    // A state file left by an earlier answer must not be mistaken for this one.
    match std::fs::remove_file(&path) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => {
            eprintln!("soroband: cannot remove {}: {error}", path.display());
            return ExitCode::FAILURE;
        }
    }

    let name = CString::new(DUMP_STATE_NOTIFICATION).expect("notification name has no NUL");
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
        "soroband: no answer from the Debug app within {} s; is it running?",
        ANSWER_TIMEOUT.as_secs()
    );
    ExitCode::FAILURE
}
