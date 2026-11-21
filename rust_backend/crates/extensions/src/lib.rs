//! Kalao's extension framework (EXTENSIONS.md): `.kalaoext` packages with a
//! manifest, run in a QuickJS sandbox with an allowlisted `kalao.fetch`,
//! installed from files or signed repositories, and queried for lyrics,
//! metadata, artwork and audio. Kalao-sized: it keeps the shape of Mornye's
//! extension runtime (one worker VM per extension, limits, a host object over
//! native calls) without Mornye's download, file and legacy hosts.

pub mod auth;
pub mod capabilities;
pub mod crypto;
pub mod fetch;
pub mod html;
pub mod logs;
pub mod manager;
pub mod manifest;
pub mod package;
pub mod repository;
pub mod runtime;
pub mod signing;
pub mod storage;
pub mod version;

pub use manager::Manager;
pub use manifest::{Capability, Manifest};
pub use package::Package;
pub use runtime::{HostContext, Limits, Runtime};

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error(transparent)]
    Package(#[from] package::PackageError),
    #[error(transparent)]
    Repository(#[from] repository::RepositoryError),
    #[error(transparent)]
    Signing(#[from] signing::SigningError),
    #[error("{0}")]
    Script(String),
    #[error("execution timeout exceeded")]
    Timeout,
    #[error("extension function not found: {0}")]
    MissingFunction(String),
    #[error("extension runtime closed")]
    Closed,
    #[error("extension is not installed: {0}")]
    NotFound(String),
    #[error("{0}")]
    Invalid(String),
    #[error("{0}")]
    Network(String),
    #[error("{0}")]
    Io(String),
}

impl From<std::io::Error> for Error {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error.to_string())
    }
}

/// Writes through a temporary file and a rename, so a crash never leaves a
/// half-written registry, storage or package.
pub(crate) fn write_atomic(path: &std::path::Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let temporary = path.with_extension("tmp");
    std::fs::write(&temporary, bytes)?;
    std::fs::rename(&temporary, path)
}
