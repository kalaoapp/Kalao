//! Kalao's playback engine: up to three sources per song (original,
//! instrumental, vocals) decoded by Symphonia, resampled with rubato to the
//! output rate, buffered in SPSC rings and mixed on one clock, so stems never
//! drift. See `android/docs/IMPLEMENTATION.md` §2.

mod decoder;
mod mixer;
mod output;
mod source;

pub use decoder::{Probe, probe_file};
pub use mixer::{Layout, soft_limit};

use mixer::Mixer;
use serde_json::{Value, json};
use source::Source;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

/// Ring size per source: about 0.5 s at 48 kHz.
const RING_FRAMES: usize = 24_000;
/// Gain changes from sliders and volume.
const GAIN_RAMP_MS: u32 = 10;
/// Original ↔ instrumental switch.
const SWITCH_RAMP_MS: u32 = 150;

#[derive(Debug, thiserror::Error)]
pub enum AudioError {
    #[error("Cannot open audio: {0}")]
    Open(String),
    #[error("Unsupported audio: {0}")]
    Unsupported(String),
    #[error("Decode failed: {0}")]
    Decode(String),
    #[error("Audio output failed: {0}")]
    Output(String),
    #[error("{0}")]
    Invalid(String),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SourceKind {
    Original,
    Instrumental,
    Vocals,
}

impl SourceKind {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "original" => Some(Self::Original),
            "instrumental" => Some(Self::Instrumental),
            "vocals" => Some(Self::Vocals),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Original => "original",
            Self::Instrumental => "instrumental",
            Self::Vocals => "vocals",
        }
    }
}

struct Session {
    song_id: String,
    sources: Vec<Source>,
    kinds: Vec<SourceKind>,
    layout: Layout,
    duration_ms: Option<u64>,
}

