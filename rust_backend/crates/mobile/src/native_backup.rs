//! `.kalaobackup` archives (DATA_MODEL.md §3): a ZIP with a `manifest.json`
//! that records the SHA-256 and size of every other entry. Dart decides what
//! goes in (snapshots, settings, media) and merges what comes out; this
//! module only streams files in and out, so large media never passes
//! through the UI isolate. Reading treats the archive as untrusted
//! (SECURITY.md): names are checked, sizes are bounded and every entry must
//! match its checksum before anything is kept.

use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::fs::{self, File};
use std::io::{BufReader, BufWriter, Read, Write};
use std::path::{Path, PathBuf};
use zip::write::SimpleFileOptions;
use zip::{CompressionMethod, ZipArchive, ZipWriter};

const MANIFEST: &str = "manifest.json";
const MAX_ENTRIES: usize = 50_000;
const MAX_MANIFEST_BYTES: u64 = 8 * 1024 * 1024;
/// A deflated entry may expand at most this much (zip-bomb guard); real
/// databases and JSON compress far less.
const MAX_RATIO: u64 = 200;

type Check<'a> = &'a dyn Fn() -> Result<(), String>;

/// `{output, entries: [{name, path}], manifest: {...}}` → the archive at
/// `output` (written to a `.partial` file, then renamed) and
/// `{bytes, entries}`. The manifest gains `entries: {name: {sha256, bytes}}`.
pub(crate) fn write(request: &Value, check: Check) -> Result<Value, String> {
    let output = PathBuf::from(field(request, "output")?);
    let mut manifest = match request.get("manifest") {
        Some(Value::Object(map)) => map.clone(),
        _ => return Err("Missing native data field: manifest".into()),
    };
    let entries = request
        .get("entries")
        .and_then(Value::as_array)
        .ok_or("Missing native data field: entries")?;
    let partial = output.with_extension("partial");
    let result = write_archive(&partial, entries, &mut manifest, check);
    if let Err(error) = result {
        let _ = fs::remove_file(&partial);
        return Err(error);
    }
    fs::rename(&partial, &output).map_err(|error| error.to_string())?;
    let bytes = fs::metadata(&output)
        .map_err(|error| error.to_string())?
        .len();
    Ok(json!({"bytes": bytes, "entries": entries.len()}))
}

fn write_archive(
    path: &Path,
    entries: &[Value],
    manifest: &mut Map<String, Value>,
    check: Check,
) -> Result<(), String> {
    let file = File::create(path).map_err(|error| error.to_string())?;
    let mut zip = ZipWriter::new(BufWriter::new(file));
    let mut sums = Map::new();
    for entry in entries {
        let name = field(entry, "name")?;
        validate_name(name)?;
        if name == MANIFEST || sums.contains_key(name) {
            return Err(format!("Duplicate backup entry: {name}"));
        }
        let source = File::open(field(entry, "path")?).map_err(|error| error.to_string())?;
        let size = source.metadata().map_err(|error| error.to_string())?.len();
        // Audio is already compressed; storing it is as small and faster.
        let method = if name.starts_with("media/") || name.starts_with("stems/") {
            CompressionMethod::Stored
        } else {
            CompressionMethod::Deflated
        };
        let options = SimpleFileOptions::default()
            .compression_method(method)
            .large_file(size >= u64::from(u32::MAX));
        zip.start_file(name, options)
            .map_err(|error| error.to_string())?;
        let (sha256, bytes) = copy_hashed(BufReader::new(source), &mut zip, u64::MAX, check)?;
        sums.insert(name.into(), json!({"sha256": sha256, "bytes": bytes}));
    }
    manifest.insert("entries".into(), Value::Object(sums));
    zip.start_file(
        MANIFEST,
        SimpleFileOptions::default().compression_method(CompressionMethod::Deflated),
    )
    .map_err(|error| error.to_string())?;
    let text = serde_json::to_vec_pretty(&Value::Object(manifest.clone()))
        .map_err(|error| error.to_string())?;
    zip.write_all(&text).map_err(|error| error.to_string())?;
    let mut writer = zip.finish().map_err(|error| error.to_string())?;
    writer.flush().map_err(|error| error.to_string())?;
    writer
        .into_inner()
        .map_err(|error| error.to_string())?
        .sync_all()
        .map_err(|error| error.to_string())
}

/// `{path, extractTo, maxFormat}` → checks the archive, extracts every entry
/// under `extractTo` (which must not exist yet) and returns the manifest.
/// Nothing is left behind when a check fails.
pub(crate) fn inspect(request: &Value, check: Check) -> Result<Value, String> {
    let path = field(request, "path")?;
    let target = PathBuf::from(field(request, "extractTo")?);
    let max_format = request
        .get("maxFormat")
        .and_then(Value::as_u64)
        .ok_or("Missing native data field: maxFormat")?;
    if target.exists() {
        return Err("Restore folder already exists".into());
    }
    let result = extract(path, &target, max_format, check);
    if result.is_err() {
        let _ = fs::remove_dir_all(&target);
    }
    result
}

