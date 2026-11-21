//! Extension repositories (EXTENSIONS.md §7): an `index.json` with the
//! repository's ed25519 key and one signed entry per package.

use crate::package::Package;
use crate::signing;
use crate::version::Version;
use kalao_network::url::UrlParts;
use serde::{Deserialize, Serialize};

pub const MAX_INDEX_BYTES: usize = 4 << 20;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub id: String,
    pub version: String,
    pub url: String,
    pub sha256: String,
    pub signature: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub min_kalao: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub capabilities: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Index {
    pub name: String,
    pub public_key: String,
    #[serde(default)]
    pub extensions: Vec<Entry>,
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum RepositoryError {
    #[error("invalid repository index: {0}")]
    Index(String),
    #[error("package checksum does not match the repository")]
    Checksum,
    #[error(transparent)]
    Signing(#[from] signing::SigningError),
    #[error("package is {found}, the repository lists {expected}")]
    Identity { expected: String, found: String },
}

/// A repository URL must be HTTPS without credentials.
pub fn validate_repository_url(url: &str) -> Result<(), RepositoryError> {
    let parts =
        UrlParts::parse(url.trim()).ok_or_else(|| RepositoryError::Index("not a URL".into()))?;
    if parts.scheme != "https" || parts.hostname.is_empty() || parts.has_credentials {
        return Err(RepositoryError::Index(
            "the repository URL must be https://".into(),
        ));
    }
    Ok(())
}

impl Index {
    /// Parses and checks an index fetched from `index_url`; entry URLs are
    /// resolved against it.
    pub fn parse(bytes: &[u8], index_url: &str) -> Result<Self, RepositoryError> {
        if bytes.len() > MAX_INDEX_BYTES {
            return Err(RepositoryError::Index(
                "index.json is larger than 4 MiB".into(),
            ));
        }
        let mut index: Index = serde_json::from_slice(bytes)
            .map_err(|error| RepositoryError::Index(error.to_string()))?;
        if index.name.trim().is_empty() {
            return Err(RepositoryError::Index("name is required".into()));
        }
        signing::parse_public_key(&index.public_key)?;
        let base = UrlParts::parse(index_url)
            .ok_or_else(|| RepositoryError::Index("bad repository URL".into()))?;
        let mut seen = std::collections::BTreeSet::new();
        for entry in &mut index.extensions {
            if Version::parse(&entry.version).is_none() {
                return Err(RepositoryError::Index(format!(
                    "{}: version '{}' is not semver",
                    entry.id, entry.version
                )));
            }
            if !seen.insert((entry.id.clone(), entry.version.clone())) {
                return Err(RepositoryError::Index(format!(
                    "{} {} is listed twice",
                    entry.id, entry.version
                )));
            }
            if entry.sha256.len() != 64 || !entry.sha256.bytes().all(|b| b.is_ascii_hexdigit()) {
                return Err(RepositoryError::Index(format!("{}: bad sha256", entry.id)));
            }
            entry.sha256.make_ascii_lowercase();
            let resolved = base
                .resolve_reference(&entry.url)
                .ok_or_else(|| RepositoryError::Index(format!("{}: bad url", entry.id)))?;
            if resolved.scheme != "https" {
                return Err(RepositoryError::Index(format!(
                    "{}: package URLs must be https",
                    entry.id
                )));
            }
            entry.url = resolved.display_url();
        }
        Ok(index)
    }

    /// The newest entry for `id` that this app version can run.
    pub fn latest(&self, id: &str, app_version: &Version) -> Option<&Entry> {
        self.extensions
            .iter()
            .filter(|entry| entry.id == id)
            .filter(|entry| {
                entry
                    .min_kalao
                    .as_deref()
                    .and_then(Version::parse)
                    .is_none_or(|minimum| *app_version >= minimum)
            })
            .max_by(|a, b| Version::parse(&a.version).cmp(&Version::parse(&b.version)))
    }

    /// Distinct extension ids, each with its newest runnable entry.
    pub fn latest_entries(&self, app_version: &Version) -> Vec<&Entry> {
        let mut ids: Vec<&str> = self.extensions.iter().map(|e| e.id.as_str()).collect();
        ids.sort_unstable();
        ids.dedup();
        ids.into_iter()
            .filter_map(|id| self.latest(id, app_version))
            .collect()
    }
}

/// Checks downloaded package bytes against their entry and the repository key
/// the user trusted, then parses them.
pub fn verify_package(
    entry: &Entry,
    trusted_key: &str,
    bytes: Vec<u8>,
) -> Result<Package, crate::Error> {
    let digest = kalao_core::lower_hex(&<sha2::Sha256 as sha2::Digest>::digest(&bytes));
    if digest != entry.sha256 {
        return Err(RepositoryError::Checksum.into());
    }
    signing::verify(trusted_key, &entry.signature, &bytes).map_err(RepositoryError::from)?;
    let package = Package::from_bytes(bytes)?;
    if package.manifest.id != entry.id || package.manifest.version != entry.version {
        return Err(RepositoryError::Identity {
            expected: format!("{} {}", entry.id, entry.version),
            found: format!("{} {}", package.manifest.id, package.manifest.version),
        }
        .into());
    }
    Ok(package)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::package::tests::package;
    use serde_json::json;

    pub(crate) fn signed_index(
        secret: &str,
        public: &str,
        packages: &[(&str, &str, &[u8])],
    ) -> String {
        json!({
            "name": "Test Repo",
            "publicKey": public,
            "extensions": packages.iter().map(|(id, version, bytes)| json!({
                "id": id,
                "version": version,
                "url": format!("pkg/{id}-{version}.kalaoext"),
                "sha256": kalao_core::lower_hex(&<sha2::Sha256 as sha2::Digest>::digest(bytes)),
                "signature": signing::sign(secret, bytes).unwrap(),
            })).collect::<Vec<_>>(),
        })
        .to_string()
    }

    #[test]
    fn parses_resolves_and_verifies() {
        let (secret, public) = signing::generate().unwrap();
        let bytes = package("dev.test.repo", "1.1.0", &["lyrics"], "export const a = 1;");
        let old = package("dev.test.repo", "1.0.0", &["lyrics"], "export const a = 0;");
        let index = Index::parse(
            signed_index(
                &secret,
                &public,
                &[
                    ("dev.test.repo", "1.1.0", &bytes),
                    ("dev.test.repo", "1.0.0", &old),
                ],
            )
            .as_bytes(),
            "https://repo.example.org/kalao/index.json",
        )
        .unwrap();
        let app = Version::parse("0.1.0").unwrap();
        let latest = index.latest("dev.test.repo", &app).unwrap();
        assert_eq!(latest.version, "1.1.0");
        assert_eq!(
            latest.url,
            "https://repo.example.org/kalao/pkg/dev.test.repo-1.1.0.kalaoext"
        );
        assert_eq!(index.latest_entries(&app).len(), 1);
        let package = verify_package(latest, &public, bytes.clone()).unwrap();
        assert_eq!(package.manifest.version, "1.1.0");

        // Tampered bytes, another key, or the wrong package are refused.
        let mut tampered = bytes.clone();
        tampered.push(0);
        assert!(verify_package(latest, &public, tampered).is_err());
        let (_, other) = signing::generate().unwrap();
        assert!(verify_package(latest, &other, bytes).is_err());
        assert!(verify_package(latest, &public, old).is_err());
    }

    #[test]
    fn rejects_bad_indexes() {
        let (_, public) = signing::generate().unwrap();
        let base = "https://repo.example.org/index.json";
        for index in [
            json!({"name": "", "publicKey": public}),
            json!({"name": "R", "publicKey": "nope"}),
            json!({"name": "R", "publicKey": public, "extensions": [
                {"id": "a.b", "version": "1", "url": "x", "sha256": "00", "signature": "ed25519:"}]}),
            json!({"name": "R", "publicKey": public, "extensions": [
                {"id": "a.b", "version": "1.0.0", "url": "http://x.org/p", "sha256": "0".repeat(64), "signature": "ed25519:"}]}),
        ] {
            assert!(
                Index::parse(index.to_string().as_bytes(), base).is_err(),
                "{index}"
            );
        }
        assert!(validate_repository_url("http://repo.example.org").is_err());
        assert!(validate_repository_url("https://repo.example.org/index.json").is_ok());
    }
}
