//! Extension methods (IMPLEMENTATION.md §1 "Extensions") over the
//! process-wide `kalao-extensions` manager, the streaming sources for
//! `playerLoad`, and the `extensionDownload` data job (offline copies and
//! artwork through the extension's own network session).

use crate::backend::{BackendError, invalid, operation, str_arg};
use crate::stream::{self, SessionOrigin};
use kalao_audio::Media;
use kalao_extensions::capabilities::Query;
use kalao_extensions::manager::{Manager, Network};
use kalao_extensions::{Capability, auth};
use kalao_network::NetworkService;
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};

struct Context {
    manager: Arc<Manager>,
    stream_cache: PathBuf,
}

fn slot() -> &'static Mutex<Option<Arc<Context>>> {
    static SLOT: Mutex<Option<Arc<Context>>> = Mutex::new(None);
    &SLOT
}

fn network() -> Result<Arc<NetworkService>, BackendError> {
    static SERVICE: OnceLock<Arc<NetworkService>> = OnceLock::new();
    if let Some(service) = SERVICE.get() {
        return Ok(service.clone());
    }
    let service = NetworkService::new().map_err(operation)?;
    Ok(SERVICE.get_or_init(|| service).clone())
}

fn context(method: &str) -> Result<Arc<Context>, BackendError> {
    slot()
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .clone()
        .ok_or_else(|| invalid(method, "extensions are not initialised (extensionsInit)"))
}

fn log_hook(level: &str, tag: &str, message: &str) {
    let level = match level {
        "error" => "ERROR",
        "warn" => "WARN",
        "debug" => "DEBUG",
        _ => "INFO",
    };
    crate::logging::global().add(level, tag, message);
}

fn json_ok<T: serde::Serialize>(value: T) -> Result<Value, BackendError> {
    serde_json::to_value(value).map_err(operation)
}

fn capability(method: &str, args: &Value) -> Result<Capability, BackendError> {
    Capability::parse(str_arg(method, args, "capability")?)
        .ok_or_else(|| invalid(method, "unknown capability"))
}

fn query(method: &str, args: &Value) -> Result<Query, BackendError> {
    serde_json::from_value(args["query"].clone())
        .map_err(|error| invalid(method, error.to_string()))
}

/// Initialises (or re-initialises) the manager:
/// `{root, streamCache, appVersion, developerMode}`.
fn init(method: &str, args: &Value) -> Result<Value, BackendError> {
    kalao_extensions::logs::set_log_hook(log_hook);
    let root = PathBuf::from(str_arg(method, args, "root")?);
    let stream_cache = PathBuf::from(str_arg(method, args, "streamCache")?);
    let manager = Manager::new(
        root,
        str_arg(method, args, "appVersion")?,
        Network::Service(network()?),
    )
    .map_err(operation)?;
    manager.set_developer_mode(args["developerMode"].as_bool().unwrap_or(false));
    let manager = Arc::new(manager);
    let list = manager.list();
    *slot().lock().unwrap_or_else(PoisonError::into_inner) = Some(Arc::new(Context {
        manager,
        stream_cache,
    }));
    Ok(json!({ "extensions": list }))
}