fn extract(path: &str, target: &Path, max_format: u64, check: Check) -> Result<Value, String> {
    let file = File::open(path).map_err(|error| error.to_string())?;
    let mut zip = ZipArchive::new(BufReader::new(file))
        .map_err(|_| "This file is not a Kalao backup".to_string())?;
    if zip.len() > MAX_ENTRIES {
        return Err("The backup has too many entries".into());
    }
    let manifest = read_manifest(&mut zip)?;
    let format = manifest
        .get("format")
        .and_then(Value::as_u64)
        .ok_or("The backup manifest has no format")?;
    if format > max_format {
        return Err(format!(
            "This backup was made by a newer version of Kalao (format {format}); update Kalao to restore it"
        ));
    }
    let expected = manifest
        .get("entries")
        .and_then(Value::as_object)
        .ok_or("The backup manifest lists no entries")?;
    let mut seen = 0usize;
    fs::create_dir_all(target).map_err(|error| error.to_string())?;
    for index in 0..zip.len() {
        check()?;
        let mut entry = zip.by_index(index).map_err(|error| error.to_string())?;
        let name = entry
            .name()
            .map_err(|_| "Unsafe backup entry name".to_string())?
            .into_owned();
        if name == MANIFEST {
            continue;
        }
        if entry.is_dir() {
            validate_name(name.trim_end_matches('/'))?;
            continue;
        }
        validate_name(&name)?;
        if entry.is_symlink() {
            return Err(format!("Backup entry is a link: {name}"));
        }
        let Some(listed) = expected.get(&name) else {
            return Err(format!("Backup entry is not in the manifest: {name}"));
        };
        let declared = entry.size();
        if entry.compression() != CompressionMethod::Stored
            && declared > entry.compressed_size().saturating_mul(MAX_RATIO) + 1024 * 1024
        {
            return Err(format!("Backup entry expands too much: {name}"));
        }
        let out = target.join(&name);
        if let Some(parent) = out.parent() {
            fs::create_dir_all(parent).map_err(|error| error.to_string())?;
        }
        let mut writer = BufWriter::new(File::create(&out).map_err(|error| error.to_string())?);
        let (sha256, bytes) = copy_hashed(&mut entry, &mut writer, declared, check)?;
        writer.flush().map_err(|error| error.to_string())?;
        if listed.get("sha256").and_then(Value::as_str) != Some(sha256.as_str())
            || listed.get("bytes").and_then(Value::as_u64) != Some(bytes)
        {
            return Err(format!("Backup entry is damaged: {name}"));
        }
        seen += 1;
    }
    if seen != expected.len() {
        return Err("The backup is missing entries".into());
    }
    Ok(manifest)
}

fn read_manifest<R: Read + std::io::Seek>(zip: &mut ZipArchive<R>) -> Result<Value, String> {
    let entry = zip
        .by_name(MANIFEST)
        .map_err(|_| "This file is not a Kalao backup".to_string())?;
    if entry.size() > MAX_MANIFEST_BYTES {
        return Err("The backup manifest is too large".into());
    }
    let mut text = String::new();
    entry
        .take(MAX_MANIFEST_BYTES)
        .read_to_string(&mut text)
        .map_err(|error| error.to_string())?;
    let manifest: Value =
        serde_json::from_str(&text).map_err(|_| "The backup manifest is unreadable".to_string())?;
    if !manifest.is_object() {
        return Err("The backup manifest is unreadable".into());
    }
    Ok(manifest)
}

/// Copies at most `limit` bytes (an error if there are more) and returns the
/// SHA-256 and the byte count.
fn copy_hashed(
    mut reader: impl Read,
    writer: &mut impl Write,
    limit: u64,
    check: Check,
) -> Result<(String, u64), String> {
    let mut hash = Sha256::new();
    let mut buffer = vec![0; 256 * 1024];
    let mut total = 0u64;
    loop {
        check()?;
        let count = reader
            .read(&mut buffer)
            .map_err(|error| error.to_string())?;
        if count == 0 {
            break;
        }
        total += count as u64;
        if total > limit {
            return Err("Backup entry is larger than declared".into());
        }
        hash.update(&buffer[..count]);
        writer
            .write_all(&buffer[..count])
            .map_err(|error| error.to_string())?;
    }
    Ok((kalao_core::lower_hex(&hash.finalize()), total))
}

/// Relative `a/b.c` paths of plain characters only: no absolute paths,
/// `.`/`..` segments, backslashes or drive letters.
fn validate_name(name: &str) -> Result<(), String> {
    let ok = !name.is_empty()
        && name.len() <= 255
        && name.split('/').all(|segment| {
            !segment.is_empty()
                && segment != "."
                && segment != ".."
                && segment
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
        });
    if ok {
        Ok(())
    } else {
        Err(format!("Unsafe backup entry name: {name}"))
    }
}

