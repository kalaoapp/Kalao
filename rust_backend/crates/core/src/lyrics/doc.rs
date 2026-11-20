//! Kalao's lyric document (DATA_MODEL.md §1) from imported text: LRC (line
//! timing, several time tags per line, `[offset:]`), enhanced LRC (word tags
//! `<mm:ss.xx>`, voices `v1:`/`v2:`, backing rows `[bg:…]`), TTML (through
//! the Apple payload reader) or plain text (one line per row, blank rows are
//! section breaks). Section markers become `section` on the following line.
//! `export` writes LRC or enhanced LRC; enhanced LRC round-trips line and
//! word timing, sections, breaks and voices.

use super::{lrc, payloads};
use crate::sections;
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::sync::LazyLock;

static TIME_TAG: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]").expect("valid"));
static WORD_TAG: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>").expect("valid"));
static METADATA: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)^\[([a-z#][a-z0-9_-]*):(.*)\]$").expect("valid"));
static BACKING: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)^\[bg:(.*)\]$").expect("valid"));
static VOICE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?i)^v([1-9][0-9]*):\s*").expect("valid"));

/// 2 adds word timing, voices and translations to lines.
pub const DOC_VERSION: u32 = 2;

/// The voice of a backing-vocal line.
pub const BACKING_VOICE: &str = "bg";

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct DocWord {
    pub time_ms: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub end_ms: Option<i64>,
    pub text: String,
    /// UTF-16 offset of the word in its line's text (Dart string index), set
    /// by [`parse`].
    pub start: usize,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct DocLine {
    pub time_ms: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub end_ms: Option<i64>,
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub section: Option<String>,
    pub section_break_before: bool,
    /// Word timing, in text order; empty for line-timed lines.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub words: Vec<DocWord>,
    /// `v1`, `v2`, … for duets, `bg` for backing vocals.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub voice: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub translation: Option<String>,
}

impl DocLine {
    fn is_backing(&self) -> bool {
        self.voice.as_deref() == Some(BACKING_VOICE)
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct LyricDoc {
    pub version: u32,
    /// `plain`, `lrc`, `elrc` (word-timed) or `ttml`.
    pub format: String,
    pub timed: bool,
    pub offset_ms: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub artist: Option<String>,
    pub lines: Vec<DocLine>,
}

fn tag_ms(captures: &regex::Captures<'_>) -> i64 {
    let minutes: i64 = captures[1].parse().unwrap_or(0);
    let seconds: i64 = captures[2].parse().unwrap_or(0);
    let fraction = captures.get(3).map_or(0, |m| {
        let digits = m.as_str();
        let value: i64 = digits.parse().unwrap_or(0);
        match digits.len() {
            1 => value * 100,
            2 => value * 10,
            _ => value,
        }
    });
    minutes * 60_000 + seconds * 1000 + fraction
}

/// Parses `raw`. `format` is `"lrc"`, `"elrc"`, `"ttml"`, `"plain"` or `None`
/// to detect. Only TTML can fail (invalid XML).
pub fn parse(raw: &str, format: Option<&str>) -> Result<LyricDoc, String> {
    let raw = raw
        .trim_start_matches('\u{feff}')
        .replace("\r\n", "\n")
        .replace('\r', "\n");
    let mut doc = match format {
        Some("lrc" | "elrc") => parse_lrc(&raw),
        Some("plain") => parse_plain(&raw),
        Some("ttml") => parse_ttml(&raw)?,
        Some(other) => return Err(format!("unknown lyrics format {other}")),
        None if raw.trim_start().starts_with('<') && raw.contains("<tt") => parse_ttml(&raw)?,
        None => {
            let timed = raw.lines().any(|line| {
                TIME_TAG
                    .find(line.trim_start())
                    .is_some_and(|tag| tag.start() == 0)
            });
            if timed {
                parse_lrc(&raw)
            } else {
                parse_plain(&raw)
            }
        }
    };
    for line in &mut doc.lines {
        locate_words(line);
    }
    Ok(doc)
}

/// Finds each word in the line's text, in order, and records its UTF-16
/// offset; a word that is not there (or empty) is dropped.
fn locate_words(line: &mut DocLine) {
    let mut cursor = 0;
    let text = &line.text;
    line.words.retain_mut(|word| {
        if word.text.is_empty() {
            return false;
        }
        let Some(found) = text[cursor..].find(&word.text) else {
            return false;
        };
        let at = cursor + found;
        word.start = text[..at].encode_utf16().count();
        cursor = at + word.text.len();
        true
    });
}

fn parse_plain(raw: &str) -> LyricDoc {
    let rows: Vec<&str> = raw.split('\n').collect();
    let lines = sections::detect(&rows)
        .into_iter()
        .map(|line| DocLine {
            text: line.text,
            section: line.section.map(str::to_owned),
            section_break_before: line.section_break_before,
            ..DocLine::default()
        })
        .collect();
    LyricDoc {
        version: DOC_VERSION,
        format: "plain".into(),
        lines,
        ..LyricDoc::default()
    }
}

/// One timed row before section detection.
struct Row {
    time: i64,
    order: usize,
    text: String,
    words: Vec<DocWord>,
    end: Option<i64>,
    voice: Option<String>,
}

/// Splits a row body at its word tags. A word runs from the tag before it
/// (or `start`) to the tag after it; a tag that ends the row is the line end.
/// One word covering the whole text is the same as no word timing.
fn timed_text(body: &str, start: i64) -> (String, Vec<DocWord>, Option<i64>) {
    let mut text = String::new();
    let mut words = Vec::new();
    let mut tag = None;
    let mut end = None;
    let mut cursor = 0;
    for captures in WORD_TAG.captures_iter(body) {
        let whole = captures.get(0).expect("match");
        let chunk = &body[cursor..whole.start()];
        let time = tag_ms(&captures);
        text.push_str(chunk);
        if !chunk.trim().is_empty() {
            words.push(DocWord {
                time_ms: tag.unwrap_or(start),
                end_ms: Some(time),
                text: chunk.trim().to_owned(),
                ..DocWord::default()
            });
        }
        tag = Some(time);
        end = Some(time);
        cursor = whole.end();
    }
    let tail = &body[cursor..];
    text.push_str(tail);
    if !tail.trim().is_empty() {
        if let Some(time) = tag {
            words.push(DocWord {
                time_ms: time,
                end_ms: None,
                text: tail.trim().to_owned(),
                ..DocWord::default()
            });
        }
        end = None;
    }
    let text = text.trim().to_owned();
    if words.len() == 1 && words[0].text == text {
        words.clear();
    }
    (text, words, end)
}

fn parse_lrc(raw: &str) -> LyricDoc {
    let mut offset_ms = 0;
    let (mut title, mut artist) = (None, None);
    let mut rows: Vec<Row> = Vec::new();
    for (order, row) in raw.split('\n').enumerate() {
        let row = row.trim();
        if row.is_empty() {
            continue;
        }
        let mut rest = row;
        let mut times = Vec::new();
        while let Some(captures) = TIME_TAG.captures(rest) {
            let whole = captures.get(0).expect("match");
            if whole.start() != 0 {
                break;
            }
            times.push(tag_ms(&captures));
            rest = rest[whole.end()..].trim_start();
        }
        if times.is_empty() {
            if let Some(captures) = BACKING.captures(row) {
                // A backing row belongs to the row before it.
                let body = captures.get(1).map_or("", |m| m.as_str());
                let previous = rows.last().map_or(0, |row| row.time);
                let time = WORD_TAG.captures(body).map_or(previous, |tag| tag_ms(&tag));
                let (text, words, end) = timed_text(body, time);
                rows.push(Row {
                    time,
                    order,
                    text,
                    words,
                    end,
                    voice: Some(BACKING_VOICE.into()),
                });
            } else if let Some(captures) = METADATA.captures(row) {
                let value = captures[2].trim().to_owned();
                match captures[1].to_lowercase().as_str() {
                    "offset" => offset_ms = value.parse().unwrap_or(0),
                    "ti" if !value.is_empty() => title = Some(value),
                    "ar" if !value.is_empty() => artist = Some(value),
                    _ => {}
                }
            }
            continue;
        }
        let mut voice = None;
        if let Some(captures) = VOICE.captures(rest) {
            voice = Some(format!("v{}", &captures[1]));
            rest = &rest[captures.get(0).expect("match").end()..];
        }
        let (text, words, end) = timed_text(rest, times[0]);
        for time in &times {
            // A repeated row keeps its word timing relative to each start.
            let shift = time - times[0];
            rows.push(Row {
                time: *time,
                order,
                text: text.clone(),
                words: words
                    .iter()
                    .map(|word| DocWord {
                        time_ms: word.time_ms + shift,
                        end_ms: word.end_ms.map(|end| end + shift),
                        text: word.text.clone(),
                        start: word.start,
                    })
                    .collect(),
                end: end.map(|end| end + shift),
                voice: voice.clone(),
            });
        }
    }
    rows.sort_by_key(|row| (row.time, row.order));
    // Section detection over the timed rows: an empty timed row is a break
    // and a marker row names the next section; times stay with their text.
    let mut lines: Vec<DocLine> = Vec::new();
    let mut pending_section = None;
    let mut pending_break = false;
    for row in rows {
        if row.text.is_empty() {
            pending_break = !lines.is_empty();
            if let Some(previous) = lines.last_mut() {
                previous.end_ms.get_or_insert(row.time);
            }
            continue;
        }
        if let Some(kind) = sections::marker_kind(&row.text) {
            pending_section = Some(kind.to_owned());
            pending_break = !lines.is_empty();
            continue;
        }
        let text = sections::strip_inline(&row.text).trim().to_owned();
        if text.is_empty() {
            continue;
        }
        let backing = row.voice.as_deref() == Some(BACKING_VOICE);
        lines.push(DocLine {
            time_ms: row.time,
            end_ms: row.end.filter(|end| *end > row.time),
            // Word ranges are found in the text, so they need it unchanged.
            words: if text == row.text {
                row.words
            } else {
                Vec::new()
            },
            text,
            section: if backing {
                None
            } else {
                pending_section.take()
            },
            section_break_before: !backing && std::mem::take(&mut pending_break),
            voice: row.voice,
            translation: None,
        });
    }
    for index in 0..lines.len() {
        // A lead line ends when the next lead line starts, at the latest.
        let next = lines[index + 1..]
            .iter()
            .find(|line| !line.is_backing())
            .map(|line| line.time_ms);
        let line = &mut lines[index];
        let keeps_end = line.is_backing() && line.end_ms.is_some();
        if let Some(next) = next
            && !keeps_end
            && line.end_ms.is_none_or(|end| end > next)
        {
            line.end_ms = Some(next);
        }
        let mut following = line.end_ms;
        for word in line.words.iter_mut().rev() {
            if word.end_ms.is_none() {
                word.end_ms = following.filter(|end| *end >= word.time_ms);
            }
            following = Some(word.time_ms);
        }
    }
    // `v1:` on every line is a solo song, not a duet.
    let duet = lines.iter().any(|line| {
        line.voice
            .as_deref()
            .is_some_and(|voice| voice != "v1" && voice != BACKING_VOICE)
    });
    if !duet {
        for line in lines.iter_mut().filter(|line| !line.is_backing()) {
            line.voice = None;
        }
    }
    let word_timed = lines.iter().any(|line| !line.words.is_empty());
    LyricDoc {
        version: DOC_VERSION,
        format: if word_timed { "elrc" } else { "lrc" }.into(),
        timed: lines.iter().any(|line| line.time_ms > 0),
        offset_ms,
        title,
        artist,
        lines,
    }
}

/// Apple-style TTML: word timing, duet sides, backing vocals and head
/// translations. The payload reader writes enhanced LRC, parsed as above.
fn parse_ttml(raw: &str) -> Result<LyricDoc, String> {
    let lyrics = payloads::ttml_lyrics(raw, "", "", true, true)?;
    if lyrics.sync_type != "LINE_SYNCED" {
        let plain: Vec<String> = lyrics
            .plain_lyrics
            .split('\n')
            .filter(|row| !BACKING.is_match(row.trim()))
            .map(|row| VOICE.replace(row.trim(), "").into_owned())
            .collect();
        return Ok(parse_plain(&plain.join("\n")));
    }
    let rows: Vec<String> = lyrics
        .lines()
        .iter()
        .map(|line| format!("{}{}", lrc::timestamp(line.start_time_ms), line.words))
        .collect();
    let mut doc = parse_lrc(&rows.join("\n"));
    for line in doc.lines.iter_mut().filter(|line| !line.is_backing()) {
        line.translation = lyrics
            .lines()
            .iter()
            .find(|source| source.start_time_ms == line.time_ms)
            .and_then(|source| source.translation.clone());
    }
    doc.format = "ttml".into();
    Ok(doc)
}

fn section_label(kind: &str) -> &'static str {
    match kind {
        "verse" => "Verse",
        "preChorus" => "Pre-Chorus",
        "chorus" => "Chorus",
        "postChorus" => "Post-Chorus",
        "bridge" => "Bridge",
        "intro" => "Intro",
        "outro" => "Outro",
        "interlude" => "Interlude",
        _ => "Tag",
    }
}

fn inline(ms: i64) -> String {
    format!("<{}>", lrc::timestamp_inline(ms))
}

/// A line's text with word tags: `<start>word <end>`, the start tag left out
/// when it repeats the previous end. Falls back to the plain text when the
/// words are not found in it.
fn word_body(line: &DocLine) -> String {
    let mut out = String::new();
    let mut last_tag = None;
    let mut cursor = 0;
    for word in &line.words {
        let Some(found) = line.text[cursor..].find(&word.text) else {
            return line.text.clone();
        };
        out.push_str(&line.text[cursor..cursor + found]);
        if last_tag != Some(word.time_ms) {
            out.push_str(&inline(word.time_ms));
        }
        out.push_str(&word.text);
        cursor += found + word.text.len();
        let rest = &line.text[cursor..];
        let space = rest.len() - rest.trim_start().len();
        out.push_str(&rest[..space]);
        cursor += space;
        last_tag = Some(word.time_ms);
        if let Some(end) = word.end_ms {
            out.push_str(&inline(end));
            last_tag = Some(end);
        }
    }
    out.push_str(&line.text[cursor..]);
    if let Some(end) = line.end_ms
        && cursor == line.text.len()
        && last_tag != Some(end)
    {
        out.push_str(&inline(end));
    }
    out
}

/// Writes `doc` as `"lrc"` (line starts; a blank timed row for each break)
/// or `"elrc"` (also word tags, line ends, sections, voices and backing
/// rows, so `parse` returns the same lines).
pub fn export(doc: &LyricDoc, format: &str) -> Result<String, String> {
    let enhanced = match format {
        "lrc" => false,
        "elrc" => true,
        other => return Err(format!("unknown export format {other}")),
    };
    if !doc.timed {
        return Err("lyrics have no timing to export".into());
    }
    let mut rows: Vec<String> = Vec::new();
    if let Some(title) = doc.title.as_deref().filter(|title| !title.is_empty()) {
        rows.push(format!("[ti:{title}]"));
    }
    if let Some(artist) = doc.artist.as_deref().filter(|artist| !artist.is_empty()) {
        rows.push(format!("[ar:{artist}]"));
    }
    if doc.offset_ms != 0 {
        rows.push(format!("[offset:{}]", doc.offset_ms));
    }
    for (index, line) in doc.lines.iter().enumerate() {
        let time = lrc::timestamp(line.time_ms);
        if line.is_backing() && enhanced {
            let body = if line.words.is_empty() {
                let end = line.end_ms.map(inline).unwrap_or_default();
                format!("{}{}{end}", inline(line.time_ms), line.text)
            } else {
                word_body(line)
            };
            rows.push(format!("[bg:{body}]"));
            continue;
        }
        let next = doc.lines[index + 1..]
            .iter()
            .find(|line| !line.is_backing())
            .map(|line| line.time_ms);
        match &line.section {
            Some(section) if enhanced => rows.push(format!("{time}[{}]", section_label(section))),
            _ if line.section_break_before && index > 0 => {
                // The blank row doubles as the end of the line before it.
                let end = doc.lines[..index]
                    .iter()
                    .rev()
                    .find(|line| !line.is_backing())
                    .and_then(|line| line.end_ms)
                    .filter(|end| *end <= line.time_ms)
                    .unwrap_or(line.time_ms);
                rows.push(lrc::timestamp(end));
            }
            _ => {}
        }
        if !enhanced {
            rows.push(format!("{time}{}", line.text));
            continue;
        }
        let voice = line
            .voice
            .as_deref()
            .map(|voice| format!("{voice}:"))
            .unwrap_or_default();
        let body = if line.words.is_empty() {
            let end = line
                .end_ms
                .filter(|end| Some(*end) != next)
                .map(inline)
                .unwrap_or_default();
            format!("{}{end}", line.text)
        } else {
            word_body(line)
        };
        rows.push(format!("{time}{voice}{body}"));
    }
    rows.push(String::new());
    Ok(rows.join("\n"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parsed(raw: &str) -> LyricDoc {
        parse(raw, None).unwrap()
    }

    fn words(line: &DocLine) -> Vec<(i64, Option<i64>, &str)> {
        line.words
            .iter()
            .map(|word| (word.time_ms, word.end_ms, word.text.as_str()))
            .collect()
    }

    #[test]
    fn plain_text_keeps_sections_and_breaks() {
        let doc = parsed("[Verse 1]\nLine one\nLine two\n\n[Chorus]\nSing it\n");
        assert_eq!(doc.format, "plain");
        assert!(!doc.timed);
        let texts: Vec<_> = doc.lines.iter().map(|l| l.text.as_str()).collect();
        assert_eq!(texts, ["Line one", "Line two", "Sing it"]);
        assert_eq!(doc.lines[0].section.as_deref(), Some("verse"));
        assert_eq!(doc.lines[2].section.as_deref(), Some("chorus"));
        assert!(doc.lines[2].section_break_before);
        assert!(doc.lines.iter().all(|l| l.time_ms == 0));
    }

    #[test]
    fn lrc_with_metadata_offset_and_repeated_tags() {
        let raw = "\u{feff}[ti:月亮代表我的心]\r\n[ar:邓丽君]\r\n[offset:-150]\r\n\
                   [00:12.34]你问我爱你有多深\r\n[00:20.5][01:10.00]我爱你有几分\r\n\
                   [00:30.120][Chorus]\r\n[00:31.00]<00:31.00>月<00:31.50>亮\r\n";
        let doc = parsed(raw);
        assert_eq!(doc.format, "elrc");
        assert!(doc.timed);
        assert_eq!(doc.offset_ms, -150);
        assert_eq!(doc.title.as_deref(), Some("月亮代表我的心"));
        assert_eq!(doc.artist.as_deref(), Some("邓丽君"));
        let lines: Vec<_> = doc
            .lines
            .iter()
            .map(|l| (l.time_ms, l.end_ms, l.text.as_str(), l.section.as_deref()))
            .collect();
        assert_eq!(
            lines,
            [
                (12_340, Some(20_500), "你问我爱你有多深", None),
                (20_500, Some(31_000), "我爱你有几分", None),
                (31_000, Some(70_000), "月亮", Some("chorus")),
                (70_000, None, "我爱你有几分", None),
            ]
        );
        assert_eq!(
            words(&doc.lines[2]),
            [(31_000, Some(31_500), "月"), (31_500, Some(70_000), "亮")]
        );
    }

    #[test]
    fn explicit_format_wins() {
        assert_eq!(parse("[00:01.00]x", Some("plain")).unwrap().format, "plain");
        assert_eq!(parse("no tags", Some("lrc")).unwrap().lines.len(), 0);
        assert!(parse("x", Some("klingon")).is_err());
        assert!(parse("not xml", Some("ttml")).is_err());
    }

    #[test]
    fn enhanced_lrc_word_tags_in_both_styles() {
        // Each tag starts a word; the last tag ends the line.
        let doc = parsed(
            "[00:01.00]<00:01.00>Hello <00:01.40>big <00:01.90>world<00:02.50>\n[00:04.00]next",
        );
        let line = &doc.lines[0];
        assert_eq!(line.text, "Hello big world");
        assert_eq!(line.end_ms, Some(2500));
        assert_eq!(
            words(line),
            [
                (1000, Some(1400), "Hello"),
                (1400, Some(1900), "big"),
                (1900, Some(2500), "world"),
            ]
        );
        // Start and end tags per word, with a gap between words; the first
        // word may start at the line time without a tag.
        let doc = parsed("[00:01.00]long <00:01.50><00:01.70>e<00:02.00><00:02.00>nough<00:03.00>");
        assert_eq!(doc.lines[0].text, "long enough");
        assert_eq!(
            words(&doc.lines[0]),
            [
                (1000, Some(1500), "long"),
                (1700, Some(2000), "e"),
                (2000, Some(3000), "nough"),
            ]
        );
        // A lone trailing tag is the line end, not word timing.
        let doc = parsed("[00:01.00]whole line<00:02.20>\n[00:05.00]next");
        assert!(doc.lines[0].words.is_empty());
        assert_eq!(doc.lines[0].end_ms, Some(2200));
        assert_eq!(doc.format, "lrc");
    }

    #[test]
    fn enhanced_lrc_round_trips() {
        let word = |time_ms, end_ms, text: &str| DocWord {
            time_ms,
            end_ms: Some(end_ms),
            text: text.into(),
            start: 0,
        };
        let doc = LyricDoc {
            version: DOC_VERSION,
            format: "elrc".into(),
            timed: true,
            offset_ms: 120,
            title: Some("Song".into()),
            artist: Some("Singer".into()),
            lines: vec![
                DocLine {
                    time_ms: 1005,
                    end_ms: Some(2500),
                    text: "Hello big world".into(),
                    section: Some("verse".into()),
                    words: vec![
                        word(1005, 1400, "Hello"),
                        word(1450, 1900, "big"),
                        word(1900, 2500, "world"),
                    ],
                    voice: Some("v1".into()),
                    ..DocLine::default()
                },
                DocLine {
                    time_ms: 1500,
                    end_ms: Some(2100),
                    text: "(ooh yeah)".into(),
                    words: vec![word(1500, 1800, "(ooh"), word(1800, 2100, "yeah)")],
                    voice: Some(BACKING_VOICE.into()),
                    ..DocLine::default()
                },
                DocLine {
                    time_ms: 4000,
                    end_ms: Some(5200),
                    text: "line with a gap after".into(),
                    voice: Some("v2".into()),
                    ..DocLine::default()
                },
                DocLine {
                    time_ms: 9000,
                    end_ms: Some(10_000),
                    text: "月亮".into(),
                    section_break_before: true,
                    words: vec![word(9000, 9400, "月"), word(9400, 10_000, "亮")],
                    voice: Some("v1".into()),
                    ..DocLine::default()
                },
                DocLine {
                    time_ms: 10_000,
                    end_ms: Some(12_345),
                    text: "last".into(),
                    section: Some("chorus".into()),
                    section_break_before: true,
                    voice: Some("v1".into()),
                    ..DocLine::default()
                },
            ],
        };
        let text = export(&doc, "elrc").unwrap();
        assert_eq!(
            text,
            "[ti:Song]\n[ar:Singer]\n[offset:120]\n\
             [00:01.005][Verse]\n\
             [00:01.005]v1:<00:01.005>Hello <00:01.40><00:01.45>big <00:01.90>world<00:02.50>\n\
             [bg:<00:01.50>(ooh <00:01.80>yeah)<00:02.10>]\n\
             [00:04.00]v2:line with a gap after<00:05.20>\n\
             [00:05.20]\n\
             [00:09.00]v1:<00:09.00>月<00:09.40>亮<00:10.00>\n\
             [00:10.00][Chorus]\n\
             [00:10.00]v1:last<00:12.345>\n"
        );
        let mut located = doc.clone();
        located.lines.iter_mut().for_each(locate_words);
        assert_eq!(parsed(&text), located);
        // Exporting what was parsed changes nothing.
        assert_eq!(export(&parsed(&text), "elrc").unwrap(), text);
    }

    #[test]
    fn lrc_export_keeps_line_starts_and_breaks() {
        let doc = parsed(
            "[00:01.00]<00:01.00>a <00:01.50>b<00:02.00>\n[00:03.00]\n[00:04.00][Chorus]\n[00:04.00]c",
        );
        let text = export(&doc, "lrc").unwrap();
        assert_eq!(text, "[00:01.00]a b\n[00:02.00]\n[00:04.00]c\n");
        let again = parsed(&text);
        assert_eq!(again.format, "lrc");
        assert_eq!(again.lines[0].end_ms, Some(2000));
        assert!(again.lines[1].section_break_before);
        assert!(export(&parsed("no timing"), "lrc").is_err());
        assert!(export(&doc, "ttml").is_err());
    }

    #[test]
    fn ttml_words_voices_backing_and_translations() {
        let raw = r#"<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" itunes:timing="Word" xml:lang="fr"><head><metadata><ttm:agent type="person" xml:id="v1"/><ttm:agent type="person" xml:id="v2"/><iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal"><translations><translation xml:lang="en-US"><text for="L1">First line</text></translation></translations></iTunesMetadata></metadata></head><body><div><p begin="1.000" end="2.000" itunes:key="L1" ttm:agent="v1"><span begin="1.000" end="1.400">Pre</span><span begin="1.400" end="1.600">mier</span> <span begin="1.600" end="2.000">vers</span></p><p begin="3.000" end="5.000" itunes:key="L2" ttm:agent="v2"><span ttm:role="x-bg"><span begin="3.000" end="3.500">(Yes)</span></span> <span begin="3.200" end="5.000">Second</span></p></div></body></tt>"#;
        let doc = parsed(raw);
        assert_eq!(doc.format, "ttml");
        assert!(doc.timed);
        let lines: Vec<_> = doc
            .lines
            .iter()
            .map(|l| (l.time_ms, l.end_ms, l.text.as_str(), l.voice.as_deref()))
            .collect();
        assert_eq!(
            lines,
            [
                (1000, Some(2000), "Premier vers", Some("v1")),
                (3000, Some(5000), "Second", Some("v2")),
                (3000, Some(3500), "(Yes)", Some("bg")),
            ]
        );
        assert_eq!(
            words(&doc.lines[0]),
            [
                (1000, Some(1400), "Pre"),
                (1400, Some(1600), "mier"),
                (1600, Some(2000), "vers"),
            ]
        );
        assert_eq!(doc.lines[0].translation.as_deref(), Some("First line"));
        // A solo song has no voices.
        let solo = parsed(
            r#"<tt xmlns="http://www.w3.org/ns/ttml"><body><div><p begin="1.000" end="2.000">One</p><p begin="2.500" end="3.000">Two</p></div></body></tt>"#,
        );
        assert_eq!(solo.lines.len(), 2);
        assert!(solo.lines.iter().all(|line| line.voice.is_none()));
        assert_eq!(solo.lines[1].time_ms, 2500);
    }
}
