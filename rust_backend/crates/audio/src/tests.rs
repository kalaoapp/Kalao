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
fn seeking_past_a_shorter_source_is_not_an_error() {
    let dir = temp_dir("seek-past");
    let original = dir.join("original.wav");
    let instrumental = dir.join("instrumental.wav");
    write_wav(&original, RATE, RATE * 2, |f| sine(f, RATE));
    write_wav(&instrumental, RATE, RATE, |f| sine(f, RATE));
    let engine = Engine::new(Output::Manual { sample_rate: RATE });
    engine
        .load(
            "song",
            &[
                (SourceKind::Original, original),
                (SourceKind::Instrumental, instrumental.clone()),
            ],
            0,
        )
        .unwrap();
    // Past the instrumental's end, and past the whole song.
    engine.seek(1500).unwrap();
    assert_eq!(engine.position_ms(), 1500);
    engine.seek(60_000).unwrap();
    // A saved position beyond the end loads too.
    engine
        .load("song", &[(SourceKind::Instrumental, instrumental)], 5000)
        .unwrap();
    engine.play().unwrap();
    render(&engine, 480);
    assert_eq!(engine.state()["completed"], true);
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn implausible_output_latency_is_ignored() {
    use output::plausible_latency_us;
    assert_eq!(
        plausible_latency_us(Some(Duration::from_millis(40))),
        40_000
    );
    assert_eq!(plausible_latency_us(None), 0);
    // cpal 0.16 on AAudio: CLOCK_MONOTONIC minus time since stream creation.
    assert_eq!(plausible_latency_us(Some(Duration::from_secs(86_400))), 0);
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

/// Sign changes of the left channel in `out` (two per cycle of a tone).
fn zero_crossings(out: &[f32]) -> usize {
    let left: Vec<f32> = out
        .as_chunks::<2>()
        .0
        .iter()
        .map(|frame| frame[0])
        .collect();
    left.windows(2)
        .filter(|pair| (pair[0] < 0.0) != (pair[1] < 0.0))
        .count()
}

/// M2.6: the position the engine reports is the song time of the audio it
/// renders, so a lyric line timed at a click lights up within ±30 ms of the
/// click: through the resampler, and through the stretcher at a slowed
/// tempo (whose delay the position allows for).
#[test]
fn reported_position_tracks_rendered_clicks_within_30_ms() {
    let dir = temp_dir("clicks");
    let path = dir.join("clicks.wav");
    let source_rate = 44_100u32;
    // A 5 ms click every 500 ms of song time.
    let clicks_ms: Vec<u64> = (1..=5).map(|index| index * 500).collect();
    write_wav(&path, source_rate, source_rate * 4, |frame| {
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
        let mut positions = vec![0u64];
        while engine.position_ms() < 2800 {
            assert_eq!(engine.state()["completed"], false, "song ended early");
            out.extend(render(&engine, block));
            positions.push(engine.position_ms());
        }
        // Song time of an output frame, by the engine clock.
        let song_ms = |frame: usize| {
            let (start, end) = (positions[frame / block], positions[frame / block + 1]);
            start + (end - start) * (frame % block) as u64 / block as u64
        };
        for click_ms in &clicks_ms {
            // The loudest frame the clock places near the click.
            let loudest = (0..out.len() / 2)
                .filter(|frame| song_ms(*frame).abs_diff(*click_ms) <= 200)
                .max_by(|a, b| out[a * 2].abs().total_cmp(&out[b * 2].abs()))
                .expect("frames near the click");
            assert!(
                out[loudest * 2].abs() > 0.2,
                "click at {click_ms} ms is audible"
            );
            let heard = song_ms(loudest);
            assert!(
                heard.abs_diff(*click_ms) <= 30,
                "click at {click_ms} ms rendered at {heard} ms (tempo {tempo})"
            );
        }
    }
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn tempo_changes_speed_but_not_pitch() {
    let dir = temp_dir("tempo");
    let path = dir.join("tone.wav");
    write_wav(&path, RATE, RATE * 4, |f| sine(f, RATE));
    let engine = Engine::new(Output::Manual { sample_rate: RATE });
    engine
        .load("song", &[(SourceKind::Original, path)], 0)
        .unwrap();
    // Built (and warmed up) at load, so a speed change only switches it in.
    assert!(lock(&engine.shared.mixer).stretch.is_some());
    engine.play().unwrap();
    render(&engine, RATE as usize / 2);
    assert_eq!(engine.position_ms(), 500);
    // Half speed: two seconds of output are one second of song.
    engine.set_tempo(0.5).unwrap();
    let out = render(&engine, RATE as usize * 2);
    engine.pause();
    assert_eq!(engine.position_ms(), 1500);
    // The tone is still 440 Hz: 880 sign changes per second.
    let crossings = zero_crossings(&out[RATE as usize * 2..]);
    assert!(
        (836..=924).contains(&crossings),
        "{crossings} crossings in the last second"
    );
    // Out-of-range values are clamped; back to normal the bus is untouched.
    engine.set_tempo(9.0).unwrap();
    assert_eq!(engine.state()["tempo"], 1.5);
    engine.set_tempo(1.0).unwrap();
    engine.seek(1000).unwrap();
    engine.play().unwrap();
    let out = render(&engine, 16);
    assert!((out[2] - sine(RATE as usize + 1, RATE)).abs() < 1e-3);
    assert!(engine.set_tempo(f32::NAN).is_err());
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn key_changes_pitch_but_not_speed() {
    let dir = temp_dir("key");
    let path = dir.join("tone.wav");
    write_wav(&path, RATE, RATE * 4, |f| sine(f, RATE));
    let engine = Engine::new(Output::Manual { sample_rate: RATE });
    engine
        .load("song", &[(SourceKind::Original, path)], 0)
        .unwrap();
    engine.set_key(6.0).unwrap();
    assert_eq!(engine.state()["key"], 6.0);
    engine.play().unwrap();
    let out = render(&engine, RATE as usize * 2);
    engine.pause();
    assert_eq!(engine.position_ms(), 2000);
    // Six semitones up: 440 Hz × √2 ≈ 622 Hz, 1245 sign changes per second.
    let crossings = zero_crossings(&out[RATE as usize * 2..]);
    assert!(
        (1182..=1307).contains(&crossings),
        "{crossings} crossings in the last second"
    );
    engine.set_key(-40.0).unwrap();
    assert_eq!(engine.state()["key"], -6.0);
    assert!(engine.set_key(f32::INFINITY).is_err());
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn loop_repeats_the_range_until_cleared() {
    let dir = temp_dir("loop");
    let path = dir.join("tone.wav");
    write_wav(&path, RATE, RATE * 3, |f| sine(f, RATE));
    let engine = Engine::new(Output::Manual { sample_rate: RATE });
    engine
        .load("song", &[(SourceKind::Original, path)], 0)
        .unwrap();
    assert!(engine.set_loop(Some((500, 600))).is_err());
    engine.set_loop(Some((500, 1000))).unwrap();
    assert_eq!(engine.state()["loopStartMs"], 500);
    assert_eq!(engine.state()["loopEndMs"], 1000);
    engine.play().unwrap();
    let mut wraps = 0;
    let mut last = 0;
    let deadline = Instant::now() + Duration::from_secs(10);
    while wraps < 3 {
        assert!(Instant::now() < deadline, "the loop did not wrap");
        render(&engine, 480);
        let position = engine.position_ms();
        assert!(position <= 1010, "played past the loop end: {position}");
        if position < last {
            assert!((500..520).contains(&position), "wrapped to {position}");
            wraps += 1;
        }
        last = position;
        // The seek back happens on the loop thread.
        std::thread::sleep(Duration::from_millis(1));
    }
    engine.set_loop(None).unwrap();
    assert!(engine.state()["loopEndMs"].is_null());
    while engine.position_ms() < 1200 {
        assert!(Instant::now() < deadline, "playback did not leave the loop");
        render(&engine, 480);
    }
    let _ = std::fs::remove_dir_all(dir);
}
