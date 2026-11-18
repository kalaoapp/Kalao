//! Kalao's playback engine: up to three sources per song (original,
//! instrumental, vocals) decoded by Symphonia, resampled with rubato to the
//! output rate, buffered in SPSC rings and mixed on one clock, so stems never
//! drift. See `android/docs/IMPLEMENTATION.md` §2.

mod clock;
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
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, PoisonError, Weak};
use std::time::{Duration, Instant};

/// Ring size per source: about 0.5 s at 48 kHz.
const RING_FRAMES: usize = 24_000;
/// Stretcher output reserved up front, in frames (larger than any callback).
const STRETCH_ROOM_FRAMES: usize = 16_384;
/// Gain changes from sliders and volume.
const GAIN_RAMP_MS: u32 = 10;
/// Original ↔ instrumental switch.
const SWITCH_RAMP_MS: u32 = 150;
/// Tempo and key ranges (FEATURES 1.4).
const MIN_TEMPO: f32 = 0.5;
const MAX_TEMPO: f32 = 1.5;
const MAX_KEY_SEMITONES: f32 = 6.0;
/// `loop_range` when no loop is set.
const NO_LOOP: u64 = u64::MAX;
/// The shortest loop: shorter ones would mostly be the seam.
const MIN_LOOP_MS: u64 = 250;

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
    /// Song position in thousandths of an output-rate frame: every source
    /// frame mixed adds 1000, so it advances in song time at any tempo.
    position: AtomicU64,
    /// Bumped whenever `position` jumps (seek, load, stop) or playback
    /// starts, so the reported clock re-anchors (`clock.rs`).
    clock_epoch: AtomicU32,
    /// Playback speed in permille (1000 = normal).
    tempo: AtomicU32,
    /// Transposition in cents (100 = one semitone up).
    key_cents: AtomicI32,
    /// Bumped whenever the stretcher must forget its history (seek, load,
    /// engaging it).
    stretch_generation: AtomicU32,
    /// The stretcher's delay in frames: input latency in the high half,
    /// output latency in the low half.
    stretch_latency: AtomicU64,
    /// Loop start and end in ms (start in the high half), or `NO_LOOP`.
    loop_range: AtomicU64,
    /// The callback reached the loop end; the loop thread seeks to the start.
    loop_pending: AtomicBool,
    loop_thread: OnceLock<std::thread::Thread>,
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
            || self.loop_pending.load(Ordering::Acquire)
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

        // With the stretcher engaged, `frames` of output consume
        // `frames × tempo` source frames; the fraction carries over.
        let tempo = self.tempo.load(Ordering::Acquire);
        let key = self.key_cents.load(Ordering::Acquire);
        let stretching = (tempo != 1000 || key != 0) && mixer.stretch.is_some();
        let frames_out = frames;
        let frames = if stretching {
            let exact = frames as f64 * f64::from(tempo) / 1000.0 + mixer.carry;
            mixer.carry = exact.fract();
            exact as usize
        } else {
            frames
        };

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
        if stretching {
            let mut stretched = std::mem::take(&mut mixer.stretched);
            stretched.resize(frames_out * 2, 0.0);
            let generation = self.stretch_generation.load(Ordering::Acquire);
            let fresh = mixer.stretch_generation != generation;
            mixer.stretch_generation = generation;
            let rekey = mixer.stretch_key != key;
            mixer.stretch_key = key;
            if let Some(stretch) = mixer.stretch.as_mut() {
                if fresh {
                    stretch.reset();
                }
                if rekey || fresh {
                    stretch.set_transpose_factor_semitones(key as f32 / 100.0, None);
                }
                stretch.process(&bus[..frames * 2], &mut stretched[..]);
            }
            write_channels(&stretched, out, channels);
            mixer.stretched = stretched;
        } else {
            write_channels(&bus, out, channels);
        }
        mixer.bus = bus;
        let position = self
            .position
            .fetch_add(frames as u64 * 1000, Ordering::AcqRel)
            + frames as u64 * 1000;
        let range = self.loop_range.load(Ordering::Acquire);
        if range != NO_LOOP {
            let rate = u64::from(self.output_rate.load(Ordering::Acquire).max(1));
            if position / rate >= range & 0xffff_ffff {
                // Decoders cannot be moved from here: hand over to the loop
                // thread and stay silent until it has sought.
                self.loop_pending.store(true, Ordering::Release);
                if let Some(thread) = self.loop_thread.get() {
                    thread.unpark();
                }
            }
        }
    }

    /// Moves every source to `ms` together.
    fn seek(&self, ms: u64) -> Result<(), AudioError> {
        let session = lock(&self.session);
        let Some(current) = session.as_ref() else {
            return Err(AudioError::Invalid("nothing is loaded".into()));
        };
        let ms = current.duration_ms.map_or(ms, |duration| ms.min(duration));
        self.seeking.store(true, Ordering::Release);
        let mut result = Ok(());
        for source in &current.sources {
            if let Err(error) = source.seek(ms) {
                result = Err(error);
            }
        }
        let rate = self.output_rate.load(Ordering::Acquire);
        self.position
            .store(ms_to_position(ms, rate), Ordering::Release);
        self.clock_epoch.fetch_add(1, Ordering::AcqRel);
        self.stretch_generation.fetch_add(1, Ordering::AcqRel);
        self.completed.store(false, Ordering::Release);
        self.seeking.store(false, Ordering::Release);
        result
    }

    /// Runs on the loop thread: seeks back to the loop start whenever the
    /// callback reaches the loop end.
    fn run_loop(shared: &Weak<Shared>) {
        loop {
            std::thread::park_timeout(Duration::from_millis(250));
            let Some(shared) = shared.upgrade() else {
                return;
            };
            if shared.loop_pending.load(Ordering::Acquire) {
                let range = shared.loop_range.load(Ordering::Acquire);
                if range != NO_LOOP {
                    let _ = shared.seek(range >> 32);
                }
                shared.loop_pending.store(false, Ordering::Release);
            }
        }
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
    clock: Mutex<clock::Clock>,
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
            clock_epoch: AtomicU32::new(0),
            tempo: AtomicU32::new(1000),
            key_cents: AtomicI32::new(0),
            stretch_generation: AtomicU32::new(0),
            stretch_latency: AtomicU64::new(0),
            loop_range: AtomicU64::new(NO_LOOP),
            loop_pending: AtomicBool::new(false),
            loop_thread: OnceLock::new(),
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
            clock: Mutex::new(clock::Clock::default()),
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
            let source = Source::open(*kind, path, rate, RING_FRAMES)?;
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
        self.shared.clock_epoch.fetch_add(1, Ordering::AcqRel);
        self.shared.completed.store(false, Ordering::Release);
        // A loop belongs to the song it was set on.
        self.shared.loop_range.store(NO_LOOP, Ordering::Release);
        self.shared.loop_pending.store(false, Ordering::Release);
        self.shared
            .stretch_generation
            .fetch_add(1, Ordering::AcqRel);
        // Join the old decoder threads outside the lock.
        drop(previous);
        self.ensure_stretch();
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
        self.shared.clock_epoch.fetch_add(1, Ordering::AcqRel);
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
        self.shared.clock_epoch.fetch_add(1, Ordering::AcqRel);
        self.shared.completed.store(false, Ordering::Release);
        self.shared.loop_range.store(NO_LOOP, Ordering::Release);
        self.shared.loop_pending.store(false, Ordering::Release);
        drop(previous);
    }

    /// Moves every source to `ms` together.
    pub fn seek(&self, ms: u64) -> Result<(), AudioError> {
        self.shared.seek(ms)
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

    fn key(&self) -> f32 {
        self.shared.key_cents.load(Ordering::Acquire) as f32 / 100.0
    }

    /// Builds the stretcher for the current output rate, at the first load,
    /// so the first key or tempo change only switches it in. Done here, never
    /// in the callback: it allocates. Built and warmed up outside the mixer
    /// lock, so the callback keeps playing meanwhile.
    fn ensure_stretch(&self) {
        let rate = self.shared.output_rate.load(Ordering::Acquire);
        {
            let mixer = lock(&self.shared.mixer);
            if rate == 0 || (mixer.stretch.is_some() && mixer.stretch_rate == rate) {
                return;
            }
        }
        // The cheaper preset splits each spectral block's work across calls.
        // The default one does a whole 120 ms block inside a single callback
        // every 30 ms, which misses small AAudio deadlines and stutters.
        let mut stretch = signalsmith_stretch::Stretch::preset_cheaper(2, rate);
        warm_up(&mut stretch, rate);
        let latency = (stretch.input_latency() as u64) << 32 | stretch.output_latency() as u64;
        let mut mixer = lock(&self.shared.mixer);
        mixer.stretch = Some(stretch);
        mixer.stretch_rate = rate;
        mixer.carry = 0.0;
        // Room for any callback size, so the callback never grows it.
        let room = STRETCH_ROOM_FRAMES * 2;
        let len = mixer.stretched.len();
        mixer.stretched.reserve(room.saturating_sub(len));
        drop(mixer);
        self.shared
            .stretch_latency
            .store(latency, Ordering::Release);
    }

    /// Whether the stretcher is in the signal path.
    fn stretching(&self) -> bool {
        self.shared.tempo.load(Ordering::Acquire) != 1000
            || self.shared.key_cents.load(Ordering::Acquire) != 0
    }

    /// Playback speed, 0.5–1.5 (1 = normal), without changing the pitch.
    /// Positions stay in song time.
    pub fn set_tempo(&self, tempo: f32) -> Result<(), AudioError> {
        if !tempo.is_finite() {
            return Err(AudioError::Invalid("tempo must be a number".into()));
        }
        let was = self.stretching();
        let permille = (tempo.clamp(MIN_TEMPO, MAX_TEMPO) * 1000.0).round() as u32;
        self.shared.tempo.store(permille, Ordering::Release);
        self.engage(was);
        Ok(())
    }

    /// Transposes by `semitones` (±6) without changing the tempo.
    pub fn set_key(&self, semitones: f32) -> Result<(), AudioError> {
        if !semitones.is_finite() {
            return Err(AudioError::Invalid("key must be a number".into()));
        }
        let was = self.stretching();
        let cents = (semitones.clamp(-MAX_KEY_SEMITONES, MAX_KEY_SEMITONES) * 100.0).round() as i32;
        self.shared.key_cents.store(cents, Ordering::Release);
        self.engage(was);
        Ok(())
    }

    /// After a key or tempo change: build the stretcher if it is now needed
    /// and start it clean when it enters the signal path.
    fn engage(&self, was_stretching: bool) {
        self.ensure_stretch();
        if self.stretching() && !was_stretching {
            self.shared
                .stretch_generation
                .fetch_add(1, Ordering::AcqRel);
        }
    }

    /// Repeats `start_ms..end_ms` (song time) until cleared with `None`.
    /// Reaching the end seeks back to the start, with a short gap at the
    /// seam while the decoders refill.
    pub fn set_loop(&self, range: Option<(u64, u64)>) -> Result<(), AudioError> {
        let Some((start, end)) = range else {
            self.shared.loop_range.store(NO_LOOP, Ordering::Release);
            return Ok(());
        };
        if end < start + MIN_LOOP_MS || end > u64::from(u32::MAX) {
            return Err(AudioError::Invalid(format!(
                "a loop must be at least {MIN_LOOP_MS} ms long"
            )));
        }
        if self.shared.loop_thread.get().is_none() {
            let shared = Arc::downgrade(&self.shared);
            let thread = std::thread::Builder::new()
                .name("kalao-loop".into())
                .spawn(move || Shared::run_loop(&shared))
                .map_err(|error| AudioError::Output(error.to_string()))?;
            let _ = self.shared.loop_thread.set(thread.thread().clone());
        }
        self.shared
            .loop_range
            .store(start << 32 | end, Ordering::Release);
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
            // What is heard now left the engine one output latency ago, and
            // entered the stretcher (when engaged) its delay before that.
            let latency_us = self.shared.latency_us.load(Ordering::Acquire);
            let tempo = u64::from(self.shared.tempo.load(Ordering::Acquire));
            let mut behind_ms = latency_us * tempo / 1_000_000;
            if self.stretching() {
                let rate = u64::from(self.shared.output_rate.load(Ordering::Acquire).max(1));
                let latency = self.shared.stretch_latency.load(Ordering::Acquire);
                let (input, output) = (latency >> 32, latency & 0xffff_ffff);
                behind_ms += (input * 1000 + output * tempo) / rate;
            }
            let limit_ms = rendered_ms.saturating_sub(behind_ms);
            if self.manual {
                // Tests pull blocks faster than real time: report them exactly.
                return limit_ms;
            }
            lock(&self.clock).position_ms(
                limit_ms,
                self.shared.clock_epoch.load(Ordering::Acquire),
                self.shared.tempo.load(Ordering::Acquire),
                Instant::now(),
            )
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
            "key": self.key(),
            "loopStartMs": self.loop_range().map(|range| range.0),
            "loopEndMs": self.loop_range().map(|range| range.1),
            "outputLatencyMs": self.shared.latency_us.load(Ordering::Acquire) / 1000,
            "sampleRate": self.shared.output_rate.load(Ordering::Acquire),
            "error": errors.first(),
        })
    }

    fn loop_range(&self) -> Option<(u64, u64)> {
        let range = self.shared.loop_range.load(Ordering::Acquire);
        (range != NO_LOOP).then_some((range >> 32, range & 0xffff_ffff))
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

/// Runs a new stretcher over half a second of tone (slowed and transposed,
/// the full spectral path), then resets it. Its first blocks touch its
/// buffers and FFT tables for the first time; in the audio callback they
/// made the first speed change after start stutter on Android.
fn warm_up(stretch: &mut signalsmith_stretch::Stretch, rate: u32) {
    const OUTPUT_FRAMES: usize = 1024;
    const INPUT_FRAMES: usize = OUTPUT_FRAMES * 3 / 4;
    let step = std::f32::consts::TAU * 440.0 / rate.max(1) as f32;
    let input: Vec<f32> = (0..INPUT_FRAMES * 2)
        .map(|sample| 0.25 * (step * (sample / 2) as f32).sin())
        .collect();
    let mut output = vec![0.0; OUTPUT_FRAMES * 2];
    stretch.set_transpose_factor_semitones(1.0, None);
    for _ in 0..(rate as usize / 2).div_ceil(OUTPUT_FRAMES) {
        stretch.process(&input, &mut output);
    }
    stretch.set_transpose_factor_semitones(0.0, None);
    stretch.reset();
}

fn ms_to_position(ms: u64, rate: u32) -> u64 {
    ms * u64::from(rate)
}

#[cfg(test)]
mod tests;
