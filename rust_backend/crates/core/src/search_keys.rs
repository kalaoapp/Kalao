//! Library search keys (FEATURES 6.2, IMPLEMENTATION.md §3 step 6). Dart
//! normalises the query with the same rule as [`normalize`] and matches keys
//! by substring, so "yueliang", "yl", "月亮" and "moon" all find a song.

use crate::annotate::{japanese, pinyin};
use serde::Serialize;

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchKey {
    pub key_kind: &'static str,
    pub key: String,
}

/// Lowercase letters and digits of any script; everything else dropped.
/// Must match `normalizeSearchText` in Dart (`library_search.dart`).
pub fn normalize(text: &str) -> String {
    text.chars()
        .filter(|ch| ch.is_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect()
}

/// Keys for one song's title and artist.
pub fn keys(title: &str, artist: &str) -> Vec<SearchKey> {
    let mut keys = Vec::new();
    let mut push = |key_kind, key: String| {
        if !key.is_empty()
            && !keys
                .iter()
                .any(|k: &SearchKey| k.key_kind == key_kind && k.key == key)
        {
            keys.push(SearchKey { key_kind, key });
        }
    };
    push("title", normalize(title));
    push("artist", normalize(artist));
    for text in [title, artist] {
        if let Some((full, initials)) = pinyin::search_keys(text) {
            push("pinyin", full);
            push("initials", initials);
        }
        // Text with kana is Japanese: its kanji are read as Japanese too.
        if let Some(romaji) = japanese::search_key(text) {
            push("romaji", normalize(&romaji));
        }
    }
    keys
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kinds(keys: &[SearchKey]) -> Vec<(&str, &str)> {
        keys.iter()
            .map(|key| (key.key_kind, key.key.as_str()))
            .collect()
    }

    #[test]
    fn chinese_song_gets_pinyin_and_initials() {
        let keys = keys("月亮代表我的心", "邓丽君 Teresa Teng");
        assert_eq!(
            kinds(&keys),
            [
                ("title", "月亮代表我的心"),
                ("artist", "邓丽君teresateng"),
                ("pinyin", "yueliangdaibiaowodexin"),
                ("initials", "yldbwdx"),
                ("pinyin", "denglijun"),
                ("initials", "dlj"),
            ]
        );
    }

    #[test]
    fn kana_gets_romaji_and_latin_is_normalised() {
        let keys = keys("さくらんぼ", "Ai Otsuka!");
        assert!(kinds(&keys).contains(&("romaji", "sakuranbo")));
        assert!(kinds(&keys).contains(&("artist", "aiotsuka")));
        assert_eq!(normalize("Don't Stop — Me Now"), "dontstopmenow");
    }
}
