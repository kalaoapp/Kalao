//! Reading layers over lyric text (DATA_MODEL.md §1). A layer is a list of
//! ruby segments, each a UTF-16 range of the line (Dart string indices) with
//! the reading shown above it.

pub mod chinese_variant;
pub mod japanese;
pub mod pinyin;

use serde::Serialize;

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct RubySegment {
    /// UTF-16 offset of the first annotated character.
    pub start: usize,
    /// UTF-16 offset after the last annotated character.
    pub end: usize,
    pub reading: String,
}

/// The language the reading layers are generated for: `ja` when any line
/// has kana (furigana and romaji), else `zh` when any has Han characters
/// (pinyin), else none.
pub fn source_language<S: AsRef<str>>(lines: &[S]) -> Option<&'static str> {
    if lines.iter().any(|line| japanese::has_kana(line.as_ref())) {
        Some("ja")
    } else if lines.iter().any(|line| line.as_ref().chars().any(is_han)) {
        Some("zh")
    } else {
        None
    }
}

/// The layers generated for `language`.
pub fn layers_for(language: Option<&str>) -> &'static [&'static str] {
    match language {
        Some("ja") => &["furigana", "romaji"],
        Some("zh") => &["pinyin"],
        _ => &[],
    }
}

/// Whether `ch` is a Han ideograph (CJK Unified, Extension A–F, compatibility).
pub fn is_han(ch: char) -> bool {
    matches!(ch as u32,
        0x3400..=0x4DBF
        | 0x4E00..=0x9FFF
        | 0xF900..=0xFAFF
        | 0x20000..=0x2EBEF
        | 0x30000..=0x3134F)
}
