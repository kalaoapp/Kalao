use super::*;
use crate::fetch::{Fixture, FixtureFetch};
use crate::logs::ExtensionLog;
use crate::package::tests::{manifest_json, zip};
use crate::storage::{Settings, Storage};
use serde_json::{Map, Value, json};

fn package_with(files: &[(&str, &str)]) -> Package {
    let manifest = manifest_json("dev.test.vm", "1.0.0", &["lyrics"]);
    let mut entries: Vec<(&str, &[u8])> = vec![("manifest.json", manifest.as_bytes())];
    entries.extend(files.iter().map(|(name, text)| (*name, text.as_bytes())));
    Package::from_bytes(zip(&entries)).expect("package")
}

fn host_for(
    package: &Package,
    fixtures: Vec<Fixture>,
) -> (HostContext, Arc<FixtureFetch>, Arc<ExtensionLog>) {
    let fetch = Arc::new(FixtureFetch::new(fixtures, &package.manifest.network.hosts));
    let log = Arc::new(ExtensionLog::default());
    let manifest = package.manifest.clone();
    let mut values = Map::new();
    values.insert("token".into(), json!("tok-123456"));
    (
        HostContext {
            extension_id: manifest.id.clone(),
            manifest: manifest.clone(),
            settings: Arc::new(Settings::new(manifest, values)),
            storage: Arc::new(Storage::new(None)),
            fetch: fetch.clone(),
            log: log.clone(),
            auth_url_check: Arc::new(|url| {
                if url.starts_with("https://") {
                    Ok(())
                } else {
                    Err("only https".into())
                }
            }),
        },
        fetch,
        log,
    )
}

fn start(js: &str) -> Runtime {
    let package = package_with(&[("index.js", js)]);
    let (host, _, _) = host_for(&package, Vec::new());
    Runtime::start(&package, host, Limits::default()).expect("start")
}

fn call(runtime: &Runtime, function: &str, argument: Value) -> Result<Value, Error> {
    runtime
        .call(function, &argument.to_string(), Duration::from_secs(5))
        .map(|text| serde_json::from_str(&text).unwrap())
}

#[test]
fn exports_sync_and_async_functions() {
    let runtime = start(
        "export function add(x) { return x.a + x.b; }
         export async function later(x) { await null; return { got: x }; }
         export const notAFunction = 1;",
    );
    assert_eq!(runtime.exports(), ["add", "later"]);
    assert_eq!(
        call(&runtime, "add", json!({"a": 2, "b": 3})).unwrap(),
        json!(5)
    );
    assert_eq!(
        call(&runtime, "later", json!("q")).unwrap(),
        json!({"got": "q"})
    );
    assert!(matches!(
        call(&runtime, "missing", json!(null)),
        Err(Error::MissingFunction(_))
    ));
    assert_eq!(call(&runtime, "add", json!(null)).ok(), None);
}

#[test]
fn relative_imports_stay_inside_the_package() {
    let package = package_with(&[
        (
            "index.js",
            "import { twice } from './lib/math.js'; export function run(x) { return twice(x); }",
        ),
        (
            "lib/math.js",
            "import { one } from '../one.js'; export const twice = (x) => x * 2 * one;",
        ),
        ("one.js", "export const one = 1;"),
    ]);
    let (host, _, _) = host_for(&package, Vec::new());
    let runtime = Runtime::start(&package, host, Limits::default()).unwrap();
    assert_eq!(call(&runtime, "run", json!(21)).unwrap(), json!(42));

    for import in [
        "import 'os';",
        "import '../../escape.js';",
        "import './missing.js';",
    ] {
        let package = package_with(&[("index.js", import)]);
        let (host, _, _) = host_for(&package, Vec::new());
        assert!(
            Runtime::start(&package, host, Limits::default()).is_err(),
            "{import}"
        );
    }
}

