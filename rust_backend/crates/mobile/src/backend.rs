//! The method table behind the Android `com.brinsley.kalao/backend` channel.
//! Kotlin forwards every name that is not a native Android method here, with
//! arguments as a JSON object; the reply is JSON text decoded by Dart.
//! The desktop C ABI crate will dispatch the same names.

use crate::logging;
use serde_json::{Value, json};
use std::sync::atomic::{AtomicBool, Ordering};

#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum BackendError {
    #[error("Rust application method is not connected yet: {0}")]
    UnknownMethod(String),
    #[error("Invalid arguments for {method}: {message}")]
    InvalidArguments { method: String, message: String },
    #[error("{0}")]
    Operation(String),
}

/// Every method this backend answers, sorted. `getBackendInfo` reports it so
/// Dart can check the contract at startup.
pub const METHODS: &[&str] = &[
    "addRepository",
    "annotateLyrics",
    "clearLogs",
    "convertChinese",
    "detectSections",
    "exportLyrics",
    "extensionAuthCallback",
    "extensionHealth",
    "extensionLogs",
    "extensionsInit",
    "getArtwork",
    "getBackendInfo",
    "getLogs",
    "getLyrics",
    "getTrack",
    "initBackend",
    "inspectExtensionPackage",
    "installExtension",
    "installExtensionFolder",
    "installFromRepository",
    "invokeExtensionAction",
    "listExtensions",
    "listRepositories",
    "pairImportFiles",
    "parseLyrics",
    "playerLoad",
    "playerPause",
    "playerPlay",
    "playerSeek",
    "playerSetKey",
    "playerSetLoop",
    "playerSetStemGains",
    "playerSetTempo",
    "playerSetVolume",
    "playerState",
    "playerStop",
    "playerSwitchTrack",
    "previewRepository",
    "probeAudio",
    "refreshRepositories",
    "removeRepository",
    "resolveAudio",
    "searchLyrics",
    "searchMetadata",
    "setExtensionDeveloperMode",
    "setExtensionEnabled",
    "setExtensionPriority",
    "setExtensionSecrets",
    "setExtensionSetting",
    "setLoggingEnabled",
    "takeExtensionAuthRequest",
    "takeExtensionSecretUpdates",
    "uninstallExtension",
];

/// Answered by `crate::extensions`.
const EXTENSION_METHODS: &[&str] = &[
    "addRepository",
    "extensionAuthCallback",
    "extensionHealth",
    "extensionLogs",
    "extensionsInit",
    "getArtwork",
    "getLyrics",
    "getTrack",
    "inspectExtensionPackage",
    "installExtension",
    "installExtensionFolder",
    "installFromRepository",
    "invokeExtensionAction",
    "listExtensions",
    "listRepositories",
    "previewRepository",
    "refreshRepositories",
    "removeRepository",
    "resolveAudio",
    "searchLyrics",
    "searchMetadata",
    "setExtensionDeveloperMode",
    "setExtensionEnabled",
    "setExtensionPriority",
    "setExtensionSecrets",
    "setExtensionSetting",
    "takeExtensionAuthRequest",
    "takeExtensionSecretUpdates",
    "uninstallExtension",
];

/// Set by `initBackend`, which the Android host calls before Flutter starts.
static INITIALIZED: AtomicBool = AtomicBool::new(false);

#[uniffi::export]
pub fn invoke_application(method: String, args_json: String) -> Result<String, BackendError> {
    let args: Value = if args_json.trim().is_empty() {
        json!({})
    } else {
        serde_json::from_str(&args_json).map_err(|error| BackendError::InvalidArguments {
            method: method.clone(),
            message: error.to_string(),
        })?
    };
    Ok(dispatch(&method, &args)?.to_string())
}

