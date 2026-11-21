//! Capability calls across extensions (EXTENSIONS.md §6, IMPLEMENTATION.md
//! §10): every enabled provider is asked in parallel, results are validated,
//! scored and merged; the user's priority order breaks ties.

use super::Manager;
use crate::Error;
use crate::capabilities::{self, Query};
use crate::manifest::Capability;
use serde_json::{Value, json};
use std::time::Duration;

/// Per-extension time for searches (IMPLEMENTATION.md §10: 6 s).
pub const SEARCH_TIMEOUT: Duration = Duration::from_secs(6);
const ITEM_TIMEOUT: Duration = Duration::from_secs(10);

impl Manager {
    fn ask_all(
        &self,
        capability: Capability,
        function: &str,
        argument: &Value,
        timeout: Duration,
    ) -> Vec<(usize, String, Result<Value, Error>)> {
        let providers = self.providers(capability);
        std::thread::scope(|scope| {
            let handles: Vec<_> = providers
                .iter()
                .enumerate()
                .map(|(rank, id)| {
                    scope.spawn(move || {
                        (rank, id.clone(), self.call(id, function, argument, timeout))
                    })
                })
                .collect();
            handles
                .into_iter()
                .filter_map(|handle| handle.join().ok())
                .collect()
        })
    }

    fn drop_report(&self, id: &str, function: &str, dropped: &[String]) {
        if !dropped.is_empty() {
            self.log(id).push(
                id,
                "warn",
                &format!(
                    "{function}: dropped invalid results: {}",
                    dropped.join("; ")
                ),
                &[],
            );
        }
    }

    /// Ranked lyrics candidates from every enabled lyrics extension.
    pub fn search_lyrics(&self, query: &Query) -> Value {
        let argument = serde_json::to_value(query).unwrap_or(Value::Null);
        let mut candidates = Vec::new();
        let mut errors = Vec::new();
        for (rank, id, result) in self.ask_all(
            Capability::Lyrics,
            "searchLyrics",
            &argument,
            SEARCH_TIMEOUT,
        ) {
            let name = self.display_name(&id);
            match result
                .map_err(|e| e.to_string())
                .and_then(|value| capabilities::lyrics_candidates(&value))
            {
                Ok((valid, dropped)) => {
                    self.drop_report(&id, "searchLyrics", &dropped);
                    for candidate in valid {
                        let score = capabilities::lyrics_score(query, &candidate);
                        candidates.push((score, rank, id.clone(), name.clone(), candidate));
                    }
                }
                Err(error) => {
                    errors.push(json!({ "extensionId": id, "name": name, "message": error }))
                }
            }
        }
        candidates.sort_by(|a, b| b.0.total_cmp(&a.0).then(a.1.cmp(&b.1)));
        json!({
            "candidates": candidates
                .into_iter()
                .map(|(score, _, id, name, candidate)| {
                    let mut value = serde_json::to_value(candidate).unwrap_or(Value::Null);
                    value["extensionId"] = json!(id);
                    value["extensionName"] = json!(name);
                    value["score"] = json!((score * 1000.0).round() / 1000.0);
                    value
                })
                .collect::<Vec<_>>(),
            "errors": errors,
        })
    }

    /// The text of a candidate that came without a body.
    pub fn get_lyrics(&self, id: &str, item: &str) -> Result<Value, Error> {
        let value = self.call(id, "getLyrics", &json!(item), ITEM_TIMEOUT)?;
        let candidate = capabilities::lyrics_body(&value).map_err(Error::Script)?;
        let mut value = serde_json::to_value(candidate).unwrap_or(Value::Null);
        value["extensionId"] = json!(id);
        Ok(value)
    }

