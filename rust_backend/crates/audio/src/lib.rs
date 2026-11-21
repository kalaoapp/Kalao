//! Kalao's playback engine: up to three sources per song (original,
//! instrumental, vocals) decoded by Symphonia, resampled with rubato to the
//! output rate, buffered in SPSC rings and mixed on one clock, so stems never
//! drift. See `android/docs/IMPLEMENTATION.md` §2.

mod clock;
mod decoder;
mod mixer;
mod output;
mod source;

pub use decoder::{Probe, probe_file, probe_media};
pub use mixer::{Layout, soft_limit};
pub use symphonia::core::io::MediaSource;

use mixer::{LoopPlay, Mixer, Preroll};
use serde_json::{Value, json};
use source::Source;
use std::f32::consts::FRAC_PI_2;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU32, AtomicU64, Ordering};
use std::sync::{
    Arc, Mutex, MutexGuard, OnceLock, PoisonError, RwLock, RwLockReadGuard, RwLockWriteGuard, Weak,
};
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
/// How much of the loop start is decoded ahead, so the seam plays while
/// the decoders seek back.
const PREROLL_MS: u64 = 500;
/// The crossfade from the loop end into the loop start.
const SEAM_FADE_MS: u64 = 10;
/// `loop_request` when nothing is pending. Never a real request: a resume
/// point is past the loop start, so it is never 0 ms.
const NO_LOOP_REQUEST: u64 = 0;
/// `loop_request`'s low half when there is no preroll: seek to the start.
const LOOP_TO_START: u64 = 0xffff_ffff;

/// Opens a byte stream the decoders read, e.g. a cached HTTP stream. Each
/// call returns a fresh reader (one per decoder, plus loop prerolls).
pub trait StreamOpener: Send + Sync {
    fn open(&self) -> std::io::Result<Box<dyn MediaSource>>;
    /// Container hint for the decoder (`mp3`, `m4a`, `flac`, …).
    fn extension(&self) -> Option<&str>;
}

/// Where a source's audio comes from.
#[derive(Clone)]
pub enum Media {
    File(PathBuf),
    Stream(Arc<dyn StreamOpener>),
}

impl From<PathBuf> for Media {
    fn from(path: PathBuf) -> Self {
        Self::File(path)
    }
}

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
    /// Shared with the loop thread, which repositions them outside the
    /// session lock so the callback keeps playing the preroll.
    sources: Vec<Arc<Source>>,
    media: Vec<Media>,
    kinds: Vec<SourceKind>,
    layout: Layout,
    duration_ms: Option<u64>,
}

/// State shared by the control thread and the audio callback.
struct Shared {
    /// Written only by load and stop. Readers never block the callback's
    /// `try_read`, so polling state or serving a loop seam drops no block.
    session: RwLock<Option<Session>>,
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
    /// The callback reached the loop end: the loop generation of the request
    /// in the high half, and in the low half where the decoders resume after
    /// the preroll (ms) or `LOOP_TO_START` to seek back without one.
    /// `NO_LOOP_REQUEST` when nothing is pending. One word, so the loop
    /// thread clears only the request it served.
    loop_request: AtomicU64,
    /// Bumped by every loop request, seek, load, stop and loop change, so a
    /// request made before a later one of them is dropped.
    loop_generation: AtomicU32,
    /// Serialises seeks with the loop thread's resume.
    seek_lock: Mutex<()>,
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

fn read<T>(lock: &RwLock<T>) -> RwLockReadGuard<'_, T> {
    lock.read().unwrap_or_else(PoisonError::into_inner)
}

