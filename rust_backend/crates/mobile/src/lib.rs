// Derived from Mornye (https://github.com/mornyeapp/Mornye), Copyright 2026 zarzet,
// LGPL-3.0-only. Modified for Kalao.
//! UniFFI mobile API. This crate is the only backend the Android app links;
//! the desktop C ABI crate will dispatch the same method table.

mod backend;
mod cancellation;
mod data_jobs;
mod logging;
mod lyrics;
mod media;
mod native_backup;
mod player;

uniffi::setup_scaffolding!();

pub use backend::{BackendError, invoke_application};
pub use cancellation::{CancellationDomain, CancellationError, CancellationRegistry, RequestLease};
pub use data_jobs::{NativeDataJobError, run_native_data_job};
