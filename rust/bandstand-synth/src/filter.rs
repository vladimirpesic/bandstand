//! The SoundFont voice's low-pass filter.
//!
//! Rules: `docs/rules/sf2-sampler.md` §4.5.

use std::f32::consts::PI;

/// Highest cutoff the filter will be set to, as a fraction of the sample rate.
///
/// A biquad becomes unstable as the cutoff approaches Nyquist; SoundFont banks
/// routinely ask for 20 kHz, which at 44.1 kHz is close enough to matter.
const MAX_CUTOFF_FRACTION: f32 = 0.45;

/// Lowest cutoff, in hertz. Below this the filter is doing nothing but
/// removing the signal.
const MIN_CUTOFF_HZ: f32 = 20.0;

/// A two-pole resonant low-pass, as the SoundFont specification describes.
///
/// A direct-form biquad with coefficients recomputed when the cutoff moves.
/// Recomputation is per block rather than per sample: modulation moves the
/// cutoff smoothly, and a block is a few milliseconds.
#[derive(Debug, Clone)]
pub struct LowPassFilter {
    sample_rate: f32,
    cutoff: f32,
    resonance_db: f32,
    a1: f32,
    a2: f32,
    b0: f32,
    b1: f32,
    b2: f32,
    x1: f32,
    x2: f32,
    y1: f32,
    y2: f32,
    bypassed: bool,
}

impl LowPassFilter {
    /// Create a filter, open and silent.
    #[must_use]
    pub fn new(sample_rate: f32) -> Self {
        let mut filter = Self {
            sample_rate: sample_rate.max(1.0),
            cutoff: 20_000.0,
            resonance_db: 0.0,
            a1: 0.0,
            a2: 0.0,
            b0: 1.0,
            b1: 0.0,
            b2: 0.0,
            x1: 0.0,
            x2: 0.0,
            y1: 0.0,
            y2: 0.0,
            bypassed: true,
        };
        filter.set(20_000.0, 0.0);
        filter
    }

    /// Set the cutoff in hertz and the resonance in decibels.
    ///
    /// A cutoff at or above the usable limit bypasses the filter entirely,
    /// which is both cheaper and exactly what the bank meant.
    pub fn set(&mut self, cutoff_hz: f32, resonance_db: f32) {
        let limit = self.sample_rate * MAX_CUTOFF_FRACTION;
        let cutoff = cutoff_hz.clamp(MIN_CUTOFF_HZ, limit);
        let resonance = resonance_db.clamp(0.0, 24.0);
        if (cutoff - self.cutoff).abs() < 0.5 && (resonance - self.resonance_db).abs() < 0.01 {
            return;
        }
        self.cutoff = cutoff;
        self.resonance_db = resonance;
        let was_bypassed = self.bypassed;
        self.bypassed = cutoff >= limit - 1.0 && resonance <= 0.01;
        if self.bypassed {
            return;
        }
        if was_bypassed {
            // Re-engaging after a bypass period with the memory the active
            // phase left behind makes the first samples ring stale state —
            // a click. A fresh filter is what the bypass implied.
            self.reset();
        }

        // Q from the specification's centibel resonance: 0 dB is Q = 1/√2, the
        // flattest a two-pole gets.
        let q = 10.0f32.powf(resonance / 20.0) / std::f32::consts::SQRT_2;
        let omega = 2.0 * PI * cutoff / self.sample_rate;
        let (sin, cos) = omega.sin_cos();
        let alpha = sin / (2.0 * q.max(0.001));

        let a0 = 1.0 + alpha;
        self.b0 = (1.0 - cos) / 2.0 / a0;
        self.b1 = (1.0 - cos) / a0;
        self.b2 = self.b0;
        self.a1 = -2.0 * cos / a0;
        self.a2 = (1.0 - alpha) / a0;
    }

    /// Whether the filter is passing everything through untouched.
    #[must_use]
    pub const fn is_bypassed(&self) -> bool {
        self.bypassed
    }

    /// The cutoff currently set, in hertz.
    #[must_use]
    pub const fn cutoff(&self) -> f32 {
        self.cutoff
    }

    /// Filter one sample.
    pub fn process(&mut self, input: f32) -> f32 {
        if self.bypassed {
            return input;
        }
        let output = self.b0 * input + self.b1 * self.x1 + self.b2 * self.x2
            - self.a1 * self.y1
            - self.a2 * self.y2;
        // A denormal or a NaN in the state would poison every later sample and
        // cost a hundred times the CPU; clear it here rather than hunt it later.
        let output = if output.is_finite() { output } else { 0.0 };
        self.x2 = self.x1;
        self.x1 = input;
        self.y2 = self.y1;
        self.y1 = output;
        output
    }

