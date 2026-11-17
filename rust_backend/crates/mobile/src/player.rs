//! Player methods (IMPLEMENTATION.md §1, "Player") over the process-wide
//! `kalao-audio` engine. Kotlin polls `playerState` for the
//! `player_position_stream` event channel.

use crate::backend::{BackendError, invalid, operation, str_arg};
use kalao_audio::{Engine, Output, SourceKind};
use serde_json::Value;
use std::path::PathBuf;
use std::sync::OnceLock;

fn engine() -> &'static Engine {
    static ENGINE: OnceLock<Engine> = OnceLock::new();
    ENGINE.get_or_init(|| Engine::new(Output::Device))
}

fn kind(method: &str, value: &str) -> Result<SourceKind, BackendError> {
    SourceKind::parse(value).ok_or_else(|| invalid(method, format!("unknown source kind {value}")))
}

fn level(args: &Value, name: &str) -> Option<f32> {
    args[name].as_f64().map(|value| value as f32)
}

pub fn dispatch(method: &str, args: &Value) -> Result<Value, BackendError> {
    let engine = engine();
    match method {
        "playerLoad" => {
            let song_id = str_arg(method, args, "songId")?;
            let sources = args["sources"]
                .as_array()
                .ok_or_else(|| invalid(method, "missing array field sources"))?
                .iter()
                .map(|source| {
                    let path = source["path"]
                        .as_str()
                        .filter(|path| !path.is_empty())
                        .ok_or_else(|| invalid(method, "source without path"))?;
                    Ok((
                        kind(method, source["kind"].as_str().unwrap_or_default())?,
                        PathBuf::from(path),
                    ))
                })
                .collect::<Result<Vec<_>, BackendError>>()?;
            let start_ms = args["startMs"].as_u64().unwrap_or(0);
            engine
                .load(song_id, &sources, start_ms)
                .map_err(operation)?;
            crate::logging::info(
                "Player",
                &format!("loaded {song_id} ({} sources)", sources.len()),
            );
        }
        "playerPlay" => engine.play().map_err(operation)?,
        "playerPause" => engine.pause(),
        "playerStop" => engine.stop(),
        "playerSeek" => {
            let ms = args["ms"]
                .as_u64()
                .ok_or_else(|| invalid(method, "missing integer field ms"))?;
            engine.seek(ms).map_err(operation)?;
        }
        "playerSetVolume" => engine.set_volume(
            level(args, "volume").ok_or_else(|| invalid(method, "missing number field volume"))?,
        ),
        "playerSetStemGains" => {
            engine.set_stem_gains(level(args, "vocals"), level(args, "instrumental"))
        }
        "playerSetKey" => engine
            .set_key(
                level(args, "semitones")
                    .ok_or_else(|| invalid(method, "missing number field semitones"))?,
            )
            .map_err(operation)?,
        "playerSetLoop" => {
            let range = match (args["startMs"].as_u64(), args["endMs"].as_u64()) {
                (Some(start), Some(end)) => Some((start, end)),
                (None, None) => None,
                _ => return Err(invalid(method, "startMs and endMs go together")),
            };
            engine.set_loop(range).map_err(operation)?;
        }
        "playerSetTempo" => engine
            .set_tempo(
                level(args, "rate").ok_or_else(|| invalid(method, "missing number field rate"))?,
            )
            .map_err(operation)?,
        "playerSwitchTrack" => engine
            .switch_track(kind(method, str_arg(method, args, "kind")?)?)
            .map_err(operation)?,
        "playerState" => return Ok(engine.state()),
        _ => return Err(BackendError::UnknownMethod(method.to_owned())),
    }
    Ok(engine.state())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn state_without_a_song_and_argument_errors() {
        let state = dispatch("playerState", &json!({})).unwrap();
        assert_eq!(state["playing"], false);
        assert!(state["songId"].is_null());
        assert!(matches!(
            dispatch(
                "playerLoad",
                &json!({"songId": "a", "sources": [{"kind": "x", "path": "p"}]})
            ),
            Err(BackendError::InvalidArguments { .. })
        ));
        assert!(matches!(
            dispatch("playerSeek", &json!({})),
            Err(BackendError::InvalidArguments { .. })
        ));
        assert!(matches!(
            dispatch("playerPlay", &json!({})),
            Err(BackendError::Operation(_))
        ));
        assert!(matches!(
            dispatch("playerNope", &json!({})),
            Err(BackendError::UnknownMethod(_))
        ));
    }
}
