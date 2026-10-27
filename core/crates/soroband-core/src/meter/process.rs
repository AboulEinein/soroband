//! Which app a flow's bytes belong to.
//!
//! A process inside an `.app` bundle is credited to the outermost bundle, so helpers (browser
//! renderers, XPC services, embedded tools) roll up to their app. Processes from the system's own
//! directories are grouped as [`SERVICES`]. Any other executable is a command-line tool, named by
//! its file name.

/// Name of the group for macOS daemons and services.
pub const SERVICES: &str = "macOS & Services";

/// Directories holding macOS's own daemons, agents and services. A path counts as a system path
/// when it starts with one of these, after any cryptex root (see [`CRYPTEX_ROOTS`]).
const SYSTEM_DIRECTORIES: [&str; 6] = [
    "/System/Library/",
    "/usr/libexec/",
    "/usr/sbin/",
    "/sbin/",
    "/Library/Apple/",
    "/System/iOSSupport/",
];

/// Roots under which macOS mounts parts of itself (`/System/Volumes/Preboot/Cryptexes/OS/System/
/// Library/...`). A path under one is read as the path that follows it.
const CRYPTEX_ROOTS: [&str; 4] = [
    "/System/Volumes/Preboot/Cryptexes/OS",
    "/System/Cryptexes/OS",
    "/System/Volumes/Preboot/Cryptexes/App",
    "/System/Cryptexes/App",
];

/// The app a flow is credited to.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct App {
    /// Stable identity: the bundle path, the executable path, [`SERVICES`], or `process:<name>`
    /// when the executable path is unknown.
    pub id: String,
    /// Name to show.
    pub name: String,
}

impl App {
    #[must_use]
    pub fn services() -> Self {
        Self {
            id: SERVICES.to_owned(),
            name: SERVICES.to_owned(),
        }
    }

    /// The app that owns the executable at `path`.
    #[must_use]
    pub fn from_executable(path: &str) -> Self {
        let system_path = CRYPTEX_ROOTS
            .iter()
            .find_map(|root| path.strip_prefix(root))
            .unwrap_or(path);
        if SYSTEM_DIRECTORIES
            .iter()
            .any(|dir| system_path.starts_with(dir))
        {
            return Self::services();
        }
        if let Some(end) = path.find(".app/") {
            let bundle = &path[..end + ".app".len()];
            let name = bundle
                .rsplit('/')
                .next()
                .unwrap_or(bundle)
                .trim_end_matches(".app");
            return Self {
                id: bundle.to_owned(),
                name: name.to_owned(),
            };
        }
        let name = path.rsplit('/').next().unwrap_or(path);
        Self {
            id: path.to_owned(),
            name: name.to_owned(),
        }
    }

    /// A process whose executable path cannot be read (it has exited, or is not visible to us),
    /// known only by the name the kernel reported.
    #[must_use]
    pub fn from_process_name(name: &str) -> Self {
        Self {
            id: format!("process:{name}"),
            name: name.to_owned(),
        }
    }
}

/// The app credited for a flow owned by `pid`, acting for `epid`.
///
/// When a process moves data on behalf of another (`nsurlsessiond` for a background download, a
/// `WebKit` networking process for a browser), the kernel reports the app it serves as the effective
/// pid, and that app is credited. `path_of` returns a process's executable path, if it still runs.
pub fn attribute(
    pid: u32,
    epid: u32,
    pname: &str,
    path_of: &mut impl FnMut(u32) -> Option<String>,
) -> App {
    if epid != 0 && epid != pid {
        if let Some(path) = path_of(epid) {
            return App::from_executable(&path);
        }
    }
    if pid == 0 {
        return App::services();
    }
    match path_of(pid) {
        Some(path) => App::from_executable(&path),
        None => App::from_process_name(pname),
    }
}