fn write<T>(lock: &RwLock<T>) -> RwLockWriteGuard<'_, T> {
    lock.write().unwrap_or_else(PoisonError::into_inner)
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
        // Without a preroll the seam is silent until the loop thread has
        // sought back to the loop start.
        let request = self.loop_request.load(Ordering::Acquire);
        let silent_seam = request != NO_LOOP_REQUEST && request & 0xffff_ffff == LOOP_TO_START;
        if frames == 0
            || !self.playing.load(Ordering::Acquire)
            || self.seeking.load(Ordering::Acquire)
            || silent_seam
        {
            return;
        }
        let Ok(session) = self.session.try_read() else {
            return;
        };
        let Some(session) = session.as_ref() else {
            return;
        };
        let Ok(mut mixer) = self.mixer.try_lock() else {
            return;
        };
        let count = session.sources.len().min(3);

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

        let rate = u64::from(self.output_rate.load(Ordering::Acquire).max(1));
        let range = self.loop_range.load(Ordering::Acquire);
        let fade = (rate * SEAM_FADE_MS / 1000) as usize;
        let block = Block::plan(
            &mixer,
            range,
            rate,
            fade,
            frames,
            count,
            self.position.load(Ordering::Acquire) / 1000,
        );
        if block.ring_len > 0
            && matches!(mixer.loop_play, LoopPlay::Preroll { .. })
            && self.loop_request.load(Ordering::Acquire) != NO_LOOP_REQUEST
        {
            // The preroll is used up before the decoders resumed after it.
            self.buffering.store(true, Ordering::Release);
            return;
        }

        use ringbuf::traits::{Consumer, Observer};
        // At most three sources; a fixed array keeps the callback allocation-free.
        let mut consumers: [Option<MutexGuard<'_, ringbuf::HeapCons<f32>>>; 3] = [None, None, None];
        if block.ring_len > 0 {
            for (slot, source) in consumers.iter_mut().zip(&session.sources) {
                let Ok(consumer) = source.shared.consumer.try_lock() else {
                    return;
                };
                *slot = Some(consumer);
            }
            let mut all_done = true;
            for (consumer, source) in consumers.iter().zip(&session.sources) {
                let consumer = consumer.as_ref().expect("filled above");
                let available = consumer.occupied_len() / 2;
                let ended = source.shared.ended.load(Ordering::Acquire);
                if available < block.ring_len && !ended {
                    // Underrun: wait for every source so they stay sample-aligned.
                    self.buffering.store(true, Ordering::Release);
                    return;
                }
                all_done &= ended && available == 0;
            }
            if all_done && block.pre_len == 0 {
                self.buffering.store(false, Ordering::Release);
                self.playing.store(false, Ordering::Release);
                self.completed.store(true, Ordering::Release);
                return;
            }
        }
        self.buffering.store(false, Ordering::Release);

        self.apply_mix_targets(&mut mixer);
        if mixer.scratch.len() < count {
            mixer.scratch.resize_with(count, Vec::new);
        }
        {
            let Mixer {
                scratch, preroll, ..
            } = &mut *mixer;
            for (index, scratch) in scratch.iter_mut().take(count).enumerate() {
                scratch.resize(frames * 2, 0.0);
                scratch[..frames * 2].fill(0.0);
                if let Some(consumer) = consumers[index].as_mut() {
                    let region =
                        &mut scratch[block.ring_off * 2..(block.ring_off + block.ring_len) * 2];
                    consumer.pop_slice(region);
                }
                if let Some(preroll) = preroll.as_ref().filter(|_| block.pre_len > 0) {
                    block.blend_preroll(&preroll.buffers[index], fade, scratch);
                }
            }
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

        let position = if let Some(offset) = block.seam_at {
            // The block crossed into the loop start: song time jumps there.
            let start_frame = (range >> 32) * rate / 1000;
            let position = (start_frame + (frames - offset) as u64) * 1000;
            self.position.store(position, Ordering::Release);
            self.clock_epoch.fetch_add(1, Ordering::AcqRel);
            position
        } else {
            self.position
                .fetch_add(frames as u64 * 1000, Ordering::AcqRel)
                + frames as u64 * 1000
        };
        let (preroll_frames, resume_ms) = mixer
            .preroll
            .as_ref()
            .map_or((0, NO_LOOP), |preroll| (preroll.frames, preroll.resume_ms));
        let next = block.next_play(mixer.loop_play, fade, preroll_frames);
        if matches!(next, LoopPlay::Preroll { .. })
            && !matches!(mixer.loop_play, LoopPlay::Preroll { .. })
        {
            // The fade is done and the rings hold the loop end: move the
            // decoders to where the preroll stops.
            self.request_loop_seek(resume_ms);
        }
        mixer.loop_play = next;

        if range != NO_LOOP && !block.preroll && position / rate >= range & 0xffff_ffff {
            // No preroll: hand over to the loop thread and stay silent until
            // it has sought back.
            self.request_loop_seek(LOOP_TO_START);
        }
    }

    /// Asks the loop thread to move the decoders to `target` (ms, or
    /// `LOOP_TO_START`). Called with the mixer locked.
    fn request_loop_seek(&self, target: u64) {
        let generation = self
            .loop_generation
            .fetch_add(1, Ordering::AcqRel)
            .wrapping_add(1);
        self.loop_request
            .store(u64::from(generation) << 32 | target, Ordering::Release);
        if let Some(thread) = self.loop_thread.get() {
            thread.unpark();
        }
    }

    /// Moves every source to `ms` together.
    fn seek(&self, ms: u64) -> Result<(), AudioError> {
        let _seeking = lock(&self.seek_lock);
        self.seek_locked(ms)
    }

    /// `seek` with `seek_lock` held.
    fn seek_locked(&self, ms: u64) -> Result<(), AudioError> {
        self.loop_generation.fetch_add(1, Ordering::AcqRel);
        let session = read(&self.session);
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
        let mut mixer = lock(&self.mixer);
        mixer.loop_play = LoopPlay::Rings;
        // A loop request made before the seek is obsolete.
        self.loop_request.store(NO_LOOP_REQUEST, Ordering::Release);
        drop(mixer);
        self.seeking.store(false, Ordering::Release);
        result
    }

    /// Serves a loop request: seeks back to the loop start, or moves the
    /// decoders to the resume point without touching the position (the
    /// callback is playing the preroll meanwhile). Dropped when a seek, load,
    /// loop change or newer request came after it.
    fn serve_loop_request(&self, request: u64) {
        let _seeking = lock(&self.seek_lock);
        if u64::from(self.loop_generation.load(Ordering::Acquire)) != request >> 32 {
            return;
        }
        let target = request & 0xffff_ffff;
        if target == LOOP_TO_START {
            let range = self.loop_range.load(Ordering::Acquire);
            if range != NO_LOOP {
                let _ = self.seek_locked(range >> 32);
            }
            return;
        }
        let sources = read(&self.session)
            .as_ref()
            .map(|session| session.sources.clone())
            .unwrap_or_default();
        for source in &sources {
            let _ = source.seek(target);
        }
    }

    /// Forgets the preroll and the seam state; the old buffers are freed
    /// here, not in the callback.
    fn clear_preroll(&self) {
        self.loop_generation.fetch_add(1, Ordering::AcqRel);
        let mut mixer = lock(&self.mixer);
        let old = mixer.preroll.take();
        mixer.loop_play = LoopPlay::Rings;
        self.loop_request.store(NO_LOOP_REQUEST, Ordering::Release);
        drop(mixer);
        drop(old);
    }

    /// Runs on the loop thread: seeks back to the loop start whenever the
    /// callback reaches the loop end.
    fn run_loop(shared: &Weak<Shared>) {
        loop {
            std::thread::park_timeout(Duration::from_millis(250));
            let Some(shared) = shared.upgrade() else {
                return;
            };
            let request = shared.loop_request.load(Ordering::Acquire);
            if request != NO_LOOP_REQUEST {
                shared.serve_loop_request(request);
                // A newer request stays pending; its unpark wakes us again.
                let _ = shared.loop_request.compare_exchange(
                    request,
                    NO_LOOP_REQUEST,
                    Ordering::AcqRel,
                    Ordering::Acquire,
                );
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

/// Where one callback block takes its source frames from: `ring_len` frames
/// from the rings at `ring_off`, and `pre_len` preroll frames (from
/// `pre_cursor`) at `pre_off`. Where both overlap, the first `fade` preroll
/// frames crossfade over the ring's last frames before the loop end.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Block {
    ring_off: usize,
    ring_len: usize,
    pre_off: usize,
    pre_len: usize,
    pre_cursor: usize,
    /// The offset where this block crosses into the loop start.
    seam_at: Option<usize>,
    /// A preroll for the current loop is ready.
    preroll: bool,
}

impl Block {
    fn plan(
        mixer: &Mixer,
        range: u64,
        rate: u64,
        fade: usize,
        frames: usize,
        sources: usize,
        position_frames: u64,
    ) -> Self {
        let mut block = Self {
            ring_off: 0,
            ring_len: frames,
            pre_off: 0,
            pre_len: 0,
            pre_cursor: 0,
            seam_at: None,
            preroll: false,
        };
        let Some(preroll) = mixer.preroll.as_ref().filter(|preroll| {
            range != NO_LOOP
                && preroll.range == (range >> 32, range & 0xffff_ffff)
                && preroll.buffers.len() == sources
                && preroll.frames > fade
        }) else {
            return block;
        };
        block.preroll = true;
        match mixer.loop_play {
            LoopPlay::Rings => {
                let seam = ((range & 0xffff_ffff) * rate / 1000).saturating_sub(fade as u64);
                let offset = seam.saturating_sub(position_frames);
                if offset < frames as u64 {
                    let offset = offset as usize;
                    block.seam_at = Some(offset);
                    block.ring_len = frames.min(offset + fade);
                    block.pre_off = offset;
                    block.pre_len = (frames - offset).min(preroll.frames);
                }
            }
            LoopPlay::Fading { done } => {
                block.ring_len = frames.min(fade.saturating_sub(done));
                block.pre_cursor = done;
                block.pre_len = frames.min(preroll.frames - done);
            }
            LoopPlay::Preroll { cursor } => {
                let from_preroll = frames.min(preroll.frames.saturating_sub(cursor));
                block.pre_cursor = cursor;
                block.pre_len = from_preroll;
                block.ring_off = from_preroll;
                block.ring_len = frames - from_preroll;
            }
        }
        block
    }

    /// Writes this block's preroll frames of one source into `scratch`,
    /// fading in over the ring frames already there during the fade.
    fn blend_preroll(&self, preroll: &[f32], fade: usize, scratch: &mut [f32]) {
        for index in 0..self.pre_len {
            let at = self.pre_cursor + index;
            let to = (self.pre_off + index) * 2;
            let (left, right) = (preroll[at * 2], preroll[at * 2 + 1]);
            if at < fade {
                let t = (at as f32 + 0.5) / fade as f32 * FRAC_PI_2;
                let (fade_out, fade_in) = (t.cos(), t.sin());
                scratch[to] = scratch[to] * fade_out + left * fade_in;
                scratch[to + 1] = scratch[to + 1] * fade_out + right * fade_in;
            } else {
                scratch[to] = left;
                scratch[to + 1] = right;
            }
        }
    }

    /// The loop state after this block.
    fn next_play(&self, play: LoopPlay, fade: usize, preroll_frames: usize) -> LoopPlay {
        let faded = |played: usize| {
            if played >= fade {
                LoopPlay::Preroll { cursor: played }
            } else {
                LoopPlay::Fading { done: played }
            }
        };
        match play {
            LoopPlay::Rings if self.seam_at.is_some() => faded(self.pre_len),
            LoopPlay::Rings => LoopPlay::Rings,
            LoopPlay::Fading { done } if preroll_frames > 0 => faded(done + self.pre_len),
            LoopPlay::Preroll { cursor } if cursor + self.pre_len < preroll_frames => {
                LoopPlay::Preroll {
                    cursor: cursor + self.pre_len,
                }
            }
            _ => LoopPlay::Rings,
        }
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
            session: RwLock::new(None),
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
            loop_request: AtomicU64::new(NO_LOOP_REQUEST),
            loop_generation: AtomicU32::new(0),
            seek_lock: Mutex::new(()),
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
        sources: &[(SourceKind, impl Clone + Into<Media>)],
        start_ms: u64,
    ) -> Result<(), AudioError> {
        let sources: Vec<(SourceKind, Media)> = sources
            .iter()
            .map(|(kind, media)| (*kind, media.clone().into()))
            .collect();
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
        for (kind, media) in &sources {
            if kinds.contains(kind) {
                return Err(AudioError::Invalid(format!(
                    "duplicate {} source",
                    kind.as_str()
                )));
            }
            let probe = probe_media(media)?;
            duration_ms = duration_ms.max(probe.duration_ms);
            let source = Arc::new(Source::open(*kind, media, rate, RING_FRAMES)?);
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
            media: sources.iter().map(|(_, media)| media.clone()).collect(),
            kinds,
            duration_ms,
        };
        let previous = write(&self.shared.session).replace(session);
        self.shared
            .position
            .store(ms_to_position(start_ms, rate), Ordering::Release);
        self.shared.clock_epoch.fetch_add(1, Ordering::AcqRel);
        self.shared.completed.store(false, Ordering::Release);
        // A loop belongs to the song it was set on.
        self.shared.loop_range.store(NO_LOOP, Ordering::Release);
        self.shared.clear_preroll();
        self.shared
            .stretch_generation
            .fetch_add(1, Ordering::AcqRel);
        // Join the old decoder threads outside the lock.
        drop(previous);
        self.ensure_stretch();
        Ok(())
    }

    pub fn play(&self) -> Result<(), AudioError> {
        if read(&self.shared.session).is_none() {
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
        let previous = write(&self.shared.session).take();
        self.shared.position.store(0, Ordering::Release);
        self.shared.clock_epoch.fetch_add(1, Ordering::AcqRel);
        self.shared.completed.store(false, Ordering::Release);
        self.shared.loop_range.store(NO_LOOP, Ordering::Release);
        self.shared.clear_preroll();
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
    /// The loop start is decoded ahead (`PREROLL_MS`), so at the end the
    /// output crossfades into it while the decoders seek back; without a
    /// preroll (it failed to decode) the seam is a short gap.
    pub fn set_loop(&self, range: Option<(u64, u64)>) -> Result<(), AudioError> {
        let Some((start, end)) = range else {
            self.shared.loop_range.store(NO_LOOP, Ordering::Release);
            self.shared.clear_preroll();
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
        self.shared.clear_preroll();
        let packed = start << 32 | end;
        self.shared.loop_range.store(packed, Ordering::Release);
        if let Some(preroll) = self.build_preroll(start, end) {
            let mut mixer = lock(&self.shared.mixer);
            if self.shared.loop_range.load(Ordering::Acquire) == packed {
                mixer.preroll = Some(preroll);
                mixer.loop_play = LoopPlay::Rings;
            }
        }
        Ok(())
    }

    /// Decodes the first part of `start..end` for every source, at the output
    /// rate. `None` when nothing is loaded or a source cannot be decoded.
    fn build_preroll(&self, start: u64, end: u64) -> Option<Preroll> {
        let media = read(&self.shared.session).as_ref()?.media.clone();
        let rate = self.shared.output_rate.load(Ordering::Acquire);
        // Leave room before the end for the rings to play the fade.
        let length_ms = PREROLL_MS.min((end - start).saturating_sub(2 * SEAM_FADE_MS));
        let frames = (u64::from(rate) * length_ms / 1000) as usize;
        let mut buffers = Vec::with_capacity(media.len());
        for item in &media {
            let mut buffer = source::decode_range(item, start, frames, rate).ok()?;
            buffer.resize(frames * 2, 0.0);
            buffers.push(buffer);
        }
        Some(Preroll {
            range: (start, end),
            frames,
            buffers,
            resume_ms: start + length_ms,
        })
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
        let session = read(&self.shared.session);
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
        read(&self.shared.session).as_ref().map_or(0, |session| {
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
