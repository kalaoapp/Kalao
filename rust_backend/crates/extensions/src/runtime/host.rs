//! The native side of the `kalao` object: one `dispatch(op, args)` call that
//! the prelude wraps. Every operation is bounded by the call's deadline.

use super::Control;
use crate::fetch::{Fetch, FetchRequest};
use crate::logs::ExtensionLog;
use crate::manifest::Manifest;
use crate::storage::{Settings, Storage};
use crate::{auth, crypto, html};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

/// Checks a page `kalao.auth.openBrowser` may open (HTTPS, not private).
pub type AuthUrlCheck = Arc<dyn Fn(&str) -> Result<(), String> + Send + Sync>;

pub struct HostContext {
    pub extension_id: String,
    pub manifest: Manifest,
    pub settings: Arc<Settings>,
    pub storage: Arc<Storage>,
    pub fetch: Arc<dyn Fetch>,
    pub log: Arc<ExtensionLog>,
    pub auth_url_check: AuthUrlCheck,
}

const DEFAULT_AUTH_WAIT: Duration = Duration::from_secs(120);

impl HostContext {
    pub(crate) fn log(&self, level: &str, message: &str) {
        self.log.push(
            &self.extension_id,
            level,
            message,
            &self.settings.secret_values(),
        );
    }

    pub(crate) fn dispatch(
        &self,
        control: &Control,
        op: &str,
        args: &str,
    ) -> Result<Value, String> {
        control.check()?;
        let args: Value = serde_json::from_str(args).map_err(|error| error.to_string())?;
        let text = |name: &str| -> Result<&str, String> {
            args[name]
                .as_str()
                .ok_or_else(|| format!("{op}: {name} must be a string"))
        };
        match op {
            "fetch" => self.fetch(control, &args),
            "settings.get" => self.settings.get(text("key")?),
            "settings.set" => self
                .settings
                .set(text("key")?, args["value"].clone())
                .map(|()| Value::Null),
            "storage.get" => Ok(self.storage.get(text("key")?)),
            "storage.set" => self
                .storage
                .set(text("key")?, args["value"].clone())
                .map(|()| Value::Null),
            "storage.remove" => self.storage.remove(text("key")?).map(|()| Value::Null),
            "auth.callbackUrl" => Ok(json!(auth::callback_url(
                &self.extension_id,
                &self.callback_path()?
            ))),
            "auth.openBrowser" => {
                self.callback_path()?;
                let url = text("url")?;
                (self.auth_url_check)(url)?;
                auth::request_browser(&self.extension_id, url);
                self.log("info", "opened a login page");
                Ok(Value::Null)
            }
            "auth.waitForCallback" => {
                self.callback_path()?;
                let wait = args["timeoutMs"]
                    .as_u64()
                    .map_or(DEFAULT_AUTH_WAIT, Duration::from_millis);
                let deadline = (Instant::now() + wait).min(control.deadline());
                auth::wait_for_callback(&self.extension_id, deadline)
            }
            "html.select" => html::select(
                text("html")?,
                text("selector")?,
                args["fragment"].as_bool().unwrap_or(false),
            ),
            "crypto.digest" => {
                let bytes = crypto::input(&args["data"], args["encoding"].as_str())?;
                crypto::digest(text("algorithm")?, &bytes).map(Value::String)
            }
            "crypto.hmac" => {
                let key = crypto::input(&args["key"], args["keyEncoding"].as_str())?;
                let bytes = crypto::input(&args["data"], args["encoding"].as_str())?;
                crypto::hmac(text("algorithm")?, &key, &bytes).map(Value::String)
            }
            "crypto.aesGcm" => crypto::aes_gcm(args["encrypt"].as_bool().unwrap_or(true), &args),
            "base64.encode" => Ok(json!(crypto::base64_encode(text("data")?.as_bytes()))),
            "base64.decode" => crypto::base64_decode_text(text("data")?).map(Value::String),
            "log" => {
                let level = args["level"]
                    .as_str()
                    .filter(|level| matches!(*level, "debug" | "info" | "warn" | "error"))
                    .unwrap_or("info");
                self.log(level, text("message")?);
                Ok(Value::Null)
            }
            other => Err(format!("unknown host call {other}")),
        }
    }

    fn callback_path(&self) -> Result<String, String> {
        self.manifest
            .auth
            .as_ref()
            .map(|auth| auth.callback_path.clone())
            .ok_or_else(|| "the manifest declares no auth.callbackPath".to_owned())
    }

    fn fetch(&self, control: &Control, args: &Value) -> Result<Value, String> {
        let url = args["url"].as_str().ok_or("fetch: url must be a string")?;
        let headers: BTreeMap<String, String> = match &args["headers"] {
            Value::Object(map) => map
                .iter()
                .map(|(name, value)| {
                    let value = match value {
                        Value::String(text) => text.clone(),
                        other => other.to_string(),
                    };
                    (name.clone(), value)
                })
                .collect(),
            _ => BTreeMap::new(),
        };
        let deadline = match args["timeoutMs"].as_u64() {
            Some(ms) => (Instant::now() + Duration::from_millis(ms)).min(control.deadline()),
            None => control.deadline(),
        };
        let check = || -> Result<(), String> {
            control.check()?;
            if Instant::now() >= deadline {
                return Err("fetch timeout exceeded".into());
            }
            Ok(())
        };
        let method = args["method"].as_str().unwrap_or("GET").to_owned();
        let started = Instant::now();
        let response = self
            .fetch
            .fetch(
                FetchRequest {
                    url: url.to_owned(),
                    method: method.clone(),
                    headers,
                    body: args["body"].as_str().unwrap_or_default().to_owned(),
                },
                &check,
            )
            .inspect_err(|error| {
                self.log("warn", &format!("fetch {method} {url} failed: {error}"))
            })?;
        self.log(
            "debug",
            &format!(
                "fetch {method} {url} → {} ({} bytes, {} ms)",
                response.status,
                response.body.len(),
                started.elapsed().as_millis()
            ),
        );
        let mut reply = json!({
            "status": response.status,
            "url": response.url,
            "headers": response.headers,
        });
        match String::from_utf8(response.body) {
            Ok(text) => reply["text"] = json!(text),
            Err(error) => {
                let bytes = error.into_bytes();
                reply["text"] = json!(String::from_utf8_lossy(&bytes));
                reply["base64"] = json!(crypto::base64_encode(&bytes));
            }
        }
        Ok(reply)
    }
}
