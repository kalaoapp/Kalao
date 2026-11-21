//! Lyrics methods: `parseLyrics` (LRC, enhanced LRC, TTML or plain text →
//! lyric document), `exportLyrics` (document → LRC or enhanced LRC),
//! `detectSections`, `annotateLyrics` (pinyin, furigana, romaji) and
//! `convertChinese` (Traditional ↔ Simplified).

use crate::backend::{BackendError, invalid, operation, str_arg};
use kalao_core::{annotate, lyrics::doc, sections};
use serde_json::{Value, json};

fn lines<'a>(method: &str, args: &'a Value) -> Result<Vec<&'a str>, BackendError> {
    args["lines"]
        .as_array()
        .ok_or_else(|| invalid(method, "missing array field lines"))?
        .iter()
        .map(|line| {
            line.as_str()
                .ok_or_else(|| invalid(method, "lines must be strings"))
        })
        .collect()
}

pub fn parse(method: &str, args: &Value) -> Result<Value, BackendError> {
    let raw = args["raw"]
        .as_str()
        .ok_or_else(|| invalid(method, "missing string field raw"))?;
    let format = args["format"].as_str();
    if let Some(format) = format
        && !matches!(format, "lrc" | "elrc" | "ttml" | "plain")
    {
        return Err(invalid(method, format!("unknown format {format}")));
    }
    let doc = doc::parse(raw, format).map_err(operation)?;
    serde_json::to_value(doc).map_err(operation)
}

/// `{doc, format}` -> `{text}`: the document as LRC or enhanced LRC.
pub fn export(method: &str, args: &Value) -> Result<Value, BackendError> {
    let doc: doc::LyricDoc = serde_json::from_value(args["doc"].clone())
        .map_err(|error| invalid(method, format!("invalid doc: {error}")))?;
    let format = str_arg(method, args, "format")?;
    if !matches!(format, "lrc" | "elrc") {
        return Err(invalid(method, format!("unknown format {format}")));
    }
    let text = doc::export(&doc, format).map_err(operation)?;
    Ok(json!({ "text": text }))
}

pub fn detect_sections(method: &str, args: &Value) -> Result<Value, BackendError> {
    let detected: Vec<Value> = sections::detect(&lines(method, args)?)
        .into_iter()
        .map(|line| {
            json!({
                "text": line.text,
                "section": line.section,
                "sectionBreakBefore": line.section_break_before,
            })
        })
        .collect();
    Ok(Value::Array(detected))
}

/// `{lines, layers?}` → `{sourceLang, layers}`: the lyrics' language (`ja`,
/// `zh` or null, from kana and Han characters) and one entry per line and
/// layer that has segments. Without `layers` the language picks them
/// (furigana and romaji for `ja`, pinyin for `zh`).
pub fn annotate(method: &str, args: &Value) -> Result<Value, BackendError> {
    let lines = lines(method, args)?;
    let language = annotate::source_language(&lines);
    let layers: Vec<&str> = match args["layers"].as_array() {
        Some(layers) => layers.iter().filter_map(Value::as_str).collect(),
        None => annotate::layers_for(language).to_vec(),
    };
    let mut out = Vec::new();
    for layer in layers {
        let annotate: fn(&str) -> Vec<annotate::RubySegment> = match layer {
            "pinyin" => annotate::pinyin::annotate,
            "furigana" => annotate::japanese::furigana,
            "romaji" => annotate::japanese::romaji,
            other => return Err(invalid(method, format!("unsupported layer {other}"))),
        };
        for (index, line) in lines.iter().enumerate() {
            let segments = annotate(line);
            if !segments.is_empty() {
                out.push(json!({
                    "lineIndex": index,
                    "kind": layer,
                    "origin": "auto",
                    "segments": segments,
                }));
            }
        }
    }
    Ok(json!({"sourceLang": language, "layers": out}))
}

