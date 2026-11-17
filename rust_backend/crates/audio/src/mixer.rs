//! The callback-side mix: pulls the same frame count from every source, applies
//! ramped gains and writes the output bus. Only the audio callback (or a test
//! driving `Engine::render`) touches `Mixer`.

use crate::SourceKind;
use signalsmith_stretch::Stretch;
use std::f32::consts::FRAC_PI_2;

/// How the loaded sources combine, decided at load time.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Layout {
    /// One file: plays at unity.
    Single,
    /// Imported original + instrumental: equal-power blend by vocal level.
    Pair,
    /// Separated stems: instrumental at the backing level, vocals at the vocal level.
    Stems,
}

impl Layout {
    pub fn for_kinds(kinds: &[SourceKind]) -> Self {
        let has = |kind| kinds.contains(&kind);
        if has(SourceKind::Vocals) && has(SourceKind::Instrumental) {
            Self::Stems
        } else if has(SourceKind::Original) && has(SourceKind::Instrumental) {
            Self::Pair
        } else {
            Self::Single
        }
    }

    /// Gain for a source of `kind` at vocal level `vocal` and backing level
    /// `backing` (both 0–1).
    pub fn gain(self, kind: SourceKind, vocal: f32, backing: f32) -> f32 {
        match (self, kind) {
            (Self::Single, _) => 1.0,
            (Self::Pair, SourceKind::Original) => (vocal * FRAC_PI_2).sin(),
            (Self::Pair, SourceKind::Instrumental) => (vocal * FRAC_PI_2).cos(),
            (Self::Stems, SourceKind::Vocals) => vocal,
            (Self::Stems, SourceKind::Instrumental) => backing,
            _ => 0.0,
        }
    }
}

/// A value moving linearly to a target over a number of frames.
#[derive(Clone, Copy, Debug)]
pub struct Ramp {
    pub current: f32,
    target: f32,
    step: f32,
    remaining: u32,
}

impl Ramp {
    pub fn new(value: f32) -> Self {
        Self {
            current: value,
            target: value,
            step: 0.0,
            remaining: 0,
        }
    }

    pub fn set(&mut self, target: f32, frames: u32) {
        self.target = target;
        if frames == 0 {
            self.current = target;
            self.remaining = 0;
        } else {
            self.step = (target - self.current) / frames as f32;
            self.remaining = frames;
        }
    }

    #[inline]
    pub fn next(&mut self) -> f32 {
        if self.remaining > 0 {
            self.remaining -= 1;
            self.current = if self.remaining == 0 {
                self.target
            } else {
                self.current + self.step
            };
        }
        self.current
    }

    #[cfg(test)]
    pub fn is_steady(&self) -> bool {
        self.remaining == 0
    }
}

pub struct Mixer {
    pub vocal: Ramp,
    pub backing: Ramp,
    pub volume: Ramp,
    pub mix_generation: u32,
    /// One stereo buffer per source, reused across callbacks.
    pub scratch: Vec<Vec<f32>>,
    /// The mixed stereo bus, reused across callbacks.
    pub bus: Vec<f32>,
    /// Key and tempo on the bus (IMPLEMENTATION.md §2), created by the
    /// control thread the first time either is not neutral.
    pub stretch: Option<Stretch>,
    /// The output rate `stretch` was built for.
    pub stretch_rate: u32,
    pub stretch_generation: u32,
    /// The transposition last given to `stretch`, in cents.
    pub stretch_key: i32,
    /// The stretcher's output, reused across callbacks.
    pub stretched: Vec<f32>,
    /// Fraction of a source frame owed to the next callback at tempo ≠ 1.
    pub carry: f64,
}

impl Mixer {
    pub fn new(vocal: f32, backing: f32, volume: f32) -> Self {
        Self {
            vocal: Ramp::new(vocal),
            backing: Ramp::new(backing),
            volume: Ramp::new(volume),
            mix_generation: 0,
            scratch: Vec::new(),
            bus: Vec::new(),
            stretch: None,
            stretch_rate: 0,
            stretch_generation: 0,
            stretch_key: 0,
            stretched: Vec::new(),
            carry: 0.0,
        }
    }

    /// Mixes `frames` stereo frames from `inputs` (already filled, one per
    /// kind) into `bus` (stereo, `frames * 2` samples).
    pub fn mix(&mut self, layout: Layout, kinds: &[SourceKind], frames: usize, bus: &mut [f32]) {
        for frame in 0..frames {
            let vocal = self.vocal.next();
            let backing = self.backing.next();
            let volume = self.volume.next();
            let (mut left, mut right) = (0.0, 0.0);
            for (input, kind) in self.scratch.iter().zip(kinds) {
                let gain = layout.gain(*kind, vocal, backing);
                left += input[frame * 2] * gain;
                right += input[frame * 2 + 1] * gain;
            }
            bus[frame * 2] = soft_limit(left * volume);
            bus[frame * 2 + 1] = soft_limit(right * volume);
        }
    }
}

/// Linear up to 0.8, then a tanh knee that never exceeds 1.0.
#[inline]
pub fn soft_limit(sample: f32) -> f32 {
    const KNEE: f32 = 0.8;
    let magnitude = sample.abs();
    if magnitude <= KNEE {
        sample
    } else {
        sample.signum() * (KNEE + (1.0 - KNEE) * ((magnitude - KNEE) / (1.0 - KNEE)).tanh())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layouts_follow_the_loaded_kinds() {
        use SourceKind::*;
        assert_eq!(Layout::for_kinds(&[Original]), Layout::Single);
        assert_eq!(Layout::for_kinds(&[Original, Instrumental]), Layout::Pair);
        assert_eq!(Layout::for_kinds(&[Vocals, Instrumental]), Layout::Stems);
    }

    #[test]
    fn pair_blend_is_equal_power() {
        for step in 0..=10 {
            let vocal = step as f32 / 10.0;
            let original = Layout::Pair.gain(SourceKind::Original, vocal, 1.0);
            let instrumental = Layout::Pair.gain(SourceKind::Instrumental, vocal, 1.0);
            assert!((original * original + instrumental * instrumental - 1.0).abs() < 1e-5);
        }
        assert_eq!(Layout::Pair.gain(SourceKind::Original, 1.0, 1.0), 1.0);
        assert!(Layout::Pair.gain(SourceKind::Instrumental, 1.0, 1.0).abs() < 1e-6);
    }

    #[test]
    fn ramp_reaches_its_target_exactly() {
        let mut ramp = Ramp::new(0.0);
        ramp.set(1.0, 4);
        let values: Vec<f32> = (0..5).map(|_| ramp.next()).collect();
        assert_eq!(values, [0.25, 0.5, 0.75, 1.0, 1.0]);
        assert!(ramp.is_steady());
    }

    #[test]
    fn soft_limit_is_transparent_below_the_knee_and_bounded_above() {
        assert_eq!(soft_limit(0.5), 0.5);
        assert_eq!(soft_limit(-0.8), -0.8);
        assert!(soft_limit(5.0) <= 1.0 && soft_limit(5.0) > 0.99);
        assert!(soft_limit(-5.0) >= -1.0);
    }
}
