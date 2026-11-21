/// Letters (Unicode `Alphabetic`, which includes the vowel signs of Indic and
/// Thai scripts) and numbers: what Rust's `char::is_alphanumeric` keeps.
final _keep = RegExp(r'[\p{Alphabetic}\p{N}]', unicode: true);

/// Lowercase letters and digits of any script, everything else dropped.
/// Must match `kalao_core::search_keys::normalize` in Rust, which builds the
/// stored keys, so a query matches the same way it was indexed.
String normalizeSearchText(String text) =>
    _keep.allMatches(text).map((match) => match.group(0)!).join().toLowerCase();
