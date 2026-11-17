//! Japanese readings (FEATURES 2.4): lindera with IPADIC splits a line into
//! words and gives each a katakana reading. Furigana are hiragana segments
//! over the kanji only (okurigana stays unannotated); romaji is one Hepburn
//! word per token.

use super::RubySegment;
use lindera::dictionary::load_dictionary;
use lindera::mode::Mode;
use lindera::segmenter::Segmenter;
use std::borrow::Cow;
use std::sync::OnceLock;
use wana_kana::ConvertJapanese;

/// IPADIC detail columns.
const PART_OF_SPEECH: usize = 0;
const READING: usize = 7;

fn segmenter() -> Option<&'static Segmenter> {
    static SEGMENTER: OnceLock<Option<Segmenter>> = OnceLock::new();
    SEGMENTER
        .get_or_init(|| {
            load_dictionary("embedded://ipadic")
                .ok()
                .map(|dictionary| Segmenter::new(Mode::Normal, dictionary, None))
        })
        .as_ref()
}

fn is_kanji(ch: char) -> bool {
    super::is_han(ch) || ch == '々' || ch == '〆' || ch == 'ヶ'
}

fn is_kana(ch: char) -> bool {
    matches!(ch as u32, 0x3041..=0x30FF)
}

/// Whether `text` has kana, which marks a line as Japanese rather than
/// Chinese.
pub fn has_kana(text: &str) -> bool {
    text.chars()
        .any(|ch| is_kana(ch) && ch != '・' && ch != 'ー')
}

fn hiragana(ch: char) -> char {
    match ch as u32 {
        0x30A1..=0x30F6 => char::from_u32(ch as u32 - 0x60).unwrap_or(ch),
        _ => ch,
    }
}

/// One word of a line: its UTF-16 range, text, hiragana reading (when the
/// dictionary knows it) and whether it is a particle.
struct Word {
    start: usize,
    surface: String,
    reading: Option<String>,
    particle: bool,
}

fn words(text: &str) -> Vec<Word> {
    let Some(segmenter) = segmenter() else {
        return Vec::new();
    };
    let Ok(mut tokens) = segmenter.segment(Cow::Borrowed(text)) else {
        return Vec::new();
    };
    tokens
        .iter_mut()
        .map(|token| {
            let start = text[..token.byte_start].encode_utf16().count();
            let surface = token.surface.to_string();
            let details = token.details();
            let reading = details
                .get(READING)
                .filter(|reading| !reading.is_empty() && **reading != "*")
                .map(|reading| reading.chars().map(hiragana).collect());
            Word {
                start,
                particle: details.get(PART_OF_SPEECH) == Some(&"助詞"),
                surface,
                reading,
            }
        })
        .collect()
}

/// Splits `reading` over the kanji runs of `surface`: kana in the surface
/// must appear in the reading as written, and each kanji run takes what lies
/// between. Returns (char start, char end, reading) per kanji run, or `None`
/// when the reading does not fit the surface.
fn kanji_readings(surface: &[char], reading: &[char]) -> Option<Vec<(usize, usize, String)>> {
    let mut out = Vec::new();
    let (mut s, mut r) = (0, 0);
    while s < surface.len() {
        if !is_kanji(surface[s]) {
            if reading.get(r).copied() != Some(hiragana(surface[s])) {
                return None;
            }
            s += 1;
            r += 1;
            continue;
        }
        let run_start = s;
        while s < surface.len() && is_kanji(surface[s]) {
            s += 1;
        }
        // The kana after the run, as it must appear in the reading.
        let literal: Vec<char> = surface[s..]
            .iter()
            .take_while(|ch| !is_kanji(**ch))
            .map(|ch| hiragana(*ch))
            .collect();
        let end = if literal.is_empty() {
            reading.len()
        } else {
            // Each kanji needs at least one kana, so search after that.
            let from = r + (s - run_start);
            (from..=reading.len().checked_sub(literal.len())?)
                .find(|at| reading[*at..].starts_with(&literal))?
        };
        if end <= r {
            return None;
        }
        out.push((run_start, s, reading[r..end].iter().collect()));
        r = end;
    }
    (r == reading.len()).then_some(out)
}

/// Furigana ruby segments for one lyric line.
pub fn furigana(text: &str) -> Vec<RubySegment> {
    let mut segments = Vec::new();
    for word in words(text) {
        let Some(reading) = &word.reading else {
            continue;
        };
        let surface: Vec<char> = word.surface.chars().collect();
        if !surface.iter().any(|ch| is_kanji(*ch)) {
            continue;
        }
        let reading: Vec<char> = reading.chars().collect();
        let utf16 = |chars: &[char]| chars.iter().map(|ch| ch.len_utf16()).sum::<usize>();
        match kanji_readings(&surface, &reading) {
            Some(runs) => {
                for (from, to, reading) in runs {
                    segments.push(RubySegment {
                        start: word.start + utf16(&surface[..from]),
                        end: word.start + utf16(&surface[..to]),
                        reading,
                    });
                }
            }
            // An irregular reading goes over the whole word.
            None => segments.push(RubySegment {
                start: word.start,
                end: word.start + utf16(&surface),
                reading: reading.iter().collect(),
            }),
        }
    }
    segments
}

