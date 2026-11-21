//! One audio file decoded to interleaved stereo `f32` at the file's own rate.

use crate::AudioError;
use crate::Media;
use std::fs::File;
use std::path::Path;
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::{CODEC_TYPE_NULL, Decoder as CodecDecoder, DecoderOptions};
use symphonia::core::errors::{Error as SymphoniaError, SeekErrorKind};
use symphonia::core::formats::{FormatOptions, FormatReader, SeekMode, SeekTo};
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::{MetadataOptions, MetadataRevision, StandardTagKey, StandardVisualKey};
use symphonia::core::probe::{Hint, ProbeResult};
use symphonia::core::units::Time;

pub struct Decoder {
    format: Box<dyn FormatReader>,
    decoder: Box<dyn CodecDecoder>,
    track_id: u32,
    pub sample_rate: u32,
    buffer: Option<SampleBuffer<f32>>,
    /// Frames still to drop after an accurate seek landed before the target.
    skip_frames: u64,
}

/// The format hint for `path`: its extension, or, for a path without one,
/// the extension of the file it links to. A file from a music folder is
/// opened as `/proc/self/fd/<n>` (a descriptor the Android host holds), whose
/// link names the real file.
pub(crate) fn file_extension(path: &Path) -> Option<String> {
    let own = |path: &Path| {
        path.extension()
            .and_then(|value| value.to_str())
            .map(str::to_owned)
    };
    own(path).or_else(|| {
        std::fs::read_link(path)
            .ok()
            .and_then(|target| own(&target))
    })
}

fn probe(media: &Media) -> Result<ProbeResult, AudioError> {
    let mut hint = Hint::new();
    let source: Box<dyn symphonia::core::io::MediaSource> = match media {
        Media::File(path) => {
            if let Some(extension) = file_extension(path) {
                hint.with_extension(&extension);
            }
            Box::new(File::open(path).map_err(|error| AudioError::Open(error.to_string()))?)
        }
        Media::Stream(stream) => {
            if let Some(extension) = stream.extension() {
                hint.with_extension(extension);
            }
            stream
                .open()
                .map_err(|error| AudioError::Open(error.to_string()))?
        }
    };
    let stream = MediaSourceStream::new(source, Default::default());
    symphonia::default::get_probe()
        .format(
            &hint,
            stream,
            &FormatOptions {
                enable_gapless: true,
                ..FormatOptions::default()
            },
            &MetadataOptions::default(),
        )
        .map_err(|error| AudioError::Unsupported(error.to_string()))
}

impl Decoder {
    pub fn open(media: &Media) -> Result<Self, AudioError> {
        let format = probe(media)?.format;
        let track = format
            .tracks()
            .iter()
            .find(|track| track.codec_params.codec != CODEC_TYPE_NULL)
            .ok_or_else(|| AudioError::Unsupported("no audio track".into()))?;
        let sample_rate = track
            .codec_params
            .sample_rate
            .ok_or_else(|| AudioError::Unsupported("unknown sample rate".into()))?;
        let decoder = symphonia::default::get_codecs()
            .make(&track.codec_params, &DecoderOptions::default())
            .map_err(|error| AudioError::Unsupported(error.to_string()))?;
        Ok(Self {
            track_id: track.id,
            format,
            decoder,
            sample_rate,
            buffer: None,
            skip_frames: 0,
        })
    }

    /// Appends the next packet as stereo frames. Returns `false` at the end.
    pub fn decode_into(&mut self, out: &mut Vec<f32>) -> Result<bool, AudioError> {
        loop {
            let packet = match self.format.next_packet() {
                Ok(packet) => packet,
                Err(SymphoniaError::IoError(error))
                    if error.kind() == std::io::ErrorKind::UnexpectedEof =>
                {
                    return Ok(false);
                }
                Err(SymphoniaError::ResetRequired) => {
                    self.decoder.reset();
                    continue;
                }
                Err(error) => return Err(AudioError::Decode(error.to_string())),
            };
            if packet.track_id() != self.track_id {
                continue;
            }
            let decoded = match self.decoder.decode(&packet) {
                Ok(decoded) => decoded,
                // A corrupt packet is skipped, as players usually do.
                Err(SymphoniaError::DecodeError(_)) => continue,
                Err(error) => return Err(AudioError::Decode(error.to_string())),
            };
            let spec = *decoded.spec();
            let channels = spec.channels.count().max(1);
            let needs_buffer = self
                .buffer
                .as_ref()
                .is_none_or(|buffer| buffer.capacity() < decoded.capacity() * channels);
            if needs_buffer {
                self.buffer = Some(SampleBuffer::new(decoded.capacity() as u64, spec));
            }
            let buffer = self.buffer.as_mut().expect("buffer allocated above");
            buffer.copy_interleaved_ref(decoded);
            let mut samples = buffer.samples();
            let skip = (self.skip_frames as usize).min(samples.len() / channels);
            self.skip_frames -= skip as u64;
            samples = &samples[skip * channels..];
            push_stereo(samples, channels, out);
            return Ok(true);
        }
    }

