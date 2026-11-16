//! Import pairing (IMPLEMENTATION.md §3 step 2): from one pick of files,
//! propose for each original an instrumental and a lyrics file by filename
//! similarity, instrumental markers and duration (±2 s). The user confirms
//! the proposal in the import sheet.

use serde::{Deserialize, Serialize};

/// Words that mark a backing track, compared after normalisation.
const INSTRUMENTAL_MARKERS: &[&str] = &[
    "instrumental",
    "inst",
    "karaoke",
    "offvocal",
    "off vocal",
    "backing",
    "backingtrack",
    "minusone",
    "伴奏",
    "纯音乐",
    "純音樂",
    "カラオケ",
    "オフボーカル",
    "インスト",
];

const AUDIO_EXTENSIONS: &[&str] = &[
    "mp3", "m4a", "aac", "flac", "wav", "ogg", "oga", "opus", "alac", "mp4", "wma", "ape", "aiff",
    "aif",
];
const LYRICS_EXTENSIONS: &[&str] = &["lrc", "txt", "ttml"];

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PickedFile {
    pub name: String,
    #[serde(default)]
    pub duration_ms: Option<u64>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Proposal {
    /// Index into the picked files.
    pub original: usize,
    pub instrumental: Option<usize>,
    pub lyrics: Option<usize>,
    /// Title guessed from the file name (tags usually win in Dart).
    pub title: String,
}

fn split_name(name: &str) -> (&str, String) {
    match name.rsplit_once('.') {
        Some((stem, extension)) if !stem.is_empty() => (stem, extension.to_lowercase()),
        _ => (name, String::new()),
    }
}

/// Lowercase words of a file stem; brackets, dashes and underscores split.
fn words(stem: &str) -> Vec<String> {
    stem.to_lowercase()
        .split(|ch: char| !ch.is_alphanumeric())
        .filter(|word| !word.is_empty())
        .map(str::to_owned)
        .collect()
}

fn is_instrumental(stem: &str) -> bool {
    let words = words(stem);
    let joined: String = words.concat();
    INSTRUMENTAL_MARKERS.iter().any(|marker| {
        let marker_joined: String = marker.split(' ').collect();
        let latin = marker.is_ascii();
        if latin {
            words.contains(&marker_joined)
                || (marker.contains(' ') && joined.contains(&marker_joined))
        } else {
            joined.contains(&marker_joined)
        }
    })
}

/// The stem without instrumental markers or leading track numbers.
fn base(stem: &str) -> String {
    let mut text: String = words(stem)
        .into_iter()
        .filter(|word| {
            !INSTRUMENTAL_MARKERS.contains(&word.as_str())
                && !matches!(word.as_str(), "off" | "vocal" | "ver" | "version" | "track")
        })
        .collect::<Vec<_>>()
        .join(" ");
    for marker in INSTRUMENTAL_MARKERS.iter().filter(|m| !m.is_ascii()) {
        text = text.replace(marker, "");
    }
    let trimmed = text.trim_start_matches(|ch: char| ch.is_ascii_digit() || ch == ' ');
    let result = if trimmed.is_empty() { &text } else { trimmed };
    result.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Character-bigram Dice similarity, 0–1.
fn similarity(a: &str, b: &str) -> f64 {
    if a == b {
        return 1.0;
    }
    let grams = |s: &str| {
        let chars: Vec<char> = s.chars().filter(|c| !c.is_whitespace()).collect();
        chars.windows(2).map(|w| (w[0], w[1])).collect::<Vec<_>>()
    };
    let (left, mut right) = (grams(a), grams(b));
    if left.is_empty() || right.is_empty() {
        return 0.0;
    }
    let total = left.len() + right.len();
    let mut shared = 0;
    for gram in left {
        if let Some(index) = right.iter().position(|other| *other == gram) {
            right.swap_remove(index);
            shared += 1;
        }
    }
    2.0 * shared as f64 / total as f64
}

fn durations_match(a: Option<u64>, b: Option<u64>) -> bool {
    match (a, b) {
        (Some(a), Some(b)) => a.abs_diff(b) <= 2000,
        _ => true,
    }
}

/// Groups `files` into songs. Every audio file appears exactly once, as an
/// original or as the instrumental of one.
pub fn propose(files: &[PickedFile]) -> Vec<Proposal> {
    let parsed: Vec<_> = files
        .iter()
        .map(|file| {
            let (stem, extension) = split_name(&file.name);
            (stem, extension, base(stem))
        })
        .collect();
    let audio = |index: usize| AUDIO_EXTENSIONS.contains(&parsed[index].1.as_str());
    let lyrics = |index: usize| LYRICS_EXTENSIONS.contains(&parsed[index].1.as_str());
    let instrumentals: Vec<usize> = (0..files.len())
        .filter(|&i| audio(i) && is_instrumental(parsed[i].0))
        .collect();
    let mut originals: Vec<usize> = (0..files.len())
        .filter(|&i| audio(i) && !instrumentals.contains(&i))
        .collect();
    let mut used_instrumental = vec![false; files.len()];
    let mut used_lyrics = vec![false; files.len()];
    let best = |candidates: &mut dyn Iterator<Item = usize>, target: &str, original: usize| {
        candidates
            .map(|i| (i, similarity(&parsed[i].2, target)))
            .filter(|(i, score)| {
                *score >= 0.6 && durations_match(files[*i].duration_ms, files[original].duration_ms)
            })
            .max_by(|a, b| a.1.total_cmp(&b.1))
            .map(|(i, _)| i)
    };
    let mut proposals = Vec::new();
    for &original in &originals {
        let target = parsed[original].2.clone();
        let instrumental = best(
            &mut instrumentals
                .iter()
                .copied()
                .filter(|&i| !used_instrumental[i]),
            &target,
            original,
        );
        if let Some(i) = instrumental {
            used_instrumental[i] = true;
        }
        let lyric = (0..files.len())
            .filter(|&i| lyrics(i) && !used_lyrics[i])
            .map(|i| (i, similarity(&parsed[i].2, &target)))
            .filter(|(_, score)| *score >= 0.6)
            .max_by(|a, b| a.1.total_cmp(&b.1))
            .map(|(i, _)| i);
        if let Some(i) = lyric {
            used_lyrics[i] = true;
        }
        proposals.push(Proposal {
            original,
            instrumental,
            lyrics: lyric,
            title: parsed[original].0.trim().to_owned(),
        });
    }
    // An instrumental with no original is imported as its own song.
    for i in instrumentals {
        if !used_instrumental[i] {
            originals.push(i);
            proposals.push(Proposal {
                original: i,
                title: parsed[i].0.trim().to_owned(),
                ..Proposal::default()
            });
        }
    }
    proposals
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file(name: &str, duration_ms: u64) -> PickedFile {
        PickedFile {
            name: name.into(),
            duration_ms: Some(duration_ms),
        }
    }

    #[test]
    fn pairs_by_name_markers_and_duration() {
        let files = [
            file("01 - 月亮代表我的心.flac", 210_000),
            file("月亮代表我的心 (伴奏).mp3", 211_000),
            file("Shape of You.m4a", 233_000),
            file("Shape of You [Instrumental].m4a", 233_500),
            file("Shape of You.lrc", 0),
            file("月亮代表我的心.txt", 0),
        ];
        let proposals = propose(&files);
        assert_eq!(
            proposals,
            [
                Proposal {
                    original: 0,
                    instrumental: Some(1),
                    lyrics: Some(5),
                    title: "01 - 月亮代表我的心".into(),
                },
                Proposal {
                    original: 2,
                    instrumental: Some(3),
                    lyrics: Some(4),
                    title: "Shape of You".into(),
                },
            ]
        );
    }

    #[test]
    fn duration_mismatch_blocks_a_pair() {
        let files = [
            file("Song.mp3", 200_000),
            file("Song (karaoke).mp3", 150_000),
        ];
        let proposals = propose(&files);
        assert_eq!(proposals.len(), 2);
        assert_eq!(proposals[0].instrumental, None);
        assert_eq!(proposals[1].original, 1);
    }

    #[test]
    fn markers_need_whole_words() {
        assert!(is_instrumental("Song (Off Vocal)"));
        assert!(is_instrumental("Song_カラオケ"));
        assert!(is_instrumental("Song inst"));
        assert!(!is_instrumental("Instinct"));
        assert!(!is_instrumental("Mr Brightside"));
    }
}