fn dispatch(method: &str, args: &Value) -> Result<Value, BackendError> {
    match method {
        "initBackend" => Ok(init_backend(args)),
        "getBackendInfo" => Ok(backend_info()),
        "getLogs" => Ok(logging::global().since(args["sinceIndex"].as_i64().unwrap_or(0))),
        "clearLogs" => {
            logging::global().clear();
            Ok(Value::Null)
        }
        "setLoggingEnabled" => {
            logging::global().set_enabled(bool_arg(method, args, "enabled")?);
            Ok(Value::Null)
        }
        "annotateLyrics" => crate::lyrics::annotate(method, args),
        "convertChinese" => crate::lyrics::convert_chinese(method, args),
        "detectSections" => crate::lyrics::detect_sections(method, args),
        "exportLyrics" => crate::lyrics::export(method, args),
        "parseLyrics" => crate::lyrics::parse(method, args),
        "pairImportFiles" => crate::media::pair(method, args),
        "probeAudio" => crate::media::probe(method, args),
        name if name.starts_with("player") => crate::player::dispatch(method, args),
        name if EXTENSION_METHODS.contains(&name) => crate::extensions::dispatch(method, args),
        _ => Err(BackendError::UnknownMethod(method.to_owned())),
    }
}

fn init_backend(args: &Value) -> Value {
    if let Some(enabled) = args["loggingEnabled"].as_bool() {
        logging::global().set_enabled(enabled);
    }
    INITIALIZED.store(true, Ordering::Release);
    logging::info("Backend", "initialized");
    backend_info()
}

fn backend_info() -> Value {
    json!({
        "name": "kalao-mobile",
        "version": env!("CARGO_PKG_VERSION"),
        "os": std::env::consts::OS,
        "arch": std::env::consts::ARCH,
        "initialized": INITIALIZED.load(Ordering::Acquire),
        "methods": METHODS,
    })
}

pub(crate) fn str_arg<'a>(
    method: &str,
    args: &'a Value,
    name: &str,
) -> Result<&'a str, BackendError> {
    args[name]
        .as_str()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| BackendError::InvalidArguments {
            method: method.into(),
            message: format!("missing string field {name}"),
        })
}

pub(crate) fn invalid(method: &str, message: impl Into<String>) -> BackendError {
    BackendError::InvalidArguments {
        method: method.into(),
        message: message.into(),
    }
}

pub(crate) fn operation(error: impl std::fmt::Display) -> BackendError {
    BackendError::Operation(error.to_string())
}

fn bool_arg(method: &str, args: &Value, name: &str) -> Result<bool, BackendError> {
    args[name]
        .as_bool()
        .ok_or_else(|| BackendError::InvalidArguments {
            method: method.into(),
            message: format!("missing bool field {name}"),
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn call(method: &str, args: Value) -> Result<Value, BackendError> {
        invoke_application(method.into(), args.to_string())
            .map(|reply| serde_json::from_str(&reply).expect("reply is JSON"))
    }

    #[test]
    fn methods_list_is_sorted_and_every_name_dispatches() {
        let mut sorted = METHODS.to_vec();
        sorted.sort_unstable();
        assert_eq!(sorted, METHODS);
        for method in METHODS {
            if let Err(BackendError::UnknownMethod(name)) = dispatch(method, &json!({})) {
                panic!("{name} is listed but not dispatched");
            }
        }
    }

    #[test]
    fn unknown_method_uses_the_not_connected_message() {
        let error = call("nope", json!({})).unwrap_err();
        assert!(
            error
                .to_string()
                .starts_with("Rust application method is not connected yet")
        );
    }

    #[test]
    fn init_reports_info() {
        let info = call("initBackend", json!({})).expect("init");
        assert_eq!(info["initialized"], true);
        assert_eq!(
            call("getBackendInfo", json!({})).unwrap()["name"],
            "kalao-mobile"
        );
    }

    #[test]
    fn invalid_arguments_are_reported() {
        assert!(matches!(
            invoke_application("setLoggingEnabled".into(), "{".into()),
            Err(BackendError::InvalidArguments { .. })
        ));
        assert!(matches!(
            call("setLoggingEnabled", json!({})),
            Err(BackendError::InvalidArguments { .. })
        ));
    }
}
