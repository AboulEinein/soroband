//! Soroband core: the meter engine and storage shared by the app and the `soroband` command.
//!
//! The app links this crate as a static library and calls the C API in [`ffi`].

pub mod day;
pub mod ffi;
pub mod ledger;
pub mod meter;
pub mod service;
pub mod settings;
pub mod store;

/// Version of the core, from the workspace `Cargo.toml`.
#[must_use]
pub fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}
