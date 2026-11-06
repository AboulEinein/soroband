//! `soroband update`: replaces the installed app with the newest release from GitHub.
//!
//! The release's `Soroband.dmg` holds the app with this command in `Contents/Helpers`, so the
//! command finds the app to replace from its own path. A command built from source is not in an
//! app bundle and is updated from its clone instead. Nothing is sent: the command downloads the
//! release's description, the DMG and its checksum, and only when it is run.

use serde_json::Value;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Stdio};
use std::time::{Duration, Instant};

pub const USAGE: &str = "\
Usage: soroband update [--check]

Downloads the newest Soroband release from GitHub, checks its SHA-256
checksum, and replaces the app this command belongs to (normally
/Applications/Soroband.app), quitting the app first and opening it again
after. --check only says whether a newer release exists.

A soroband built from source is updated from its clone instead:
git pull && scripts/install.sh --replace";

const LATEST: &str = "https://api.github.com/repos/AboulEinein/soroband/releases/latest";
const DMG: &str = "Soroband.dmg";
const CHECKSUM: &str = "Soroband.dmg.sha256";

pub fn run(args: &[&str]) -> ExitCode {
    let check_only = match args {
        [] => false,
        ["--check"] => true,
        _ => {
            eprintln!("{USAGE}");
            return ExitCode::from(2);
        }
    };
    match update(check_only) {
        Ok(text) => {
            println!("{text}");
            ExitCode::SUCCESS
        }
        Err(message) => {
            eprintln!("soroband update: {message}");
            ExitCode::FAILURE
        }
    }
}

fn update(check_only: bool) -> Result<String, String> {
    let exe = std::env::current_exe()
        .and_then(std::fs::canonicalize)
        .map_err(|e| format!("cannot find this command's path: {e}"))?;
    let app = app_bundle(&exe).ok_or_else(|| {
        format!(
            "{} was built from source, not installed from a release. Update it from its clone: git pull && scripts/install.sh --replace",
            exe.display()
        )
    })?;

    // SOROBAND_RELEASE_URL stands in for GitHub's latest release in tests, with file:// URLs.
    let (latest, protocols) = match std::env::var("SOROBAND_RELEASE_URL") {
        Ok(url) if !url.is_empty() => (url, "=https,file"),
        _ => (LATEST.to_owned(), "=https"),
    };
    let release: Value = serde_json::from_slice(&fetch(&latest, protocols)?)
        .map_err(|e| format!("the release description from {latest} is not JSON: {e}"))?;
    let tag = release["tag_name"]
        .as_str()
        .ok_or("the latest release has no tag")?;
    let newest =
        parse_version(tag).ok_or_else(|| format!("cannot read the version in tag {tag}"))?;
    let current = soroband_core::version();
    let installed = parse_version(current).expect("the crate's own version is x.y.z");
    let newest_text = tag.trim_start_matches('v');
    if newest <= installed {
        return Ok(format!("Soroband {current} is up to date."));
    }
    if check_only {
        return Ok(format!(
            "Soroband {newest_text} is available (this is {current}). Run `soroband update` to install it."
        ));
    }

    let dmg_url = asset_url(&release, DMG)?;
    let checksum_url = asset_url(&release, CHECKSUM)?;
    check_writable(&app, &dmg_url)?;
    let work = WorkDir::new()?;
    let dmg = work.0.join(DMG);
    std::fs::write(&dmg, fetch(&dmg_url, protocols)?).map_err(|e| e.to_string())?;
    let expected = String::from_utf8(fetch(&checksum_url, protocols)?)
        .ok()
        .and_then(|text| parse_checksum(&text))
        .ok_or_else(|| format!("{CHECKSUM} holds no SHA-256 checksum"))?;
    let actual = sha256(&dmg)?;
    if actual != expected {
        return Err(format!(
            "the downloaded {DMG} does not match its checksum (expected {expected}, got {actual}); nothing was changed"
        ));
    }

    let staged = sibling(&app, "update");
    stage(&dmg, &work.0.join("mount"), &staged)?;

    let was_running = match quit(&app) {
        Ok(running) => running,
        Err(e) => {
            let _ = std::fs::remove_dir_all(&staged);
            return Err(e);
        }
    };
    let replaced = replace(&app, &staged);
    if replaced.is_err() {
        let _ = std::fs::remove_dir_all(&staged);
    }
    // Open whichever app is in place now, the new one or, if the move failed, the old one.
    let opened = if was_running {
        run_tool(Command::new("/usr/bin/open").arg(&app))
    } else {
        Ok(())
    };
    // An old version the update could not remove is named whether or not the app opened.
    let leftover = replaced?.map_or_else(String::new, |old| {
        format!(
            " The old version could not be removed, because another account installed it: remove {} as an administrator.",
            old.display()
        )
    });
    if let Err(e) = opened {
        return Err(format!(
            "updated {} to {newest_text}, but could not open it: {e}.{leftover}",
            app.display()
        ));
    }
    Ok(format!(
        "Updated {} from {current} to {newest_text}{}.{leftover}",
        app.display(),
        if was_running { " and opened it" } else { "" },
    ))
}