#[test]
fn script_errors_are_reported_and_the_vm_keeps_working() {
    let runtime = start(
        "export function boom() { throw new Error('bad input'); }
         export async function reject() { throw new TypeError('nope'); }
         export function ok() { return 'fine'; }",
    );
    let error = call(&runtime, "boom", json!(null)).unwrap_err().to_string();
    assert!(error.contains("bad input"), "{error}");
    assert!(
        call(&runtime, "reject", json!(null))
            .unwrap_err()
            .to_string()
            .contains("nope")
    );
    assert_eq!(call(&runtime, "ok", json!(null)).unwrap(), json!("fine"));
    assert!(!runtime.is_retired());
}

#[test]
fn a_runaway_loop_times_out_and_retires_the_vm() {
    let runtime =
        start("export function spin() { for (;;) {} } export function ok() { return 1; }");
    let started = Instant::now();
    let result = runtime.call("spin", "null", Duration::from_millis(300));
    assert!(matches!(result, Err(Error::Timeout)), "{result:?}");
    assert!(started.elapsed() < Duration::from_secs(3));
    assert!(runtime.is_retired());
    assert!(runtime.call("ok", "null", Duration::from_secs(1)).is_err());
}

#[test]
fn memory_is_capped() {
    let package = package_with(&[(
        "index.js",
        "export function hog() { const a = []; for (;;) a.push('x'.repeat(1 << 16) + a.length); }",
    )]);
    let (host, _, _) = host_for(&package, Vec::new());
    let runtime = Runtime::start(
        &package,
        host,
        Limits {
            memory_bytes: 16 << 20,
            ..Limits::default()
        },
    )
    .unwrap();
    let error = runtime
        .call("hog", "null", Duration::from_secs(10))
        .unwrap_err();
    assert!(error.to_string().contains("out of memory"), "{error}");
    assert!(runtime.is_retired());
}

#[test]
fn code_from_strings_is_refused() {
    let runtime = start(
        "export function tryEval() { return typeof globalThis.eval; }
         export function tryFunction() { try { return new Function('return 1')(); } catch (e) { return 'refused'; } }
         export function tryCtor() { try { return (function(){}).constructor('return 1')(); } catch (e) { return 'refused'; } }
         export function tryAsyncCtor() { try { (async function(){}).constructor('return 1'); return 'ran'; } catch (e) { return 'refused'; } }",
    );
    assert_eq!(
        call(&runtime, "tryEval", json!(null)).unwrap(),
        json!("undefined")
    );
    assert_eq!(
        call(&runtime, "tryFunction", json!(null)).unwrap(),
        json!("refused")
    );
    assert_eq!(
        call(&runtime, "tryCtor", json!(null)).unwrap(),
        json!("refused")
    );
    assert_eq!(
        call(&runtime, "tryAsyncCtor", json!(null)).unwrap(),
        json!("refused")
    );
}

#[test]
fn fetch_uses_fixtures_and_the_allowlist() {
    let package = package_with(&[(
        "index.js",
        "export async function search(q) {
           const res = await kalao.fetch('https://api.example.org/search?' + kalao.url.params({ q: q, empty: null }), {
             headers: { Authorization: 'Bearer ' + kalao.settings.get('token') } });
           return { status: res.status, ok: res.ok, items: res.json().items, type: res.header('Content-Type'), first: res.bytes()[0] };
         }
         export async function outside() { return (await kalao.fetch('https://evil.example.com/')).status; }
         export async function insecure() { return (await kalao.fetch('http://api.example.org/')).status; }",
    )]);
    let (host, fetch, log) = host_for(
        &package,
        vec![Fixture {
            method: "GET".into(),
            url: "https://api.example.org/search?q=moon%20song".into(),
            status: 200,
            headers: [("Content-Type".to_owned(), "application/json".to_owned())].into(),
            body: None,
            body_json: Some(json!({ "items": [1, 2] })),
            body_base64: None,
        }],
    );
    let runtime = Runtime::start(&package, host, Limits::default()).unwrap();
    assert_eq!(
        call(&runtime, "search", json!("moon song")).unwrap(),
        json!({ "status": 200, "ok": true, "items": [1, 2], "type": "application/json", "first": 123 })
    );
    let requests = fetch.requests.lock().unwrap().clone();
    assert_eq!(requests[0].headers["Authorization"], "Bearer tok-123456");
    for function in ["outside", "insecure"] {
        let error = call(&runtime, function, json!(null))
            .unwrap_err()
            .to_string();
        assert!(
            error.contains("network access denied"),
            "{function}: {error}"
        );
    }
    // The secret never reaches the debug log.
    assert!(
        log.entries()
            .iter()
            .all(|entry| !entry.message.contains("tok-123456"))
    );
    assert!(
        log.entries()
            .iter()
            .any(|entry| entry.message.contains("fetch GET"))
    );
}

