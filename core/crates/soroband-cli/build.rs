//! Stamps the `soroband` command with the commit it is built from, read by `scripts/build-stamp.sh`,
//! as the environment variables `SOROBAND_BUILD`, `SOROBAND_COMMIT` and `SOROBAND_BRANCH`.

use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
    let script = root.join("scripts/build-stamp.sh");
    println!("cargo:rerun-if-changed={}", script.display());

    let output = Command::new(&script)
        .output()
        .ok()
        .filter(|o| o.status.success());
    let stamp = output
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default();
    let value = |key: &str| {
        stamp
            .lines()
            .find_map(|line| line.strip_prefix(key)?.strip_prefix('='))
            .map(str::to_owned)
    };
    let commit = value("commit").unwrap_or_else(|| "unknown".to_owned());
    println!(
        "cargo:rustc-env=SOROBAND_BUILD={}",
        value("build").unwrap_or_else(|| "0".to_owned())
    );
    println!("cargo:rustc-env=SOROBAND_COMMIT={commit}");
    println!(
        "cargo:rustc-env=SOROBAND_BRANCH={}",
        value("branch").unwrap_or_default()
    );

    for path in watched(&root) {
        println!("cargo:rerun-if-changed={}", path.display());
    }
}

/// The files whose change can change the stamp: git's record of HEAD, the branch and the index,
/// and every tracked file (an edit makes the build dirty). A new untracked file is not among them,
/// so it marks the command dirty only from the next build that reruns this script.
fn watched(root: &Path) -> Vec<PathBuf> {
    let git = |args: &[&str]| {
        let output = Command::new("git")
            .arg("-C")
            .arg(root)
            .args(args)
            .output()
            .ok()?;
        output
            .status
            .success()
            .then(|| String::from_utf8_lossy(&output.stdout).into_owned())
    };
    let Some(paths) = git(&[
        "rev-parse",
        "--path-format=absolute",
        "--git-dir",
        "--git-common-dir",
    ]) else {
        return Vec::new();
    };
    let mut lines = paths.lines();
    let (Some(git_dir), Some(common_dir)) = (lines.next(), lines.next()) else {
        return Vec::new();
    };
    let mut watched = vec![
        Path::new(git_dir).join("HEAD"),
        Path::new(git_dir).join("index"),
        Path::new(common_dir).join("packed-refs"),
    ];
    if let Some(branch) = git(&["symbolic-ref", "-q", "HEAD"]) {
        watched.push(Path::new(common_dir).join(branch.trim()));
    }
    if let Some(files) = git(&["ls-files"]) {
        watched.extend(files.lines().map(|file| root.join(file)));
    }
    // A missing path makes Cargo rerun this script on every build.
    watched.retain(|path| path.exists());
    watched
}
