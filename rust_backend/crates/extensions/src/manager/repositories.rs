//! Trusted repositories: added with the key the user saw (trust on first
//! add), refreshed to find new extensions and updates, installed from with
//! the package's checksum and signature checked against that key.

use super::{Manager, Network, Source, guard, now};
use crate::Error;
use crate::fetch::{Fetch, FetchRequest, SessionFetch};
use crate::package::Package;
use crate::repository::{self, Index, RepositoryError};
use crate::signing;
use crate::version::Version;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

const FETCH_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RepositoryRecord {
    pub url: String,
    pub name: String,
    pub public_key: String,
    pub added_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub checked_at: Option<String>,
    /// Set when a refresh found a different key; nothing installs from the
    /// repository until it is removed and added again.
    #[serde(default)]
    pub key_changed: bool,
}

fn cache_path(root: &Path, url: &str) -> PathBuf {
    let digest = kalao_core::lower_hex(&Sha256::digest(url.as_bytes()));
    root.join("repositories")
        .join(format!("{}.json", &digest[..16]))
}

fn cached_index(root: &Path, record: &RepositoryRecord) -> Option<Index> {
    let bytes = std::fs::read(cache_path(root, &record.url)).ok()?;
    Index::parse(&bytes, &record.url).ok()
}

/// The trusted repository whose last index lists exactly these bytes with a
/// valid signature, if any.
pub(super) fn listing(
    root: &Path,
    records: &[RepositoryRecord],
    package: &Package,
) -> Option<String> {
    records
        .iter()
        .filter(|record| !record.key_changed)
        .find_map(|record| {
            let index = cached_index(root, record)?;
            index
                .extensions
                .iter()
                .find(|entry| {
                    entry.id == package.manifest.id
                        && entry.sha256 == package.sha256
                        && signing::verify(&record.public_key, &entry.signature, &package.bytes)
                            .is_ok()
                })
                .map(|_| record.name.clone())
        })
}

impl Manager {
    fn app_fetch(&self) -> Arc<dyn Fetch> {
        match &self.network {
            Network::Service(service) => {
                Arc::new(SessionFetch(service.native_session(FETCH_TIMEOUT)))
            }
            Network::Fixed(fetch) => fetch.clone(),
        }
    }

    fn download(&self, url: &str) -> Result<Vec<u8>, Error> {
        let deadline = Instant::now() + FETCH_TIMEOUT;
        let response = self
            .app_fetch()
            .fetch(
                FetchRequest {
                    url: url.to_owned(),
                    method: "GET".into(),
                    ..FetchRequest::default()
                },
                &|| {
                    if Instant::now() >= deadline {
                        Err("download timed out".into())
                    } else {
                        Ok(())
                    }
                },
            )
            .map_err(Error::Network)?;
        if response.status != 200 {
            return Err(Error::Network(format!(
                "{url} answered HTTP {}",
                response.status
            )));
        }
        Ok(response.body)
    }

    fn fetch_index(&self, url: &str) -> Result<(Index, Vec<u8>), Error> {
        repository::validate_repository_url(url)?;
        let bytes = self.download(url)?;
        Ok((Index::parse(&bytes, url)?, bytes))
    }

    pub fn repositories(&self) -> Vec<RepositoryRecord> {
        guard(&self.registry).repositories.clone()
    }

    /// Fetches an index for the trust prompt without saving anything.
    pub fn preview_repository(&self, url: &str) -> Result<Value, Error> {
        let (index, _) = self.fetch_index(url.trim())?;
        Ok(json!({
            "url": url.trim(),
            "name": index.name,
            "publicKey": index.public_key,
            "fingerprint": signing::key_fingerprint(&index.public_key)?,
            "extensions": index.latest_entries(&self.app_version).len(),
        }))
    }

    /// Adds (or re-trusts) a repository with the key the user confirmed.
    /// `fetch` false restores a repository from a backup without the
    /// network; it is checked at the next refresh.
    pub fn add_repository(
        &self,
        url: &str,
        public_key: &str,
        name: Option<&str>,
        fetch: bool,
    ) -> Result<RepositoryRecord, Error> {
        let url = url.trim().to_owned();
        repository::validate_repository_url(&url)?;
        signing::parse_public_key(public_key).map_err(RepositoryError::from)?;
        let (name, cached) = if fetch {
            let (index, bytes) = self.fetch_index(&url)?;
            if index.public_key != public_key {
                return Err(Error::Invalid(
                    "the repository key changed while adding it; check the repository and try again".into(),
                ));
            }
            (index.name, Some(bytes))
        } else {
            (name.unwrap_or(&url).to_owned(), None)
        };
        if let Some(bytes) = cached {
            crate::write_atomic(&cache_path(&self.root, &url), &bytes)?;
        }
        let record = RepositoryRecord {
            url: url.clone(),
            name,
            public_key: public_key.to_owned(),
            added_at: now(),
            checked_at: fetch.then(now),
            key_changed: false,
        };
        let mut registry = guard(&self.registry);
        registry.repositories.retain(|existing| existing.url != url);
        registry.repositories.push(record.clone());
        self.save(&registry)?;
        Ok(record)
    }

