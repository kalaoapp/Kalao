//! Engine tests on rendered buffers (IMPLEMENTATION.md §17): stems stay
//! sample-aligned, seeks land on the right frame, the switch crossfades,
//! resampling keeps duration, and playback completes.

use super::*;
use std::path::Path;
use std::time::{Duration, Instant};

const RATE: u32 = 48_000;

fn temp_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("kalao-audio-{name}-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// Writes a 16-bit stereo WAV whose left and right samples are `f(frame)`.
fn write_wav(path: &Path, rate: u32, frames: u32, f: impl Fn(usize) -> f32) {
    let mut data = Vec::with_capacity(frames as usize * 4);
    for frame in 0..frames as usize {
        let sample = (f(frame).clamp(-1.0, 1.0) * 32767.0).round() as i16;
        data.extend_from_slice(&sample.to_le_bytes());
        data.extend_from_slice(&sample.to_le_bytes());
    }
    let mut out = Vec::with_capacity(44 + data.len());
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(36 + data.len() as u32).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&2u16.to_le_bytes());
    out.extend_from_slice(&rate.to_le_bytes());
    out.extend_from_slice(&(rate * 4).to_le_bytes());
    out.extend_from_slice(&4u16.to_le_bytes());
    out.extend_from_slice(&16u16.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&(data.len() as u32).to_le_bytes());
    out.extend_from_slice(&data);
    std::fs::write(path, out).unwrap();
}

fn sine(frame: usize, rate: u32) -> f32 {
    0.4 * (frame as f32 * 440.0 * std::f32::consts::TAU / rate as f32).sin()
}

fn wait_prefill(engine: &Engine, frames: usize) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while engine.min_buffered_frames() < frames {
        assert!(Instant::now() < deadline, "sources did not prefill");
        std::thread::sleep(Duration::from_millis(2));
    }
}

/// Renders `frames` stereo frames, waiting through underruns.
fn render(engine: &Engine, frames: usize) -> Vec<f32> {
    let mut out = Vec::with_capacity(frames * 2);
    let block = 480;
    let deadline = Instant::now() + Duration::from_secs(10);
    while out.len() < frames * 2 {
        let want = block.min(frames - out.len() / 2);
        wait_prefill(engine, want);
        let before = engine.position_ms();
        let mut buffer = vec![0.0; want * 2];
        engine.render(&mut buffer, 2);
        if engine.state()["completed"] == true {
            out.extend_from_slice(&buffer);
            break;
        }
        if engine.position_ms() == before && engine.state()["buffering"] == true {
            assert!(Instant::now() < deadline, "engine stuck buffering");
            continue;
        }
        out.extend_from_slice(&buffer);
    }
    out
}