    /// Tracks from every enabled metadata extension, merged: the same song
    /// from several sources appears once, from the highest-priority one,
    /// with the others under `alternatives`.
    pub fn search_tracks(&self, query: &Query) -> Value {
        let argument = serde_json::to_value(query).unwrap_or(Value::Null);
        let mut found: Vec<(f64, usize, String, String, capabilities::Track)> = Vec::new();
        let mut errors = Vec::new();
        for (rank, id, result) in self.ask_all(
            Capability::Metadata,
            "searchTracks",
            &argument,
            SEARCH_TIMEOUT,
        ) {
            let name = self.display_name(&id);
            match result
                .map_err(|e| e.to_string())
                .and_then(|value| capabilities::tracks(&value))
            {
                Ok((valid, dropped)) => {
                    self.drop_report(&id, "searchTracks", &dropped);
                    for track in valid {
                        let artist = track.artists.join(", ");
                        let score = capabilities::match_score(
                            query,
                            &track.title,
                            &artist,
                            track.duration_ms,
                        );
                        found.push((score, rank, id.clone(), name.clone(), track));
                    }
                }
                Err(error) => {
                    errors.push(json!({ "extensionId": id, "name": name, "message": error }))
                }
            }
        }
        // Highest priority first, so the kept copy of a duplicate is the
        // preferred source; then by score for display.
        found.sort_by(|a, b| a.1.cmp(&b.1).then(b.0.total_cmp(&a.0)));
        let mut merged: Vec<(f64, Value)> = Vec::new();
        let mut keys: Vec<String> = Vec::new();
        for (score, _, id, name, track) in found {
            let key = match &track.isrc {
                Some(isrc) if !isrc.is_empty() => format!("isrc:{}", isrc.to_uppercase()),
                _ => format!(
                    "{}|{}",
                    capabilities::match_key(&track.title),
                    capabilities::match_key(track.artists.first().map_or("", String::as_str))
                ),
            };
            let mut value = serde_json::to_value(&track).unwrap_or(Value::Null);
            value["extensionId"] = json!(id);
            value["extensionName"] = json!(name);
            if let Some(index) = keys.iter().position(|existing| *existing == key) {
                let kept = &mut merged[index].1;
                if kept["alternatives"].is_null() {
                    kept["alternatives"] = json!([]);
                }
                if let Some(list) = kept["alternatives"].as_array_mut() {
                    list.push(json!({ "extensionId": id, "id": track.id, "extensionName": name }));
                }
                // Fill gaps from the other source.
                for field in [
                    "album",
                    "durationMs",
                    "isrc",
                    "language",
                    "artworkUrl",
                    "year",
                ] {
                    if kept[field].is_null() && !value[field].is_null() {
                        kept[field] = value[field].clone();
                    }
                }
                merged[index].0 = merged[index].0.max(score);
            } else {
                value["score"] = json!((score * 1000.0).round() / 1000.0);
                keys.push(key);
                merged.push((score, value));
            }
        }
        merged.sort_by(|a, b| b.0.total_cmp(&a.0));
        json!({
            "tracks": merged.into_iter().map(|(_, value)| value).collect::<Vec<_>>(),
            "errors": errors,
        })
    }

    pub fn get_track(&self, id: &str, item: &str) -> Result<Value, Error> {
        let value = self.call(id, "getTrack", &json!(item), ITEM_TIMEOUT)?;
        let track = capabilities::single_track(&value).map_err(Error::Script)?;
        let mut value = serde_json::to_value(track).unwrap_or(Value::Null);
        value["extensionId"] = json!(id);
        value["extensionName"] = json!(self.display_name(id));
        Ok(value)
    }

    /// Artwork for a track: from `id` when given, else the first artwork
    /// extension (in priority order) that has some.
    pub fn get_artwork(&self, id: Option<&str>, track: &Value) -> Result<Value, Error> {
        let providers = match id {
            Some(id) => vec![id.to_owned()],
            None => self.providers(Capability::Artwork),
        };
        let mut last_error = None;
        for provider in providers {
            match self
                .call(&provider, "getArtwork", track, ITEM_TIMEOUT)
                .and_then(|value| capabilities::images(&value).map_err(Error::Script))
            {
                Ok(images) if !images.is_empty() => {
                    return Ok(json!({ "extensionId": provider, "images": images }));
                }
                Ok(_) => {}
                Err(error) => last_error = Some(error),
            }
        }
        match last_error {
            Some(error) => Err(error),
            None => Ok(json!({ "extensionId": null, "images": [] })),
        }
    }

    /// Streamable sources for a track from one audio extension.
    pub fn resolve_audio(&self, id: &str, track: &Value) -> Result<Value, Error> {
        let instance = self.instance(id)?;
        if !instance.manifest.has(Capability::Audio) {
            return Err(Error::Invalid(format!("{id} does not provide audio")));
        }
        let value = self.call(id, "resolveAudio", track, ITEM_TIMEOUT)?;
        let sources = capabilities::audio_sources(&value).map_err(Error::Script)?;
        Ok(json!({ "extensionId": id, "sources": sources }))
    }
}