/// State shared by the control thread and the audio callback.
struct Shared {
    session: Mutex<Option<Session>>,
    mixer: Mutex<Mixer>,
    playing: AtomicBool,
    seeking: AtomicBool,
    completed: AtomicBool,
    buffering: AtomicBool,
    /// Song position in thousandths of an output frame: each rendered frame
    /// adds the tempo in permille, so it advances in song time.
    position: AtomicU64,
    /// Playback speed in permille (1000 = normal).
    tempo: AtomicU32,
    output_rate: AtomicU32,
    latency_us: AtomicU64,
    vocal_target: AtomicU32,
    backing_target: AtomicU32,
    volume_target: AtomicU32,
    vocal_ramp_ms: AtomicU32,
    mix_generation: AtomicU32,
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

fn store_f32(atomic: &AtomicU32, value: f32) {
    atomic.store(value.to_bits(), Ordering::Release);
}

fn load_f32(atomic: &AtomicU32) -> f32 {
    f32::from_bits(atomic.load(Ordering::Acquire))
}

impl Shared {
    /// Fills `out` (interleaved, `channels` per frame). Called from the audio
    /// callback: never blocks, never allocates once warmed up.
    fn render(&self, out: &mut [f32], channels: usize) {
        out.fill(0.0);
        let channels = channels.max(1);
        let frames = out.len() / channels;
        if frames == 0
            || !self.playing.load(Ordering::Acquire)
            || self.seeking.load(Ordering::Acquire)
        {
            return;
        }
        let Ok(session) = self.session.try_lock() else {
            return;
        };
        let Some(session) = session.as_ref() else {
            return;
        };
        let Ok(mut mixer) = self.mixer.try_lock() else {
            return;
        };
        // At most three sources; a fixed array keeps the callback allocation-free.
        let mut consumers: [Option<MutexGuard<'_, ringbuf::HeapCons<f32>>>; 3] = [None, None, None];
        for (slot, source) in consumers.iter_mut().zip(&session.sources) {
            let Ok(consumer) = source.shared.consumer.try_lock() else {
                return;
            };
            *slot = Some(consumer);
        }
        let count = session.sources.len().min(3);
        let consumers = &mut consumers[..count];

        use ringbuf::traits::{Consumer, Observer};
        let mut all_done = true;
        for (consumer, source) in consumers.iter().zip(&session.sources) {
            let consumer = consumer.as_ref().expect("filled above");
            let available = consumer.occupied_len() / 2;
            let ended = source.shared.ended.load(Ordering::Acquire);
            if available < frames && !ended {
                // Underrun: wait for every source so they stay sample-aligned.
                self.buffering.store(true, Ordering::Release);
                return;
            }
            all_done &= ended && available == 0;
        }
        self.buffering.store(false, Ordering::Release);
        if all_done {
            self.playing.store(false, Ordering::Release);
            self.completed.store(true, Ordering::Release);
            return;
        }

        self.apply_mix_targets(&mut mixer);
        if mixer.scratch.len() < count {
            mixer.scratch.resize_with(count, Vec::new);
        }
        for (consumer, scratch) in consumers.iter_mut().zip(mixer.scratch.iter_mut()) {
            let consumer = consumer.as_mut().expect("filled above");
            scratch.resize(frames * 2, 0.0);
            let read = consumer.pop_slice(&mut scratch[..frames * 2]);
            scratch[read..].fill(0.0);
        }
        let mut bus = std::mem::take(&mut mixer.bus);
        bus.resize(frames * 2, 0.0);
        mixer.mix(session.layout, &session.kinds, frames, &mut bus);
        write_channels(&bus, out, channels);
        mixer.bus = bus;
        let tempo = u64::from(self.tempo.load(Ordering::Acquire));
        self.position
            .fetch_add(frames as u64 * tempo, Ordering::AcqRel);
    }

    fn apply_mix_targets(&self, mixer: &mut Mixer) {
        let generation = self.mix_generation.load(Ordering::Acquire);
        if generation == mixer.mix_generation {
            return;
        }
        mixer.mix_generation = generation;
        let rate = self.output_rate.load(Ordering::Acquire);
        let frames = |ms: u32| (u64::from(rate) * u64::from(ms) / 1000) as u32;
        let vocal_ramp = self.vocal_ramp_ms.load(Ordering::Acquire);
        mixer
            .vocal
            .set(load_f32(&self.vocal_target), frames(vocal_ramp));
        mixer
            .backing
            .set(load_f32(&self.backing_target), frames(GAIN_RAMP_MS));
        mixer
            .volume
            .set(load_f32(&self.volume_target), frames(GAIN_RAMP_MS));
    }

    fn bump_mix(&self) {
        self.mix_generation.fetch_add(1, Ordering::AcqRel);
    }
}

fn write_channels(stereo: &[f32], out: &mut [f32], channels: usize) {
    match channels {
        1 => out
            .iter_mut()
            .zip(stereo.as_chunks::<2>().0.iter())
            .for_each(|(sample, frame)| *sample = (frame[0] + frame[1]) * 0.5),
        2 => out.copy_from_slice(&stereo[..out.len()]),
        _ => out
            .chunks_exact_mut(channels)
            .zip(stereo.as_chunks::<2>().0.iter())
            .for_each(|(slot, frame)| {
                slot[0] = frame[0];
                slot[1] = frame[1];
            }),
    }
}

/// How the engine produces sound.
pub enum Output {
    /// The default system output through cpal (AAudio on Android).
    Device,
    /// No device; the caller pulls frames with `Engine::render` (tests).
    Manual { sample_rate: u32 },
}

pub struct Engine {
    shared: Arc<Shared>,
    output: Mutex<Option<output::OutputThread>>,
    manual: bool,
}

impl Engine {
    pub fn new(output: Output) -> Self {
        let (rate, manual) = match output {
            Output::Device => (output::PREFERRED_RATE, false),
            Output::Manual { sample_rate } => (sample_rate, true),
        };
        let shared = Arc::new(Shared {
            session: Mutex::new(None),
            mixer: Mutex::new(Mixer::new(1.0, 1.0, 1.0)),
            playing: AtomicBool::new(false),
            seeking: AtomicBool::new(false),
            completed: AtomicBool::new(false),
            buffering: AtomicBool::new(false),
            position: AtomicU64::new(0),
            tempo: AtomicU32::new(1000),
            output_rate: AtomicU32::new(rate),
            latency_us: AtomicU64::new(0),
            vocal_target: AtomicU32::new(1.0f32.to_bits()),
            backing_target: AtomicU32::new(1.0f32.to_bits()),
            volume_target: AtomicU32::new(1.0f32.to_bits()),
            vocal_ramp_ms: AtomicU32::new(GAIN_RAMP_MS),
            mix_generation: AtomicU32::new(0),
        });
        Self {
            shared,
            output: Mutex::new(None),
            manual,
        }
    }

    fn ensure_output(&self) -> Result<(), AudioError> {
        if self.manual {
            return Ok(());
        }
        let mut output = lock(&self.output);
        if output.is_none() {
            let thread = output::OutputThread::start(self.shared.clone())?;
            self.shared
                .output_rate
                .store(thread.sample_rate, Ordering::Release);
            *output = Some(thread);
        }
        Ok(())
    }