    pub fn remove_repository(&self, url: &str) -> Result<(), Error> {
        let mut registry = guard(&self.registry);
        let before = registry.repositories.len();
        registry.repositories.retain(|record| record.url != url);
        if registry.repositories.len() == before {
            return Err(Error::NotFound(url.to_owned()));
        }
        self.save(&registry)?;
        let _ = std::fs::remove_file(cache_path(&self.root, url));
        Ok(())
    }

    /// Refreshes every repository (or one) and lists what each offers, with
    /// `installed`, `update` or `available` per extension. A failed fetch
    /// keeps the last index and reports the error.
    pub fn refresh_repositories(&self, only: Option<&str>) -> Result<Vec<Value>, Error> {
        let records = self.repositories();
        let mut out = Vec::new();
        for record in records
            .into_iter()
            .filter(|r| only.is_none_or(|url| r.url == url))
        {
            let mut error = None;
            let mut index = cached_index(&self.root, &record);
            match self.fetch_index(&record.url) {
                Ok((fresh, bytes)) if fresh.public_key == record.public_key => {
                    crate::write_atomic(&cache_path(&self.root, &record.url), &bytes)?;
                    index = Some(fresh);
                    self.update_record(&record.url, |r| {
                        r.checked_at = Some(now());
                        r.key_changed = false;
                    })?;
                }
                Ok(_) => {
                    self.update_record(&record.url, |r| r.key_changed = true)?;
                    error = Some("the repository key changed; remove and add the repository again to trust the new key".to_owned());
                    index = None;
                }
                Err(failure) => error = Some(failure.to_string()),
            }
            let record = self
                .repositories()
                .into_iter()
                .find(|r| r.url == record.url)
                .unwrap_or(record);
            let entries: Vec<Value> = index
                .as_ref()
                .map(|index| {
                    index
                        .latest_entries(&self.app_version)
                        .into_iter()
                        .map(|entry| {
                            let installed = guard(&self.registry)
                                .extensions
                                .get(&entry.id)
                                .map(|i| i.version.clone());
                            let status = match installed.as_deref().and_then(Version::parse) {
                                None => "available",
                                Some(current) => match Version::parse(&entry.version) {
                                    Some(latest) if latest > current => "update",
                                    _ => "installed",
                                },
                            };
                            json!({
                                "entry": entry,
                                "installedVersion": installed,
                                "status": status,
                            })
                        })
                        .collect()
                })
                .unwrap_or_default();
            out.push(json!({ "repository": record, "entries": entries, "error": error }));
        }
        Ok(out)
    }

    fn update_record(
        &self,
        url: &str,
        apply: impl FnOnce(&mut RepositoryRecord),
    ) -> Result<(), Error> {
        let mut registry = guard(&self.registry);
        if let Some(record) = registry.repositories.iter_mut().find(|r| r.url == url) {
            apply(record);
            self.save(&registry)?;
        }
        Ok(())
    }

    /// Downloads the newest runnable version of `id` from a trusted
    /// repository, verifies it and installs it.
    pub fn install_from_repository(
        &self,
        url: &str,
        id: &str,
        allow_downgrade: bool,
    ) -> Result<Value, Error> {
        let record = self
            .repositories()
            .into_iter()
            .find(|r| r.url == url)
            .ok_or_else(|| Error::NotFound(url.to_owned()))?;
        if record.key_changed {
            return Err(Error::Invalid(
                "the repository key changed; remove and add the repository again to trust the new key".into(),
            ));
        }
        let (index, bytes) = self.fetch_index(&record.url)?;
        if index.public_key != record.public_key {
            self.update_record(&record.url, |r| r.key_changed = true)?;
            return Err(Error::Invalid(
                "the repository key changed; remove and add the repository again to trust the new key".into(),
            ));
        }
        crate::write_atomic(&cache_path(&self.root, &record.url), &bytes)?;
        let entry = index
            .latest(id, &self.app_version)
            .ok_or_else(|| Error::NotFound(format!("{id} in {}", record.name)))?;
        let package =
            repository::verify_package(entry, &record.public_key, self.download(&entry.url)?)?;
        self.install(
            package,
            Source {
                kind: "repository".into(),
                repository: Some(record.url),
                path: None,
            },
            allow_downgrade,
        )
    }
}
