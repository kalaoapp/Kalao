//! `.kalaoext` packages (EXTENSIONS.md §2): a zip with a root `manifest.json`
//! and `index.js`. Everything is read into memory and checked before use;
//! nothing is extracted to disk.

use crate::manifest::{Manifest, ManifestError};
use kalao_core::lower_hex;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::io::{Cursor, Read, Write};
use std::path::Path;
use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipArchive, ZipWriter};

pub const MAX_ENTRIES: usize = 2048;
pub const MAX_EXTRACTED_BYTES: u64 = 64 << 20;
/// A package file itself; larger downloads are refused before unzipping.
pub const MAX_PACKAGE_BYTES: u64 = 64 << 20;
pub const ENTRY_POINT: &str = "index.js";
pub const MANIFEST: &str = "manifest.json";

#[derive(Debug, thiserror::Error)]
pub enum PackageError {
    #[error("not a valid .kalaoext package: {0}")]
    Archive(String),
    #[error("unsafe package entry '{0}'")]
    UnsafeEntry(String),
    #[error("package is too large: {0}")]
    TooLarge(String),
    #[error("package is missing {0}")]
    Missing(&'static str),
    #[error(transparent)]
    Manifest(#[from] ManifestError),
    #[error("{0}")]
    Io(String),
}

/// A checked package: its manifest, its files by relative path, and the
/// SHA-256 of the package bytes (the fingerprint shown before install).
#[derive(Clone, Debug)]
pub struct Package {
    pub manifest: Manifest,
    pub files: BTreeMap<String, Vec<u8>>,
    pub sha256: String,
    pub bytes: Vec<u8>,
}

impl Package {
    pub fn read_file(path: &Path) -> Result<Self, PackageError> {
        let size = std::fs::metadata(path)
            .map_err(|error| PackageError::Io(error.to_string()))?
            .len();
        if size > MAX_PACKAGE_BYTES {
            return Err(PackageError::TooLarge(format!("{size} bytes")));
        }
        let bytes = std::fs::read(path).map_err(|error| PackageError::Io(error.to_string()))?;
        Self::from_bytes(bytes)
    }

    pub fn from_bytes(bytes: Vec<u8>) -> Result<Self, PackageError> {
        if bytes.len() as u64 > MAX_PACKAGE_BYTES {
            return Err(PackageError::TooLarge(format!("{} bytes", bytes.len())));
        }
        let sha256 = lower_hex(&Sha256::digest(&bytes));
        let mut zip = ZipArchive::new(Cursor::new(bytes.as_slice()))
            .map_err(|error| PackageError::Archive(error.to_string()))?;
        if zip.len() > MAX_ENTRIES {
            return Err(PackageError::TooLarge(format!("{} entries", zip.len())));
        }
        let mut files = BTreeMap::new();
        let mut total = 0u64;
        for index in 0..zip.len() {
            let mut entry = zip
                .by_index(index)
                .map_err(|error| PackageError::Archive(error.to_string()))?;
            let name = entry
                .name()
                .map_err(|_| PackageError::UnsafeEntry(format!("entry {index}")))?
                .into_owned();
            if entry.is_symlink() || !safe_name(&name) {
                return Err(PackageError::UnsafeEntry(name));
            }
            if entry.is_dir() {
                continue;
            }
            total = total.saturating_add(entry.size());
            if total > MAX_EXTRACTED_BYTES {
                return Err(PackageError::TooLarge("more than 64 MiB extracted".into()));
            }
            let mut content = Vec::with_capacity(entry.size().min(1 << 20) as usize);
            // The declared size can lie; never read past the remaining budget.
            let budget = MAX_EXTRACTED_BYTES - (total - entry.size());
            (&mut entry)
                .take(budget + 1)
                .read_to_end(&mut content)
                .map_err(|error| PackageError::Archive(error.to_string()))?;
            if content.len() as u64 > budget || content.len() as u64 != entry.size() {
                return Err(PackageError::Archive(format!(
                    "entry '{name}' size mismatch"
                )));
            }
            if files.insert(name.clone(), content).is_some() {
                return Err(PackageError::UnsafeEntry(name));
            }
        }
        let manifest =
            Manifest::parse(files.get(MANIFEST).ok_or(PackageError::Missing(MANIFEST))?)?;
        let entry = files
            .get(ENTRY_POINT)
            .ok_or(PackageError::Missing(ENTRY_POINT))?;
        if std::str::from_utf8(entry).is_err() {
            return Err(PackageError::Archive("index.js is not UTF-8".into()));
        }
        Ok(Self {
            manifest,
            files,
            sha256,
            bytes,
        })
    }

    /// Text of a JavaScript module in the package.
    pub fn source(&self, path: &str) -> Option<&str> {
        self.files
            .get(path)
            .and_then(|bytes| std::str::from_utf8(bytes).ok())
    }
}

/// Relative, `/`-separated, plain characters, no `.`/`..` segments.
fn safe_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 255
        && !name.starts_with('/')
        && !name.contains('\\')
        && !name.contains(':')
        && name
            .trim_end_matches('/')
            .split('/')
            .all(|segment| !segment.is_empty() && segment != "." && segment != "..")
        && name.chars().all(|ch| !ch.is_control())
}

/// Packs a folder into package bytes (the `kalao-ext pack` command and the
/// developer-mode folder install). Hidden files and `fixtures/` are skipped.
pub fn pack_dir(root: &Path) -> Result<Vec<u8>, PackageError> {
    let mut paths = Vec::new();
    collect(root, root, &mut paths)?;
    paths.sort();
    let mut zip = ZipWriter::new(Cursor::new(Vec::new()));
    let options = SimpleFileOptions::default()
        .compression_method(CompressionMethod::Deflated)
        // Fixed timestamps keep the fingerprint stable across packs.
        .last_modified_time(zip::DateTime::default());
    for (name, path) in paths {
        let content = std::fs::read(&path).map_err(|error| PackageError::Io(error.to_string()))?;
        zip.start_file(name, options)
            .map_err(|error| PackageError::Archive(error.to_string()))?;
        zip.write_all(&content)
            .map_err(|error| PackageError::Io(error.to_string()))?;
    }
    let bytes = zip
        .finish()
        .map_err(|error| PackageError::Archive(error.to_string()))?
        .into_inner();
    // Validate what was written exactly as an install would.
    Package::from_bytes(bytes.clone())?;
    Ok(bytes)
}

fn collect(
    root: &Path,
    dir: &Path,
    out: &mut Vec<(String, std::path::PathBuf)>,
) -> Result<(), PackageError> {
    let entries = std::fs::read_dir(dir).map_err(|error| PackageError::Io(error.to_string()))?;
    for entry in entries {
        let entry = entry.map_err(|error| PackageError::Io(error.to_string()))?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') || (dir == root && name == "fixtures") {
            continue;
        }
        let path = entry.path();
        let kind = entry
            .file_type()
            .map_err(|error| PackageError::Io(error.to_string()))?;
        if kind.is_symlink() {
            return Err(PackageError::UnsafeEntry(name));
        }
        if kind.is_dir() {
            collect(root, &path, out)?;
        } else {
            let relative = path
                .strip_prefix(root)
                .map_err(|error| PackageError::Io(error.to_string()))?
                .components()
                .map(|part| part.as_os_str().to_string_lossy().into_owned())
                .collect::<Vec<_>>()
                .join("/");
            out.push((relative, path));
        }
    }
    Ok(())
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use serde_json::json;

