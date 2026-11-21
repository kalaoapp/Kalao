//! What capability functions must return (EXTENSIONS.md §1), and how
//! results from several extensions are ranked. Invalid items are dropped
//! and reported; they never reach the app.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

pub const MAX_ITEMS: usize = 50;
const MAX_LYRICS_BYTES: usize = 1 << 20;
const MAX_TEXT: usize = 512;

/// What the app asks for: `{ title, artist, album?, durationMs?, isrc?, language? }`.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Query {
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub artist: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub album: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub isrc: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub language: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LyricsFormat {
    Plain,
    Lrc,
    Elrc,
    Ttml,
}

impl LyricsFormat {
    fn bonus(self) -> f64 {
        match self {
            Self::Elrc | Self::Ttml => 0.3,
            Self::Lrc => 0.2,
            Self::Plain => 0.0,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LyricsCandidate {
    pub id: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub artist: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub album: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<u64>,
    pub format: LyricsFormat,
    /// Absent when the extension fetches the text with `getLyrics(id)`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub body: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub language: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Track {
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub artists: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub album: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub isrc: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub language: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artwork_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub year: Option<u32>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Image {
    pub url: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub width: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub height: Option<u32>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct AudioSource {
    /// `original` (the default), `instrumental` or `vocals`.
    #[serde(default = "original")]
    pub kind: String,
    pub url: String,
    #[serde(default)]
    pub headers: std::collections::BTreeMap<String, String>,
    /// File extension hint for the decoder (`mp3`, `m4a`, `flac`, …).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub format: Option<String>,
}

fn original() -> String {
    "original".into()
}

/// Items of an array result; `{items: [...]}` is accepted too.
fn items(value: &Value) -> Result<&Vec<Value>, String> {
    match value {
        Value::Array(items) => Ok(items),
        Value::Object(map) => match map.get("items") {
            Some(Value::Array(items)) => Ok(items),
            _ => Err("expected an array".into()),
        },
        Value::Null => Err("returned nothing".into()),
        _ => Err("expected an array".into()),
    }
}

fn short(text: &str) -> String {
    text.chars()
        .take(MAX_TEXT)
        .collect::<String>()
        .trim()
        .to_owned()
}

/// Numbers may arrive as floats from JavaScript.
fn normalise_numbers(value: &mut Value, fields: &[&str]) {
    for field in fields {
        if let Some(number) = value.get(*field).and_then(Value::as_f64) {
            value[*field] = if number.is_finite() && number >= 0.0 {
                json!(number.round() as u64)
            } else {
                Value::Null
            };
        }
    }
}

/// Valid candidates and the reasons others were dropped.
pub fn lyrics_candidates(value: &Value) -> Result<(Vec<LyricsCandidate>, Vec<String>), String> {
    let mut valid = Vec::new();
    let mut dropped = Vec::new();
    for (index, item) in items(value)?.iter().take(MAX_ITEMS).enumerate() {
        let mut item = item.clone();
        normalise_numbers(&mut item, &["durationMs"]);
        if let Some(id) = item.get("id").and_then(Value::as_i64) {
            item["id"] = json!(id.to_string());
        }
        match serde_json::from_value::<LyricsCandidate>(item) {
            Ok(mut candidate) if !candidate.id.is_empty() => {
                if candidate
                    .body
                    .as_ref()
                    .is_some_and(|body| body.len() > MAX_LYRICS_BYTES)
                {
                    dropped.push(format!("item {index}: lyrics larger than 1 MiB"));
                    continue;
                }
                if candidate
                    .body
                    .as_ref()
                    .is_some_and(|body| body.trim().is_empty())
                {
                    candidate.body = None;
                }
                candidate.title = short(&candidate.title);
                candidate.artist = short(&candidate.artist);
                valid.push(candidate);
            }
            Ok(_) => dropped.push(format!("item {index}: id is empty")),
            Err(error) => dropped.push(format!("item {index}: {error}")),
        }
    }
    Ok((valid, dropped))
}

pub fn lyrics_body(value: &Value) -> Result<LyricsCandidate, String> {
    let (mut candidates, dropped) = lyrics_candidates(&Value::Array(vec![value.clone()]))?;
    match candidates.pop() {
        Some(candidate) if candidate.body.is_some() => Ok(candidate),
        Some(_) => Err("getLyrics returned no body".into()),
        None => Err(dropped.join("; ")),
    }
}

fn track(item: &Value) -> Result<Track, String> {
    let mut item = item.clone();
    normalise_numbers(&mut item, &["durationMs", "year"]);
    if let Some(id) = item.get("id").and_then(Value::as_i64) {
        item["id"] = json!(id.to_string());
    }
    // `artist: "A"` is accepted for `artists: ["A"]`.
    if item.get("artists").is_none()
        && let Some(artist) = item.get("artist").and_then(Value::as_str)
    {
        item["artists"] = json!([artist]);
    }
    let mut track: Track = serde_json::from_value(item).map_err(|error| error.to_string())?;
    if track.id.is_empty() || track.title.trim().is_empty() {
        return Err("id and title are required".into());
    }
    track.title = short(&track.title);
    track.artists = track
        .artists
        .iter()
        .map(|a| short(a))
        .filter(|a| !a.is_empty())
        .collect();
    if let Some(url) = &track.artwork_url
        && !url.starts_with("https://")
    {
        track.artwork_url = None;
    }
    Ok(track)
}

pub fn tracks(value: &Value) -> Result<(Vec<Track>, Vec<String>), String> {
    let mut valid = Vec::new();
    let mut dropped = Vec::new();
    for (index, item) in items(value)?.iter().take(MAX_ITEMS).enumerate() {
        match track(item) {
            Ok(track) => valid.push(track),
            Err(error) => dropped.push(format!("item {index}: {error}")),
        }
    }
    Ok((valid, dropped))
}

pub fn single_track(value: &Value) -> Result<Track, String> {
    track(value)
}

pub fn images(value: &Value) -> Result<Vec<Image>, String> {
    let list = match value {
        Value::String(url) => vec![json!({ "url": url })],
        other => items(other)?.clone(),
    };
    Ok(list
        .into_iter()
        .take(MAX_ITEMS)
        .filter_map(|mut item| {
            normalise_numbers(&mut item, &["width", "height"]);
            serde_json::from_value::<Image>(item).ok()
        })
        .filter(|image| image.url.starts_with("https://"))
        .collect())
}

/// `resolveAudio` returns `{sources: [...]}`, a list of sources, or a URL.
pub fn audio_sources(value: &Value) -> Result<Vec<AudioSource>, String> {
    let list = match value {
        Value::String(url) => vec![json!({ "url": url })],
        Value::Object(map) if map.contains_key("sources") => items(&map["sources"])?.clone(),
        Value::Object(map) if map.contains_key("url") => vec![value.clone()],
        other => items(other)?.clone(),
    };
    let mut sources: Vec<AudioSource> = Vec::new();
    for item in list.into_iter().take(3) {
        let source: AudioSource =
            serde_json::from_value(item).map_err(|error| error.to_string())?;
        if !matches!(source.kind.as_str(), "original" | "instrumental" | "vocals") {
            return Err(format!("unknown source kind '{}'", source.kind));
        }
        if !(source.url.starts_with("https://") || source.url.starts_with("http://")) {
            return Err("audio URLs must be http(s)".into());
        }
        if sources.iter().any(|other| other.kind == source.kind) {
            return Err(format!("two {} sources", source.kind));
        }
        sources.push(source);
    }
    if sources.is_empty() {
        return Err("no audio sources".into());
    }
    Ok(sources)
}

/// Lowercase letters and digits of every script, single spaces; brackets
/// and what follows "feat." are dropped.
pub fn match_key(text: &str) -> String {
    let lowered = text.to_lowercase();
    let mut cut = lowered.as_str();
    for marker in [" feat.", " ft.", " (feat", " (ft", "（"] {
        if let Some(index) = cut.find(marker) {
            cut = &cut[..index];
        }
    }
    let mut out = String::with_capacity(cut.len());
    let mut space = false;
    for ch in cut.chars() {
        if ch.is_alphanumeric() {
            if space && !out.is_empty() {
                out.push(' ');
            }
            space = false;
            out.push(ch);
        } else {
            space = true;
        }
    }
    out
}

fn similarity(first: &str, second: &str) -> f64 {
    let (first, second) = (match_key(first), match_key(second));
    if first.is_empty() || second.is_empty() {
        return 0.0;
    }
    if first == second {
        return 1.0;
    }
    if first.contains(&second) || second.contains(&first) {
        return 0.85;
    }
    kalao_core::matching::compare_strings(&first, &second, &|| Ok(())).unwrap_or(0.0)
}

/// Match quality (title, artist, duration within ±3 s), 0–1.
pub fn match_score(query: &Query, title: &str, artist: &str, duration_ms: Option<u64>) -> f64 {
    let title_score = similarity(&query.title, title);
    let artist_score = if query.artist.trim().is_empty() || artist.trim().is_empty() {
        0.5
    } else {
        similarity(&query.artist, artist)
    };
    let duration_score = match (query.duration_ms, duration_ms) {
        (Some(wanted), Some(found)) => {
            let difference = wanted.abs_diff(found);
            if difference <= 3000 {
                1.0
            } else if difference <= 10_000 {
                0.4
            } else {
                0.0
            }
        }
        _ => 0.5,
    };
    0.55 * title_score + 0.3 * artist_score + 0.15 * duration_score
}

/// Match quality plus the format bonus (`elrc` > `lrc` > `plain`), 0–1.3.
pub fn lyrics_score(query: &Query, candidate: &LyricsCandidate) -> f64 {
    match_score(
        query,
        &candidate.title,
        &candidate.artist,
        candidate.duration_ms,
    ) + candidate.format.bonus()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn query() -> Query {
        Query {
            title: "月亮代表我的心".into(),
            artist: "鄧麗君".into(),
            duration_ms: Some(210_000),
            ..Query::default()
        }
    }

    #[test]
    fn validates_lyrics_and_drops_bad_items() {
        let (valid, dropped) = lyrics_candidates(&json!([
            { "id": 7, "title": "A", "artist": "B", "format": "lrc", "body": "[00:01.00]x", "durationMs": 1000.4 },
            { "id": "x", "format": "karaoke" },
            { "title": "no id", "format": "plain" },
            "nonsense"
        ]))
        .unwrap();
        assert_eq!(valid.len(), 1);
        assert_eq!(valid[0].id, "7");
        assert_eq!(valid[0].duration_ms, Some(1000));
        assert_eq!(dropped.len(), 3);
        assert!(lyrics_candidates(&json!("oops")).is_err());
    }

    #[test]
    fn synced_and_closer_matches_rank_first() {
        let candidate = |title: &str, format: LyricsFormat, duration: u64| LyricsCandidate {
            id: "1".into(),
            title: title.into(),
            artist: "鄧麗君".into(),
            album: None,
            duration_ms: Some(duration),
            format,
            body: Some("x".into()),
            language: None,
        };
        let q = query();
        let elrc = lyrics_score(
            &q,
            &candidate("月亮代表我的心", LyricsFormat::Elrc, 211_000),
        );
        let lrc = lyrics_score(&q, &candidate("月亮代表我的心", LyricsFormat::Lrc, 211_000));
        let plain = lyrics_score(
            &q,
            &candidate("月亮代表我的心", LyricsFormat::Plain, 211_000),
        );
        let wrong = lyrics_score(&q, &candidate("甜蜜蜜", LyricsFormat::Elrc, 180_000));
        assert!(elrc > lrc && lrc > plain && plain > wrong);
        assert_eq!(match_key("Hello, World (feat. X)"), "hello world");
    }

    #[test]
    fn validates_tracks_images_and_audio() {
        let (tracks, dropped) = tracks(&json!({ "items": [
            { "id": 1, "title": "Song", "artist": "Singer", "artworkUrl": "http://insecure" },
            { "id": "2" }
        ]}))
        .unwrap();
        assert_eq!(tracks[0].artists, ["Singer"]);
        assert_eq!(tracks[0].artwork_url, None);
        assert_eq!(dropped.len(), 1);
        assert_eq!(images(&json!("https://img.org/a.jpg")).unwrap().len(), 1);
        assert!(
            images(&json!([{ "url": "http://img.org/a.jpg" }]))
                .unwrap()
                .is_empty()
        );
        let audio = audio_sources(&json!({ "sources": [
            { "url": "https://cdn.org/a.mp3" },
            { "kind": "instrumental", "url": "https://cdn.org/b.mp3", "headers": { "Referer": "x" } }
        ]}))
        .unwrap();
        assert_eq!(audio[0].kind, "original");
        assert!(audio_sources(&json!([{ "url": "file:///etc/passwd" }])).is_err());
        assert!(
            audio_sources(&json!([{ "url": "https://a.org/1" }, { "url": "https://a.org/2" }]))
                .is_err()
        );
    }
}