pub fn dispatch(method: &str, args: &Value) -> Result<Value, BackendError> {
    if method == "extensionsInit" {
        return init(method, args);
    }
    if method == "extensionAuthCallback" {
        // Answered even before init: the URL is only routed.
        let url = str_arg(method, args, "url")?;
        let context = context(method)?;
        let manager = context.manager.clone();
        let id = auth::deliver_callback(url, |id| {
            manager.info(id).ok().and_then(|info| {
                info["manifest"]["auth"]["callbackPath"]
                    .as_str()
                    .map(str::to_owned)
            })
        })
        .map_err(|message| invalid(method, message))?;
        return Ok(json!({ "extensionId": id }));
    }
    if method == "takeExtensionAuthRequest" {
        return Ok(match auth::take_browser_request() {
            Some((id, url)) => json!({ "extensionId": id, "url": url }),
            None => Value::Null,
        });
    }
    let context = context(method)?;
    let manager = &context.manager;
    let id = || str_arg(method, args, "id");
    let path = || str_arg(method, args, "path").map(PathBuf::from);
    let allow_downgrade = args["allowDowngrade"].as_bool().unwrap_or(false);
    let result = match method {
        "listExtensions" => json!({
            "extensions": manager.list(),
            "priority": manager.priority(),
            "developerMode": manager.developer_mode(),
        }),
        "inspectExtensionPackage" => manager.inspect_file(&path()?).map_err(operation)?,
        "installExtension" => manager
            .install_file(&path()?, allow_downgrade)
            .map_err(operation)?,
        "installExtensionFolder" => manager.install_folder(&path()?).map_err(operation)?,
        "uninstallExtension" => {
            manager.uninstall(id()?).map_err(operation)?;
            Value::Null
        }
        "setExtensionEnabled" => {
            let enabled = args["enabled"]
                .as_bool()
                .ok_or_else(|| invalid(method, "missing bool field enabled"))?;
            manager.set_enabled(id()?, enabled).map_err(operation)?;
            Value::Null
        }
        "setExtensionPriority" => {
            let ids: Vec<String> = serde_json::from_value(args["ids"].clone())
                .map_err(|error| invalid(method, error.to_string()))?;
            manager
                .set_priority(capability(method, args)?, &ids)
                .map_err(operation)?;
            json_ok(manager.priority())?
        }
        "setExtensionSetting" => {
            manager
                .set_setting(id()?, str_arg(method, args, "key")?, args["value"].clone())
                .map_err(operation)?;
            Value::Null
        }
        "setExtensionSecrets" => {
            let values: Map<String, Value> =
                args["values"].as_object().cloned().unwrap_or_default();
            manager.set_secrets(id()?, values);
            Value::Null
        }
        "takeExtensionSecretUpdates" => json_ok(manager.take_secret_updates())?,
        "setExtensionDeveloperMode" => {
            manager.set_developer_mode(args["enabled"].as_bool().unwrap_or(false));
            Value::Null
        }
        "invokeExtensionAction" => {
            json!({ "result": manager.invoke_action(id()?, str_arg(method, args, "key")?).map_err(operation)? })
        }
        "extensionHealth" => manager.check_health(id()?).map_err(operation)?,
        "extensionLogs" => json!({ "logs": manager.logs(id()?) }),
        "listRepositories" => json_ok(manager.repositories())?,
        "previewRepository" => manager
            .preview_repository(str_arg(method, args, "url")?)
            .map_err(operation)?,
        "addRepository" => json_ok(
            manager
                .add_repository(
                    str_arg(method, args, "url")?,
                    str_arg(method, args, "publicKey")?,
                    args["name"].as_str(),
                    args["fetch"].as_bool().unwrap_or(true),
                )
                .map_err(operation)?,
        )?,
        "removeRepository" => {
            manager
                .remove_repository(str_arg(method, args, "url")?)
                .map_err(operation)?;
            Value::Null
        }
        "refreshRepositories" => json!({
            "repositories": manager.refresh_repositories(args["url"].as_str()).map_err(operation)?,
        }),
        "installFromRepository" => manager
            .install_from_repository(str_arg(method, args, "url")?, id()?, allow_downgrade)
            .map_err(operation)?,
        "searchLyrics" => manager.search_lyrics(&query(method, args)?),
        "getLyrics" => manager
            .get_lyrics(str_arg(method, args, "extensionId")?, id()?)
            .map_err(operation)?,
        "searchMetadata" => manager.search_tracks(&query(method, args)?),
        "getTrack" => manager
            .get_track(str_arg(method, args, "extensionId")?, id()?)
            .map_err(operation)?,
        "getArtwork" => manager
            .get_artwork(args["extensionId"].as_str(), &args["track"])
            .map_err(operation)?,
        "resolveAudio" => manager
            .resolve_audio(str_arg(method, args, "extensionId")?, &args["track"])
            .map_err(operation)?,
        _ => return Err(BackendError::UnknownMethod(method.to_owned())),
    };
    Ok(result)
}

fn headers(value: &Value) -> BTreeMap<String, String> {
    value
        .as_object()
        .map(|map| {
            map.iter()
                .filter_map(|(name, value)| Some((name.clone(), value.as_str()?.to_owned())))
                .collect()
        })
        .unwrap_or_default()
}

fn origin(
    extension_id: &str,
    url: &str,
    headers: BTreeMap<String, String>,
) -> Result<SessionOrigin, String> {
    let context = context("stream").map_err(|error| error.to_string())?;
    let session = context
        .manager
        .network_session(extension_id)
        .map_err(|error| error.to_string())?
        .ok_or("no network session")?;
    Ok(SessionOrigin {
        session,
        url: url.to_owned(),
        headers,
    })
}