    pub(crate) fn manifest_json(id: &str, version: &str, capabilities: &[&str]) -> String {
        json!({
            "schema": 1,
            "id": id,
            "name": "Test extension",
            "version": version,
            "author": "Tests",
            "capabilities": capabilities,
            "network": { "hosts": ["api.example.org"] },
            "settings": [
                { "key": "token", "type": "secret", "label": "Token" },
                { "key": "region", "type": "select", "label": "Region", "options": ["jp", "tw"], "default": "jp" },
                { "key": "login", "type": "button", "label": "Log in", "action": "startLogin" }
            ],
            "auth": { "callbackPath": "callback" }
        })
        .to_string()
    }

    pub(crate) fn zip(entries: &[(&str, &[u8])]) -> Vec<u8> {
        let mut zip = ZipWriter::new(Cursor::new(Vec::new()));
        for (name, content) in entries {
            zip.start_file(*name, SimpleFileOptions::default()).unwrap();
            zip.write_all(content).unwrap();
        }
        zip.finish().unwrap().into_inner()
    }

    pub(crate) fn package(id: &str, version: &str, capabilities: &[&str], js: &str) -> Vec<u8> {
        let manifest = manifest_json(id, version, capabilities);
        zip(&[
            ("manifest.json", manifest.as_bytes()),
            ("index.js", js.as_bytes()),
        ])
    }