    fn command(&self, command: output::Command) {
        if let Some(output) = lock(&self.output).as_ref() {
            output.send(command);
        }
    }

    /// Replaces the current song with `sources` and positions at `start_ms`,
    /// paused. Keeps the vocal level and volume.
    pub fn load(
        &self,
        song_id: &str,
        sources: &[(SourceKind, PathBuf)],
        start_ms: u64,
    ) -> Result<(), AudioError> {
        if sources.is_empty() || sources.len() > 3 {
            return Err(AudioError::Invalid(
                "one to three sources are required".into(),
            ));
        }
        self.ensure_output()?;
        let rate = self.shared.output_rate.load(Ordering::Acquire);
        let mut duration_ms = None;
        let mut opened = Vec::with_capacity(sources.len());
        let mut kinds = Vec::with_capacity(sources.len());
        for (kind, path) in sources {
            if kinds.contains(kind) {
                return Err(AudioError::Invalid(format!(
                    "duplicate {} source",
                    kind.as_str()
                )));
            }
            let probe = probe_file(path)?;
            duration_ms = duration_ms.max(probe.duration_ms);
            let source = Source::open(*kind, path, rate, RING_FRAMES, self.tempo())?;
            if start_ms > 0 {
                source.seek(start_ms)?;
            }
            opened.push(source);
            kinds.push(*kind);
        }
        self.shared.playing.store(false, Ordering::Release);
        self.command(output::Command::Pause);
        let session = Session {
            song_id: song_id.to_owned(),
            layout: Layout::for_kinds(&kinds),
            sources: opened,
            kinds,
            duration_ms,
        };
        let previous = lock(&self.shared.session).replace(session);
        self.shared
            .position
            .store(ms_to_position(start_ms, rate), Ordering::Release);
        self.shared.completed.store(false, Ordering::Release);
        // Join the old decoder threads outside the lock.
        drop(previous);
        Ok(())
    }

    pub fn play(&self) -> Result<(), AudioError> {
        if lock(&self.shared.session).is_none() {
            return Err(AudioError::Invalid("nothing is loaded".into()));
        }
        if self.shared.completed.swap(false, Ordering::AcqRel) {
            self.seek(0)?;
        }
        self.ensure_output()?;
        self.shared.playing.store(true, Ordering::Release);
        self.command(output::Command::Play);
        Ok(())
    }

    pub fn pause(&self) {
        self.shared.playing.store(false, Ordering::Release);
        self.command(output::Command::Pause);
    }

    pub fn stop(&self) {
        self.pause();
        let previous = lock(&self.shared.session).take();
        self.shared.position.store(0, Ordering::Release);
        self.shared.completed.store(false, Ordering::Release);
        drop(previous);
    }

    /// Moves every source to `ms` together.
    pub fn seek(&self, ms: u64) -> Result<(), AudioError> {
        let session = lock(&self.shared.session);
        let Some(current) = session.as_ref() else {
            return Err(AudioError::Invalid("nothing is loaded".into()));
        };
        let ms = current.duration_ms.map_or(ms, |duration| ms.min(duration));
        self.shared.seeking.store(true, Ordering::Release);
        let mut result = Ok(());
        for source in &current.sources {
            if let Err(error) = source.seek(ms) {
                result = Err(error);
            }
        }
        let rate = self.shared.output_rate.load(Ordering::Acquire);
        self.shared
            .position
            .store(ms_to_position(ms, rate), Ordering::Release);
        self.shared.completed.store(false, Ordering::Release);
        self.shared.seeking.store(false, Ordering::Release);
        result
    }

    pub fn set_volume(&self, volume: f32) {
        store_f32(&self.shared.volume_target, volume.clamp(0.0, 1.0));
        self.shared.bump_mix();
    }

    /// Vocal level 0–1 (vocal-guide blend) and, for stems, the backing level.
    pub fn set_stem_gains(&self, vocals: Option<f32>, instrumental: Option<f32>) {
        if let Some(vocals) = vocals {
            store_f32(&self.shared.vocal_target, vocals.clamp(0.0, 1.0));
            self.shared
                .vocal_ramp_ms
                .store(GAIN_RAMP_MS, Ordering::Release);
        }
        if let Some(instrumental) = instrumental {
            store_f32(&self.shared.backing_target, instrumental.clamp(0.0, 1.0));
        }
        self.shared.bump_mix();
    }

