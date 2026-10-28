//! C API for the app. `scripts/build-core.sh` turns this module into `soroband_core.h` with cbindgen.

use std::ffi::c_char;

/// The core's version as a NUL-terminated UTF-8 string.
///
/// The string is static: the caller must not free it.
#[unsafe(no_mangle)]
pub extern "C" fn soroband_core_version() -> *const c_char {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr().cast()
}

#[cfg(test)]
mod tests {
    use super::soroband_core_version;
    use std::ffi::CStr;

    /// The workspace version, read from `core/Cargo.toml` rather than from the compiled crate.
    fn workspace_version() -> String {
        let manifest = concat!(env!("CARGO_MANIFEST_DIR"), "/../../Cargo.toml");
        let text = std::fs::read_to_string(manifest).expect("read core/Cargo.toml");
        let package = text
            .split("[workspace.package]")
            .nth(1)
            .expect("[workspace.package] section");
        package
            .lines()
            .find_map(|line| line.trim().strip_prefix("version = "))
            .map(|value| value.trim_matches('"').to_owned())
            .expect("version in [workspace.package]")
    }

    #[test]
    fn c_api_returns_the_workspace_version() {
        // SAFETY: soroband_core_version returns a pointer to a static NUL-terminated string.
        let version = unsafe { CStr::from_ptr(soroband_core_version()) };
        assert_eq!(version.to_str().unwrap(), workspace_version());
    }
}