    #[test]
    fn reads_a_valid_package() {
        let bytes = package(
            "dev.test.one",
            "1.0.0",
            &["lyrics"],
            "export function searchLyrics() { return []; }",
        );
        let package = Package::from_bytes(bytes.clone()).expect("valid");
        assert_eq!(package.manifest.id, "dev.test.one");
        assert_eq!(package.sha256, lower_hex(&Sha256::digest(&bytes)));
        assert!(package.source("index.js").unwrap().contains("searchLyrics"));
    }

    #[test]
    fn refuses_unsafe_or_incomplete_packages() {
        let manifest = manifest_json("dev.test.one", "1.0.0", &["lyrics"]);
        let m = manifest.as_bytes();
        let cases: Vec<Vec<u8>> = vec![
            zip(&[("index.js", b"")]),
            zip(&[("manifest.json", m)]),
            zip(&[("manifest.json", m), ("index.js", b""), ("../evil.js", b"")]),
            zip(&[("manifest.json", m), ("index.js", b""), ("/abs.js", b"")]),
            zip(&[("manifest.json", m), ("index.js", b""), ("lib\\x.js", b"")]),
            zip(&[("manifest.json", b"{"), ("index.js", b"")]),
            b"not a zip".to_vec(),
        ];
        for bytes in cases {
            assert!(Package::from_bytes(bytes).is_err());
        }
    }

    #[test]
    fn refuses_too_many_entries() {
        let manifest = manifest_json("dev.test.one", "1.0.0", &["lyrics"]);
        let names: Vec<String> = (0..MAX_ENTRIES).map(|i| format!("lib/{i}.js")).collect();
        let mut entries: Vec<(&str, &[u8])> =
            vec![("manifest.json", manifest.as_bytes()), ("index.js", b"")];
        entries.extend(names.iter().map(|name| (name.as_str(), b"".as_slice())));
        assert!(matches!(
            Package::from_bytes(zip(&entries)),
            Err(PackageError::TooLarge(_))
        ));
    }

    #[test]
    fn packs_a_folder_reproducibly() {
        let dir = std::env::temp_dir().join(format!("kalao-pack-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("lib")).unwrap();
        std::fs::create_dir_all(dir.join("fixtures")).unwrap();
        std::fs::write(
            dir.join("manifest.json"),
            manifest_json("dev.test.pack", "1.0.0", &["lyrics"]),
        )
        .unwrap();
        std::fs::write(dir.join("index.js"), "import { x } from './lib/x.js';").unwrap();
        std::fs::write(dir.join("lib/x.js"), "export const x = 1;").unwrap();
        std::fs::write(dir.join("fixtures/f.json"), "{}").unwrap();
        std::fs::write(dir.join(".hidden"), "").unwrap();
        let first = pack_dir(&dir).unwrap();
        let second = pack_dir(&dir).unwrap();
        assert_eq!(first, second);
        let package = Package::from_bytes(first).unwrap();
        assert_eq!(
            package.files.keys().collect::<Vec<_>>(),
            ["index.js", "lib/x.js", "manifest.json"]
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