#[test]
fn settings_storage_html_crypto_and_logs() {
    let runtime = start(
        "export function run() {
           kalao.storage.set('count', (kalao.storage.get('count') || 0) + 1);
           kalao.settings.set('region', 'tw');
           let refused = false;
           try { kalao.settings.set('undeclared', 1); } catch (e) { refused = true; }
           const doc = kalao.html.parse('<ul><li class=a data-id=1>One</li><li class=a>Two <b>B</b></li></ul>');
           const items = doc.select('li.a');
           kalao.log.info('ran with', kalao.settings.get('token'));
           console.log('console works');
           return {
             count: kalao.storage.get('count'),
             region: kalao.settings.get('region'),
             refused,
             texts: items.map((li) => li.text()),
             id: items[0].attr('data-id'),
             nested: items[1].selectFirst('b').text(),
             sha256: kalao.crypto.sha256('abc'),
             hmac: kalao.crypto.hmac('sha1', 'k', 'v'),
             b64: kalao.crypto.base64.decode(kalao.crypto.base64.encode('é')),
             frozen: Object.isFrozen(kalao) && Object.isFrozen(kalao.crypto.aes),
           };
         }",
    );
    let result = call(&runtime, "run", json!(null)).unwrap();
    assert_eq!(result["count"], 1);
    assert_eq!(result["region"], "tw");
    assert_eq!(result["refused"], true);
    assert_eq!(result["texts"], json!(["One", "Two B"]));
    assert_eq!(result["id"], "1");
    assert_eq!(result["nested"], "B");
    assert_eq!(
        result["sha256"],
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    );
    assert_eq!(result["b64"], "é");
    assert_eq!(result["frozen"], true);
    assert_eq!(call(&runtime, "run", json!(null)).unwrap()["count"], 2);
}

#[test]
fn login_flow_waits_for_the_callback() {
    let runtime = start(
        "export async function startLogin() {
           await kalao.auth.openBrowser('https://example.org/oauth?redirect=' + encodeURIComponent(kalao.auth.callbackUrl()));
           const { query } = await kalao.auth.waitForCallback({ timeoutMs: 4000 });
           kalao.settings.set('token', query.code);
           return query.code;
         }
         export async function badPage() { await kalao.auth.openBrowser('http://example.org'); }",
    );
    std::thread::scope(|scope| {
        let handle = scope.spawn(|| call(&runtime, "startLogin", json!(null)));
        let opened = loop {
            if let Some(request) = crate::auth::take_browser_request()
                && request.0 == "dev.test.vm"
            {
                break request.1;
            }
            std::thread::sleep(Duration::from_millis(10));
        };
        assert!(opened.contains("kalao%3A%2F%2Fext%2Fdev.test.vm%2Fcallback"));
        crate::auth::deliver_callback("kalao://ext/dev.test.vm/callback?code=xyz", |_| {
            Some("callback".into())
        })
        .unwrap();
        assert_eq!(handle.join().unwrap().unwrap(), json!("xyz"));
    });
    assert!(call(&runtime, "badPage", json!(null)).is_err());
}

#[test]
fn a_promise_that_never_settles_is_an_error() {
    let runtime = start("export function wait() { return new Promise(() => {}); }");
    let error = call(&runtime, "wait", json!(null)).unwrap_err().to_string();
    assert!(error.contains("never settled"), "{error}");
}
