//! `kalao-ext`: the extension author's tool (EXTENSIONS.md §8).
//!
//! ```text
//! kalao-ext validate <folder|package.kalaoext>
//! kalao-ext test <folder> [--fixtures <tests.json>]
//! kalao-ext pack <folder> [-o <out.kalaoext>]
//! kalao-ext keygen -o <secret.key>
//! kalao-ext sign <package.kalaoext> --key <secret.key>
//! kalao-ext index <packages-folder> --key <secret.key> --name <repository name> [-o index.json]
//! ```

use kalao_extensions::capabilities;
use kalao_extensions::fetch::{Fixture, FixtureFetch};
use kalao_extensions::logs::ExtensionLog;
use kalao_extensions::manager::check_package;
use kalao_extensions::storage::{Settings, Storage};
use kalao_extensions::{HostContext, Limits, Package, Runtime, signing};
use serde_json::{Map, Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

const USAGE: &str = "usage:
  kalao-ext validate <folder|package.kalaoext>
  kalao-ext test <folder> [--fixtures <tests.json>]
  kalao-ext pack <folder> [-o <out.kalaoext>]
  kalao-ext keygen -o <secret.key>
  kalao-ext sign <package.kalaoext> --key <secret.key>
  kalao-ext index <packages-folder> --key <secret.key> --name <name> [-o <index.json>]";

/// `--name value` or `-n value`.
fn option(args: &[String], names: &[&str]) -> Option<String> {
    args.iter()
        .position(|arg| names.contains(&arg.as_str()))
        .and_then(|index| args.get(index + 1).cloned())
}

fn positional(args: &[String]) -> Option<&String> {
    let mut skip = false;
    for arg in args {
        if skip {
            skip = false;
            continue;
        }
        if arg.starts_with('-') {
            skip = true;
            continue;
        }
        return Some(arg);
    }
    None
}

fn load(path: &Path) -> Result<Package, String> {
    let bytes = if path.is_dir() {
        kalao_extensions::package::pack_dir(path).map_err(|e| e.to_string())?
    } else {
        std::fs::read(path).map_err(|e| format!("{}: {e}", path.display()))?
    };
    Package::from_bytes(bytes).map_err(|e| e.to_string())
}

/// Runs one command; the error is the message to print.
pub fn run(args: &[String]) -> Result<(), String> {
    let (command, rest) = args.split_first().ok_or(USAGE)?;
    let target = || {
        positional(rest)
            .map(PathBuf::from)
            .ok_or_else(|| USAGE.to_owned())
    };
    match command.as_str() {
        "validate" => {
            let package = load(&target()?)?;
            let exports = check_package(&package, &Limits::default()).map_err(|e| e.to_string())?;
            let manifest = &package.manifest;
            println!(
                "{} {} ({}) is valid",
                manifest.name, manifest.version, manifest.id
            );
            println!(
                "  capabilities: {}",
                manifest
                    .capabilities
                    .iter()
                    .map(|c| c.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            );
            println!("  hosts: {}", manifest.network.hosts.join(", "));
            println!("  exports: {}", exports.join(", "));
            println!("  sha256: {}", package.sha256);
            Ok(())
        }
        "test" => {
            let folder = target()?;
            let fixtures = option(rest, &["--fixtures", "-f"])
                .map(PathBuf::from)
                .unwrap_or_else(|| folder.join("fixtures").join("tests.json"));
            test(&folder, &fixtures)
        }
        "pack" => {
            let folder = target()?;
            let package = load(&folder)?;
            check_package(&package, &Limits::default()).map_err(|e| e.to_string())?;
            let out = option(rest, &["-o", "--out"])
                .map(PathBuf::from)
                .unwrap_or_else(|| {
                    PathBuf::from(format!(
                        "{}-{}.kalaoext",
                        package.manifest.id, package.manifest.version
                    ))
                });
            std::fs::write(&out, &package.bytes).map_err(|e| e.to_string())?;
            println!("{}  {}", package.sha256, out.display());
            Ok(())
        }
        "keygen" => {
            let out = option(rest, &["-o", "--out"]).ok_or(USAGE)?;
            if Path::new(&out).exists() {
                return Err(format!("{out} exists; refusing to overwrite a key"));
            }
            let (secret, public) = signing::generate().map_err(|e| e.to_string())?;
            std::fs::write(&out, format!("{secret}\n")).map_err(|e| e.to_string())?;
            println!("secret key written to {out} (keep it out of git)");
            println!("public key: {public}");
            println!(
                "fingerprint: {}",
                signing::key_fingerprint(&public).map_err(|e| e.to_string())?
            );
            Ok(())
        }
        "sign" => {
            let package = target()?;
            let secret = read_key(rest)?;
            let bytes = std::fs::read(&package).map_err(|e| e.to_string())?;
            let parsed = Package::from_bytes(bytes.clone()).map_err(|e| e.to_string())?;
            println!("sha256: {}", parsed.sha256);
            println!(
                "signature: {}",
                signing::sign(&secret, &bytes).map_err(|e| e.to_string())?
            );
            Ok(())
        }
        "index" => {
            let folder = target()?;
            let secret = read_key(rest)?;
            let name = option(rest, &["--name", "-n"]).ok_or(USAGE)?;
            let out = option(rest, &["-o", "--out"])
                .map(PathBuf::from)
                .unwrap_or_else(|| folder.join("index.json"));
            index(&folder, &secret, &name, &out)
        }
        "-h" | "--help" | "help" => {
            println!("{USAGE}");
            Ok(())
        }
        other => Err(format!("unknown command '{other}'\n{USAGE}")),
    }
}

fn read_key(args: &[String]) -> Result<String, String> {
    let path = option(args, &["--key", "-k"]).ok_or(USAGE)?;
    Ok(std::fs::read_to_string(&path)
        .map_err(|e| format!("{path}: {e}"))?
        .trim()
        .to_owned())
}

fn index(folder: &Path, secret: &str, name: &str, out: &Path) -> Result<(), String> {
    let mut entries = Vec::new();
    let mut paths: Vec<PathBuf> = std::fs::read_dir(folder)
        .map_err(|e| e.to_string())?
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .filter(|path| path.extension().is_some_and(|ext| ext == "kalaoext"))
        .collect();
    paths.sort();
    for path in paths {
        let bytes = std::fs::read(&path).map_err(|e| e.to_string())?;
        let package =
            Package::from_bytes(bytes.clone()).map_err(|e| format!("{}: {e}", path.display()))?;
        let manifest = &package.manifest;
        let file = path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        entries.push(json!({
            "id": manifest.id,
            "version": manifest.version,
            "name": manifest.name,
            "description": manifest.description,
            "capabilities": manifest.capabilities,
            "minKalao": manifest.min_kalao,
            "url": file,
            "sha256": package.sha256,
            "signature": signing::sign(secret, &bytes).map_err(|e| e.to_string())?,
        }));
    }
    let index = json!({
        "name": name,
        "publicKey": signing::public_key(secret).map_err(|e| e.to_string())?,
        "extensions": entries,
    });
    let text = serde_json::to_string_pretty(&index).map_err(|e| e.to_string())?;
    std::fs::write(out, text + "\n").map_err(|e| e.to_string())?;
    println!("{} extensions listed in {}", entries.len(), out.display());
    Ok(())
}

/// Runs the calls in a fixtures file against recorded HTTP responses and
/// checks each result as the app would.
fn test(folder: &Path, fixtures_path: &Path) -> Result<(), String> {
    let package = load(folder)?;
    check_package(&package, &Limits::default()).map_err(|e| e.to_string())?;
    let spec: Value = serde_json::from_slice(
        &std::fs::read(fixtures_path).map_err(|e| format!("{}: {e}", fixtures_path.display()))?,
    )
    .map_err(|e| format!("{}: {e}", fixtures_path.display()))?;
    let fixtures: Vec<Fixture> =
        serde_json::from_value(spec["fixtures"].clone()).map_err(|e| format!("fixtures: {e}"))?;
    let manifest = package.manifest.clone();
    let settings: Map<String, Value> = spec["settings"].as_object().cloned().unwrap_or_default();
    let fetch = Arc::new(FixtureFetch::new(fixtures, &manifest.network.hosts));
    let log = Arc::new(ExtensionLog::default());
    let runtime = Runtime::start(
        &package,
        HostContext {
            extension_id: manifest.id.clone(),
            manifest: manifest.clone(),
            settings: Arc::new(Settings::new(manifest.clone(), settings)),
            storage: Arc::new(Storage::new(None)),
            fetch,
            log: log.clone(),
            auth_url_check: Arc::new(|_| Err("logins cannot run in tests".into())),
        },
        Limits::default(),
    )
    .map_err(|e| e.to_string())?;
    let calls = spec["calls"].as_array().cloned().unwrap_or_default();
    if calls.is_empty() {
        return Err("the fixtures file has no calls".into());
    }
    let mut failures = 0;
    for call in &calls {
        let function = call["function"]
            .as_str()
            .ok_or("each call needs a function")?;
        let name = call["name"].as_str().unwrap_or(function);
        let outcome = runtime
            .call(
                function,
                &call["argument"].to_string(),
                Duration::from_secs(10),
            )
            .map_err(|e| e.to_string())
            .and_then(|text| serde_json::from_str::<Value>(&text).map_err(|e| e.to_string()))
            .and_then(|value| validated(function, &value))
            .and_then(|(items, dropped)| {
                for reason in &dropped {
                    println!("    dropped: {reason}");
                }
                expect(&call["expect"], &items)
            });
        match outcome {
            Ok(()) => println!("ok    {name}"),
            Err(error) => {
                failures += 1;
                println!("FAIL  {name}: {error}");
            }
        }
    }
    for entry in log.entries() {
        println!("    [{}] {}", entry.level, entry.message);
    }
    if failures > 0 {
        return Err(format!("{failures} of {} calls failed", calls.len()));
    }
    println!("{} calls passed", calls.len());
    Ok(())
}

/// The result as the app keeps it: a list of valid items, and why others
/// were dropped.
fn validated(function: &str, value: &Value) -> Result<(Vec<Value>, Vec<String>), String> {
    let to_values = |items: Vec<Value>| items;
    Ok(match function {
        "searchLyrics" => {
            let (items, dropped) = capabilities::lyrics_candidates(value)?;
            (
                to_values(
                    items
                        .iter()
                        .map(|i| serde_json::to_value(i).unwrap_or_default())
                        .collect(),
                ),
                dropped,
            )
        }
        "getLyrics" => (
            vec![serde_json::to_value(capabilities::lyrics_body(value)?).unwrap_or_default()],
            Vec::new(),
        ),
        "searchTracks" => {
            let (items, dropped) = capabilities::tracks(value)?;
            (
                items
                    .iter()
                    .map(|i| serde_json::to_value(i).unwrap_or_default())
                    .collect(),
                dropped,
            )
        }
        "getTrack" => (
            vec![serde_json::to_value(capabilities::single_track(value)?).unwrap_or_default()],
            Vec::new(),
        ),
        "getArtwork" => (
            capabilities::images(value)?
                .iter()
                .map(|i| serde_json::to_value(i).unwrap_or_default())
                .collect(),
            Vec::new(),
        ),
        "resolveAudio" => (
            capabilities::audio_sources(value)?
                .iter()
                .map(|i| serde_json::to_value(i).unwrap_or_default())
                .collect(),
            Vec::new(),
        ),
        _ => (vec![value.clone()], Vec::new()),
    })
}

/// `{ "items": n, "minItems": n, "first": { partial match } }`.
fn expect(expectation: &Value, items: &[Value]) -> Result<(), String> {
    if let Some(count) = expectation["items"].as_u64()
        && items.len() as u64 != count
    {
        return Err(format!("expected {count} items, got {}", items.len()));
    }
    if let Some(minimum) = expectation["minItems"].as_u64()
        && (items.len() as u64) < minimum
    {
        return Err(format!(
            "expected at least {minimum} items, got {}",
            items.len()
        ));
    }
    if let Some(first) = expectation["first"].as_object() {
        let item = items.first().ok_or("expected a first item, got none")?;
        for (key, wanted) in first {
            if &item[key] != wanted {
                return Err(format!(
                    "first item: {key} is {}, expected {wanted}",
                    item[key]
                ));
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> String {
        concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../examples/extensions/lrclib"
        )
        .to_owned()
    }

    #[test]
    fn the_lrclib_sample_validates_and_passes_its_fixtures() {
        run(&["validate".into(), sample()]).unwrap();
        run(&["test".into(), sample()]).unwrap();
    }

    #[test]
    fn keys_sign_packages_and_build_an_index() {
        let dir = std::env::temp_dir().join(format!("kalao-ext-cli-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let key = dir.join("secret.key").to_string_lossy().into_owned();
        let package = dir.join("lrclib.kalaoext").to_string_lossy().into_owned();
        run(&["keygen".into(), "-o".into(), key.clone()]).unwrap();
        assert!(run(&["keygen".into(), "-o".into(), key.clone()]).is_err());
        run(&["pack".into(), sample(), "-o".into(), package.clone()]).unwrap();
        run(&["sign".into(), package, "--key".into(), key.clone()]).unwrap();
        run(&[
            "index".into(),
            dir.to_string_lossy().into_owned(),
            "--key".into(),
            key,
            "--name".into(),
            "Test".into(),
        ])
        .unwrap();
        let index = std::fs::read(dir.join("index.json")).unwrap();
        let parsed = kalao_extensions::repository::Index::parse(
            &index,
            "https://example.org/repo/index.json",
        )
        .unwrap();
        assert_eq!(parsed.extensions[0].id, "app.kalao.lrclib");
        assert_eq!(
            parsed.extensions[0].url,
            "https://example.org/repo/lrclib.kalaoext"
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