    /// Crossfades to the original (vocals on) or instrumental (vocals off).
    pub fn switch_track(&self, kind: SourceKind) -> Result<(), AudioError> {
        let vocal = match kind {
            SourceKind::Original | SourceKind::Vocals => 1.0,
            SourceKind::Instrumental => 0.0,
        };
        store_f32(&self.shared.vocal_target, vocal);
        self.shared
            .vocal_ramp_ms
            .store(SWITCH_RAMP_MS, Ordering::Release);
        self.shared.bump_mix();
        Ok(())
    }

    fn tempo(&self) -> f32 {
        self.shared.tempo.load(Ordering::Acquire) as f32 / 1000.0
    }

    /// Playback speed, 0.5–1.5 (1 = normal). The pitch follows the speed;
    /// positions stay in song time. Buffered audio is dropped so the change
    /// is heard at once.
    pub fn set_tempo(&self, tempo: f32) -> Result<(), AudioError> {
        if !tempo.is_finite() {
            return Err(AudioError::Invalid("tempo must be a number".into()));
        }
        let permille = (tempo.clamp(source::MIN_TEMPO, source::MAX_TEMPO) * 1000.0).round() as u32;
        if self.shared.tempo.swap(permille, Ordering::AcqRel) == permille {
            return Ok(());
        }
        let loaded = {
            let session = lock(&self.shared.session);
            for source in session.iter().flat_map(|session| &session.sources) {
                source.set_tempo(permille as f32 / 1000.0)?;
            }
            session.is_some()
        };
        if loaded {
            self.seek(self.rendered_ms())?;
        }
        Ok(())
    }

    /// Song time of the frames handed to the output so far.
    fn rendered_ms(&self) -> u64 {
        let rate = u64::from(self.shared.output_rate.load(Ordering::Acquire).max(1));
        self.shared.position.load(Ordering::Acquire) / rate
    }

    pub fn position_ms(&self) -> u64 {
        let rendered_ms = self.rendered_ms();
        if self.shared.playing.load(Ordering::Acquire) {
            // What is heard now left the engine one output latency ago.
            let latency_us = self.shared.latency_us.load(Ordering::Acquire);
            let tempo = u64::from(self.shared.tempo.load(Ordering::Acquire));
            rendered_ms.saturating_sub(latency_us * tempo / 1_000_000)
        } else {
            rendered_ms
        }
    }

    /// The state Dart reads for `playerState` and the position stream.
    pub fn state(&self) -> Value {
        let session = lock(&self.shared.session);
        let errors: Vec<String> = session
            .as_ref()
            .map(|session| {
                session
                    .sources
                    .iter()
                    .filter_map(|source| lock(&source.shared.error).clone())
                    .collect()
            })
            .unwrap_or_default();
        json!({
            "songId": session.as_ref().map(|s| s.song_id.clone()),
            "sources": session.as_ref().map(|s| s.kinds.iter().map(|k| k.as_str()).collect::<Vec<_>>()),
            "layout": session.as_ref().map(|s| format!("{:?}", s.layout).to_lowercase()),
            "durationMs": session.as_ref().and_then(|s| s.duration_ms),
            "positionMs": self.position_ms(),
            "playing": self.shared.playing.load(Ordering::Acquire),
            "completed": self.shared.completed.load(Ordering::Acquire),
            "buffering": self.shared.buffering.load(Ordering::Acquire),
            "vocalLevel": load_f32(&self.shared.vocal_target),
            "volume": load_f32(&self.shared.volume_target),
            "tempo": self.tempo(),
            "outputLatencyMs": self.shared.latency_us.load(Ordering::Acquire) / 1000,
            "sampleRate": self.shared.output_rate.load(Ordering::Acquire),
            "error": errors.first(),
        })
    }

    /// Pulls frames as the audio callback would (manual output and tests).
    pub fn render(&self, out: &mut [f32], channels: usize) {
        self.shared.render(out, channels);
    }

    /// Frames buffered by the slowest source (tests wait on this to prefill).
    pub fn min_buffered_frames(&self) -> usize {
        lock(&self.shared.session).as_ref().map_or(0, |session| {
            session
                .sources
                .iter()
                .map(|source| {
                    if source.shared.ended.load(Ordering::Acquire) {
                        usize::MAX
                    } else {
                        source.buffered_frames()
                    }
                })
                .min()
                .unwrap_or(0)
        })
    }
}

fn ms_to_position(ms: u64, rate: u32) -> u64 {
    ms * u64::from(rate)
}

#[cfg(test)]
mod tests;
