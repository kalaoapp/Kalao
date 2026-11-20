//! Import: `probeAudio` (tags, cover, duration, codec, decodability),
//! `pairImportFiles` (original/instrumental/lyrics proposals), and the
//! `importInspect` / `importStore` data jobs that hash, probe and move a
//! staged file into the library with one read of its bytes.

use crate::backend::{BackendError, invalid, operation, str_arg};
use crate::data_jobs::{Check, hash_file};
use kalao_core::pairing::{self, PickedFile};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

/// `{path, coverBase?}`. When the file has embedded art and `coverBase` is
/// given, the picture is written to `coverBase` + `.jpg`/`.png` and the
/// reply's `coverPath` names it.
pub fn probe(method: &str, args: &Value) -> Result<Value, BackendError> {
    let path = str_arg(method, args, "path")?;
    probe_with_cover(Path::new(path), args["coverBase"].as_str()).map_err(operation)
}

fn probe_with_cover(path: &Path, cover_base: Option<&str>) -> Result<Value, String> {
    let probe = kalao_audio::probe_file(path).map_err(|error| error.to_string())?;
    let mut reply = serde_json::to_value(&probe).map_err(|error| error.to_string())?;
    if let (Some(base), Some((media_type, bytes))) = (cover_base, &probe.cover) {
        let extension = if media_type.contains("png") {
            "png"
        } else {
            "jpg"
        };
        let cover_path = format!("{base}.{extension}");
        if let Some(parent) = Path::new(&cover_path).parent() {
            std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
        }
        std::fs::write(&cover_path, bytes).map_err(|error| error.to_string())?;
        reply["coverPath"] = Value::String(cover_path);
    }
    Ok(reply)
}

/// `{files: [{name, durationMs?}]}` → proposals (indices into `files`).
pub fn pair(method: &str, args: &Value) -> Result<Value, BackendError> {
    let files: Vec<PickedFile> = serde_json::from_value(args["files"].clone())
        .map_err(|error| invalid(method, error.to_string()))?;
    serde_json::to_value(pairing::propose(&files)).map_err(operation)
}

fn field<'a>(request: &'a Value, name: &str) -> Result<&'a str, String> {
    request[name]
        .as_str()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| format!("Missing native data field: {name}"))
}

/// `{path}` → `{sha256, probe}`: what the import sheet needs about a staged
/// file (duplicate check, tags, duration for pairing). A file Symphonia cannot
/// read still gets its hash, with `probe: null`.
pub(crate) fn inspect(request: &Value, check: Check) -> Result<Value, String> {
    let path = field(request, "path")?;
    let sha256 = hash_file(path, check)?;
    let probe = probe_with_cover(Path::new(path), None).ok();
    Ok(json!({"sha256": sha256, "probe": probe}))
}

/// `{path, sha256, mediaDir, coverBase?}` → `{path, bytes, probe}`: moves the
/// staged file to `mediaDir/<sha256>.<ext>` (by rename; the staged copy is
/// removed when the library already has the file) and probes it there,
/// writing its cover when `coverBase` is given.
pub(crate) fn store(request: &Value, check: Check) -> Result<Value, String> {
    let source = PathBuf::from(field(request, "path")?);
    let sha256 = field(request, "sha256")?;
    if sha256.len() != 64 || !sha256.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err("sha256 must be 64 hex digits".into());
    }
    let media_dir = PathBuf::from(field(request, "mediaDir")?);
    let extension = source
        .extension()
        .and_then(|value| value.to_str())
        .map(str::to_ascii_lowercase)
        .filter(|value| !value.is_empty() && value.bytes().all(|b| b.is_ascii_alphanumeric()))
        .ok_or("the staged file has no extension")?;
    std::fs::create_dir_all(&media_dir).map_err(|error| error.to_string())?;
    let target = media_dir.join(format!("{sha256}.{extension}"));
    check()?;
    if target.exists() {
        let _ = std::fs::remove_file(&source);
    } else if std::fs::rename(&source, &target).is_err() {
        // Another file system: copy, then drop the staged file.
        let partial = media_dir.join(format!("{sha256}.{extension}.part"));
        std::fs::copy(&source, &partial).map_err(|error| error.to_string())?;
        std::fs::rename(&partial, &target).map_err(|error| error.to_string())?;
        let _ = std::fs::remove_file(&source);
    }
    let bytes = std::fs::metadata(&target)
        .map_err(|error| error.to_string())?
        .len();
    let probe = probe_with_cover(&target, request["coverBase"].as_str()).ok();
    Ok(json!({
        "path": target.display().to_string(),
        "bytes": bytes,
        "probe": probe,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pair_and_probe_errors() {
        let reply = pair(
            "pairImportFiles",
            &json!({"files": [{"name": "a.mp3"}, {"name": "a (karaoke).mp3"}]}),
        )
        .unwrap();
        assert_eq!(reply[0]["instrumental"], 1);
        assert!(pair("pairImportFiles", &json!({})).is_err());
        assert!(probe("probeAudio", &json!({"path": "missing.mp3"})).is_err());
    }

    #[test]
    fn inspect_then_store_moves_the_file_once() {
        let root = std::env::temp_dir().join(format!("kalao-import-{}", std::process::id()));
        let staged = root.join("staging").join("123_song.MP3");
        std::fs::create_dir_all(staged.parent().unwrap()).unwrap();
        std::fs::write(&staged, b"not audio").unwrap();
        let ok = || Ok(());
        let inspected = inspect(&json!({"path": staged}), &ok).unwrap();
        let sha = inspected["sha256"].as_str().unwrap().to_owned();
        assert!(inspected["probe"].is_null());
        let media = root.join("media");
        let request = json!({"path": staged, "sha256": sha, "mediaDir": media});
        let stored = store(&request, &ok).unwrap();
        let target = media.join(format!("{sha}.mp3"));
        assert_eq!(stored["path"], target.display().to_string());
        assert_eq!(stored["bytes"], 9);
        assert!(!staged.exists() && target.exists());
        // A second import of the same file only drops the staged copy.
        std::fs::write(&staged, b"not audio").unwrap();
        store(&request, &ok).unwrap();
        assert!(!staged.exists());
        let bad = json!({"path": staged, "sha256": "x", "mediaDir": media});
        assert!(store(&bad, &ok).is_err());
        let _ = std::fs::remove_dir_all(root);
    }
}
