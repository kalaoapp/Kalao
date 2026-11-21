//! A decoder thread per source: decode → resample to the output rate → ring
//! buffer. The audio callback is the ring's only consumer.
//!
//! Seeking locks the worker (so the thread is not pushing) and the consumer
//! (so the callback is not reading), clears the ring and repositions the
//! decoder; the callback outputs silence while either lock is held.

use crate::Media;
use crate::decoder::Decoder;
use crate::{AudioError, SourceKind};
use ringbuf::traits::{Consumer, Observer, Producer, Split};
use ringbuf::{HeapCons, HeapProd, HeapRb};
use rubato::{FastFixedIn, PolynomialDegree, Resampler};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::thread::JoinHandle;
use std::time::Duration;

const RESAMPLE_CHUNK: usize = 1024;

/// What the callback and the control thread share for one source.
pub struct SourceShared {
    pub consumer: Mutex<HeapCons<f32>>,
    /// The decoder reached the end and every frame is in the ring.
    pub ended: AtomicBool,
    pub error: Mutex<Option<String>>,
}

pub struct Worker {
    decoder: Decoder,
    resampler: Option<FastFixedIn<f32>>,
    producer: HeapProd<f32>,
    /// Decoded stereo frames at the source rate awaiting resampling.
    input: Vec<f32>,
    /// Output-rate stereo samples awaiting room in the ring.
    pending: Vec<f32>,
    decoder_done: bool,
}

pub struct Source {
    pub shared: Arc<SourceShared>,
    worker: Arc<Mutex<Worker>>,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl Source {
    /// Opens `media` and starts its decoder thread. `ring_frames` is the ring
    /// capacity in output frames.
    pub fn open(
        kind: SourceKind,
        media: &Media,
        output_rate: u32,
        ring_frames: usize,
    ) -> Result<Self, AudioError> {
        let decoder = Decoder::open(media)?;
        let resampler = resampler(decoder.sample_rate, output_rate)?;
        let (producer, consumer) = HeapRb::<f32>::new(ring_frames * 2).split();
        let shared = Arc::new(SourceShared {
            consumer: Mutex::new(consumer),
            ended: AtomicBool::new(false),
            error: Mutex::new(None),
        });
        let worker = Arc::new(Mutex::new(Worker {
            decoder,
            resampler,
            producer,
            input: Vec::new(),
            pending: Vec::new(),
            decoder_done: false,
        }));
        let stop = Arc::new(AtomicBool::new(false));
        let thread = {
            let (shared, worker, stop) = (shared.clone(), worker.clone(), stop.clone());
            std::thread::Builder::new()
                .name(format!("kalao-decode-{}", kind.as_str()))
                .spawn(move || run(&shared, &worker, &stop))
                .map_err(|error| AudioError::Open(error.to_string()))?
        };
        Ok(Self {
            shared,
            worker,
            stop,
            thread: Some(thread),
        })
    }

    /// Repositions to `ms`; the ring restarts empty.
    pub fn seek(&self, ms: u64) -> Result<(), AudioError> {
        let mut worker = self.worker.lock().unwrap_or_else(PoisonError::into_inner);
        let mut consumer = self
            .shared
            .consumer
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        consumer.clear();
        worker.input.clear();
        worker.pending.clear();
        worker.decoder_done = false;
        if let Some(resampler) = worker.resampler.as_mut() {
            resampler.reset();
        }
        self.shared.ended.store(false, Ordering::Release);
        let result = worker.decoder.seek(ms);
        if !matches!(result, Ok(true)) {
            // Past the end or unseekable: behave as finished.
            worker.decoder_done = true;
        }
        drop(consumer);
        drop(worker);
        if let Some(thread) = &self.thread {
            thread.thread().unpark();
        }
        result.map(|_| ())
    }

    /// Frames ready in the ring (for prefill checks).
    pub fn buffered_frames(&self) -> usize {
        self.shared
            .consumer
            .try_lock()
            .map_or(0, |consumer| consumer.occupied_len() / 2)
    }
}

/// `frames` stereo frames of `media` from `start_ms`, at `output_rate`, decoded
/// off the audio thread (the loop start, played while the decoders seek back).
/// Shorter when the file ends first.
pub fn decode_range(
    media: &Media,
    start_ms: u64,
    frames: usize,
    output_rate: u32,
) -> Result<Vec<f32>, AudioError> {
    let decoder = Decoder::open(media)?;
    let resampler = resampler(decoder.sample_rate, output_rate)?;
    let (producer, mut consumer) = HeapRb::<f32>::new(frames.max(1) * 2).split();
    let mut worker = Worker {
        decoder,
        resampler,
        producer,
        input: Vec::new(),
        pending: Vec::new(),
        decoder_done: false,
    };
    if !matches!(worker.decoder.seek(start_ms), Ok(true)) {
        return Ok(Vec::new());
    }
    while consumer.occupied_len() < frames * 2 && !worker.finished() {
        worker.step()?;
    }
    let mut out = vec![0.0; consumer.occupied_len()];
    consumer.pop_slice(&mut out);
    Ok(out)
}

fn resampler(source_rate: u32, output_rate: u32) -> Result<Option<FastFixedIn<f32>>, AudioError> {
    if source_rate == output_rate {
        return Ok(None);
    }
    FastFixedIn::new(
        f64::from(output_rate) / f64::from(source_rate),
        1.0,
        PolynomialDegree::Cubic,
        RESAMPLE_CHUNK,
        2,
    )
    .map(Some)
    .map_err(|error| AudioError::Unsupported(error.to_string()))
}

impl Drop for Source {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(thread) = self.thread.take() {
            thread.thread().unpark();
            let _ = thread.join();
        }
    }
}

