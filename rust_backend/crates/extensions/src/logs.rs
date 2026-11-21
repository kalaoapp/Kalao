// Redaction patterns derived from Mornye (https://github.com/mornyeapp/Mornye),
// Copyright 2026 zarzet, LGPL-3.0-only. Modified for Kalao.
//! Each extension's debug log (`kalao.log.*`, script errors), with secrets
//! redacted, and a hook that copies entries into the app's log buffer.

use regex::Regex;
use serde::Serialize;
use std::borrow::Cow;
use std::collections::VecDeque;
use std::sync::{LazyLock, Mutex, OnceLock, PoisonError};

const CAPACITY: usize = 300;
const MAX_MESSAGE: usize = 2000;

static PATTERNS: LazyLock<Vec<(Regex, &'static str)>> = LazyLock::new(|| {
    [
        (
            r"(?i)(?-u:\b)Authorization(?-u:\b)[\t\n\f\r ]*[:=][\t\n\f\r ]*Bearer[\t\n\f\r ]+[A-Za-z0-9._~+/\-]+=*",
            "Authorization: Bearer [REDACTED]",
        ),
        (
            r#"(?i)("?(?:access[_\t\n\f\r -]?token|refresh[_\t\n\f\r -]?token|id[_\t\n\f\r -]?token|client[_\t\n\f\r -]?secret|authorization|password|api[_\t\n\f\r -]?key|session[_\t\n\f\r -]?secret|cookie|set-cookie)"?)([\t\n\f\r ]*[:=][\t\n\f\r ]*)("(?:\\.|[^"\\])*"|[^\t\n\f\r ,;}\]]+)"#,
            "${1}${2}[REDACTED]",
        ),
        (
            r"(?i)([?&](?:access_token|refresh_token|id_token|token|client_secret|api_key|apikey|password|code|sig|signature|key)=)[^&\t\n\f\r ]+",
            "${1}[REDACTED]",
        ),
        (
            r"(?i)(?-u:\b)Bearer[\t\n\f\r ]+[A-Za-z0-9._~+/\-]+=*",
            "Bearer [REDACTED]",
        ),
    ]
    .into_iter()
    .filter_map(|(pattern, replacement)| Regex::new(pattern).ok().map(|re| (re, replacement)))
    .collect()
});

/// Removes token-like values and the given secret values from `text`.
pub fn redact(text: &str, secrets: &[String]) -> String {
    let mut text = text.to_owned();
    for secret in secrets.iter().filter(|secret| secret.len() >= 4) {
        if text.contains(secret.as_str()) {
            text = text.replace(secret.as_str(), "[REDACTED]");
        }
    }
    for (pattern, replacement) in PATTERNS.iter() {
        if let Cow::Owned(replaced) = pattern.replace_all(&text, *replacement) {
            text = replaced;
        }
    }
    text
}

#[derive(Clone, Debug, Serialize)]
pub struct LogEntry {
    pub timestamp: String,
    pub level: String,
    pub message: String,
}

/// Copies extension log lines into the host's diagnostics (`kalao-mobile`
/// forwards them to its log buffer). Messages are already redacted.
pub type LogHook = fn(level: &str, tag: &str, message: &str);

static HOOK: OnceLock<LogHook> = OnceLock::new();

pub fn set_log_hook(hook: LogHook) {
    let _ = HOOK.set(hook);
}

#[derive(Default)]
pub struct ExtensionLog {
    entries: Mutex<VecDeque<LogEntry>>,
}

impl ExtensionLog {
    pub fn push(&self, extension_id: &str, level: &str, message: &str, secrets: &[String]) {
        let mut message = redact(message, secrets);
        if message.len() > MAX_MESSAGE {
            let mut end = MAX_MESSAGE;
            while !message.is_char_boundary(end) {
                end -= 1;
            }
            message.truncate(end);
            message.push('…');
        }
        if let Some(hook) = HOOK.get() {
            hook(level, &format!("Ext:{extension_id}"), &message);
        }
        let mut entries = self.entries.lock().unwrap_or_else(PoisonError::into_inner);
        if entries.len() == CAPACITY {
            entries.pop_front();
        }
        entries.push_back(LogEntry {
            timestamp: chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
            level: level.to_owned(),
            message,
        });
    }

    pub fn entries(&self) -> Vec<LogEntry> {
        self.entries
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .cloned()
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn redacts_tokens_and_secret_values() {
        let text = "GET https://a.org/x?token=abc123&q=1 Authorization: Bearer xyz.1 my-own-secret password=hunter2";
        let redacted = redact(text, &["my-own-secret".into()]);
        assert!(!redacted.contains("abc123"));
        assert!(!redacted.contains("xyz.1"));
        assert!(!redacted.contains("my-own-secret"));
        assert!(!redacted.contains("hunter2"));
        assert!(redacted.contains("q=1"));
    }

    #[test]
    fn keeps_the_newest_entries() {
        let log = ExtensionLog::default();
        for i in 0..CAPACITY + 5 {
            log.push("a.b", "info", &format!("line {i}"), &[]);
        }
        let entries = log.entries();
        assert_eq!(entries.len(), CAPACITY);
        assert_eq!(entries[0].message, "line 5");
    }
}
