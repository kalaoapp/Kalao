//! `manifest.json` (EXTENSIONS.md §3): parsed, then validated before anything
//! from the package runs.

use crate::version::Version;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeSet;

pub const SCHEMA: u64 = 1;
pub const MAX_MANIFEST_BYTES: usize = 1 << 20;

/// What an extension can provide; each maps to exported functions.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Capability {
    Lyrics,
    Metadata,
    Audio,
    Artwork,
}

impl Capability {
    pub const ALL: [Capability; 4] = [
        Capability::Lyrics,
        Capability::Metadata,
        Capability::Audio,
        Capability::Artwork,
    ];

    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "lyrics" => Some(Self::Lyrics),
            "metadata" => Some(Self::Metadata),
            "audio" => Some(Self::Audio),
            "artwork" => Some(Self::Artwork),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Lyrics => "lyrics",
            Self::Metadata => "metadata",
            Self::Audio => "audio",
            Self::Artwork => "artwork",
        }
    }

    /// Functions the extension must export for this capability.
    pub fn required_functions(self) -> &'static [&'static str] {
        match self {
            Self::Lyrics => &["searchLyrics"],
            Self::Metadata => &["searchTracks", "getTrack"],
            Self::Audio => &["resolveAudio"],
            Self::Artwork => &["getArtwork"],
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SettingType {
    Text,
    Secret,
    Toggle,
    Select,
    Number,
    Button,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Setting {
    pub key: String,
    #[serde(rename = "type")]
    pub kind: SettingType,
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default: Option<Value>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub options: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub min: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max: Option<f64>,
    /// A host from `network.hosts` that is enabled only once this setting
    /// has a value.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub grants_network: Option<String>,
    /// For `button`: the exported function to call.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub action: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Network {
    #[serde(default)]
    pub hosts: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Auth {
    pub callback_path: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct HealthCheck {
    pub id: String,
    pub url: String,
    #[serde(default = "default_health_method")]
    pub method: String,
}

fn default_health_method() -> String {
    "GET".into()
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    pub schema: u64,
    pub id: String,
    pub name: String,
    pub version: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub min_kalao: Option<String>,
    #[serde(default)]
    pub author: String,
    #[serde(default)]
    pub description: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub homepage: Option<String>,
    pub capabilities: Vec<Capability>,
    #[serde(default)]
    pub languages: Vec<String>,
    #[serde(default)]
    pub network: Network,
    #[serde(default)]
    pub settings: Vec<Setting>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auth: Option<Auth>,
    #[serde(default)]
    pub health: Vec<HealthCheck>,
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
#[error("invalid manifest: {0}")]
pub struct ManifestError(pub String);

fn invalid(message: impl Into<String>) -> ManifestError {
    ManifestError(message.into())
}

impl Manifest {
    pub fn parse(bytes: &[u8]) -> Result<Self, ManifestError> {
        if bytes.len() > MAX_MANIFEST_BYTES {
            return Err(invalid("manifest.json is larger than 1 MiB"));
        }
        let manifest: Manifest =
            serde_json::from_slice(bytes).map_err(|error| invalid(error.to_string()))?;
        manifest.validate()?;
        Ok(manifest)
    }

    pub fn parsed_version(&self) -> Version {
        // validate() guarantees the version parses.
        Version::parse(&self.version).unwrap_or(Version {
            major: 0,
            minor: 0,
            patch: 0,
            pre: Vec::new(),
        })
    }

    pub fn has(&self, capability: Capability) -> bool {
        self.capabilities.contains(&capability)
    }

    pub fn setting(&self, key: &str) -> Option<&Setting> {
        self.settings.iter().find(|setting| setting.key == key)
    }

    /// Whether this app version satisfies `minKalao`.
    pub fn supports_app(&self, app_version: &Version) -> bool {
        self.min_kalao
            .as_deref()
            .and_then(Version::parse)
            .is_none_or(|minimum| *app_version >= minimum)
    }

    pub fn validate(&self) -> Result<(), ManifestError> {
        if self.schema != SCHEMA {
            return Err(invalid(format!(
                "schema {} is not supported (expected {SCHEMA})",
                self.schema
            )));
        }
        if !valid_id(&self.id) {
            return Err(invalid(format!(
                "id '{}' must be reverse-DNS (lowercase letters, digits, '-', at least two dots-separated parts)",
                self.id
            )));
        }
        if self.name.trim().is_empty() || self.name.chars().count() > 64 {
            return Err(invalid("name must be 1–64 characters"));
        }
        if Version::parse(&self.version).is_none() {
            return Err(invalid(format!("version '{}' is not semver", self.version)));
        }
        if let Some(minimum) = &self.min_kalao
            && Version::parse(minimum).is_none()
        {
            return Err(invalid(format!("minKalao '{minimum}' is not semver")));
        }
        if self.capabilities.is_empty() {
            return Err(invalid("at least one capability is required"));
        }
        if self.capabilities.iter().collect::<BTreeSet<_>>().len() != self.capabilities.len() {
            return Err(invalid("capabilities are listed twice"));
        }
        if let Some(homepage) = &self.homepage
            && !homepage.starts_with("https://")
        {
            return Err(invalid("homepage must be an https URL"));
        }
        if self.network.hosts.len() > 64 {
            return Err(invalid("at most 64 network hosts"));
        }
        for host in &self.network.hosts {
            if !valid_host_pattern(host) {
                return Err(invalid(format!("network host '{host}' is not a host name")));
            }
        }
        let mut keys = BTreeSet::new();
        for setting in &self.settings {
            if !valid_key(&setting.key) {
                return Err(invalid(format!("setting key '{}' is invalid", setting.key)));
            }
            if !keys.insert(setting.key.as_str()) {
                return Err(invalid(format!(
                    "setting '{}' is declared twice",
                    setting.key
                )));
            }
            if setting.label.trim().is_empty() {
                return Err(invalid(format!("setting '{}' needs a label", setting.key)));
            }
            match setting.kind {
                SettingType::Select if setting.options.is_empty() => {
                    return Err(invalid(format!("select '{}' needs options", setting.key)));
                }
                SettingType::Button => {
                    let action = setting.action.as_deref().unwrap_or_default();
                    if !valid_key(action) {
                        return Err(invalid(format!(
                            "button '{}' needs an action function name",
                            setting.key
                        )));
                    }
                }
                _ => {}
            }
            if let Some(host) = &setting.grants_network {
                if !matches!(setting.kind, SettingType::Secret | SettingType::Text) {
                    return Err(invalid(format!(
                        "grantsNetwork is only allowed on text and secret settings ('{}')",
                        setting.key
                    )));
                }
                if !self.network.hosts.contains(host) {
                    return Err(invalid(format!(
                        "grantsNetwork host '{host}' must be listed in network.hosts"
                    )));
                }
            }
            if let Some(default) = &setting.default {
                let ok = match setting.kind {
                    SettingType::Text => default.is_string(),
                    SettingType::Toggle => default.is_boolean(),
                    SettingType::Number => default.is_number(),
                    SettingType::Select => default
                        .as_str()
                        .is_some_and(|value| setting.options.iter().any(|o| o == value)),
                    SettingType::Secret | SettingType::Button => false,
                };
                if !ok {
                    return Err(invalid(format!(
                        "default of setting '{}' does not match its type",
                        setting.key
                    )));
                }
            }
        }
        if let Some(auth) = &self.auth
            && !valid_key(&auth.callback_path)
        {
            return Err(invalid("auth.callbackPath must be a simple path segment"));
        }
        for check in &self.health {
            if !check.url.starts_with("https://") {
                return Err(invalid(format!(
                    "health check '{}' must use https",
                    check.id
                )));
            }
            if !matches!(check.method.as_str(), "GET" | "HEAD") {
                return Err(invalid(format!(
                    "health check '{}' must use GET or HEAD",
                    check.id
                )));
            }
        }
        Ok(())
    }
}

fn valid_id(id: &str) -> bool {
    let parts: Vec<&str> = id.split('.').collect();
    id.len() <= 128
        && parts.len() >= 2
        && parts.iter().all(|part| {
            !part.is_empty()
                && part
                    .bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
                && !part.starts_with('-')
                && !part.ends_with('-')
        })
}

/// Setting keys, action names and callback paths: identifiers.
fn valid_key(key: &str) -> bool {
    !key.is_empty()
        && key.len() <= 64
        && key.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
        && !key.as_bytes()[0].is_ascii_digit()
}

/// `example.org` or `*.example.org` (no scheme, port or path).
fn valid_host_pattern(host: &str) -> bool {
    let name = host.strip_prefix("*.").unwrap_or(host);
    let labels: Vec<&str> = name.split('.').collect();
    !name.is_empty()
        && name.len() <= 253
        && (labels.len() >= 2 || name == "localhost")
        && labels.iter().all(|label| {
            !label.is_empty()
                && label.len() <= 63
                && label
                    .bytes()
                    .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    pub(crate) fn sample() -> Value {
        json!({
            "schema": 1,
            "id": "dev.example.lrcfinder",
            "name": "LRC Finder",
            "version": "1.2.0",
            "minKalao": "0.1.0",
            "author": "Example Dev",
            "capabilities": ["lyrics"],
            "network": { "hosts": ["api.example.org", "*.cdn.example.org"] },
            "settings": [
                { "key": "token", "type": "secret", "label": "API token", "grantsNetwork": "api.example.org" },
                { "key": "preferSynced", "type": "toggle", "label": "Prefer synced", "default": true },
                { "key": "region", "type": "select", "label": "Region", "options": ["jp", "tw"] },
                { "key": "login", "type": "button", "label": "Log in", "action": "startLogin" }
            ],
            "auth": { "callbackPath": "callback" },
            "health": [ { "id": "api", "url": "https://api.example.org/ping", "method": "HEAD" } ]
        })
    }

    fn parse(value: &Value) -> Result<Manifest, ManifestError> {
        Manifest::parse(value.to_string().as_bytes())
    }

    #[test]
    fn the_documented_example_is_valid() {
        let manifest = parse(&sample()).expect("valid");
        assert!(manifest.has(Capability::Lyrics));
        assert_eq!(manifest.setting("token").unwrap().kind, SettingType::Secret);
        assert!(manifest.supports_app(&Version::parse("0.1.0").unwrap()));
        assert!(!manifest.supports_app(&Version::parse("0.0.9").unwrap()));
    }

    #[test]
    fn unknown_keys_are_ignored() {
        let mut value = sample();
        value["futureField"] = json!(true);
        assert!(parse(&value).is_ok());
    }

    #[test]
    fn rejects_invalid_fields() {
        let cases: Vec<(&str, Value)> = vec![
            ("schema", json!(2)),
            ("id", json!("NoDots")),
            ("id", json!("Dev.Example.x")),
            ("version", json!("1.2")),
            ("capabilities", json!([])),
            ("capabilities", json!(["lyrics", "lyrics"])),
            ("capabilities", json!(["video"])),
            ("homepage", json!("http://example.org")),
            ("network", json!({"hosts": ["https://api.example.org"]})),
            ("network", json!({"hosts": ["api.example.org/path"]})),
            (
                "health",
                json!([{"id": "x", "url": "http://a.org", "method": "GET"}]),
            ),
            ("auth", json!({"callbackPath": "../x"})),
        ];
        for (field, value) in cases {
            let mut manifest = sample();
            manifest[field] = value.clone();
            assert!(parse(&manifest).is_err(), "{field} = {value}");
        }
    }

    #[test]
    fn rejects_invalid_settings() {
        let cases = [
            json!([{ "key": "a", "type": "select", "label": "A" }]),
            json!([{ "key": "a", "type": "button", "label": "A" }]),
            json!([{ "key": "a", "type": "toggle", "label": "A", "default": "yes" }]),
            json!([{ "key": "a", "type": "text", "label": "A", "grantsNetwork": "other.org" }]),
            json!([{ "key": "a", "type": "toggle", "label": "A", "grantsNetwork": "api.example.org" }]),
            json!([{ "key": "a", "type": "text", "label": "A" }, { "key": "a", "type": "text", "label": "B" }]),
            json!([{ "key": "a b", "type": "text", "label": "A" }]),
        ];
        for settings in cases {
            let mut manifest = sample();
            manifest["settings"] = settings.clone();
            assert!(parse(&manifest).is_err(), "{settings}");
        }
    }
}
