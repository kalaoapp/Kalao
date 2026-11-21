//! `kalao.storage`: a private key-value store per extension (≤ 5 MiB),
//! persisted as one JSON file, and the extension's settings values.

use crate::manifest::{Manifest, SettingType};
use serde_json::{Map, Value};
use std::path::PathBuf;
use std::sync::{Mutex, PoisonError};

pub const MAX_STORAGE_BYTES: usize = 5 << 20;

pub struct Storage {
    path: Option<PathBuf>,
    values: Mutex<Option<Map<String, Value>>>,
}

impl Storage {
    /// `None` keeps the store in memory (CLI and tests).
    pub fn new(path: Option<PathBuf>) -> Self {
        Self {
            path,
            values: Mutex::new(None),
        }
    }

    fn with<T>(&self, apply: impl FnOnce(&mut Map<String, Value>) -> T) -> T {
        let mut guard = self.values.lock().unwrap_or_else(PoisonError::into_inner);
        let values = guard.get_or_insert_with(|| {
            self.path
                .as_ref()
                .and_then(|path| std::fs::read(path).ok())
                .and_then(|bytes| serde_json::from_slice(&bytes).ok())
                .unwrap_or_default()
        });
        apply(values)
    }

    pub fn get(&self, key: &str) -> Value {
        self.with(|values| values.get(key).cloned().unwrap_or(Value::Null))
    }

    pub fn set(&self, key: &str, value: Value) -> Result<(), String> {
        self.with(|values| {
            let previous = values.insert(key.to_owned(), value);
            let encoded = serde_json::to_vec(values).map_err(|error| error.to_string())?;
            if encoded.len() > MAX_STORAGE_BYTES {
                match previous {
                    Some(previous) => values.insert(key.to_owned(), previous),
                    None => values.remove(key),
                };
                return Err("extension storage is full (5 MiB)".into());
            }
            self.write(&encoded)
        })
    }

    pub fn remove(&self, key: &str) -> Result<(), String> {
        self.with(|values| {
            if values.remove(key).is_none() {
                return Ok(());
            }
            let encoded = serde_json::to_vec(values).map_err(|error| error.to_string())?;
            self.write(&encoded)
        })
    }

    pub fn bytes_used(&self) -> usize {
        self.with(|values| serde_json::to_vec(values).map_or(0, |bytes| bytes.len()))
    }

    fn write(&self, encoded: &[u8]) -> Result<(), String> {
        let Some(path) = &self.path else {
            return Ok(());
        };
        crate::write_atomic(path, encoded).map_err(|error| error.to_string())
    }
}

/// The values `kalao.settings` sees: stored values over manifest defaults,
/// secrets held in memory only. Changes made from JavaScript are recorded
/// so the manager can persist plain values and hand secrets to the app.
pub struct Settings {
    manifest: Manifest,
    values: Mutex<Map<String, Value>>,
    changed: Mutex<Map<String, Value>>,
}

impl Settings {
    pub fn new(manifest: Manifest, values: Map<String, Value>) -> Self {
        Self {
            manifest,
            values: Mutex::new(values),
            changed: Mutex::default(),
        }
    }

    pub fn get(&self, key: &str) -> Result<Value, String> {
        let setting = self
            .manifest
            .setting(key)
            .ok_or_else(|| format!("setting '{key}' is not declared in the manifest"))?;
        let values = self.values.lock().unwrap_or_else(PoisonError::into_inner);
        Ok(values
            .get(key)
            .cloned()
            .or_else(|| setting.default.clone())
            .unwrap_or(Value::Null))
    }

    pub fn set(&self, key: &str, value: Value) -> Result<(), String> {
        let setting = self
            .manifest
            .setting(key)
            .ok_or_else(|| format!("setting '{key}' is not declared in the manifest"))?;
        let value = coerce(setting.kind, &setting.options, value)
            .ok_or_else(|| format!("value for setting '{key}' does not match its type"))?;
        self.values
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(key.to_owned(), value.clone());
        self.changed
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(key.to_owned(), value);
        Ok(())
    }

    pub fn take_changes(&self) -> Map<String, Value> {
        std::mem::take(&mut *self.changed.lock().unwrap_or_else(PoisonError::into_inner))
    }

    /// Secret values, for log redaction.
    pub fn secret_values(&self) -> Vec<String> {
        let values = self.values.lock().unwrap_or_else(PoisonError::into_inner);
        self.manifest
            .settings
            .iter()
            .filter(|setting| setting.kind == SettingType::Secret)
            .filter_map(|setting| values.get(&setting.key)?.as_str().map(str::to_owned))
            .collect()
    }
}

/// Checks a value against a setting type; `null` clears it.
pub fn coerce(kind: SettingType, options: &[String], value: Value) -> Option<Value> {
    if value.is_null() {
        return Some(Value::Null);
    }
    let ok = match kind {
        SettingType::Text | SettingType::Secret => {
            value.as_str().is_some_and(|text| text.len() <= 64 * 1024)
        }
        SettingType::Toggle => value.is_boolean(),
        SettingType::Number => value.is_number(),
        SettingType::Select => value
            .as_str()
            .is_some_and(|text| options.iter().any(|option| option == text)),
        SettingType::Button => false,
    };
    ok.then_some(value)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn storage_persists_and_enforces_the_quota() {
        let path = std::env::temp_dir().join(format!("kalao-storage-{}.json", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let storage = Storage::new(Some(path.clone()));
        storage.set("a", json!({"n": 1})).unwrap();
        assert_eq!(Storage::new(Some(path.clone())).get("a"), json!({"n": 1}));
        let big = "x".repeat(MAX_STORAGE_BYTES);
        assert!(storage.set("big", json!(big)).is_err());
        assert_eq!(storage.get("big"), Value::Null);
        storage.remove("a").unwrap();
        assert_eq!(Storage::new(Some(path.clone())).get("a"), Value::Null);
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn settings_use_defaults_check_types_and_record_changes() {
        let manifest = crate::manifest::Manifest::parse(
            crate::package::tests::manifest_json("a.b", "1.0.0", &["lyrics"]).as_bytes(),
        )
        .unwrap();
        let settings = Settings::new(manifest, Map::new());
        assert_eq!(settings.get("region").unwrap(), json!("jp"));
        assert!(settings.get("missing").is_err());
        assert!(settings.set("region", json!("us")).is_err());
        settings.set("token", json!("s3cret-value")).unwrap();
        assert_eq!(settings.secret_values(), vec!["s3cret-value".to_owned()]);
        assert_eq!(settings.take_changes()["token"], json!("s3cret-value"));
        assert!(settings.take_changes().is_empty());
    }
}
