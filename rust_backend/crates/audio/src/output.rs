//! The cpal output stream, owned by one thread because a cpal `Stream` is not
//! `Send` on every platform. The stream is rebuilt after a device error (for
//! example when headphones are unplugged and AAudio closes the route).

use crate::{AudioError, Shared};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{BufferSize, SampleRate, StreamConfig};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::time::Duration;

/// Requested from the device; AAudio resamples if the route differs.
pub const PREFERRED_RATE: u32 = 48_000;

pub enum Command {
    Play,
    Pause,
    Shutdown,
}

pub struct OutputThread {
    sender: Sender<Command>,
    pub sample_rate: u32,
}

impl OutputThread {
    pub fn start(shared: Arc<Shared>) -> Result<Self, AudioError> {
        let (sender, receiver) = mpsc::channel();
        let (ready_sender, ready) = mpsc::channel();
        std::thread::Builder::new()
            .name("kalao-audio-out".into())
            .spawn(move || {
                let broken = Arc::new(AtomicBool::new(false));
                let mut stream = match build(&shared, &broken) {
                    Ok(stream) => {
                        let _ = ready_sender.send(Ok(PREFERRED_RATE));
                        Some(stream)
                    }
                    Err(error) => {
                        let _ = ready_sender.send(Err(error));
                        return;
                    }
                };
                let mut wants_play = false;
                loop {
                    match receiver.recv_timeout(Duration::from_millis(250)) {
                        Ok(Command::Play) => {
                            wants_play = true;
                            if let Some(stream) = &stream {
                                let _ = stream.play();
                            }
                        }
                        Ok(Command::Pause) => {
                            wants_play = false;
                            if let Some(stream) = &stream {
                                let _ = stream.pause();
                            }
                        }
                        Ok(Command::Shutdown) | Err(RecvTimeoutError::Disconnected) => break,
                        Err(RecvTimeoutError::Timeout) => {}
                    }
                    if broken.swap(false, Ordering::AcqRel) {
                        drop(stream.take());
                        stream = build(&shared, &broken).ok();
                        if wants_play && let Some(stream) = &stream {
                            let _ = stream.play();
                        }
                    }
                }
            })
            .map_err(|error| AudioError::Output(error.to_string()))?;
        let sample_rate = ready
            .recv()
            .map_err(|error| AudioError::Output(error.to_string()))??;
        Ok(Self {
            sender,
            sample_rate,
        })
    }

    pub fn send(&self, command: Command) {
        let _ = self.sender.send(command);
    }
}

impl Drop for OutputThread {
    fn drop(&mut self) {
        self.send(Command::Shutdown);
    }
}

/// Output latencies above this are measurement errors, not latency.
const MAX_LATENCY: Duration = Duration::from_millis(500);

/// The callback-to-speaker latency cpal reports, or 0 when it is not a real
/// latency. cpal 0.16's AAudio backend measures `callback` from stream
/// creation but `playback` on CLOCK_MONOTONIC (time since boot), so their
/// difference is the device uptime; subtracting that from the position
/// pinned it at 0 while playing.
pub(crate) fn plausible_latency_us(latency: Option<Duration>) -> u64 {
    latency
        .filter(|latency| *latency <= MAX_LATENCY)
        .map_or(0, |latency| latency.as_micros() as u64)
}

fn build(shared: &Arc<Shared>, broken: &Arc<AtomicBool>) -> Result<cpal::Stream, AudioError> {
    let device = cpal::default_host()
        .default_output_device()
        .ok_or_else(|| AudioError::Output("no output device".into()))?;
    // Ask for stereo f32 at 48 kHz directly: on Android, querying the
    // default config goes through JNI, which this library does not set up.
    let config = StreamConfig {
        channels: 2,
        sample_rate: SampleRate(PREFERRED_RATE),
        buffer_size: BufferSize::Default,
    };
    let callback_shared = shared.clone();
    let error_flag = broken.clone();
    let stream = device
        .build_output_stream(
            &config,
            move |data: &mut [f32], info: &cpal::OutputCallbackInfo| {
                let timestamp = info.timestamp();
                let latency = timestamp.playback.duration_since(&timestamp.callback);
                callback_shared
                    .latency_us
                    .store(plausible_latency_us(latency), Ordering::Release);
                callback_shared.render(data, 2);
            },
            move |_error| error_flag.store(true, Ordering::Release),
            None,
        )
        .map_err(|error| AudioError::Output(error.to_string()))?;
    // Streams start paused on some hosts and playing on others.
    let _ = stream.pause();
    if shared.playing.load(Ordering::Acquire) {
        stream
            .play()
            .map_err(|error| AudioError::Output(error.to_string()))?;
    }
    Ok(stream)
}