/// Copies the DMG's app to `staged`, next to the installed app, mounting the DMG at `mount` for
/// the copy. A failed copy leaves nothing at `staged`.
fn stage(dmg: &Path, mount: &Path, staged: &Path) -> Result<(), String> {
    run_tool(
        Command::new("/usr/bin/hdiutil")
            .args(["attach", "-quiet", "-nobrowse", "-readonly", "-noautoopen"])
            .arg("-mountpoint")
            .arg(mount)
            .arg(dmg),
    )?;
    let copied = (|| {
        let source = mount.join("Soroband.app");
        if !source.join("Contents/MacOS/Soroband").exists() {
            return Err(format!("{DMG} holds no Soroband.app"));
        }
        let _ = std::fs::remove_dir_all(staged);
        run_tool(Command::new("/usr/bin/ditto").arg(&source).arg(staged))
    })();
    let _ = run_tool(
        Command::new("/usr/bin/hdiutil")
            .args(["detach", "-quiet"])
            .arg(mount),
    );
    if copied.is_err() {
        let _ = std::fs::remove_dir_all(staged);
    }
    copied
}

/// The app bundle this command is in, when its path is `<name>.app/Contents/Helpers/<command>`.
fn app_bundle(exe: &Path) -> Option<PathBuf> {
    let helpers = exe.parent()?;
    let contents = helpers.parent()?;
    let app = contents.parent()?;
    let is_app = app.extension().is_some_and(|e| e == "app");
    (helpers.file_name()? == "Helpers" && contents.file_name()? == "Contents" && is_app)
        .then(|| app.to_owned())
}

/// `x.y.z`, with or without a leading `v`.
fn parse_version(text: &str) -> Option<(u64, u64, u64)> {
    let mut parts = text.strip_prefix('v').unwrap_or(text).split('.');
    let mut next = || parts.next()?.parse().ok();
    let version = (next()?, next()?, next()?);
    parts.next().is_none().then_some(version)
}

/// The checksum in a `shasum -a 256` line: 64 hexadecimal digits, then the file's name.
fn parse_checksum(text: &str) -> Option<String> {
    let digest = text.split_whitespace().next()?;
    (digest.len() == 64 && digest.bytes().all(|b| b.is_ascii_hexdigit()))
        .then(|| digest.to_ascii_lowercase())
}

fn asset_url(release: &Value, name: &str) -> Result<String, String> {
    release["assets"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|asset| asset["name"] == name)
        .and_then(|asset| asset["browser_download_url"].as_str())
        .map(str::to_owned)
        .ok_or_else(|| format!("the latest release has no {name}"))
}

