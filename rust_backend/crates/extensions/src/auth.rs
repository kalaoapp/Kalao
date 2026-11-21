//! Login flows (`kalao.auth`): the extension asks for a browser page, the app
//! opens it, and the site redirects to `kalao://ext/<id>/<callbackPath>`,
//! which the app hands back here to wake `waitForCallback`.

use serde_json::{Map, Value, json};
use std::collections::{HashMap, VecDeque};
use std::sync::{Condvar, LazyLock, Mutex, PoisonError};
use std::time::{Duration, Instant};

pub const SCHEME: &str = "kalao";
/// A callback nobody waits for is kept this long.
const CALLBACK_TTL: Duration = Duration::from_secs(120);

#[derive(Default)]
struct State {
    /// Pages to open, in order: (extension id, URL).
    browser: VecDeque<(String, String)>,
    /// The latest callback per extension and when it arrived.
    callbacks: HashMap<String, (String, Instant)>,
}

static STATE: LazyLock<(Mutex<State>, Condvar)> =
    LazyLock::new(|| (Mutex::new(State::default()), Condvar::new()));

fn state() -> std::sync::MutexGuard<'static, State> {
    STATE.0.lock().unwrap_or_else(PoisonError::into_inner)
}

pub fn callback_url(extension_id: &str, path: &str) -> String {
    format!("{SCHEME}://ext/{extension_id}/{path}")
}

/// Queues a page for the app to open. A previous callback is discarded so
/// `waitForCallback` sees only the answer to this request.
pub fn request_browser(extension_id: &str, url: &str) {
    let mut state = state();
    state.callbacks.remove(extension_id);
    state
        .browser
        .push_back((extension_id.to_owned(), url.to_owned()));
}

/// The next page to open, for the app to poll while an action runs.
pub fn take_browser_request() -> Option<(String, String)> {
    state().browser.pop_front()
}

/// Delivers a `kalao://ext/<id>/<path>?…` URL. Returns the extension id, or
/// an error for a URL that is not an extension callback.
pub fn deliver_callback(
    url: &str,
    expected_path: impl Fn(&str) -> Option<String>,
) -> Result<String, String> {
    let rest = url
        .strip_prefix(&format!("{SCHEME}://ext/"))
        .ok_or_else(|| "not an extension callback URL".to_owned())?;
    let path_part = rest.split(['?', '#']).next().unwrap_or_default();
    let (id, path) = path_part
        .split_once('/')
        .ok_or_else(|| "callback URL has no path".to_owned())?;
    match expected_path(id) {
        Some(expected) if expected == path => {}
        Some(_) => return Err(format!("unexpected callback path for {id}")),
        None => return Err(format!("{id} does not accept login callbacks")),
    }
    let mut state = state();
    state
        .callbacks
        .insert(id.to_owned(), (url.to_owned(), Instant::now()));
    drop(state);
    STATE.1.notify_all();
    Ok(id.to_owned())
}

/// Blocks until a callback for `extension_id` arrives or `deadline` passes;
/// returns `{url, query}`.
pub fn wait_for_callback(extension_id: &str, deadline: Instant) -> Result<Value, String> {
    let mut state = state();
    loop {
        if let Some((url, at)) = state.callbacks.remove(extension_id)
            && at.elapsed() <= CALLBACK_TTL
        {
            return Ok(json!({ "url": url, "query": query_of(&url) }));
        }
        let now = Instant::now();
        if now >= deadline {
            return Err("timed out waiting for the login callback".into());
        }
        state = STATE
            .1
            .wait_timeout(state, deadline - now)
            .unwrap_or_else(PoisonError::into_inner)
            .0;
    }
}

fn query_of(url: &str) -> Value {
    let query = url
        .split_once('?')
        .map(|(_, query)| query.split('#').next().unwrap_or_default())
        .unwrap_or_default();
    let mut map = Map::new();
    for (key, values) in kalao_network::query::parse(query) {
        let key = String::from_utf8_lossy(&key).into_owned();
        if let Some(value) = values.first() {
            map.insert(
                key,
                Value::String(String::from_utf8_lossy(value).into_owned()),
            );
        }
    }
    Value::Object(map)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_callback_wakes_the_waiting_extension() {
        let id = "dev.test.auth";
        request_browser(id, "https://example.org/login");
        assert!(
            std::iter::from_fn(take_browser_request)
                .any(|(ext, url)| ext == id && url == "https://example.org/login")
        );
        let waiter = std::thread::spawn(move || {
            wait_for_callback(id, Instant::now() + Duration::from_secs(5))
        });
        std::thread::sleep(Duration::from_millis(50));
        let expected = |ext: &str| (ext == id).then(|| "callback".to_owned());
        assert!(deliver_callback("kalao://ext/dev.test.auth/other", expected).is_err());
        assert!(deliver_callback("https://ext/dev.test.auth/callback", expected).is_err());
        assert_eq!(
            deliver_callback(
                "kalao://ext/dev.test.auth/callback?code=abc%20d&state=1",
                expected
            ),
            Ok(id.to_owned())
        );
        let reply = waiter.join().unwrap().unwrap();
        assert_eq!(reply["query"]["code"], "abc d");
    }

    #[test]
    fn waiting_times_out() {
        assert!(
            wait_for_callback("dev.test.none", Instant::now() + Duration::from_millis(20)).is_err()
        );
    }
}
