//! `kalao.html.parse`: CSS selection over HTML, in Rust (scraper).

use scraper::{Html, Selector};
use serde_json::{Map, Value, json};

/// At most this many elements per `select`.
const MAX_MATCHES: usize = 2000;

/// Elements matching `selector` in `html` (a document, or a fragment such as
/// an element's own markup), each as `{text, html, outerHtml, attrs}`.
pub fn select(html: &str, selector: &str, fragment: bool) -> Result<Value, String> {
    let selector =
        Selector::parse(selector).map_err(|error| format!("invalid CSS selector: {error}"))?;
    let document = if fragment {
        Html::parse_fragment(html)
    } else {
        Html::parse_document(html)
    };
    let elements: Vec<Value> = document
        .select(&selector)
        .take(MAX_MATCHES)
        .map(|element| {
            let attrs: Map<String, Value> = element
                .value()
                .attrs()
                .map(|(name, value)| (name.to_owned(), Value::String(value.to_owned())))
                .collect();
            json!({
                "text": element.text().collect::<String>(),
                "html": element.inner_html(),
                "outerHtml": element.html(),
                "attrs": attrs,
            })
        })
        .collect();
    Ok(Value::Array(elements))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn selects_text_attributes_and_nested_markup() {
        let html = r#"<html><body><ul><li class="song"><a href="/1">One</a></li>
            <li class="song"><a href="/2">Two <b>2</b></a></li></ul></body></html>"#;
        let links = select(html, "li.song a", false).unwrap();
        assert_eq!(links[0]["text"], "One");
        assert_eq!(links[1]["attrs"]["href"], "/2");
        let nested = select(links[1]["outerHtml"].as_str().unwrap(), "b", true).unwrap();
        assert_eq!(nested[0]["text"], "2");
        assert!(select(html, "li[", false).is_err());
    }
}
