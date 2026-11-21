//! Player methods (IMPLEMENTATION.md §1, "Player") over the process-wide
//! `kalao-audio` engine, and the state publisher behind the
//! `player_position_stream` event channel: Kotlin subscribes a sink, and a
//! publisher thread sends the state whenever it changes (every 33 ms while
//! playing, at once after a command).

use crate::backend::{BackendError, invalid, operation, str_arg};
use kalao_audio::{Engine, Media, Output, SourceKind};
use serde_json::Value;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, MutexGuard, OnceLock, PoisonError};
use std::thread::Thread;
use std::time::Duration;

const PLAYING_INTERVAL: Duration = Duration::from_millis(33);
const IDLE_INTERVAL: Duration = Duration::from_millis(250);

/// Receives the engine state (`playerState` JSON) each time it changes.
#[uniffi::export(callback_interface)]
pub trait PlayerStateSink: Send + Sync {
    fn on_state(&self, state_json: String);
}

fn sink() -> MutexGuard<'static, Option<Box<dyn PlayerStateSink>>> {
    static SINK: Mutex<Option<Box<dyn PlayerStateSink>>> = Mutex::new(None);
    SINK.lock().unwrap_or_else(PoisonError::into_inner)
}

/// The new subscriber gets the current state even if it did not change.
static RESEND: AtomicBool = AtomicBool::new(false);

fn publisher() -> &'static Thread {
    static PUBLISHER: OnceLock<Thread> = OnceLock::new();
    PUBLISHER.get_or_init(|| {
        std::thread::Builder::new()
            .name("kalao-state".into())
            .spawn(publish_states)
            .map(|handle| handle.thread().clone())
            .unwrap_or_else(|_| std::thread::current())
    })
}

/// Replaces the subscriber; the state is sent to it right away.
#[uniffi::export]
pub fn player_subscribe(sink_impl: Box<dyn PlayerStateSink>) {
    *sink() = Some(sink_impl);
    RESEND.store(true, Ordering::Release);
    publisher().unpark();
}

#[uniffi::export]
pub fn player_unsubscribe() {
    *sink() = None;
}

fn publish_states() {
    let mut last = String::new();
    loop {
        let state = engine().state();
        let playing = state["playing"] == true;
        let json = state.to_string();
        let resend = RESEND.swap(false, Ordering::AcqRel);
        if resend || json != last {
            if let Some(sink) = sink().as_ref() {
                sink.on_state(json.clone());
            }
            last = json;
        }
        std::thread::park_timeout(if playing {
            PLAYING_INTERVAL
        } else {
            IDLE_INTERVAL
        });
    }
}

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
                    let kind = kind(method, source["kind"].as_str().unwrap_or_default())?;
                    // A file, or a stream an extension resolved (FEATURES 1.8).
                    let media = match source["path"].as_str().filter(|path| !path.is_empty()) {
                        Some(path) => Media::File(PathBuf::from(path)),
                        None if source["url"].is_string() => {
                            crate::extensions::stream_media(source).map_err(operation)?
                        }
                        None => return Err(invalid(method, "source without path or url")),
                    };
                    Ok((kind, media))
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
    // Commands change the state: publish it now, not at the next tick.
    publisher().unpark();
    Ok(engine.state())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::Arc;
    use std::sync::mpsc::{Sender, channel};

    struct Collect(Mutex<Sender<String>>);

    impl PlayerStateSink for Arc<Collect> {
        fn on_state(&self, state_json: String) {
            let _ = self.0.lock().unwrap().send(state_json);
        }
    }

    #[test]
    fn subscriber_receives_the_state_at_once() {
        let (send, receive) = channel();
        player_subscribe(Box::new(Arc::new(Collect(Mutex::new(send)))));
        let state = receive
            .recv_timeout(Duration::from_secs(2))
            .expect("state published");
        let state: Value = serde_json::from_str(&state).unwrap();
        assert_eq!(state["playing"], false);
        player_unsubscribe();
    }

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
