//! Installed extensions and repositories under one folder (DATA_MODEL.md §2):
//!
//! ```text
//! extensions/
//! ├── registry.json            enabled, priority, plain settings, repositories
//! └── <id>/
//!     ├── package.kalaoext     the installed package, byte for byte
//!     └── storage.json         kalao.storage
//! ```
//!
//! Secrets are never written here: the app keeps them in secure storage and
//! hands them over with `set_secrets`; secrets an extension sets come back
//! through `take_secret_updates`.

mod calls;
mod repositories;
#[cfg(test)]
mod tests;

use crate::fetch::{Fetch, SessionFetch};
use crate::logs::ExtensionLog;
use crate::manifest::{Capability, Manifest, SettingType};
use crate::package::Package;
use crate::runtime::{HostContext, Limits, Runtime};
use crate::storage::{Settings, Storage};
use crate::version::Version;
use crate::{Error, write_atomic};
use kalao_network::policy::NetworkPermissions;
use kalao_network::{NetworkService, NetworkSession};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

pub use repositories::RepositoryRecord;

const PACKAGE_FILE: &str = "package.kalaoext";
const REGISTRY_FILE: &str = "registry.json";
/// Consecutive failures that mark an extension degraded.
const DEGRADED_AFTER: u32 = 3;
/// How long a degraded extension is skipped before it is tried again.
const DEGRADED_FOR: Duration = Duration::from_secs(600);
const SESSION_TIMEOUT: Duration = Duration::from_secs(30);