/// A `playerLoad` source `{kind, url, headers?, extensionId, cacheKey, format?}`.
pub fn stream_media(source: &Value) -> Result<Media, String> {
    let extension_id = source["extensionId"]
        .as_str()
        .ok_or("stream source without extensionId")?;
    let url = source["url"].as_str().ok_or("stream source without url")?;
    let key = source["cacheKey"]
        .as_str()
        .filter(|key| stream::valid_key(key))
        .ok_or("stream source without a valid cacheKey")?;
    let cache = context("playerLoad")
        .map_err(|error| error.to_string())?
        .stream_cache
        .clone();
    if let Some(path) = stream::cached(&cache, key) {
        return Ok(Media::File(path));
    }
    let origin = origin(extension_id, url, headers(&source["headers"]))?;
    stream::media(
        Arc::new(origin),
        &cache,
        key,
        source["format"].as_str().map(str::to_owned),
    )
    .map_err(|error| error.to_string())
}

/// Data job `extensionDownload {extensionId, url, headers?, path, cacheKey?, maxBytes?}`:
/// saves the URL (or its finished stream cache) to `path` and reports its size.
pub fn download_job(request: &Value, check: crate::data_jobs::Check) -> Result<Value, String> {
    let extension_id = request["extensionId"]
        .as_str()
        .ok_or("Missing native data field: extensionId")?;
    let url = request["url"]
        .as_str()
        .ok_or("Missing native data field: url")?;
    let target = PathBuf::from(
        request["path"]
            .as_str()
            .ok_or("Missing native data field: path")?,
    );
    let max_bytes = request["maxBytes"].as_u64().unwrap_or(2 << 30);
    if let Some(parent) = target.parent() {
        std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    if let Some(key) = request["cacheKey"]
        .as_str()
        .filter(|key| stream::valid_key(key))
    {
        let cache = context("extensionDownload")
            .map_err(|error| error.to_string())?
            .stream_cache
            .clone();
        if let Some(cached) = stream::cached(&cache, key) {
            std::fs::copy(&cached, &target).map_err(|error| error.to_string())?;
            return Ok(json!({ "path": target, "bytes": file_size(&target) }));
        }
    }
    let origin = origin(extension_id, url, headers(&request["headers"]))?;
    let partial = target.with_extension("download");
    let result = (|| -> Result<u64, String> {
        let mut body = origin.open_stream(0, check)?;
        let mut file = std::fs::File::create(&partial).map_err(|error| error.to_string())?;
        let mut buffer = vec![0u8; 64 << 10];
        let mut total = 0u64;
        loop {
            check()?;
            let count = stream::Body::read(&mut body, &mut buffer)?;
            if count == 0 {
                break;
            }
            total += count as u64;
            if total > max_bytes {
                return Err(format!("the download is larger than {max_bytes} bytes"));
            }
            file.write_all(&buffer[..count])
                .map_err(|error| error.to_string())?;
        }
        file.flush().map_err(|error| error.to_string())?;
        Ok(total)
    })();
    match result {
        Ok(total) => {
            std::fs::rename(&partial, &target).map_err(|error| error.to_string())?;
            Ok(json!({ "path": target, "bytes": total }))
        }
        Err(error) => {
            let _ = std::fs::remove_file(&partial);
            Err(error)
        }
    }
}

fn file_size(path: &Path) -> u64 {
    std::fs::metadata(path).map_or(0, |meta| meta.len())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn methods_need_init_and_validate_arguments() {
        assert!(matches!(
            dispatch("searchLyrics", &json!({})),
            Err(BackendError::InvalidArguments { .. }) | Err(BackendError::Operation(_))
        ));
        assert_eq!(
            dispatch("takeExtensionAuthRequest", &json!({})).unwrap(),
            Value::Null
        );
        assert!(stream_media(&json!({"extensionId": "a.b", "url": "https://x.org/a"})).is_err());
    }

    #[test]
    fn init_lists_extensions_and_routes_methods() {
        let root = std::env::temp_dir().join(format!("kalao-mobile-ext-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let reply = dispatch(
            "extensionsInit",
            &json!({
                "root": root.join("extensions"),
                "streamCache": root.join("stream_cache"),
                "appVersion": "0.1.0",
            }),
        )
        .unwrap();
        assert_eq!(reply["extensions"], json!([]));
        let listed = dispatch("listExtensions", &json!({})).unwrap();
        assert_eq!(listed["developerMode"], false);
        let result = dispatch(
            "searchLyrics",
            &json!({ "query": { "title": "x", "artist": "" } }),
        )
        .unwrap();
        assert_eq!(result["candidates"], json!([]));
        assert!(dispatch("uninstallExtension", &json!({ "id": "a.b" })).is_err());
        assert!(
            dispatch(
                "setExtensionPriority",
                &json!({ "capability": "video", "ids": [] })
            )
            .is_err()
        );
        assert!(
            dispatch(
                "extensionAuthCallback",
                &json!({ "url": "kalao://ext/a.b/callback" })
            )
            .is_err()
        );
        let _ = std::fs::remove_dir_all(&root);
    }
}
