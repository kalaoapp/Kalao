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

/// Whether `ch` is a Han ideograph (CJK Unified, Extension A–F, compatibility).
pub fn is_han(ch: char) -> bool {
    matches!(ch as u32,
        0x3400..=0x4DBF
        | 0x4E00..=0x9FFF
        | 0xF900..=0xFAFF
        | 0x20000..=0x2EBEF
        | 0x30000..=0x3134F)
}