/// The executable path of a running process, from `proc_pidpath(3)`.
#[must_use]
pub fn executable_path(pid: u32) -> Option<String> {
    const MAX: u32 = 4096; // PROC_PIDPATHINFO_MAXSIZE
    let pid = i32::try_from(pid).ok()?;
    let mut buf = vec![0u8; MAX as usize];
    // SAFETY: `buf` is writable for the length passed.
    let n = unsafe { libc::proc_pidpath(pid, buf.as_mut_ptr().cast(), MAX) };
    let n = usize::try_from(n).ok().filter(|&n| n > 0)?;
    buf.truncate(n);
    String::from_utf8(buf).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn table(entries: &[(u32, &str)]) -> impl FnMut(u32) -> Option<String> {
        let map: HashMap<u32, String> = entries
            .iter()
            .map(|&(pid, path)| (pid, path.to_owned()))
            .collect();
        move |pid| map.get(&pid).cloned()
    }

    #[test]
    fn browser_helper_is_credited_to_its_app() {
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome \
                      Framework.framework/Versions/131/Helpers/Google Chrome Helper.app/Contents/\
                      MacOS/Google Chrome Helper";
        let app = App::from_executable(helper);
        assert_eq!(app.name, "Google Chrome");
        assert_eq!(app.id, "/Applications/Google Chrome.app");
    }

    #[test]
    fn app_main_executable_is_credited_to_its_bundle() {
        let app = App::from_executable("/Applications/Slack.app/Contents/MacOS/Slack");
        assert_eq!(
            app,
            App {
                id: "/Applications/Slack.app".into(),
                name: "Slack".into()
            }
        );
    }

    #[test]
    fn system_daemons_are_grouped_as_services() {
        for path in [
            "/usr/libexec/nsurlsessiond",
            "/usr/sbin/mDNSResponder",
            "/System/Library/PrivateFrameworks/ApplePushService.framework/apsd",
            "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter",
            "/System/Volumes/Preboot/Cryptexes/OS/System/Library/Frameworks/WebKit.framework/\
             Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/\
             com.apple.WebKit.Networking",
            "/System/Volumes/Preboot/Cryptexes/App/usr/libexec/PasswordBreachAgent",
            "/System/Cryptexes/App/usr/libexec/SafariLaunchAgent",
        ] {
            assert_eq!(App::from_executable(path), App::services(), "{path}");
        }
    }

    #[test]
    fn daemons_outside_the_system_directories_are_named() {
        for (path, name) in [
            ("/opt/homebrew/Cellar/dnsmasq/2.90/sbin/dnsmasq", "dnsmasq"),
            ("/usr/local/sbin/unbound", "unbound"),
            ("/Users/user/Library/System/Library/agent", "agent"),
        ] {
            assert_eq!(App::from_executable(path).name, name, "{path}");
        }
    }

    #[test]
    fn apple_apps_outside_system_library_are_apps() {
        let safari = "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/\
                      Contents/MacOS/Safari";
        assert_eq!(App::from_executable(safari).name, "Safari");
        assert_eq!(
            App::from_executable("/System/Applications/Mail.app/Contents/MacOS/Mail").name,
            "Mail"
        );
    }

    #[test]
    fn command_line_tool_is_named_by_its_executable() {
        let app = App::from_executable("/usr/bin/curl");
        assert_eq!(
            app,
            App {
                id: "/usr/bin/curl".into(),
                name: "curl".into()
            }
        );
    }

    #[test]
    fn delegated_flow_is_credited_to_the_effective_process() {
        let mut path_of = table(&[
            (300, "/usr/libexec/nsurlsessiond"),
            (812, "/Applications/Music.app/Contents/MacOS/Music"),
        ]);
        let app = attribute(300, 812, "nsurlsessiond", &mut path_of);
        assert_eq!(app.name, "Music");
    }

    #[test]
    fn delegated_flow_falls_back_to_the_owner_when_the_effective_process_is_gone() {
        let mut path_of = table(&[(300, "/usr/libexec/nsurlsessiond")]);
        assert_eq!(
            attribute(300, 999, "nsurlsessiond", &mut path_of),
            App::services()
        );
    }

    #[test]
    fn exited_process_is_known_by_its_kernel_name() {
        let mut path_of = table(&[]);
        let app = attribute(4242, 4242, "curl", &mut path_of);
        assert_eq!(
            app,
            App {
                id: "process:curl".into(),
                name: "curl".into()
            }
        );
    }

    #[test]
    fn kernel_flows_are_services() {
        let mut path_of = table(&[]);
        assert_eq!(
            attribute(0, 0, "kernel_task", &mut path_of),
            App::services()
        );
    }

    #[test]
    fn executable_path_of_a_missing_process_is_none() {
        assert_eq!(executable_path(i32::MAX.cast_unsigned()), None);
    }

    #[test]
    fn executable_path_of_this_test_process() {
        let path = executable_path(std::process::id()).expect("own path");
        assert_eq!(
            std::path::Path::new(&path),
            std::env::current_exe().unwrap()
        );
    }
}
