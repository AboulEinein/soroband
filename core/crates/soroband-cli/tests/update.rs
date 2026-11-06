//! `soroband update` against a release in a temporary directory: a `Soroband.dmg` made with
//! `hdiutil`, its checksum, and a release description in GitHub's shape with `file://` URLs
//! (`SOROBAND_RELEASE_URL`). The command runs from inside a stand-in app bundle, as the DMG
//! installs it, and replaces that bundle.

use serde_json::json;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

struct Fixture {
    dir: PathBuf,
    app: PathBuf,
}

impl Fixture {
    /// An installed app whose executable reads "old", with this build's command in its Helpers.
    fn new(name: &str) -> Self {
        let dir =
            std::env::temp_dir().join(format!("soroband-update-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let app = dir.join("Applications/Soroband.app");
        make_app(&app, "old");
        let helpers = app.join("Contents/Helpers");
        std::fs::create_dir_all(&helpers).unwrap();
        std::fs::copy(env!("CARGO_BIN_EXE_soroband"), helpers.join("soroband")).unwrap();
        Self { dir, app }
    }

    /// Publishes a release tagged `tag` whose DMG holds an app reading "new"; `checksum` replaces
    /// the DMG's real checksum when given.
    fn publish(&self, tag: &str, checksum: Option<&str>) -> String {
        self.publish_with(tag, checksum, |app| make_app(app, "new"))
    }

    /// Publishes a release whose DMG holds the app `make` writes.
    fn publish_with(&self, tag: &str, checksum: Option<&str>, make: impl FnOnce(&Path)) -> String {
        let release = self.dir.join("release");
        let source = release.join("source");
        make(&source.join("Soroband.app"));
        let dmg = release.join("Soroband.dmg");
        let created = Command::new("/usr/bin/hdiutil")
            .args([
                "create",
                "-quiet",
                "-volname",
                "Soroband",
                "-fs",
                "HFS+",
                "-srcfolder",
            ])
            .arg(&source)
            .arg(&dmg)
            .status()
            .unwrap();
        assert!(created.success());
        let digest = checksum.map_or_else(
            || {
                let output = Command::new("/usr/bin/shasum")
                    .args(["-a", "256"])
                    .arg(&dmg)
                    .output()
                    .unwrap();
                let text = String::from_utf8(output.stdout).unwrap();
                text.split_whitespace().next().unwrap().to_owned()
            },
            str::to_owned,
        );
        std::fs::write(
            release.join("Soroband.dmg.sha256"),
            format!("{digest}  Soroband.dmg\n"),
        )
        .unwrap();
        let url = |name: &str| format!("file://{}", release.join(name).display());
        let description = json!({
            "tag_name": tag,
            "assets": [
                {"name": "Soroband.dmg", "browser_download_url": url("Soroband.dmg")},
                {"name": "Soroband.dmg.sha256", "browser_download_url": url("Soroband.dmg.sha256")},
            ],
        });
        std::fs::write(release.join("latest.json"), description.to_string()).unwrap();
        url("latest.json")
    }

    fn update(&self, release: &str, args: &[&str]) -> Output {
        Command::new(self.app.join("Contents/Helpers/soroband"))
            .arg("update")
            .args(args)
            .env("SOROBAND_RELEASE_URL", release)
            .output()
            .unwrap()
    }

    fn installed(&self) -> String {
        std::fs::read_to_string(self.app.join("Contents/MacOS/Soroband")).unwrap()
    }

    /// What is next to the app: only the app itself once an update has finished or failed.
    fn applications(&self) -> Vec<String> {
        let mut names: Vec<String> = std::fs::read_dir(self.app.parent().unwrap())
            .unwrap()
            .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        names.sort();
        names
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn make_app(app: &Path, executable: &str) {
    let macos = app.join("Contents/MacOS");
    std::fs::create_dir_all(&macos).unwrap();
    std::fs::write(macos.join("Soroband"), executable).unwrap();
}

/// Compiles the C program `source` to `output`.
fn compile(source: &str, output: &Path) {
    std::fs::create_dir_all(output.parent().unwrap()).unwrap();
    let mut cc = Command::new("/usr/bin/cc")
        .args(["-x", "c", "-", "-o"])
        .arg(output)
        .stdin(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    std::io::Write::write_all(&mut cc.stdin.take().unwrap(), source.as_bytes()).unwrap();
    assert!(cc.wait().unwrap().success());
}

fn text(output: &Output) -> String {
    format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )
}

#[test]
fn update_installs_a_newer_release_in_the_apps_place() {
    let fixture = Fixture::new("newer");
    let release = fixture.publish("v999.0.0", None);
    let output = fixture.update(&release, &[]);
    assert!(output.status.success(), "{}", text(&output));
    assert_eq!(fixture.installed(), "new");
    assert_eq!(fixture.applications(), ["Soroband.app"]);
    assert!(text(&output).contains("to 999.0.0"), "{}", text(&output));
}

/// The app is running while it updates, as it normally is: a program at the app's executable path
/// that waits for a signal stands in for the menu bar process. The new app is a bundle macOS can
/// open, whose executable exits at once. Both are compiled here: copies of system binaries in an
/// app bundle are held at launch by macOS's checks.
#[test]
fn update_quits_a_running_app_and_opens_the_new_one() {
    let fixture = Fixture::new("running");
    let executable = fixture.app.join("Contents/MacOS/Soroband");
    compile(
        "#include <unistd.h>\nint main(void) { pause(); return 0; }",
        &executable,
    );
    let release = fixture.publish_with("v999.0.0", None, |app| {
        let macos = app.join("Contents/MacOS");
        std::fs::create_dir_all(&macos).unwrap();
        compile("int main(void) { return 0; }", &macos.join("Soroband"));
        std::fs::write(
            app.join("Contents/Info.plist"),
            r#"<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Soroband</string>
<key>CFBundleIdentifier</key><string>io.github.abouleinein.soroband.update-test</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
"#,
        )
        .unwrap();
    });
    // At its real path, as LaunchServices starts an app: the temporary directory is behind the
    // /var -> /private/var link, and the command finds the app from its own resolved path.
    let mut running = Command::new(std::fs::canonicalize(&executable).unwrap())
        .spawn()
        .unwrap();
    let pid = running.id();
    // Reaped as soon as it exits, as launchd reaps an app: an unreaped exit stays a zombie, which
    // `kill -0` still finds.
    let reaper = std::thread::spawn(move || running.wait().unwrap());

    let output = fixture.update(&release, &[]);
    let exited = reaper.is_finished();
    if !exited {
        let _ = Command::new("/bin/kill")
            .args(["-9", &pid.to_string()])
            .status();
    }
    reaper.join().unwrap();
    assert!(output.status.success(), "{}", text(&output));
    assert!(exited, "the running app was not quit");
    assert!(text(&output).contains("and opened it"), "{}", text(&output));
    let new = fixture
        .dir
        .join("release/source/Soroband.app/Contents/MacOS/Soroband");
    assert_eq!(
        std::fs::read(&executable).unwrap(),
        std::fs::read(new).unwrap()
    );
    assert_eq!(fixture.applications(), ["Soroband.app"]);
}

#[test]
fn update_refuses_a_download_that_does_not_match_its_checksum() {
    let fixture = Fixture::new("checksum");
    let release = fixture.publish("v999.0.0", Some(&"0".repeat(64)));
    let output = fixture.update(&release, &[]);
    assert!(!output.status.success());
    assert!(
        text(&output).contains("does not match its checksum"),
        "{}",
        text(&output)
    );
    assert_eq!(fixture.installed(), "old");
    assert_eq!(fixture.applications(), ["Soroband.app"]);
}

#[test]
fn update_leaves_the_app_alone_when_it_is_the_newest_release() {
    let fixture = Fixture::new("current");
    let release = fixture.publish(&format!("v{}", soroband_core::version()), None);
    let output = fixture.update(&release, &[]);
    assert!(output.status.success(), "{}", text(&output));
    assert!(text(&output).contains("is up to date"), "{}", text(&output));
    assert_eq!(fixture.installed(), "old");
}

#[test]
fn update_check_reports_a_newer_release_without_installing_it() {
    let fixture = Fixture::new("check");
    let release = fixture.publish("v999.0.0", None);
    let output = fixture.update(&release, &["--check"]);
    assert!(output.status.success(), "{}", text(&output));
    assert!(
        text(&output).contains("999.0.0 is available"),
        "{}",
        text(&output)
    );
    assert_eq!(fixture.installed(), "old");
}

#[test]
fn update_refuses_arguments_it_does_not_know_and_installs_nothing() {
    let fixture = Fixture::new("arguments");
    let release = fixture.publish("v999.0.0", None);
    for args in [&["--chek"][..], &["--check", "extra"], &["now"]] {
        let output = fixture.update(&release, args);
        assert_eq!(output.status.code(), Some(2), "{args:?}: {}", text(&output));
        assert_eq!(fixture.installed(), "old", "{args:?}");
    }
}

#[test]
fn update_refuses_before_downloading_when_the_app_cannot_be_replaced() {
    use std::os::unix::fs::PermissionsExt;
    let fixture = Fixture::new("read-only");
    let release = fixture.publish("v999.0.0", None);
    let applications = fixture.app.parent().unwrap();
    std::fs::set_permissions(applications, std::fs::Permissions::from_mode(0o555)).unwrap();
    let output = fixture.update(&release, &[]);
    std::fs::set_permissions(applications, std::fs::Permissions::from_mode(0o755)).unwrap();
    assert!(!output.status.success());
    assert!(
        text(&output).contains("cannot write to"),
        "{}",
        text(&output)
    );
    assert_eq!(fixture.installed(), "old");
    assert_eq!(fixture.applications(), ["Soroband.app"]);
}

#[test]
fn update_from_a_source_build_points_to_the_clone() {
    let output = Command::new(env!("CARGO_BIN_EXE_soroband"))
        .arg("update")
        .env("SOROBAND_RELEASE_URL", "file:///nonexistent/latest.json")
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(
        text(&output).contains("scripts/install.sh --replace"),
        "{}",
        text(&output)
    );
}