fn fetch(url: &str, protocols: &str) -> Result<Vec<u8>, String> {
    let output = Command::new("/usr/bin/curl")
        .args(["--fail", "--silent", "--show-error", "--location"])
        .args(["--proto", protocols, "--proto-redir", protocols])
        .args(["--max-time", "600"])
        .arg(url)
        .output()
        .map_err(|e| format!("cannot run curl: {e}"))?;
    if !output.status.success() {
        return Err(format!(
            "cannot download {url}: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    Ok(output.stdout)
}

fn sha256(path: &Path) -> Result<String, String> {
    let output = Command::new("/usr/bin/shasum")
        .args(["-a", "256"])
        .arg(path)
        .output()
        .map_err(|e| format!("cannot run shasum: {e}"))?;
    String::from_utf8(output.stdout)
        .ok()
        .and_then(|text| parse_checksum(&text))
        .ok_or_else(|| format!("shasum could not read {}", path.display()))
}

fn run_tool(command: &mut Command) -> Result<(), String> {
    let output = command
        .stdout(Stdio::null())
        .output()
        .map_err(|e| format!("cannot run {:?}: {e}", command.get_program()))?;
    if output.status.success() {
        Ok(())
    } else {
        Err(format!(
            "{:?} failed: {}",
            command.get_program(),
            String::from_utf8_lossy(&output.stderr).trim()
        ))
    }
}

unsafe extern "C" {
    /// `getuid(2)` from libSystem.
    fn getuid() -> u32;
}

/// Quits this user's copy of the app's menu bar process (its UI process quits with it) and waits
/// for it to exit. Returns whether it was running. Another user's copy of the same app is left
/// alone: this user cannot quit it, and `kill -0` on it fails as if it had exited.
fn quit(app: &Path) -> Result<bool, String> {
    let pattern = format!(
        "^{}/Contents/MacOS/Soroband$",
        regex_escape(&app.to_string_lossy())
    );
    // SAFETY: getuid takes no arguments and cannot fail.
    let uid = unsafe { getuid() }.to_string();
    let output = Command::new("/usr/bin/pgrep")
        .args(["-U", &uid, "-f", &pattern])
        .output()
        .map_err(|e| format!("cannot run pgrep: {e}"))?;
    let pids: Vec<String> = String::from_utf8_lossy(&output.stdout)
        .split_whitespace()
        .map(str::to_owned)
        .collect();
    for pid in &pids {
        let _ = Command::new("/bin/kill").arg(pid).status();
    }
    let deadline = Instant::now() + Duration::from_secs(10);
    for pid in &pids {
        while Command::new("/bin/kill")
            .args(["-0", pid])
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|s| s.success())
        {
            if Instant::now() > deadline {
                return Err(format!(
                    "Soroband (pid {pid}) did not quit; quit it and run soroband update again"
                ));
            }
            std::thread::sleep(Duration::from_millis(200));
        }
    }
    Ok(!pids.is_empty())
}

fn regex_escape(text: &str) -> String {
    text.chars()
        .flat_map(|c| {
            let special = "\\^$.|?*+()[]{}".contains(c);
            special.then_some('\\').into_iter().chain([c])
        })
        .collect()
}

/// Fails before anything is downloaded when this user cannot replace the app: an account that is
/// not an administrator cannot write to `/Applications`, and copying in the Finder asks for an
/// administrator's password instead.
fn check_writable(app: &Path, dmg_url: &str) -> Result<(), String> {
    let probe = sibling(app, "write-check");
    match std::fs::create_dir(&probe) {
        Ok(()) => {
            let _ = std::fs::remove_dir(&probe);
            Ok(())
        }
        Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => Err(format!(
            "this account cannot write to {}. Download {dmg_url}, open it and drag Soroband to Applications in the Finder, which asks for an administrator's password.",
            app.parent().unwrap_or(app).display()
        )),
        Err(e) => Err(format!("cannot write next to {}: {e}", app.display())),
    }
}

/// `.<app name>-<label>-<pid>.app` next to the app, on the same volume, so a rename moves it into
/// place. The pid keeps a leftover this user cannot delete (one another account's update left)
/// from blocking a rename onto it or mixing into a copy.
fn sibling(app: &Path, label: &str) -> PathBuf {
    let name = app.file_stem().unwrap_or_default().to_string_lossy();
    app.with_file_name(format!(".{name}-{label}-{}.app", std::process::id()))
}

/// Puts `staged` in the app's place, keeping the old app until the new one is there. Returns the
/// old app's path when it could not be removed (files another account installed).
fn replace(app: &Path, staged: &Path) -> Result<Option<PathBuf>, String> {
    let old = sibling(app, "old");
    std::fs::rename(app, &old).map_err(|e| format!("cannot move {}: {e}", app.display()))?;
    if let Err(e) = std::fs::rename(staged, app) {
        let _ = std::fs::rename(&old, app);
        return Err(format!("cannot move the new app into place: {e}"));
    }
    Ok(std::fs::remove_dir_all(&old).is_err().then_some(old))
}

/// A temporary directory removed when dropped.
struct WorkDir(PathBuf);

impl WorkDir {
    fn new() -> Result<Self, String> {
        let dir = std::env::temp_dir().join(format!("soroband-update-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        Ok(Self(dir))
    }
}

impl Drop for WorkDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn versions_compare_by_number_not_text() {
        assert!(parse_version("v0.1.10") > parse_version("0.1.9"));
        assert!(parse_version("v1.0.0") > parse_version("v0.99.99"));
        assert_eq!(parse_version("v0.1.0"), Some((0, 1, 0)));
    }

    #[test]
    fn versions_other_than_three_numbers_are_refused() {
        for tag in ["v0.1", "v0.1.0.1", "v0.1.0-beta", "latest", ""] {
            assert_eq!(parse_version(tag), None, "{tag}");
        }
    }

    #[test]
    fn checksum_is_the_first_word_of_a_shasum_line() {
        let digest = "AB".repeat(32);
        assert_eq!(
            parse_checksum(&format!("{digest}  Soroband.dmg\n")),
            Some(digest.to_ascii_lowercase())
        );
        assert_eq!(
            parse_checksum(&format!("{}  Soroband.dmg", "a".repeat(63))),
            None
        );
        assert_eq!(
            parse_checksum(&format!("{}  Soroband.dmg", "g".repeat(64))),
            None
        );
        assert_eq!(parse_checksum(""), None);
    }

    #[test]
    fn only_a_command_inside_an_app_bundle_has_an_app_to_update() {
        assert_eq!(
            app_bundle(Path::new(
                "/Applications/Soroband.app/Contents/Helpers/soroband"
            )),
            Some(PathBuf::from("/Applications/Soroband.app"))
        );
        for path in [
            "/Users/me/.local/bin/soroband",
            "/Users/me/soroband/core/target/release/soroband",
            "/Applications/Soroband.app/Contents/MacOS/soroband",
            "/Applications/Soroband/Contents/Helpers/soroband",
        ] {
            assert_eq!(app_bundle(Path::new(path)), None, "{path}");
        }
    }

    #[test]
    fn the_running_app_is_matched_by_its_literal_path() {
        assert_eq!(
            regex_escape("/Applications/My (old) Soroband.app"),
            r"/Applications/My \(old\) Soroband\.app"
        );
    }
}