#[test]
fn stems_stay_sample_aligned() {
    let dir = temp_dir("sync");
    let vocals = dir.join("vocals.wav");
    let instrumental = dir.join("instrumental.wav");
    write_wav(&vocals, RATE, RATE, |f| sine(f, RATE));
    write_wav(&instrumental, RATE, RATE, |f| -sine(f, RATE));
    let engine = Engine::new(Output::Manual { sample_rate: RATE });
    engine
        .load(
            "song",
            &[
                (SourceKind::Vocals, vocals),
                (SourceKind::Instrumental, instrumental),
            ],
            0,
        )
        .unwrap();
    assert_eq!(engine.state()["layout"], "stems");
    engine.play().unwrap();
    let out = render(&engine, RATE as usize / 2);
    // Opposite-phase stems cancel exactly only if every frame lines up.
    assert!(out.iter().all(|sample| sample.abs() < 1e-6));
    engine.seek(700).unwrap();
    let out = render(&engine, 4800);
    assert!(out.iter().all(|sample| sample.abs() < 1e-6));
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn seek_lands_on_the_requested_frame() {
    let dir = temp_dir("seek");
    let path = dir.join("ramp.wav");
    // A slow ramp makes every frame's value identify its position.
    let frames = RATE as usize * 2;
    write_wav(&path, RATE, frames as u32, |f| {
        f as f32 / frames as f32 * 0.7
    });
    let engine = Engine::new(Output::Manual { sample_rate: RATE });
    engine
        .load("song", &[(SourceKind::Original, path)], 0)
        .unwrap();
    engine.play().unwrap();
    engine.seek(1000).unwrap();
    assert_eq!(engine.position_ms(), 1000);
    let out = render(&engine, 16);
    let expected = (RATE as usize) as f32 / frames as f32 * 0.7;
    assert!((out[0] - expected).abs() < 1e-3, "{} vs {expected}", out[0]);
    assert_eq!(engine.position_ms(), 1000);
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn load_can_start_mid_song_and_report_duration() {
    let dir = temp_dir("start");
    let path = dir.join("tone.wav");
    write_wav(&path, RATE, RATE * 3, |f| sine(f, RATE));
    let engine = Engine::new(Output::Manual { sample_rate: RATE });
    engine
        .load("song-7", &[(SourceKind::Original, path)], 2500)
        .unwrap();
    let state = engine.state();
    assert_eq!(state["songId"], "song-7");
    assert_eq!(state["durationMs"], 3000);
    assert_eq!(state["positionMs"], 2500);
    assert_eq!(state["playing"], false);
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn switch_track_crossfades_to_the_instrumental() {
    let dir = temp_dir("switch");
    let original = dir.join("original.wav");
    let instrumental = dir.join("instrumental.wav");
    write_wav(&original, RATE, RATE * 2, |_| 0.5);
    write_wav(&instrumental, RATE, RATE * 2, |_| 0.0);
    let engine = Engine::new(Output::Manual { sample_rate: RATE });
    engine
        .load(
            "song",
            &[
                (SourceKind::Original, original),
                (SourceKind::Instrumental, instrumental),
            ],
            0,
        )
        .unwrap();
    engine.play().unwrap();
    let before = render(&engine, 480);
    assert!((before[0] - 0.5).abs() < 1e-3);
    engine.switch_track(SourceKind::Instrumental).unwrap();
    // 150 ms crossfade = 7200 frames at 48 kHz; halfway the original is at
    // sin(π/4) ≈ 0.707 of its level, and silent afterwards.
    let fade = render(&engine, 7200 + 480);
    let mid = fade[3600 * 2];
    assert!(
        (mid - 0.5 * std::f32::consts::FRAC_1_SQRT_2).abs() < 0.01,
        "{mid}"
    );
    assert!(fade[7300 * 2].abs() < 1e-4);
    // Monotonic: no clicks back up during the fade.
    assert!(
        fade.as_chunks::<2>()
            .0
            .iter()
            .zip(fade.as_chunks::<2>().0.iter().skip(1))
            .all(|(a, b)| b[0] <= a[0] + 1e-6)
    );
    engine.switch_track(SourceKind::Original).unwrap();
    let back = render(&engine, 7200 + 480);
    assert!((back[7300 * 2] - 0.5).abs() < 1e-3);
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn resampled_sources_keep_their_duration_and_complete() {
    let dir = temp_dir("resample");
    let path = dir.join("cd.wav");
    write_wav(&path, 44_100, 44_100 / 2, |f| sine(f, 44_100));
    let engine = Engine::new(Output::Manual { sample_rate: RATE });
    engine
        .load("song", &[(SourceKind::Original, path)], 0)
        .unwrap();
    engine.play().unwrap();
    let out = render(&engine, RATE as usize);
    assert_eq!(engine.state()["completed"], true);
    assert_eq!(engine.state()["playing"], false);
    let audible = out.iter().rposition(|sample| sample.abs() > 1e-3).unwrap() / 2;
    // Half a second at 48 kHz, within the resampler's tail.
    assert!((23_500..=24_100).contains(&audible), "{audible}");
    // Playing again after completion restarts from the beginning.
    engine.play().unwrap();
    assert_eq!(engine.position_ms(), 0);
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn volume_and_vocal_level_ramp_without_steps() {
    let dir = temp_dir("volume");
    let vocals = dir.join("v.wav");
    let instrumental = dir.join("i.wav");
    write_wav(&vocals, RATE, RATE, |_| 0.4);
    write_wav(&instrumental, RATE, RATE, |_| 0.2);
    let engine = Engine::new(Output::Manual { sample_rate: RATE });
    engine
        .load(
            "song",
            &[
                (SourceKind::Vocals, vocals),
                (SourceKind::Instrumental, instrumental),
            ],
            0,
        )
        .unwrap();
    engine.play().unwrap();
    let full = render(&engine, 480);
    assert!((full[0] - 0.6).abs() < 1e-3);
    engine.set_stem_gains(Some(0.0), None);
    let out = render(&engine, 960);
    // 10 ms ramp = 480 frames, then instrumental only.
    assert!(out[0] > 0.59 && out[0] < 0.6);
    assert!((out[600 * 2] - 0.2).abs() < 1e-3);
    engine.set_volume(0.5);
    let out = render(&engine, 960);
    assert!((out[900 * 2] - 0.1).abs() < 1e-3);
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn bad_loads_are_rejected() {
    let engine = Engine::new(Output::Manual { sample_rate: RATE });
    assert!(engine.load("x", &[], 0).is_err());
    assert!(
        engine
            .load("x", &[(SourceKind::Original, "missing.wav".into())], 0)
            .is_err()
    );
    assert!(engine.play().is_err());
}

#[test]
fn probe_reports_wav_details() {
    let dir = temp_dir("probe");
    let path = dir.join("p.wav");
    write_wav(&path, 44_100, 44_100 * 2, |f| sine(f, 44_100));
    let probe = probe_file(&path).unwrap();
    assert_eq!(probe.sample_rate, 44_100);
    assert_eq!(probe.channels, 2);
    assert_eq!(probe.duration_ms, Some(2000));
    assert!(probe.decodable);
    let _ = std::fs::remove_dir_all(dir);
}

/// The frame of the first sample louder than 0.5 at or after `from`.
fn click_frame(out: &[f32], from: usize) -> Option<usize> {
    out.as_chunks::<2>()
        .0
        .iter()
        .skip(from)
        .position(|frame| frame[0].abs() > 0.5)
        .map(|index| index + from)
}

/// M2.6: the position the engine reports is the song time of the audio it
/// renders, so a lyric line timed at a click lights up within ±30 ms of the
/// click, through the resampler and at a slowed tempo.
#[test]
fn reported_position_tracks_rendered_clicks_within_30_ms() {
    let dir = temp_dir("clicks");
    let path = dir.join("clicks.wav");
    let source_rate = 44_100u32;
    // A 5 ms click every 500 ms of song time.
    let clicks_ms: Vec<u64> = (1..=5).map(|index| index * 500).collect();
    write_wav(&path, source_rate, source_rate * 3, |frame| {
        let ms = frame as u64 * 1000 / u64::from(source_rate);
        if ms % 500 < 5 && ms >= 500 { 0.9 } else { 0.0 }
    });
    for tempo in [1.0f32, 0.5] {
        let engine = Engine::new(Output::Manual { sample_rate: RATE });
        engine
            .load("clicks", &[(SourceKind::Original, path.clone())], 0)
            .unwrap();
        engine.set_tempo(tempo).unwrap();
        assert_eq!(engine.state()["tempo"], f64::from(tempo));
        engine.play().unwrap();
        // Render in callback-sized blocks, noting the position after each.
        let block = 480;
        let mut out = Vec::new();
        let mut positions = Vec::new();
        while engine.position_ms() < 2700 {
            assert_eq!(engine.state()["completed"], false, "song ended early");
            out.extend(render(&engine, block));
            positions.push(engine.position_ms());
        }
        let mut from = 0;
        for click_ms in &clicks_ms {
            let frame = click_frame(&out, from).expect("click rendered");
            from = frame + block * 4;
            // Song time when that frame was rendered, by the engine clock.
            let index = frame / block;
            let start = if index == 0 { 0 } else { positions[index - 1] };
            let heard = start + (positions[index] - start) * (frame % block) as u64 / block as u64;
            let error = heard as i64 - *click_ms as i64;
            assert!(
                error.abs() <= 30,
                "click at {click_ms} ms rendered at {heard} ms (tempo {tempo})"
            );
        }
    }
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn tempo_slows_song_time_and_keeps_the_position() {
    let dir = temp_dir("tempo");
    let path = dir.join("ramp.wav");
    let frames = RATE as usize * 2;
    write_wav(&path, RATE, frames as u32, |f| {
        f as f32 / frames as f32 * 0.7
    });
    let engine = Engine::new(Output::Manual { sample_rate: RATE });
    engine
        .load("song", &[(SourceKind::Original, path)], 0)
        .unwrap();
    engine.play().unwrap();
    render(&engine, RATE as usize / 2);
    assert_eq!(engine.position_ms(), 500);
    // Half speed: one second of output is half a second of song.
    engine.set_tempo(0.5).unwrap();
    assert_eq!(engine.position_ms(), 500);
    let out = render(&engine, RATE as usize);
    assert_eq!(engine.position_ms(), 1000);
    let expected = 0.7 * 0.5;
    let last = out[out.len() - 2];
    assert!((last - expected).abs() < 0.01, "{last} vs {expected}");
    // Out-of-range values are clamped; back to normal passes frames through.
    engine.set_tempo(9.0).unwrap();
    assert_eq!(engine.state()["tempo"], 1.5);
    engine.set_tempo(1.0).unwrap();
    engine.seek(1000).unwrap();
    let out = render(&engine, 16);
    assert!((out[0] - expected).abs() < 1e-3);
    assert!(engine.set_tempo(f32::NAN).is_err());
    let _ = std::fs::remove_dir_all(dir);
}