    /// Seeks so the next decoded frame is the one at `ms`.
    /// Repositions to `ms`. Returns `false` when `ms` is past the end of the
    /// stream (a shorter stem, or a saved position beyond the end): the
    /// caller treats the source as finished.
    pub fn seek(&mut self, ms: u64) -> Result<bool, AudioError> {
        let seeked = match self.format.seek(
            SeekMode::Accurate,
            SeekTo::Time {
                time: Time::from(ms as f64 / 1000.0),
                track_id: Some(self.track_id),
            },
        ) {
            Ok(seeked) => seeked,
            Err(SymphoniaError::SeekError(SeekErrorKind::OutOfRange)) => return Ok(false),
            Err(error) => return Err(AudioError::Decode(error.to_string())),
        };
        self.decoder.reset();
        let time_base = self
            .format
            .tracks()
            .iter()
            .find(|track| track.id == self.track_id)
            .and_then(|track| track.codec_params.time_base);
        let behind = seeked.required_ts.saturating_sub(seeked.actual_ts);
        self.skip_frames = match time_base {
            Some(base) => {
                let time = base.calc_time(behind);
                ((time.seconds as f64 + time.frac) * f64::from(self.sample_rate)).round() as u64
            }
            None => behind,
        };
        Ok(true)
    }
}

fn push_stereo(samples: &[f32], channels: usize, out: &mut Vec<f32>) {
    match channels {
        1 => samples.iter().for_each(|&s| out.extend_from_slice(&[s, s])),
        2 => out.extend_from_slice(samples),
        _ => samples
            .chunks_exact(channels)
            .for_each(|frame| out.extend_from_slice(&frame[..2])),
    }
}

/// What `probeAudio` reports about a file.
#[derive(Debug, Default, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Probe {
    pub codec: String,
    pub sample_rate: u32,
    pub channels: usize,
    pub duration_ms: Option<u64>,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub isrc: Option<String>,
    pub lyrics: Option<String>,
    /// Embedded front cover (or the first picture), not serialized.
    #[serde(skip)]
    pub cover: Option<(String, Vec<u8>)>,
    /// Whether the engine can play the file without conversion.
    pub decodable: bool,
}

/// Reads tags, cover, duration and codec. A file Symphonia cannot open is an
/// error; one it can open but not decode reports `decodable: false`.
pub fn probe_file(path: &Path) -> Result<Probe, AudioError> {
    probe_media(&Media::File(path.to_path_buf()))
}

/// `probe_file` for any media, a stream included.
pub fn probe_media(media: &Media) -> Result<Probe, AudioError> {
    let mut probed = probe(media)?;
    let mut result = Probe::default();
    if let Some(revision) = probed.metadata.get().as_ref().and_then(|m| m.current()) {
        apply_revision(&mut result, revision);
    }
    if let Some(revision) = probed.format.metadata().current() {
        apply_revision(&mut result, revision);
    }
    let format = probed.format;
    let track = format
        .tracks()
        .iter()
        .find(|track| track.codec_params.codec != CODEC_TYPE_NULL)
        .ok_or_else(|| AudioError::Unsupported("no audio track".into()))?;
    let params = &track.codec_params;
    result.codec = symphonia::default::get_codecs()
        .get_codec(params.codec)
        .map_or_else(|| "unknown".into(), |codec| codec.short_name.to_owned());
    result.sample_rate = params.sample_rate.unwrap_or(0);
    result.channels = params.channels.map_or(0, |channels| channels.count());
    result.duration_ms = match (params.n_frames, params.time_base) {
        (Some(frames), Some(base)) => {
            let time = base.calc_time(frames);
            Some(((time.seconds as f64 + time.frac) * 1000.0).round() as u64)
        }
        (Some(frames), None) if result.sample_rate > 0 => {
            Some(frames * 1000 / u64::from(result.sample_rate))
        }
        _ => None,
    };
    result.decodable = result.sample_rate > 0
        && symphonia::default::get_codecs()
            .make(params, &DecoderOptions::default())
            .is_ok();
    Ok(result)
}

fn apply_revision(result: &mut Probe, revision: &MetadataRevision) {
    for tag in revision.tags() {
        let value = tag.value.to_string().trim().to_owned();
        if value.is_empty() {
            continue;
        }
        let slot = match tag.std_key {
            Some(StandardTagKey::TrackTitle) => &mut result.title,
            Some(StandardTagKey::Artist) => &mut result.artist,
            Some(StandardTagKey::AlbumArtist) if result.artist.is_none() => &mut result.artist,
            Some(StandardTagKey::Album) => &mut result.album,
            Some(StandardTagKey::IdentIsrc) => &mut result.isrc,
            Some(StandardTagKey::Lyrics) => &mut result.lyrics,
            _ => continue,
        };
        slot.get_or_insert(value);
    }
    let visuals = revision.visuals();
    let front = visuals
        .iter()
        .find(|visual| visual.usage == Some(StandardVisualKey::FrontCover))
        .or_else(|| visuals.first());
    if result.cover.is_none()
        && let Some(visual) = front
    {
        result.cover = Some((visual.media_type.clone(), visual.data.to_vec()));
    }
}