fn run(shared: &SourceShared, worker: &Mutex<Worker>, stop: &AtomicBool) {
    while !stop.load(Ordering::Acquire) {
        let idle = {
            let mut worker = worker.lock().unwrap_or_else(PoisonError::into_inner);
            match worker.step() {
                Ok(idle) => {
                    if worker.finished() {
                        shared.ended.store(true, Ordering::Release);
                    }
                    idle
                }
                Err(error) => {
                    *shared.error.lock().unwrap_or_else(PoisonError::into_inner) =
                        Some(error.to_string());
                    worker.decoder_done = true;
                    worker.input.clear();
                    true
                }
            }
        };
        if idle {
            std::thread::park_timeout(Duration::from_millis(5));
        }
    }
}

impl Worker {
    fn finished(&self) -> bool {
        self.decoder_done && self.input.is_empty() && self.pending.is_empty()
    }

    /// Moves data one step along. Returns `true` when there is nothing to do
    /// until the callback drains the ring.
    fn step(&mut self) -> Result<bool, AudioError> {
        if !self.pending.is_empty() {
            let pushed = self.producer.push_slice(&self.pending);
            self.pending.drain(..pushed);
            return Ok(!self.pending.is_empty());
        }
        if self.finished() {
            return Ok(true);
        }
        if !self.decoder_done && !self.decoder.decode_into(&mut self.input)? {
            self.decoder_done = true;
        }
        self.resample()?;
        Ok(false)
    }

    fn resample(&mut self) -> Result<(), AudioError> {
        let Some(resampler) = self.resampler.as_mut() else {
            self.pending.append(&mut self.input);
            return Ok(());
        };
        loop {
            let needed = resampler.input_frames_next();
            let available = self.input.len() / 2;
            let partial = self.decoder_done && available < needed;
            if available < needed && !(partial && available > 0) {
                return Ok(());
            }
            let take = available.min(needed);
            let planar = deinterleave(&self.input[..take * 2]);
            let output = if partial {
                resampler.process_partial(Some(&planar), None)
            } else {
                resampler.process(&planar, None)
            }
            .map_err(|error| AudioError::Decode(error.to_string()))?;
            self.input.drain(..take * 2);
            for (left, right) in output[0].iter().zip(&output[1]) {
                self.pending.extend_from_slice(&[*left, *right]);
            }
            if partial {
                return Ok(());
            }
        }
    }
}

fn deinterleave(samples: &[f32]) -> [Vec<f32>; 2] {
    let mut left = Vec::with_capacity(samples.len() / 2);
    let mut right = Vec::with_capacity(samples.len() / 2);
    for frame in samples.as_chunks::<2>().0.iter() {
        left.push(frame[0]);
        right.push(frame[1]);
    }
    [left, right]
}
