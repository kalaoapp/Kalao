//! The position reported while a device plays. The output pulls audio in
//! blocks (about 45 ms on the emulator, sometimes late, and several at once
//! when a stream starts), so the song time of the frames handed to it moves
//! in steps and runs ahead in bursts. This clock advances with the wall clock
//! (× tempo) instead, and never past those frames: it holds only when the
//! output has nothing left to play.

use std::time::Instant;

struct Anchor {
    /// `Shared::clock_epoch` when anchored; a seek, load, stop or play bumps it.
    epoch: u32,
    /// Tempo in permille while anchored.
    tempo: u32,
    song_us: u64,
    at: Instant,
}

#[derive(Default)]
pub(crate) struct Clock {
    anchor: Option<Anchor>,
}

impl Clock {
    /// Song time in ms at `now`. `limit_ms` is the latest song time the
    /// output can be playing (frames handed to it, less known latency).
    pub(crate) fn position_ms(
        &mut self,
        limit_ms: u64,
        epoch: u32,
        tempo: u32,
        now: Instant,
    ) -> u64 {
        let limit_us = limit_ms.saturating_mul(1000);
        let estimate_us = self
            .anchor
            .as_ref()
            .filter(|anchor| anchor.epoch == epoch)
            .map(|anchor| {
                let elapsed_us =
                    u64::try_from(now.saturating_duration_since(anchor.at).as_micros())
                        .unwrap_or(u64::MAX);
                anchor
                    .song_us
                    .saturating_add(elapsed_us.saturating_mul(u64::from(anchor.tempo)) / 1000)
            });
        let song_us = match estimate_us {
            Some(estimate_us) if estimate_us < limit_us => estimate_us,
            _ => limit_us,
        };
        // Re-anchor on a new epoch, at the limit, or when the tempo changes,
        // so time before the change keeps the old rate.
        let keep = estimate_us.is_some_and(|estimate_us| estimate_us < limit_us)
            && self
                .anchor
                .as_ref()
                .is_some_and(|anchor| anchor.tempo == tempo);
        if !keep {
            self.anchor = Some(Anchor {
                epoch,
                tempo,
                song_us,
                at: now,
            });
        }
        song_us / 1000
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn ms(value: u64) -> Duration {
        Duration::from_millis(value)
    }

    #[test]
    fn starts_at_the_limit_and_follows_the_wall_clock() {
        let start = Instant::now();
        let mut clock = Clock::default();
        assert_eq!(clock.position_ms(1000, 0, 1000, start), 1000);
        // Several blocks handed over at once: the clock does not jump.
        assert_eq!(clock.position_ms(1180, 0, 1000, start + ms(20)), 1020);
        assert_eq!(clock.position_ms(1180, 0, 1000, start + ms(100)), 1100);
    }

    #[test]
    fn holds_at_the_limit_then_continues_from_there() {
        let start = Instant::now();
        let mut clock = Clock::default();
        clock.position_ms(0, 0, 1000, start);
        // The output starved: nothing past 50 ms was handed over.
        assert_eq!(clock.position_ms(50, 0, 1000, start + ms(80)), 50);
        assert_eq!(clock.position_ms(50, 0, 1000, start + ms(120)), 50);
        // Audio flows again; the clock resumes from where it held.
        assert_eq!(clock.position_ms(300, 0, 1000, start + ms(150)), 80);
    }

    #[test]
    fn a_new_epoch_restarts_at_the_limit() {
        let start = Instant::now();
        let mut clock = Clock::default();
        clock.position_ms(5000, 0, 1000, start);
        assert_eq!(clock.position_ms(60_000, 0, 1000, start + ms(10)), 5010);
        // Seek back: the old anchor would be ahead of the new limit anyway,
        // but a seek forward must not keep counting from before it.
        assert_eq!(clock.position_ms(60_000, 1, 1000, start + ms(20)), 60_000);
        assert_eq!(clock.position_ms(60_500, 1, 1000, start + ms(30)), 60_010);
    }

    #[test]
    fn tempo_scales_song_time_and_a_change_keeps_earlier_time() {
        let start = Instant::now();
        let mut clock = Clock::default();
        clock.position_ms(0, 0, 500, start);
        assert_eq!(clock.position_ms(1000, 0, 500, start + ms(100)), 50);
        // Faster from here on; the first 100 ms stay at half speed.
        assert_eq!(clock.position_ms(1000, 0, 1500, start + ms(100)), 50);
        assert_eq!(clock.position_ms(1000, 0, 1500, start + ms(200)), 200);
    }
}
