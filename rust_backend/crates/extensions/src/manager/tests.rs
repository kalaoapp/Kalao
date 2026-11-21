use super::*;
use crate::capabilities::Query;
use crate::fetch::{Fixture, FixtureFetch};
use crate::package::tests::zip;
use base64::Engine;
use serde_json::json;

struct Dir(PathBuf);

impl Drop for Dir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn temp_dir(name: &str) -> Dir {
    static COUNTER: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    let dir = std::env::temp_dir().join(format!("kalao-mgr-{name}-{}-{n}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    Dir(dir)
}

fn manifest(id: &str, version: &str, capabilities: &[&str], extra: Value) -> String {
    let mut value = json!({
        "schema": 1,
        "id": id,
        "name": format!("Ext {id}"),
        "version": version,
        "capabilities": capabilities,
        "network": { "hosts": ["api.example.org", "private.example.org"] },
        "settings": [
            { "key": "token", "type": "secret", "label": "Token", "grantsNetwork": "private.example.org" },
            { "key": "region", "type": "select", "label": "Region", "options": ["jp", "tw"], "default": "jp" },
            { "key": "login", "type": "button", "label": "Log in", "action": "startLogin" }
        ],
    });
    if let Value::Object(extra) = extra {
        for (key, field) in extra {
            value[key] = field;
        }
    }
    value.to_string()
}

fn package(id: &str, version: &str, capabilities: &[&str], js: &str) -> Vec<u8> {
    let manifest = manifest(id, version, capabilities, json!({}));
    zip(&[
        ("manifest.json", manifest.as_bytes()),
        ("index.js", js.as_bytes()),
    ])
}

const LYRICS_JS: &str = "
export async function searchLyrics(q) {
  return [
    { id: 'a', title: q.title, artist: q.artist, durationMs: q.durationMs, format: kalao.settings.get('region') === 'tw' ? 'elrc' : 'lrc', body: '[00:01.00]hi' },
    { id: 'bad' },
  ];
}
export async function startLogin() { kalao.settings.set('token', 'new-secret'); kalao.settings.set('region', 'tw'); return 'done'; }
";

fn manager(dir: &Dir, fixtures: Vec<Fixture>) -> Manager {
    let fetch = Arc::new(FixtureFetch::new(
        fixtures,
        &["api.example.org".into(), "repo.example.org".into()],
    ));
    Manager::new(dir.0.clone(), "0.1.0", Network::Fixed(fetch)).unwrap()
}

fn install(manager: &Manager, bytes: Vec<u8>) -> Result<Value, Error> {
    manager.install(
        Package::from_bytes(bytes)?,
        Source {
            kind: "file".into(),
            ..Source::default()
        },
        false,
    )
}

#[test]
fn installs_updates_and_uninstalls() {
    let dir = temp_dir("install");
    let manager = manager(&dir, Vec::new());
    let info = install(
        &manager,
        package("dev.test.a", "1.0.0", &["lyrics"], LYRICS_JS),
    )
    .unwrap();
    assert_eq!(info["enabled"], true);
    assert_eq!(info["missingSecrets"], json!(["token"]));
    manager
        .set_setting("dev.test.a", "region", json!("tw"))
        .unwrap();

    // An update keeps settings and state; a downgrade needs consent.
    install(
        &manager,
        package("dev.test.a", "1.1.0", &["lyrics"], LYRICS_JS),
    )
    .unwrap();
    let info = manager.info("dev.test.a").unwrap();
    assert_eq!(info["version"], "1.1.0");
    assert_eq!(info["settings"]["region"], "tw");
    assert!(
        install(
            &manager,
            package("dev.test.a", "1.0.0", &["lyrics"], LYRICS_JS)
        )
        .is_err()
    );
    let older =
        Package::from_bytes(package("dev.test.a", "1.0.0", &["lyrics"], LYRICS_JS)).unwrap();
    assert!(manager.install(older, Source::default(), true).is_ok());

    // The registry survives a restart.
    let reopened = manager_reopen(&dir);
    assert_eq!(reopened.list().len(), 1);
    assert_eq!(reopened.priority()[&Capability::Lyrics], ["dev.test.a"]);

    manager.uninstall("dev.test.a").unwrap();
    assert!(manager.list().is_empty());
    assert!(!dir.0.join("dev.test.a").exists());
    assert!(manager.uninstall("dev.test.a").is_err());
}

fn manager_reopen(dir: &Dir) -> Manager {
    manager(dir, Vec::new())
}

#[test]
fn refuses_packages_that_do_not_export_their_capabilities() {
    let dir = temp_dir("exports");
    let manager = manager(&dir, Vec::new());
    let error = install(
        &manager,
        package("dev.test.b", "1.0.0", &["metadata"], LYRICS_JS),
    )
    .unwrap_err()
    .to_string();
    assert!(error.contains("searchTracks"), "{error}");
    let error = install(
        &manager,
        package(
            "dev.test.b",
            "1.0.0",
            &["lyrics"],
            "export function searchLyrics() { return []; }",
        ),
    )
    .unwrap_err()
    .to_string();
    assert!(error.contains("startLogin"), "{error}");
    let error = install(
        &manager,
        package("dev.test.b", "1.0.0", &["lyrics"], "syntax error here"),
    )
    .unwrap_err()
    .to_string();
    assert!(error.contains("failed to load"), "{error}");
    let needs_newer = manifest(
        "dev.test.c",
        "1.0.0",
        &["lyrics"],
        json!({ "minKalao": "9.0.0" }),
    );
    let bytes = zip(&[
        ("manifest.json", needs_newer.as_bytes()),
        ("index.js", LYRICS_JS.as_bytes()),
    ]);
    assert!(
        install(&manager, bytes)
            .unwrap_err()
            .to_string()
            .contains("9.0.0")
    );
}

#[test]
fn actions_hand_secrets_back_and_persist_plain_settings() {
    let dir = temp_dir("secrets");
    let manager = manager(&dir, Vec::new());
    install(
        &manager,
        package("dev.test.a", "1.0.0", &["lyrics"], LYRICS_JS),
    )
    .unwrap();
    assert_eq!(
        manager.invoke_action("dev.test.a", "login").unwrap(),
        json!("done")
    );
    let updates = manager.take_secret_updates();
    assert_eq!(updates["dev.test.a"]["token"], "new-secret");
    assert!(manager.take_secret_updates().is_empty());
    let info = manager.info("dev.test.a").unwrap();
    assert_eq!(info["settings"]["region"], "tw");
    assert_eq!(info["secretsSet"], json!(["token"]));
    // The secret never lands on disk.
    let registry = std::fs::read_to_string(dir.0.join("registry.json")).unwrap();
    assert!(!registry.contains("new-secret"));
    assert!(manager.invoke_action("dev.test.a", "region").is_err());
}

#[test]
fn granted_hosts_unlock_only_with_their_setting() {
    let manifest =
        Manifest::parse(manifest("a.b", "1.0.0", &["lyrics"], json!({})).as_bytes()).unwrap();
    let mut values = Map::new();
    assert_eq!(
        Manager::active_hosts(&manifest, &values),
        ["api.example.org"]
    );
    values.insert("token".into(), json!("x"));
    assert_eq!(
        Manager::active_hosts(&manifest, &values),
        ["api.example.org", "private.example.org"]
    );
}

#[test]
fn lyrics_are_ranked_across_extensions_and_failures_degrade() {
    let dir = temp_dir("lyrics");
    let manager = manager(&dir, Vec::new());
    install(
        &manager,
        package("dev.test.a", "1.0.0", &["lyrics"], LYRICS_JS),
    )
    .unwrap();
    install(
        &manager,
        package(
            "dev.test.plain",
            "1.0.0",
            &["lyrics"],
            "export function searchLyrics(q) { return [{ id: 1, title: q.title, artist: q.artist, format: 'plain', body: 'hi' }]; }
             export function startLogin() {}",
        ),
    )
    .unwrap();
    install(
        &manager,
        package(
            "dev.test.broken",
            "1.0.0",
            &["lyrics"],
            "export function searchLyrics() { throw new Error('site changed'); } export function startLogin() {}",
        ),
    )
    .unwrap();
    // The plain provider is preferred, but synced lyrics still rank first.
    manager
        .set_priority(
            Capability::Lyrics,
            &["dev.test.plain".into(), "dev.test.a".into()],
        )
        .unwrap();
    assert_eq!(
        manager.priority()[&Capability::Lyrics],
        ["dev.test.plain", "dev.test.a", "dev.test.broken"]
    );
    let query = Query {
        title: "Moon".into(),
        artist: "Teresa".into(),
        duration_ms: Some(200_000),
        ..Query::default()
    };
    let result = manager.search_lyrics(&query);
    let candidates = result["candidates"].as_array().unwrap();
    assert_eq!(candidates.len(), 2);
    assert_eq!(candidates[0]["extensionId"], "dev.test.a");
    assert_eq!(candidates[0]["format"], "lrc");
    assert_eq!(candidates[1]["extensionId"], "dev.test.plain");
    assert_eq!(result["errors"][0]["extensionId"], "dev.test.broken");
    assert!(
        manager
            .logs("dev.test.a")
            .iter()
            .any(|e| e.message.contains("dropped invalid"))
    );

    for _ in 0..2 {
        manager.search_lyrics(&query);
    }
    assert!(
        !manager
            .providers(Capability::Lyrics)
            .contains(&"dev.test.broken".to_owned())
    );
    assert_eq!(manager.info("dev.test.broken").unwrap()["degraded"], true);
    manager.set_enabled("dev.test.broken", true).unwrap();
    assert!(
        manager
            .providers(Capability::Lyrics)
            .contains(&"dev.test.broken".to_owned())
    );
    manager.set_enabled("dev.test.plain", false).unwrap();
    assert!(
        !manager
            .providers(Capability::Lyrics)
            .contains(&"dev.test.plain".to_owned())
    );
}

#[test]
fn metadata_results_merge_and_audio_is_validated() {
    let dir = temp_dir("metadata");
    let manager = manager(&dir, Vec::new());
    let js = |isrc: &str, album: &str| {
        format!(
            "export function searchTracks(q) {{ return [{{ id: 't1', title: q.title, artist: 'Teresa Teng', isrc: '{isrc}', album: {album} }}]; }}
             export function getTrack(id) {{ return {{ id, title: 'Moon', artists: ['Teresa Teng'] }}; }}
             export function getArtwork(t) {{ return [{{ url: 'https://img.example.org/' + t.id + '.jpg', width: 600 }}]; }}
             export function resolveAudio(t) {{ return {{ sources: [{{ url: 'https://cdn.example.org/' + t.id + '.mp3', format: 'mp3' }}] }}; }}
             export function startLogin() {{}}"
        )
    };
    install(
        &manager,
        package(
            "dev.test.m1",
            "1.0.0",
            &["metadata", "artwork", "audio"],
            &js("TW1", "null"),
        ),
    )
    .unwrap();
    install(
        &manager,
        package("dev.test.m2", "1.0.0", &["metadata"], &js("tw1", "'Album'")),
    )
    .unwrap();
    let result = manager.search_tracks(&Query {
        title: "Moon".into(),
        ..Query::default()
    });
    let tracks = result["tracks"].as_array().unwrap();
    assert_eq!(tracks.len(), 1, "{result}");
    assert_eq!(tracks[0]["extensionId"], "dev.test.m1");
    assert_eq!(tracks[0]["album"], "Album");
    assert_eq!(tracks[0]["alternatives"][0]["extensionId"], "dev.test.m2");

    assert_eq!(manager.get_track("dev.test.m2", "t9").unwrap()["id"], "t9");
    let art = manager.get_artwork(None, &json!({ "id": "t1" })).unwrap();
    assert_eq!(art["images"][0]["url"], "https://img.example.org/t1.jpg");
    let audio = manager
        .resolve_audio("dev.test.m1", &json!({ "id": "t1" }))
        .unwrap();
    assert_eq!(audio["sources"][0]["kind"], "original");
    assert!(
        manager
            .resolve_audio("dev.test.m2", &json!({ "id": "t1" }))
            .is_err()
    );
}

#[test]
fn health_checks_report_and_clear_degraded() {
    let dir = temp_dir("health");
    let manager = manager(
        &dir,
        vec![Fixture {
            method: "HEAD".into(),
            url: "https://api.example.org/ping".into(),
            status: 204,
            headers: Default::default(),
            body: None,
            body_json: None,
            body_base64: None,
        }],
    );
    let manifest = manifest(
        "dev.test.h",
        "1.0.0",
        &["lyrics"],
        json!({ "health": [{ "id": "api", "url": "https://api.example.org/ping", "method": "HEAD" }] }),
    );
    let bytes = zip(&[
        ("manifest.json", manifest.as_bytes()),
        ("index.js", LYRICS_JS.as_bytes()),
    ]);
    install(&manager, bytes).unwrap();
    let report = manager.check_health("dev.test.h").unwrap();
    assert_eq!(report["ok"], true);
    assert_eq!(report["checks"][0]["status"], 204);
    assert_eq!(manager.info("dev.test.h").unwrap()["health"]["ok"], true);
}

#[test]
fn repositories_are_trusted_refreshed_and_installed_from() {
    let dir = temp_dir("repo");
    let (secret, public) = crate::signing::generate().unwrap();
    let v1 = package("dev.test.r", "1.0.0", &["lyrics"], LYRICS_JS);
    let v2 = package("dev.test.r", "1.1.0", &["lyrics"], LYRICS_JS);
    let index = crate::repository::tests::signed_index(
        &secret,
        &public,
        &[("dev.test.r", "1.0.0", &v1), ("dev.test.r", "1.1.0", &v2)],
    );
    let url = "https://repo.example.org/index.json";
    let fixture = |url: &str, bytes: &[u8]| Fixture {
        method: "GET".into(),
        url: url.into(),
        status: 200,
        headers: Default::default(),
        body: None,
        body_json: None,
        body_base64: Some(base64::engine::general_purpose::STANDARD.encode(bytes)),
    };
    let manager = manager(
        &dir,
        vec![
            fixture(url, index.as_bytes()),
            fixture(
                "https://repo.example.org/pkg/dev.test.r-1.1.0.kalaoext",
                &v2,
            ),
        ],
    );
    let preview = manager.preview_repository(url).unwrap();
    assert_eq!(preview["name"], "Test Repo");
    assert_eq!(preview["extensions"], 1);
    assert!(
        manager
            .add_repository(url, "ed25519:AAAA", None, true)
            .is_err()
    );
    manager.add_repository(url, &public, None, true).unwrap();

    let refreshed = manager.refresh_repositories(None).unwrap();
    assert_eq!(refreshed[0]["entries"][0]["status"], "available");
    let info = manager
        .install_from_repository(url, "dev.test.r", false)
        .unwrap();
    assert_eq!(info["version"], "1.1.0");
    assert_eq!(info["source"]["kind"], "repository");
    assert_eq!(
        manager.refresh_repositories(Some(url)).unwrap()[0]["entries"][0]["status"],
        "installed"
    );

    // A file install of the same bytes is shown as verified by the repository.
    let inspected = manager.inspect(&Package::from_bytes(v2).unwrap());
    assert_eq!(inspected["verifiedBy"], "Test Repo");
    assert_eq!(inspected["isReinstall"], true);
    let older = manager.inspect(&Package::from_bytes(v1).unwrap());
    assert_eq!(older["verifiedBy"], "Test Repo");
    assert_eq!(older["isDowngrade"], true);
    let unlisted = package("dev.test.r", "1.2.0", &["lyrics"], LYRICS_JS);
    let unlisted = manager.inspect(&Package::from_bytes(unlisted).unwrap());
    assert_eq!(unlisted["verifiedBy"], Value::Null);
    assert_eq!(unlisted["isUpdate"], true);

    manager.remove_repository(url).unwrap();
    assert!(manager.repositories().is_empty());
}

#[test]
fn a_changed_repository_key_blocks_installs() {
    let dir = temp_dir("rekey");
    let (secret, public) = crate::signing::generate().unwrap();
    let (other_secret, other_public) = crate::signing::generate().unwrap();
    let bytes = package("dev.test.r", "1.0.0", &["lyrics"], LYRICS_JS);
    let url = "https://repo.example.org/index.json";
    let index = crate::repository::tests::signed_index(
        &other_secret,
        &other_public,
        &[("dev.test.r", "1.0.0", &bytes)],
    );
    let _ = secret;
    let manager = manager(
        &dir,
        vec![Fixture {
            method: "GET".into(),
            url: url.into(),
            status: 200,
            headers: Default::default(),
            body: Some(index),
            body_json: None,
            body_base64: None,
        }],
    );
    // Restored from a backup with the old key, without the network.
    manager
        .add_repository(url, &public, Some("Old"), false)
        .unwrap();
    let refreshed = manager.refresh_repositories(None).unwrap();
    assert!(
        refreshed[0]["error"]
            .as_str()
            .unwrap()
            .contains("key changed")
    );
    assert_eq!(refreshed[0]["repository"]["keyChanged"], true);
    assert!(
        manager
            .install_from_repository(url, "dev.test.r", false)
            .is_err()
    );
}

#[test]
fn folder_installs_need_developer_mode() {
    let dir = temp_dir("folder");
    let source = temp_dir("folder-src");
    std::fs::create_dir_all(&source.0).unwrap();
    std::fs::write(
        source.0.join("manifest.json"),
        manifest("dev.test.f", "0.1.0", &["lyrics"], json!({})),
    )
    .unwrap();
    std::fs::write(source.0.join("index.js"), LYRICS_JS).unwrap();
    let manager = manager(&dir, Vec::new());
    assert!(manager.install_folder(&source.0).is_err());
    manager.set_developer_mode(true);
    assert_eq!(
        manager.install_folder(&source.0).unwrap()["source"]["kind"],
        "folder"
    );
}