/// The romaji of one word, or `None` for text with no Japanese reading.
fn word_romaji(word: &Word) -> Option<String> {
    if word.particle {
        // Particles are written は/へ/を and said wa/e/o.
        match word.surface.as_str() {
            "は" => return Some("wa".into()),
            "へ" => return Some("e".into()),
            "を" => return Some("o".into()),
            _ => {}
        }
    }
    let kana = match &word.reading {
        Some(reading) => reading.clone(),
        None if word.surface.chars().all(is_kana) => word.surface.clone(),
        None => return None,
    };
    if !kana.chars().any(is_kana) {
        return None;
    }
    Some(kana.to_romaji())
}

/// Romaji segments for one lyric line: one per word, over that word.
pub fn romaji(text: &str) -> Vec<RubySegment> {
    words(text)
        .iter()
        .filter_map(|word| {
            Some(RubySegment {
                start: word.start,
                end: word.start + word.surface.encode_utf16().count(),
                reading: word_romaji(word)?,
            })
        })
        .collect()
}

/// The line's romaji joined, for library search keys (kanji included), or
/// `None` when the text has no kana (it may be Chinese).
pub fn search_key(text: &str) -> Option<String> {
    if !has_kana(text) {
        return None;
    }
    let joined: String = words(text).iter().filter_map(word_romaji).collect();
    (!joined.is_empty()).then_some(joined)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pairs(text: &str, segments: &[RubySegment]) -> Vec<(String, String)> {
        let units: Vec<u16> = text.encode_utf16().collect();
        segments
            .iter()
            .map(|segment| {
                (
                    String::from_utf16_lossy(&units[segment.start..segment.end]),
                    segment.reading.clone(),
                )
            })
            .collect()
    }

    fn strs(pairs: &[(String, String)]) -> Vec<(&str, &str)> {
        pairs
            .iter()
            .map(|(base, reading)| (base.as_str(), reading.as_str()))
            .collect()
    }

    #[test]
    fn furigana_covers_kanji_and_leaves_okurigana() {
        let text = "桜の花が咲く";
        assert_eq!(
            strs(&pairs(text, &furigana(text))),
            [("桜", "さくら"), ("花", "はな"), ("咲", "さ")]
        );
        // Kana and Latin text get nothing; offsets are UTF-16.
        let text = "𠮷野家で食べた Hello";
        let found = pairs(text, &furigana(text));
        assert!(
            found
                .iter()
                .any(|(base, reading)| base == "食" && reading == "た")
        );
        assert!(found.iter().all(|(base, _)| base.chars().all(is_kanji)));
        assert!(furigana("ひらがな カタカナ abc").is_empty());
    }

    #[test]
    fn readings_split_around_kana_inside_a_word() {
        let split = |surface: &str, reading: &str| {
            kanji_readings(
                &surface.chars().collect::<Vec<_>>(),
                &reading.chars().collect::<Vec<_>>(),
            )
        };
        assert_eq!(
            split("引き出し", "ひきだし"),
            Some(vec![(0, 1, "ひ".into()), (2, 3, "だ".into())])
        );
        assert_eq!(split("お茶", "おちゃ"), Some(vec![(1, 2, "ちゃ".into())]));
        assert_eq!(
            split("東京", "とうきょう"),
            Some(vec![(0, 2, "とうきょう".into())])
        );
        // Katakana in the surface matches the hiragana reading.
        assert_eq!(
            split("消しゴム", "けしごむ"),
            Some(vec![(0, 1, "け".into())])
        );
        // A reading that does not contain the okurigana does not fit.
        assert_eq!(split("食べる", "くう"), None);
    }

    #[test]
    fn romaji_is_one_word_per_token_with_spoken_particles() {
        let text = "私は東京へ行く";
        let found = pairs(text, &romaji(text));
        assert_eq!(
            strs(&found),
            [
                ("私", "watashi"),
                ("は", "wa"),
                ("東京", "toukyou"),
                ("へ", "e"),
                ("行く", "iku"),
            ]
        );
        assert!(romaji("Hello 你好").iter().all(|s| s.reading != "Hello"));
        assert_eq!(search_key("夜に駆ける").as_deref(), Some("yorunikakeru"));
        // No kana: possibly Chinese, so no romaji key.
        assert_eq!(search_key("月亮代表我的心"), None);
    }
}