    /// Forget the filter's memory, for a voice being reused.
    pub fn reset(&mut self) {
        self.x1 = 0.0;
        self.x2 = 0.0;
        self.y1 = 0.0;
        self.y2 = 0.0;
    }
}

#[cfg(test)]
// These tests assert the exact values the code produces — a silence that is
// zero, a gain that is one — so comparing floats is the point rather than a
// mistake. Casts in test arithmetic are likewise deliberate.
#[allow(
    clippy::float_cmp,
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    clippy::cast_precision_loss
)]
mod tests {
    use super::*;

    const SR: f32 = 48_000.0;

    /// The filter's gain at a frequency, measured rather than derived.
    fn gain_at(filter: &mut LowPassFilter, frequency: f32) -> f32 {
        filter.reset();
        let samples = (SR / frequency * 40.0) as usize;
        let mut peak = 0.0f32;
        for i in 0..samples {
            let phase = 2.0 * PI * frequency * i as f32 / SR;
            let out = filter.process(phase.sin());
            // Ignore the first few cycles while the filter settles.
            if i > samples / 2 {
                peak = peak.max(out.abs());
            }
        }
        peak
    }

    #[test]
    fn an_open_filter_passes_everything() {
        let mut filter = LowPassFilter::new(SR);
        filter.set(20_000.0, 0.0);
        assert!(filter.is_bypassed());
        assert_eq!(filter.process(0.5), 0.5);
    }

    #[test]
    fn it_passes_below_the_cutoff_and_stops_above_it() {
        let mut filter = LowPassFilter::new(SR);
        filter.set(1000.0, 0.0);
        assert!(!filter.is_bypassed());
        let low = gain_at(&mut filter, 100.0);
        let at = gain_at(&mut filter, 1000.0);
        let high = gain_at(&mut filter, 8000.0);
        assert!((low - 1.0).abs() < 0.05, "passband gain {low}");
        // Two poles: −3 dB at the corner, and steeply down after it.
        assert!(at < low && at > 0.5, "corner gain {at}");
        assert!(high < 0.05, "stopband gain {high}");
    }

    #[test]
    fn resonance_lifts_the_corner() {
        let mut flat = LowPassFilter::new(SR);
        flat.set(1000.0, 0.0);
        let mut resonant = LowPassFilter::new(SR);
        resonant.set(1000.0, 12.0);
        assert!(gain_at(&mut resonant, 1000.0) > gain_at(&mut flat, 1000.0) * 1.5);
    }

    #[test]
    fn the_cutoff_is_kept_away_from_nyquist() {
        let mut filter = LowPassFilter::new(SR);
        filter.set(1_000_000.0, 6.0);
        assert!(filter.cutoff() <= SR * MAX_CUTOFF_FRACTION);
        filter.set(0.0001, 0.0);
        assert!(filter.cutoff() >= MIN_CUTOFF_HZ);
    }

    #[test]
    fn it_stays_finite_however_it_is_driven() {
        let mut filter = LowPassFilter::new(SR);
        filter.set(200.0, 24.0);
        for i in 0..48_000 {
            let out = filter.process(if i % 2 == 0 { 1.0 } else { -1.0 });
            assert!(out.is_finite(), "sample {i} is {out}");
            assert!(out.abs() < 100.0, "sample {i} is {out}");
        }
    }

    #[test]
    fn a_non_finite_input_does_not_poison_the_state() {
        let mut filter = LowPassFilter::new(SR);
        filter.set(1000.0, 3.0);
        filter.process(f32::NAN);
        for _ in 0..100 {
            assert!(filter.process(0.5).is_finite());
        }
    }

    #[test]
    fn reset_clears_the_memory() {
        let mut filter = LowPassFilter::new(SR);
        filter.set(500.0, 0.0);
        for _ in 0..100 {
            filter.process(1.0);
        }
        let ringing = filter.process(0.0);
        filter.reset();
        assert!(filter.process(0.0).abs() < ringing.abs());
    }

    #[test]
    fn reengaging_after_a_bypass_starts_clean() {
        let mut filter = LowPassFilter::new(SR);
        filter.set(1000.0, 0.0);
        for _ in 0..100 {
            filter.process(1.0);
        }
        // A bypass period: the state is left with whatever the active phase
        // had accumulated, and `process` does not touch it while bypassed.
        // Above ~0.45 × the sample rate the filter declares itself bypassed.
        filter.set(1_000_000.0, 0.0);
        assert!(filter.is_bypassed());
        for _ in 0..100 {
            filter.process(1.0);
        }
        filter.set(1000.0, 0.0);
        // Silence in must be silence out: stale state would ring here.
        assert_eq!(filter.process(0.0), 0.0);
    }
}