/// `{texts, to}` -> the texts in the Chinese variant `to` (`s2t`, `s2tw`,
/// `s2hk`, `t2s`), in order.
pub fn convert_chinese(method: &str, args: &Value) -> Result<Value, BackendError> {
    let to = str_arg(method, args, "to")?;
    let variant = annotate::chinese_variant::Variant::parse(to)
        .ok_or_else(|| invalid(method, format!("unknown variant {to}")))?;
    let texts = args["texts"]
        .as_array()
        .ok_or_else(|| invalid(method, "missing array field texts"))?
        .iter()
        .map(|text| {
            text.as_str()
                .map(|text| Value::String(annotate::chinese_variant::convert(text, variant)))
                .ok_or_else(|| invalid(method, "texts must be strings"))
        })
        .collect::<Result<Vec<_>, _>>()?;
    Ok(Value::Array(texts))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn methods_round_trip_json() {
        let doc = parse("parseLyrics", &json!({"raw": "[00:01.00]你好"})).unwrap();
        assert_eq!(doc["timed"], true);
        assert_eq!(doc["lines"][0]["timeMs"], 1000);
        let reply = annotate(
            "annotateLyrics",
            &json!({"lines": ["你好", "hello"], "layers": ["pinyin"]}),
        )
        .unwrap();
        assert_eq!(reply["sourceLang"], "zh");
        let layers = &reply["layers"];
        assert_eq!(layers.as_array().unwrap().len(), 1);
        assert_eq!(layers[0]["segments"][1]["reading"], "hǎo");
        let none = annotate("annotateLyrics", &json!({"lines": ["hello"]})).unwrap();
        assert!(none["sourceLang"].is_null());
        assert_eq!(none["layers"], json!([]));
        let sections =
            detect_sections("detectSections", &json!({"lines": ["[Chorus]", "la"]})).unwrap();
        assert_eq!(sections[0]["section"], "chorus");
        assert!(
            annotate(
                "annotateLyrics",
                &json!({"lines": ["x"], "layers": ["klingon"]})
            )
            .is_err()
        );
        assert!(parse("parseLyrics", &json!({"raw": "x", "format": "ttml"})).is_err());
        assert!(parse("parseLyrics", &json!({"raw": "x", "format": "docx"})).is_err());
    }

    #[test]
    fn japanese_layers_and_chinese_variants() {
        // Kana makes the lyrics Japanese: furigana and romaji, no pinyin.
        let reply = annotate("annotateLyrics", &json!({"lines": ["桜が咲く"]})).unwrap();
        assert_eq!(reply["sourceLang"], "ja");
        let layers = &reply["layers"];
        assert_eq!(layers.as_array().unwrap().len(), 2);
        assert_eq!(layers[0]["kind"], "furigana");
        assert_eq!(layers[0]["segments"][0]["reading"], "さくら");
        assert_eq!(layers[1]["kind"], "romaji");
        assert_eq!(layers[1]["segments"][0]["reading"], "sakura");
        let converted = convert_chinese(
            "convertChinese",
            &json!({"texts": ["爱", "hello"], "to": "s2t"}),
        )
        .unwrap();
        assert_eq!(converted, json!(["愛", "hello"]));
        assert!(convert_chinese("convertChinese", &json!({"texts": [], "to": "x"})).is_err());
        assert!(convert_chinese("convertChinese", &json!({"to": "t2s"})).is_err());
    }

    #[test]
    fn export_round_trips_the_parsed_document() {
        let raw = "[00:01.00]<00:01.00>你<00:01.50>好<00:02.00>
";
        let doc = parse("parseLyrics", &json!({ "raw": raw })).unwrap();
        assert_eq!(doc["format"], "elrc");
        assert_eq!(doc["lines"][0]["words"][1]["timeMs"], 1500);
        assert_eq!(doc["lines"][0]["words"][1]["start"], 1);
        let text = export("exportLyrics", &json!({"doc": doc, "format": "elrc"})).unwrap();
        assert_eq!(text["text"], raw);
        let lrc = export("exportLyrics", &json!({"doc": doc, "format": "lrc"})).unwrap();
        assert_eq!(
            lrc["text"],
            "[00:01.00]你好
"
        );
        assert!(export("exportLyrics", &json!({"doc": doc, "format": "ttml"})).is_err());
        assert!(export("exportLyrics", &json!({"doc": 3, "format": "lrc"})).is_err());
    }
}
