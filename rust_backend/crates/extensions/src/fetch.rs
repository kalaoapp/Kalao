//! The HTTP behind `kalao.fetch`. In the app it is the extension's own
//! `kalao-network` session (allowlist checked before the request and after
//! every redirect, cookies per extension, 16 MiB per response); the CLI and
//! tests answer from recorded fixtures with the same allowlist check.

use kalao_network::policy::NetworkPermissions;
use kalao_network::{HttpRequest, NetworkSession};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct FetchRequest {
    pub url: String,
    #[serde(default)]
    pub method: String,
    #[serde(default)]
    pub headers: BTreeMap<String, String>,
    #[serde(default)]
    pub body: String,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct FetchResponse {
    pub status: u16,
    pub url: String,
    #[serde(default)]
    pub headers: BTreeMap<String, Vec<String>>,
    #[serde(default)]
    pub body: Vec<u8>,
}

/// `check` returns an error once the calling extension's time is up.
pub trait Fetch: Send + Sync {
    fn fetch(
        &self,
        request: FetchRequest,
        check: &dyn Fn() -> Result<(), String>,
    ) -> Result<FetchResponse, String>;
}

pub struct SessionFetch(pub Arc<NetworkSession>);

impl Fetch for SessionFetch {
    fn fetch(
        &self,
        request: FetchRequest,
        check: &dyn Fn() -> Result<(), String>,
    ) -> Result<FetchResponse, String> {
        let response = self.0.request(
            HttpRequest {
                url: request.url,
                method: if request.method.is_empty() {
                    "GET".into()
                } else {
                    request.method.to_ascii_uppercase()
                },
                body: request.body,
                headers: request.headers,
                default_json: false,
                user_agent: "Kalao-Extension/1.0".into(),
            },
            check,
        )?;
        Ok(FetchResponse {
            status: response.status,
            url: response.url,
            headers: response.headers,
            body: response.body,
        })
    }
}

/// One recorded exchange: requests match on method and exact URL.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Fixture {
    #[serde(default = "get")]
    pub method: String,
    pub url: String,
    #[serde(default = "ok")]
    pub status: u16,
    #[serde(default)]
    pub headers: BTreeMap<String, String>,
    /// The body as text, or `bodyJson` for a JSON value.
    #[serde(default)]
    pub body: Option<String>,
    #[serde(default)]
    pub body_json: Option<serde_json::Value>,
    /// Binary bodies (packages, images).
    #[serde(default)]
    pub body_base64: Option<String>,
}

fn get() -> String {
    "GET".into()
}

fn ok() -> u16 {
    200
}

/// Offline `Fetch` for `kalao-ext test` and unit tests. Requests outside the
/// manifest's hosts fail exactly as on a device; unmatched requests fail too,
/// and every request is recorded.
pub struct FixtureFetch {
    fixtures: Vec<Fixture>,
    permissions: NetworkPermissions,
    pub requests: Mutex<Vec<FetchRequest>>,
}

impl FixtureFetch {
    pub fn new(fixtures: Vec<Fixture>, hosts: &[String]) -> Self {
        Self {
            fixtures,
            permissions: NetworkPermissions {
                domains: hosts.to_vec(),
                allow_http: false,
            },
            requests: Mutex::default(),
        }
    }
}

impl Fetch for FixtureFetch {
    fn fetch(
        &self,
        request: FetchRequest,
        check: &dyn Fn() -> Result<(), String>,
    ) -> Result<FetchResponse, String> {
        check()?;
        self.permissions.validate(&request.url, false, false)?;
        let method = if request.method.is_empty() {
            "GET".to_owned()
        } else {
            request.method.to_ascii_uppercase()
        };
        self.requests
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .push(request.clone());
        let fixture = self
            .fixtures
            .iter()
            .find(|fixture| {
                fixture.method.eq_ignore_ascii_case(&method) && fixture.url == request.url
            })
            .ok_or_else(|| format!("no fixture for {method} {}", request.url))?;
        let body = match (&fixture.body, &fixture.body_json, &fixture.body_base64) {
            (Some(text), _, _) => text.clone().into_bytes(),
            (None, Some(value), _) => value.to_string().into_bytes(),
            (None, None, Some(encoded)) => {
                use base64::Engine;
                base64::engine::general_purpose::STANDARD
                    .decode(encoded)
                    .map_err(|error| error.to_string())?
            }
            (None, None, None) => Vec::new(),
        };
        Ok(FetchResponse {
            status: fixture.status,
            url: request.url,
            headers: fixture
                .headers
                .iter()
                .map(|(name, value)| (name.to_ascii_lowercase(), vec![value.clone()]))
                .collect(),
            body,
        })
    }
}
