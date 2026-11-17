//! Traditional ↔ Simplified Chinese (FEATURES 2.5) with OpenCC dictionaries
//! through `ferrous-opencc`: `s2t`, `s2tw`, `s2hk` and `t2s`. These are
//! character-variant conversions (no regional vocabulary), so a converted
//! line normally keeps its length and readings stay aligned.

use ferrous_opencc::OpenCC;
use ferrous_opencc::config::BuiltinConfig;
use std::sync::OnceLock;

/// A conversion direction, named as in OpenCC.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Variant {
    /// Simplified → Traditional (OpenCC standard).
    S2t,
    /// Simplified → Traditional as used in Taiwan.
    S2tw,
    /// Simplified → Traditional as used in Hong Kong.
    S2hk,
    /// Traditional → Simplified.
    T2s,
}

impl Variant {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "s2t" => Some(Self::S2t),
            "s2tw" => Some(Self::S2tw),
            "s2hk" => Some(Self::S2hk),
            "t2s" => Some(Self::T2s),
            _ => None,
        }
    }

    fn converter(self) -> Option<&'static OpenCC> {
        static CONVERTERS: [OnceLock<Option<OpenCC>>; 4] = [
            OnceLock::new(),
            OnceLock::new(),
            OnceLock::new(),
            OnceLock::new(),
        ];
        let (slot, config) = match self {
            Self::S2t => (0, BuiltinConfig::S2t),
            Self::S2tw => (1, BuiltinConfig::S2tw),
            Self::S2hk => (2, BuiltinConfig::S2hk),
            Self::T2s => (3, BuiltinConfig::T2s),
        };
        CONVERTERS[slot]
            .get_or_init(|| OpenCC::from_config(config).ok())
            .as_ref()
    }
}

/// `text` in the target variant; unchanged if the dictionary is unavailable.
pub fn convert(text: &str, variant: Variant) -> String {
    match variant.converter() {
        Some(converter) => converter.convert(text),
        None => text.to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn converts_between_simplified_and_traditional() {
        assert_eq!(convert("月亮代表我的心", Variant::S2t), "月亮代表我的心");
        assert_eq!(
            convert("爱情里没有谁对谁错", Variant::S2t),
            "愛情裏沒有誰對誰錯"
        );
        assert_eq!(
            convert("愛情裡沒有誰對誰錯", Variant::T2s),
            "爱情里没有谁对谁错"
        );
        // Regional standards differ in a few characters.
        assert_eq!(convert("爱情里", Variant::S2tw), "愛情裡");
        assert_eq!(convert("为什么", Variant::S2hk), "為什麼");
        // Other scripts pass through, and lengths are kept.
        let mixed = "Hello 头发 123";
        let converted = convert(mixed, Variant::S2t);
        assert_eq!(converted, "Hello 頭髮 123");
        assert_eq!(
            converted.encode_utf16().count(),
            mixed.encode_utf16().count()
        );
        assert_eq!(Variant::parse("t2s"), Some(Variant::T2s));
        assert_eq!(Variant::parse("s2twp"), None);
    }
}