fn field<'a>(value: &'a Value, name: &str) -> Result<&'a str, String> {
    value
        .get(name)
        .and_then(Value::as_str)
        .filter(|text| !text.is_empty())
        .ok_or_else(|| format!("Missing native data field: {name}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ok() -> Result<(), String> {
        Ok(())
    }

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "kalao-backup-{name}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn sample(dir: &Path) -> Value {
        fs::write(dir.join("library.db"), b"sqlite bytes ".repeat(100)).unwrap();
        fs::write(dir.join("song.mp3"), b"\xff\xfbaudio").unwrap();
        let output = dir.join("out.kalaobackup");
        write(
            &json!({
                "output": output,
                "manifest": {"format": 1, "appVersion": "0.1.0"},
                "entries": [
                    {"name": "library.db", "path": dir.join("library.db")},
                    {"name": "media/abc.mp3", "path": dir.join("song.mp3")},
                ],
            }),
            &ok,
        )
        .unwrap()
    }

    #[test]
    fn round_trips_entries_with_checksums() {
        let dir = temp("round");
        let written = sample(&dir);
        assert_eq!(written["entries"], 2);
        let restored = dir.join("restore");
        let manifest = inspect(
            &json!({"path": dir.join("out.kalaobackup"), "extractTo": restored, "maxFormat": 1}),
            &ok,
        )
        .unwrap();
        assert_eq!(manifest["appVersion"], "0.1.0");
        assert_eq!(
            manifest["entries"]["media/abc.mp3"]["sha256"],
            kalao_core::lower_hex(&Sha256::digest(b"\xff\xfbaudio"))
        );
        assert_eq!(
            fs::read(restored.join("library.db")).unwrap(),
            b"sqlite bytes ".repeat(100)
        );
        assert_eq!(
            fs::read(restored.join("media/abc.mp3")).unwrap(),
            b"\xff\xfbaudio"
        );
        assert!(!dir.join("out.partial").exists());
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn refuses_newer_formats_and_leaves_nothing_behind() {
        let dir = temp("newer");
        sample(&dir);
        let restored = dir.join("restore");
        let error = inspect(
            &json!({"path": dir.join("out.kalaobackup"), "extractTo": restored, "maxFormat": 0}),
            &ok,
        )
        .unwrap_err();
        assert!(error.contains("newer version"), "{error}");
        assert!(!restored.exists());
        let _ = fs::remove_dir_all(dir);
    }

    /// Writes a hand-made archive with [entries] and a manifest listing
    /// [listed] as `{name: (sha256, bytes)}`.
    fn forged(dir: &Path, entries: &[(&str, &[u8])], listed: Value) -> PathBuf {
        let path = dir.join("forged.kalaobackup");
        let mut zip = ZipWriter::new(File::create(&path).unwrap());
        for (name, data) in entries {
            zip.start_file(*name, SimpleFileOptions::default()).unwrap();
            zip.write_all(data).unwrap();
        }
        zip.start_file(MANIFEST, SimpleFileOptions::default())
            .unwrap();
        zip.write_all(
            json!({"format": 1, "entries": listed})
                .to_string()
                .as_bytes(),
        )
        .unwrap();
        zip.finish().unwrap();
        path
    }

    fn inspect_err(path: &Path, dir: &Path) -> String {
        let restored = dir.join("restore");
        let error = inspect(
            &json!({"path": path, "extractTo": restored, "maxFormat": 1}),
            &ok,
        )
        .unwrap_err();
        assert!(!restored.exists());
        error
    }

    #[test]
    fn rejects_damaged_unlisted_missing_and_unsafe_entries() {
        let dir = temp("bad");
        let sha = |data: &[u8]| kalao_core::lower_hex(&Sha256::digest(data));
        let damaged = forged(
            &dir,
            &[("a.db", b"one")],
            json!({"a.db": {"sha256": sha(b"two"), "bytes": 3}}),
        );
        assert!(inspect_err(&damaged, &dir).contains("damaged"));
        let unlisted = forged(&dir, &[("a.db", b"one")], json!({}));
        assert!(inspect_err(&unlisted, &dir).contains("not in the manifest"));
        let missing = forged(
            &dir,
            &[],
            json!({"a.db": {"sha256": sha(b"one"), "bytes": 3}}),
        );
        assert!(inspect_err(&missing, &dir).contains("missing"));
        for name in ["../evil", "/abs", "a/../b", "c:\\x", "a//b"] {
            let unsafe_name = forged(
                &dir,
                &[(name, b"x")],
                json!({name: {"sha256": sha(b"x"), "bytes": 1}}),
            );
            assert!(
                inspect_err(&unsafe_name, &dir).contains("Unsafe"),
                "{name} was accepted"
            );
        }
        fs::write(dir.join("plain.txt"), b"not a zip").unwrap();
        assert!(inspect_err(&dir.join("plain.txt"), &dir).contains("not a Kalao backup"));
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn cancellation_stops_writing_and_removes_the_partial_file() {
        let dir = temp("cancel");
        fs::write(dir.join("a.db"), b"x").unwrap();
        let output = dir.join("out.kalaobackup");
        let error = write(
            &json!({"output": output, "manifest": {"format": 1},
                "entries": [{"name": "a.db", "path": dir.join("a.db")}]}),
            &|| Err("data job cancelled".into()),
        )
        .unwrap_err();
        assert_eq!(error, "data job cancelled");
        assert!(!output.exists() && !dir.join("out.partial").exists());
        let _ = fs::remove_dir_all(dir);
    }
}