/// Where `kalao.fetch` and the app's own requests go.
#[derive(Clone)]
pub enum Network {
    /// The app: one `kalao-network` service, a session per extension.
    Service(Arc<NetworkService>),
    /// Tests and the CLI: every request answered by this fetcher.
    Fixed(Arc<dyn Fetch>),
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Source {
    /// `file`, `repository` or `folder` (developer mode).
    pub kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repository: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Installed {
    version: String,
    enabled: bool,
    installed_at: String,
    updated_at: String,
    source: Source,
    sha256: String,
    /// Plain (non-secret) setting values.
    #[serde(default)]
    settings: Map<String, Value>,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct Registry {
    #[serde(default)]
    extensions: BTreeMap<String, Installed>,
    /// Per capability, extension ids in the user's order.
    #[serde(default)]
    priority: BTreeMap<Capability, Vec<String>>,
    #[serde(default)]
    repositories: Vec<RepositoryRecord>,
}

#[derive(Default)]
struct Failures {
    consecutive: u32,
    degraded_at: Option<Instant>,
    last_error: Option<String>,
}

struct Instance {
    manifest: Manifest,
    runtime: Runtime,
    settings: Arc<Settings>,
    session: Option<Arc<NetworkSession>>,
}

type Slot = Arc<Mutex<Option<Arc<Instance>>>>;

pub struct Manager {
    root: PathBuf,
    app_version: Version,
    network: Network,
    developer_mode: AtomicBool,
    limits: Limits,
    registry: Mutex<Registry>,
    slots: Mutex<HashMap<String, Slot>>,
    secrets: Mutex<HashMap<String, Map<String, Value>>>,
    secret_updates: Mutex<BTreeMap<String, Map<String, Value>>>,
    logs: Mutex<HashMap<String, Arc<ExtensionLog>>>,
    failures: Mutex<HashMap<String, Failures>>,
    health: Mutex<HashMap<String, Value>>,
}

/// Loads the package in a scratch VM (no network, no storage) and checks it
/// exports every function its capabilities and buttons need. Returns the
/// exported functions.
pub fn check_package(package: &Package, limits: &Limits) -> Result<Vec<String>, Error> {
    let manifest = &package.manifest;
    let runtime = Runtime::start(
        package,
        HostContext {
            extension_id: manifest.id.clone(),
            manifest: manifest.clone(),
            settings: Arc::new(Settings::new(manifest.clone(), Map::new())),
            storage: Arc::new(Storage::new(None)),
            fetch: Arc::new(crate::fetch::FixtureFetch::new(Vec::new(), &[])),
            log: Arc::new(ExtensionLog::default()),
            auth_url_check: Arc::new(|_| Err("not available while installing".into())),
        },
        limits.clone(),
    )
    .map_err(|error| Error::Invalid(format!("the extension failed to load: {error}")))?;
    let missing: Vec<&str> = manifest
        .capabilities
        .iter()
        .flat_map(|capability| capability.required_functions().iter().copied())
        .chain(
            manifest
                .settings
                .iter()
                .filter_map(|setting| setting.action.as_deref()),
        )
        .filter(|function| !runtime.exports_function(function))
        .collect();
    let exports = runtime.exports().to_vec();
    runtime.shutdown();
    if !missing.is_empty() {
        return Err(Error::Invalid(format!(
            "index.js does not export {}",
            missing.join(", ")
        )));
    }
    Ok(exports)
}

fn guard<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

fn now() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}

impl Manager {
    pub fn new(root: PathBuf, app_version: &str, network: Network) -> Result<Self, Error> {
        std::fs::create_dir_all(&root)?;
        let app_version = Version::parse(app_version)
            .ok_or_else(|| Error::Invalid(format!("app version '{app_version}' is not semver")))?;
        let registry = match std::fs::read(root.join(REGISTRY_FILE)) {
            Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_default(),
            Err(_) => Registry::default(),
        };
        Ok(Self {
            root,
            app_version,
            network,
            developer_mode: AtomicBool::new(false),
            limits: Limits::default(),
            registry: Mutex::new(registry),
            slots: Mutex::default(),
            secrets: Mutex::default(),
            secret_updates: Mutex::default(),
            logs: Mutex::default(),
            failures: Mutex::default(),
            health: Mutex::default(),
        })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn app_version(&self) -> &Version {
        &self.app_version
    }

    /// Developer mode (EXTENSIONS.md §8): HTTP to `localhost` and installs
    /// from a folder. Running extensions restart with the new policy.
    pub fn set_developer_mode(&self, enabled: bool) {
        if self.developer_mode.swap(enabled, Ordering::AcqRel) != enabled {
            if let Network::Service(service) = &self.network {
                service.set_allow_private_network(enabled);
            }
            self.invalidate_all();
        }
    }

    pub fn developer_mode(&self) -> bool {
        self.developer_mode.load(Ordering::Acquire)
    }

    fn package_path(&self, id: &str) -> PathBuf {
        self.root.join(id).join(PACKAGE_FILE)
    }

    fn save(&self, registry: &Registry) -> Result<(), Error> {
        let bytes = serde_json::to_vec_pretty(registry).map_err(|e| Error::Io(e.to_string()))?;
        write_atomic(&self.root.join(REGISTRY_FILE), &bytes)?;
        Ok(())
    }

    fn log(&self, id: &str) -> Arc<ExtensionLog> {
        guard(&self.logs).entry(id.to_owned()).or_default().clone()
    }

    fn slot(&self, id: &str) -> Slot {
        guard(&self.slots).entry(id.to_owned()).or_default().clone()
    }

    /// Drops the running VM; the next call starts a fresh one.
    fn invalidate(&self, id: &str) {
        if let Some(slot) = guard(&self.slots).remove(id)
            && let Some(instance) = guard(&slot).take()
        {
            instance.runtime.shutdown();
        }
    }

    fn invalidate_all(&self) {
        let ids: Vec<String> = guard(&self.slots).keys().cloned().collect();
        for id in ids {
            self.invalidate(&id);
        }
    }

    // ---- Secrets --------------------------------------------------------

    /// Replaces the secret values the app holds for `id` (from secure storage).
    pub fn set_secrets(&self, id: &str, values: Map<String, Value>) {
        let values = values
            .into_iter()
            .filter(|(_, value)| value.as_str().is_some_and(|text| !text.is_empty()))
            .collect();
        guard(&self.secrets).insert(id.to_owned(), values);
        self.invalidate(id);
    }

    /// Secrets set by extensions since the last call, for secure storage
    /// (`null` deletes).
    pub fn take_secret_updates(&self) -> BTreeMap<String, Map<String, Value>> {
        std::mem::take(&mut *guard(&self.secret_updates))
    }

    // ---- Installed list -------------------------------------------------

    fn read_package(&self, id: &str) -> Result<Package, Error> {
        Ok(Package::read_file(&self.package_path(id))?)
    }

    fn info_value(&self, id: &str, installed: &Installed, manifest: &Manifest) -> Value {
        let secrets = guard(&self.secrets).get(id).cloned().unwrap_or_default();
        let failures = guard(&self.failures);
        let failure = failures.get(id);
        let degraded =
            failure.is_some_and(|f| f.degraded_at.is_some_and(|at| at.elapsed() < DEGRADED_FOR));
        let missing_secrets: Vec<&str> = manifest
            .settings
            .iter()
            .filter(|s| s.kind == SettingType::Secret && !secrets.contains_key(&s.key))
            .map(|s| s.key.as_str())
            .collect();
        json!({
            "id": id,
            "manifest": manifest,
            "enabled": installed.enabled,
            "version": installed.version,
            "installedAt": installed.installed_at,
            "updatedAt": installed.updated_at,
            "source": installed.source,
            "sha256": installed.sha256,
            "packagePath": self.package_path(id).to_string_lossy(),
            "settings": installed.settings,
            "secretsSet": secrets.keys().collect::<Vec<_>>(),
            "missingSecrets": missing_secrets,
            "degraded": degraded,
            "lastError": failure.and_then(|f| f.last_error.clone()),
            "health": guard(&self.health).get(id).cloned().unwrap_or(Value::Null),
            "supported": manifest.supports_app(&self.app_version),
            "storageBytes": Storage::new(Some(self.root.join(id).join("storage.json"))).bytes_used(),
        })
    }

    pub fn list(&self) -> Vec<Value> {
        let entries: Vec<(String, Installed)> = guard(&self.registry)
            .extensions
            .iter()
            .map(|(id, installed)| (id.clone(), installed.clone()))
            .collect();
        entries
            .iter()
            .filter_map(|(id, installed)| {
                let package = self.read_package(id).ok()?;
                Some(self.info_value(id, installed, &package.manifest))
            })
            .collect()
    }

    pub fn info(&self, id: &str) -> Result<Value, Error> {
        let installed = guard(&self.registry)
            .extensions
            .get(id)
            .cloned()
            .ok_or_else(|| Error::NotFound(id.to_owned()))?;
        let package = self.read_package(id)?;
        Ok(self.info_value(id, &installed, &package.manifest))
    }

    pub fn priority(&self) -> BTreeMap<Capability, Vec<String>> {
        guard(&self.registry).priority.clone()
    }

    // ---- Install --------------------------------------------------------

    /// What the install prompt shows: manifest, fingerprint, whether it is an
    /// update or a downgrade, and which trusted repository lists these bytes.
    pub fn inspect(&self, package: &Package) -> Value {
        let registry = guard(&self.registry);
        let installed = registry.extensions.get(&package.manifest.id);
        let ordering = installed
            .and_then(|installed| Version::parse(&installed.version))
            .map(|current| package.manifest.parsed_version().cmp(&current));
        let verified_by = repositories::listing(&self.root, &registry.repositories, package);
        json!({
            "manifest": package.manifest,
            "sha256": package.sha256,
            "bytes": package.bytes.len(),
            "installedVersion": installed.map(|i| i.version.clone()),
            "isUpdate": ordering == Some(std::cmp::Ordering::Greater),
            "isDowngrade": ordering == Some(std::cmp::Ordering::Less),
            "isReinstall": ordering == Some(std::cmp::Ordering::Equal),
            "supported": package.manifest.supports_app(&self.app_version),
            "verifiedBy": verified_by,
        })
    }

    pub fn inspect_file(&self, path: &Path) -> Result<Value, Error> {
        Ok(self.inspect(&Package::read_file(path)?))
    }

    pub fn install_file(&self, path: &Path, allow_downgrade: bool) -> Result<Value, Error> {
        let package = Package::read_file(path)?;
        self.install(
            package,
            Source {
                kind: "file".into(),
                ..Source::default()
            },
            allow_downgrade,
        )
    }

    /// Developer mode: packs a folder and installs it; installing the same
    /// folder again is the live reload.
    pub fn install_folder(&self, path: &Path) -> Result<Value, Error> {
        if !self.developer_mode() {
            return Err(Error::Invalid(
                "installing from a folder needs developer mode".into(),
            ));
        }
        let package = Package::from_bytes(crate::package::pack_dir(path)?)?;
        self.install(
            package,
            Source {
                kind: "folder".into(),
                path: Some(path.to_string_lossy().into_owned()),
                ..Source::default()
            },
            true,
        )
    }

    /// Checks the package runs and exports its capabilities' functions,
    /// then replaces any installed version, keeping its settings, state and
    /// priority.
    pub fn install(
        &self,
        package: Package,
        source: Source,
        allow_downgrade: bool,
    ) -> Result<Value, Error> {
        let manifest = package.manifest.clone();
        let id = manifest.id.clone();
        if !manifest.supports_app(&self.app_version) {
            return Err(Error::Invalid(format!(
                "{} needs Kalao {} or newer",
                manifest.name,
                manifest.min_kalao.as_deref().unwrap_or("?")
            )));
        }
        if let Some(current) = guard(&self.registry)
            .extensions
            .get(&id)
            .and_then(|installed| Version::parse(&installed.version))
            && manifest.parsed_version() < current
            && !allow_downgrade
        {
            return Err(Error::Invalid(format!(
                "{} {} is older than the installed {current}",
                manifest.name, manifest.version
            )));
        }
        self.validate_runtime(&package)?;
        self.invalidate(&id);
        std::fs::create_dir_all(self.root.join(&id))?;
        write_atomic(&self.package_path(&id), &package.bytes)?;
        let mut registry = guard(&self.registry);
        let stamp = now();
        let previous = registry.extensions.remove(&id);
        let settings = previous
            .as_ref()
            .map(|p| {
                // Keep values the new manifest still declares, as non-secrets.
                p.settings
                    .iter()
                    .filter(|(key, _)| {
                        manifest.setting(key).is_some_and(|s| {
                            !matches!(s.kind, SettingType::Secret | SettingType::Button)
                        })
                    })
                    .map(|(k, v)| (k.clone(), v.clone()))
                    .collect()
            })
            .unwrap_or_default();
        registry.extensions.insert(
            id.clone(),
            Installed {
                version: manifest.version.clone(),
                enabled: previous.as_ref().is_none_or(|p| p.enabled),
                installed_at: previous
                    .as_ref()
                    .map_or(stamp.clone(), |p| p.installed_at.clone()),
                updated_at: stamp,
                source,
                sha256: package.sha256.clone(),
                settings,
            },
        );
        for capability in Capability::ALL {
            let order = registry.priority.entry(capability).or_default();
            if manifest.has(capability) {
                if !order.contains(&id) {
                    order.push(id.clone());
                }
            } else {
                order.retain(|other| other != &id);
            }
        }
        registry.priority.retain(|_, order| !order.is_empty());
        self.save(&registry)?;
        let installed = registry.extensions[&id].clone();
        drop(registry);
        guard(&self.failures).remove(&id);
        Ok(self.info_value(&id, &installed, &manifest))
    }

    fn validate_runtime(&self, package: &Package) -> Result<(), Error> {
        check_package(package, &self.limits).map(|_| ())
    }

    pub fn uninstall(&self, id: &str) -> Result<(), Error> {
        self.invalidate(id);
        let mut registry = guard(&self.registry);
        if registry.extensions.remove(id).is_none() {
            return Err(Error::NotFound(id.to_owned()));
        }
        for order in registry.priority.values_mut() {
            order.retain(|other| other != id);
        }
        registry.priority.retain(|_, order| !order.is_empty());
        self.save(&registry)?;
        drop(registry);
        let directory = self.root.join(id);
        if directory.starts_with(&self.root) && directory != self.root {
            let _ = std::fs::remove_dir_all(directory);
        }
        guard(&self.secrets).remove(id);
        guard(&self.failures).remove(id);
        guard(&self.health).remove(id);
        guard(&self.logs).remove(id);
        Ok(())
    }

    pub fn set_enabled(&self, id: &str, enabled: bool) -> Result<(), Error> {
        let mut registry = guard(&self.registry);
        let installed = registry
            .extensions
            .get_mut(id)
            .ok_or_else(|| Error::NotFound(id.to_owned()))?;
        installed.enabled = enabled;
        self.save(&registry)?;
        drop(registry);
        if !enabled {
            self.invalidate(id);
        }
        guard(&self.failures).remove(id);
        Ok(())
    }

    /// Sets the order for one capability; ids missing from `ids` keep their
    /// relative order after the listed ones.
    pub fn set_priority(&self, capability: Capability, ids: &[String]) -> Result<(), Error> {
        let mut registry = guard(&self.registry);
        let current = registry
            .priority
            .get(&capability)
            .cloned()
            .unwrap_or_default();
        let mut order: Vec<String> = ids
            .iter()
            .filter(|id| current.contains(id))
            .cloned()
            .collect();
        order.dedup();
        order.extend(current.into_iter().filter(|id| !ids.contains(id)));
        registry.priority.insert(capability, order);
        self.save(&registry)
    }

    pub fn set_setting(&self, id: &str, key: &str, value: Value) -> Result<(), Error> {
        let manifest = self.read_package(id)?.manifest;
        let setting = manifest
            .setting(key)
            .ok_or_else(|| Error::Invalid(format!("{id} has no setting '{key}'")))?;
        let value = crate::storage::coerce(setting.kind, &setting.options, value)
            .ok_or_else(|| Error::Invalid(format!("value for '{key}' does not match its type")))?;
        if setting.kind == SettingType::Secret {
            let mut secrets = guard(&self.secrets);
            let values = secrets.entry(id.to_owned()).or_default();
            match value.as_str() {
                Some(text) if !text.is_empty() => values.insert(key.to_owned(), value),
                _ => values.remove(key),
            };
        } else {
            let mut registry = guard(&self.registry);
            let installed = registry
                .extensions
                .get_mut(id)
                .ok_or_else(|| Error::NotFound(id.to_owned()))?;
            if value.is_null() {
                installed.settings.remove(key);
            } else {
                installed.settings.insert(key.to_owned(), value);
            }
            self.save(&registry)?;
        }
        self.invalidate(id);
        Ok(())
    }

    pub fn logs(&self, id: &str) -> Vec<crate::logs::LogEntry> {
        self.log(id).entries()
    }

    // ---- Runtimes -------------------------------------------------------

    /// Hosts the extension may reach now: `network.hosts` without the hosts
    /// of `grantsNetwork` settings that are still empty.
    fn active_hosts(manifest: &Manifest, values: &Map<String, Value>) -> Vec<String> {
        let locked: Vec<&str> = manifest
            .settings
            .iter()
            .filter(|setting| {
                setting.grants_network.is_some()
                    && values
                        .get(&setting.key)
                        .and_then(Value::as_str)
                        .is_none_or(str::is_empty)
            })
            .filter_map(|setting| setting.grants_network.as_deref())
            .collect();
        manifest
            .network
            .hosts
            .iter()
            .filter(|host| !locked.contains(&host.as_str()))
            .cloned()
            .collect()
    }

    fn instance(&self, id: &str) -> Result<Arc<Instance>, Error> {
        let installed = guard(&self.registry)
            .extensions
            .get(id)
            .cloned()
            .ok_or_else(|| Error::NotFound(id.to_owned()))?;
        if !installed.enabled {
            return Err(Error::Invalid(format!("{id} is disabled")));
        }
        let slot = self.slot(id);
        let mut slot = guard(&slot);
        if let Some(instance) = slot.as_ref()
            && !instance.runtime.is_retired()
        {
            return Ok(instance.clone());
        }
        let package = self.read_package(id)?;
        let manifest = package.manifest.clone();
        let mut values = installed.settings.clone();
        values.extend(guard(&self.secrets).get(id).cloned().unwrap_or_default());
        let hosts = Self::active_hosts(&manifest, &values);
        let developer = self.developer_mode();
        let (fetch, session): (Arc<dyn Fetch>, Option<Arc<NetworkSession>>) = match &self.network {
            Network::Service(service) => {
                let session = service.session(
                    NetworkPermissions {
                        domains: hosts,
                        allow_http: developer,
                    },
                    SESSION_TIMEOUT,
                );
                (Arc::new(SessionFetch(session.clone())), Some(session))
            }
            Network::Fixed(fetch) => (fetch.clone(), None),
        };
        let auth_check: crate::runtime::host::AuthUrlCheck = match &session {
            Some(session) => {
                let session = session.clone();
                Arc::new(move |url| session.validate_auth_url(url, || Ok(())).map(|_| ()))
            }
            None => Arc::new(|url| {
                if url.starts_with("https://") {
                    Ok(())
                } else {
                    Err("invalid auth URL: only https is allowed".into())
                }
            }),
        };
        let settings = Arc::new(Settings::new(manifest.clone(), values));
        let runtime = Runtime::start(
            &package,
            HostContext {
                extension_id: id.to_owned(),
                manifest: manifest.clone(),
                settings: settings.clone(),
                storage: Arc::new(Storage::new(Some(self.root.join(id).join("storage.json")))),
                fetch,
                log: self.log(id),
                auth_url_check: auth_check,
            },
            self.limits.clone(),
        )?;
        let instance = Arc::new(Instance {
            manifest,
            runtime,
            settings,
            session,
        });
        *slot = Some(instance.clone());
        Ok(instance)
    }

    /// The extension's network session (allowlist, cookies), for streaming
    /// what its `resolveAudio` returned. `None` without a network service.
    pub fn network_session(&self, id: &str) -> Result<Option<Arc<NetworkSession>>, Error> {
        Ok(self.instance(id)?.session.clone())
    }

    /// Calls `function` with one JSON argument. Records failures for the
    /// degraded state and persists settings the extension changed.
    pub fn call(
        &self,
        id: &str,
        function: &str,
        argument: &Value,
        timeout: Duration,
    ) -> Result<Value, Error> {
        let instance = self.instance(id)?;
        let result = instance
            .runtime
            .call(function, &argument.to_string(), timeout)
            .and_then(|text| {
                serde_json::from_str::<Value>(&text).map_err(|e| Error::Script(e.to_string()))
            });
        self.persist_changes(id, &instance)?;
        match &result {
            Ok(_) => self.record_success(id),
            Err(Error::MissingFunction(_)) => {}
            Err(error) => {
                self.record_failure(id, &error.to_string());
                self.log(id).push(
                    id,
                    "error",
                    &format!("{function} failed: {error}"),
                    &instance.settings.secret_values(),
                );
            }
        }
        result
    }

    fn persist_changes(&self, id: &str, instance: &Instance) -> Result<(), Error> {
        let changes = instance.settings.take_changes();
        if changes.is_empty() {
            return Ok(());
        }
        let mut grants_changed = false;
        let mut plain = Vec::new();
        for (key, value) in changes {
            let Some(setting) = instance.manifest.setting(&key) else {
                continue;
            };
            grants_changed |= setting.grants_network.is_some();
            if setting.kind == SettingType::Secret {
                let mut secrets = guard(&self.secrets);
                let values = secrets.entry(id.to_owned()).or_default();
                match value.as_str() {
                    Some(text) if !text.is_empty() => values.insert(key.clone(), value.clone()),
                    _ => values.remove(&key),
                };
                guard(&self.secret_updates)
                    .entry(id.to_owned())
                    .or_default()
                    .insert(key, value);
            } else {
                plain.push((key, value));
            }
        }
        if !plain.is_empty() {
            let mut registry = guard(&self.registry);
            if let Some(installed) = registry.extensions.get_mut(id) {
                for (key, value) in plain {
                    if value.is_null() {
                        installed.settings.remove(&key);
                    } else {
                        installed.settings.insert(key, value);
                    }
                }
                self.save(&registry)?;
            }
        }
        if grants_changed {
            // The allowlist changed: the next call gets a new session.
            if let Some(slot) = guard(&self.slots).remove(id) {
                guard(&slot).take();
            }
        }
        Ok(())
    }

    fn record_success(&self, id: &str) {
        guard(&self.failures).remove(id);
    }

    fn record_failure(&self, id: &str, error: &str) {
        let mut failures = guard(&self.failures);
        let entry = failures.entry(id.to_owned()).or_default();
        entry.consecutive += 1;
        entry.last_error = Some(error.to_owned());
        if entry.consecutive >= DEGRADED_AFTER {
            entry.degraded_at = Some(Instant::now());
        }
    }

    fn is_degraded(&self, id: &str) -> bool {
        guard(&self.failures)
            .get(id)
            .and_then(|failure| failure.degraded_at)
            .is_some_and(|at| at.elapsed() < DEGRADED_FOR)
    }

    /// Enabled extensions with `capability`, in the user's order, without
    /// degraded ones (fallback chains skip them until they recover).
    pub fn providers(&self, capability: Capability) -> Vec<String> {
        let registry = guard(&self.registry);
        let ordered = registry
            .priority
            .get(&capability)
            .cloned()
            .unwrap_or_default();
        let ids: Vec<String> = ordered
            .into_iter()
            .filter(|id| {
                registry
                    .extensions
                    .get(id)
                    .is_some_and(|installed| installed.enabled)
            })
            .collect();
        drop(registry);
        ids.into_iter().filter(|id| !self.is_degraded(id)).collect()
    }

    pub fn display_name(&self, id: &str) -> String {
        self.read_package(id)
            .map(|package| package.manifest.name)
            .unwrap_or_else(|_| id.to_owned())
    }

    /// Runs the manifest's health checks; a passing check clears the
    /// degraded state.
    pub fn check_health(&self, id: &str) -> Result<Value, Error> {
        let instance = self.instance(id)?;
        let fetch: Arc<dyn Fetch> = match (&instance.session, &self.network) {
            (Some(session), _) => Arc::new(SessionFetch(session.clone())),
            (None, Network::Fixed(fetch)) => fetch.clone(),
            (None, Network::Service(_)) => return Err(Error::Network("no network session".into())),
        };
        let mut checks = Vec::new();
        let mut all_ok = true;
        for check in &instance.manifest.health {
            let started = Instant::now();
            let deadline = started + Duration::from_secs(8);
            let result = fetch.fetch(
                crate::fetch::FetchRequest {
                    url: check.url.clone(),
                    method: check.method.clone(),
                    ..Default::default()
                },
                &|| {
                    if Instant::now() >= deadline {
                        Err("health check timed out".into())
                    } else {
                        Ok(())
                    }
                },
            );
            let (ok, status, error) = match result {
                Ok(response) => (response.status < 500, Some(response.status), None),
                Err(error) => (false, None, Some(error)),
            };
            all_ok &= ok;
            checks.push(json!({
                "id": check.id,
                "ok": ok,
                "status": status,
                "error": error,
                "latencyMs": started.elapsed().as_millis() as u64,
            }));
        }
        let report = json!({ "ok": all_ok, "checkedAt": now(), "checks": checks });
        if all_ok && !instance.manifest.health.is_empty() {
            self.record_success(id);
        }
        guard(&self.health).insert(id.to_owned(), report.clone());
        Ok(report)
    }

    /// Runs a `button` setting's function (login flows may wait for the
    /// browser, so actions get up to three minutes).
    pub fn invoke_action(&self, id: &str, key: &str) -> Result<Value, Error> {
        let manifest = self.read_package(id)?.manifest;
        let action = manifest
            .setting(key)
            .filter(|setting| setting.kind == SettingType::Button)
            .and_then(|setting| setting.action.clone())
            .ok_or_else(|| Error::Invalid(format!("{id} has no button '{key}'")))?;
        self.call(id, &action, &Value::Null, Duration::from_secs(180))
    }
}
