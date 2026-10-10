//! Parameter ramping and the reference test tone.
//!
//! Ported out of the retired `bandstand-synth` crate when the pivot of ADR 0012
//! removed the sampler: a player that decodes files still needs click-free gain
//! changes, and the audio path still needs its known-good diagnostic signal.
//!
//! The ramp is **linear**, not one-pole. An exponential glide in `f32` stalls:
//! once the per-sample delta falls below one unit in the last place of the
//! current value, the parameter stops moving and never reaches its target. A
//! linear ramp arrives exactly, in a known number of samples, which also makes
//! it testable.
//!
//! The tone is a phase-accumulator sine, not a table lookup: exact frequency at
//! any sample rate, no interpolation error, and cheap enough that its cost is
//! irrelevant next to a decoder.

use std::f32::consts::TAU;

/// Time constant for gain and frequency glides, in milliseconds.
const GLIDE_MS: f64 = 15.0;

/// A parameter that ramps towards its target rather than jumping.
#[derive(Debug, Clone, Copy)]
pub struct Smoothed {
    current: f32,
    target: f32,
    step: f32,
    remaining: u32,
    ramp_samples: u32,
}

impl Smoothed {
    /// Create a parameter sitting at `value`, ramping over `time_ms`.
    ///
    /// # Panics
    /// Panics if `sample_rate` is not positive.
    #[must_use]
    pub fn new(value: f32, sample_rate: f64, time_ms: f64) -> Self {
        let mut smoothed = Self {
            current: value,
            target: value,
            step: 0.0,
            remaining: 0,
            ramp_samples: 1,
        };
        smoothed.set_ramp_time(sample_rate, time_ms);
        smoothed
    }

    /// Recompute the ramp length for a new sample rate or time constant.
    ///
    /// Any ramp in progress is restarted over the new length, so this is safe
    /// to call while sounding, though in practice it only happens when a stream
    /// opens.
    ///
    /// # Panics
    /// Panics if `sample_rate` is not positive.
    pub fn set_ramp_time(&mut self, sample_rate: f64, time_ms: f64) {
        assert!(sample_rate > 0.0, "sample rate must be positive");
        #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
        let samples = (time_ms / 1000.0 * sample_rate).round().max(1.0) as u32;
        self.ramp_samples = samples;
        if self.remaining > 0 {
            self.restart_ramp();
        }
    }

    fn restart_ramp(&mut self) {
        if (self.target - self.current).abs() < f32::EPSILON {
            self.current = self.target;
            self.remaining = 0;
            self.step = 0.0;
            return;
        }
        self.remaining = self.ramp_samples;
        #[allow(clippy::cast_precision_loss)]
        {
            self.step = (self.target - self.current) / self.ramp_samples as f32;
        }
    }

    /// Aim at a new value.
    pub fn set_target(&mut self, target: f32) {
        if (target - self.target).abs() < f32::EPSILON {
            return;
        }
        self.target = target;
        self.restart_ramp();
    }

    /// Jump straight to a value, bypassing the ramp. Use only when silent.
    ///
    /// Unused by the tone-and-gain engine today; the file player of ADR 0012
    /// will need it, and the tests exercise it.
    #[allow(dead_code)]
    pub fn reset(&mut self, value: f32) {
        self.current = value;
        self.target = value;
        self.step = 0.0;
        self.remaining = 0;
    }

    /// The value being ramped towards.
    #[must_use]
    pub const fn target(&self) -> f32 {
        self.target
    }

    /// The current value, without advancing.
    #[must_use]
    pub const fn current(&self) -> f32 {
        self.current
    }

    /// Whether the ramp has finished.
    ///
    /// Exercised by tests; the player will read it to know when a gain change
    /// has landed.
    #[allow(dead_code)]
    pub const fn is_settled(&self) -> bool {
        self.remaining == 0
    }

    /// How many samples the ramp takes end to end.
    ///
    /// Exercised by tests; the player will need it to schedule downstream work
    /// that must wait for a glide to land.
    #[allow(dead_code)]
    pub const fn ramp_samples(&self) -> u32 {
        self.ramp_samples
    }

    /// Advance one sample and return the new value.
    pub fn next_value(&mut self) -> f32 {
        if self.remaining == 0 {
            return self.current;
        }
        self.remaining -= 1;
        if self.remaining == 0 {
            self.current = self.target;
        } else {
            self.current += self.step;
        }
        self.current
    }
}

/// Amplitude the tone uses when enabled, in linear gain. −18 dBFS: clearly
/// audible, and safe on headphones.
pub const DEFAULT_AMPLITUDE: f32 = 0.125;

/// Default frequency: A440, the reference every musician recognises instantly.
pub const DEFAULT_FREQUENCY_HZ: f32 = 440.0;

/// A click-free sine oscillator.
///
/// The audio path — device, buffer size, channel layout, sample format, the FFI
/// boundary — is verified by playing a known signal and listening to it. This
/// is that signal, and it stays in the shipping build as the audio diagnostic.
#[derive(Debug)]
pub struct TestTone {
    sample_rate: f64,
    phase: f32,
    amplitude: Smoothed,
    frequency: Smoothed,
}

impl TestTone {
    /// Create a silent tone at the given sample rate.
    #[must_use]
    pub fn new(sample_rate: f64) -> Self {
        Self {
            sample_rate,
            phase: 0.0,
            amplitude: Smoothed::new(0.0, sample_rate, GLIDE_MS),
            frequency: Smoothed::new(DEFAULT_FREQUENCY_HZ, sample_rate, GLIDE_MS),
        }
    }

    /// Reconfigure for a new sample rate. Resets the phase; call only when
    /// silent (i.e. when a stream is opening).
    pub fn set_sample_rate(&mut self, sample_rate: f64) {
        self.sample_rate = sample_rate;
        self.phase = 0.0;
        self.amplitude.set_ramp_time(sample_rate, GLIDE_MS);
        self.frequency.set_ramp_time(sample_rate, GLIDE_MS);
    }

    /// Turn the tone on or off. The change is ramped, so this is click-free.
    ///
    /// Unused by the engine, which drives the amplitude directly through
    /// [`ToneControls`]; kept because the player-side channel mute wants the
    /// same click-free toggle, and the tests exercise it.
    #[allow(dead_code)]
    pub fn set_enabled(&mut self, enabled: bool) {
        self.amplitude
            .set_target(if enabled { DEFAULT_AMPLITUDE } else { 0.0 });
    }

    /// Set the amplitude directly, in linear gain, clamped to `0.0..=1.0`.
    pub fn set_amplitude(&mut self, amplitude: f32) {
        self.amplitude.set_target(amplitude.clamp(0.0, 1.0));
    }

    /// Set the frequency in hertz, clamped to the audible range.
    pub fn set_frequency(&mut self, hz: f32) {
        self.frequency.set_target(hz.clamp(20.0, 20_000.0));
    }

    /// Whether the tone is currently producing any signal. False once a
    /// switched-off tone has finished ramping down.
    #[must_use]
    pub fn is_audible(&self) -> bool {
        self.amplitude.current() > 1.0e-6 || self.amplitude.target() > 0.0
    }

    /// Add the tone into an interleaved output buffer.
    ///
    /// The buffer is *summed into*, not overwritten, so the tone can coexist
    /// with anything else on the bus. `channels` must divide `output.len()`.
    pub fn mix_into(&mut self, output: &mut [f32], channels: usize) {
        if channels == 0 {
            return;
        }
        if !self.is_audible() {
            // Keep the phase coherent so re-enabling does not click.
            return;
        }
        #[allow(clippy::cast_possible_truncation)]
        let inv_sample_rate = (1.0 / self.sample_rate) as f32;
        for frame in output.chunks_mut(channels) {
            let amplitude = self.amplitude.next_value();
            let frequency = self.frequency.next_value();
            let sample = (self.phase * TAU).sin() * amplitude;
            self.phase += frequency * inv_sample_rate;
            if self.phase >= 1.0 {
                self.phase -= 1.0;
            }
            for slot in frame.iter_mut() {
                *slot += sample;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn peak(buffer: &[f32]) -> f32 {
        buffer.iter().fold(0.0f32, |acc, s| acc.max(s.abs()))
    }

    #[test]
    fn ramp_reaches_the_target_exactly() {
        let mut p = Smoothed::new(0.0, 48_000.0, 10.0);
        p.set_target(1.0);
        for _ in 0..p.ramp_samples() {
            p.next_value();
        }
        assert!(p.is_settled());
        assert!((p.current() - 1.0).abs() < f32::EPSILON, "{}", p.current());
    }

    #[test]
    fn ramp_length_follows_the_time_constant() {
        let p = Smoothed::new(0.0, 48_000.0, 10.0);
        assert_eq!(p.ramp_samples(), 480);
        let q = Smoothed::new(0.0, 44_100.0, 5.0);
        assert_eq!(q.ramp_samples(), 221);
    }

    #[test]
    fn ramp_never_jumps_in_a_single_sample() {
        let mut p = Smoothed::new(0.0, 48_000.0, 10.0);
        p.set_target(1.0);
        assert!(p.next_value() < 0.01);
    }

    #[test]
    fn ramp_settles_at_very_small_values_without_stalling() {
        // The failure mode a one-pole ramp has in f32: a target close to the
        // current value must still be reached exactly.
        let mut p = Smoothed::new(1.0, 48_000.0, 10.0);
        p.set_target(1.000_01);
        for _ in 0..p.ramp_samples() {
            p.next_value();
        }
        assert!(p.is_settled());
        assert!((p.current() - 1.000_01).abs() < 1e-6, "{}", p.current());
    }

    #[test]
    fn tone_is_silent_when_disabled() {
        let mut tone = TestTone::new(48_000.0);
        let mut buffer = vec![0.0f32; 512];
        tone.mix_into(&mut buffer, 2);
        assert!(peak(&buffer) < f32::EPSILON);
    }

    #[test]
    fn tone_produces_signal_when_enabled() {
        let mut tone = TestTone::new(48_000.0);
        tone.set_enabled(true);
        let mut buffer = vec![0.0f32; 48_000 * 2];
        tone.mix_into(&mut buffer, 2);
        let p = peak(&buffer);
        assert!(p > 0.1 && p <= DEFAULT_AMPLITUDE + 1e-6, "peak {p}");
    }

    #[test]
    fn tone_ramps_rather_than_stepping() {
        let mut tone = TestTone::new(48_000.0);
        tone.set_enabled(true);
        let mut buffer = vec![0.0f32; 64];
        tone.mix_into(&mut buffer, 1);
        // Within the first 64 samples the ramp is nowhere near full scale.
        assert!(peak(&buffer) < DEFAULT_AMPLITUDE * 0.5);
    }

    #[test]
    fn tone_frequency_is_accurate() {
        let mut tone = TestTone::new(48_000.0);
        tone.set_amplitude(1.0);
        tone.set_frequency(1000.0);
        // Let the glides settle before measuring.
        let mut warmup = vec![0.0f32; 48_000];
        tone.mix_into(&mut warmup, 1);

        let mut buffer = vec![0.0f32; 48_000];
        tone.mix_into(&mut buffer, 1);
        let mut zero_crossings = 0usize;
        for pair in buffer.windows(2) {
            if pair[0] < 0.0 && pair[1] >= 0.0 {
                zero_crossings += 1;
            }
        }
        // One rising zero crossing per cycle: 1000 in one second.
        assert!(
            (999..=1001).contains(&zero_crossings),
            "{zero_crossings} crossings"
        );
    }

    #[test]
    fn tone_sums_into_existing_content() {
        let mut tone = TestTone::new(48_000.0);
        tone.set_amplitude(1.0);
        let mut buffer = vec![0.5f32; 16];
        tone.mix_into(&mut buffer, 1);
        assert!(buffer.iter().any(|s| (*s - 0.5).abs() > 1e-9));
    }

    #[test]
    fn tone_zero_channels_is_a_no_op() {
        let mut tone = TestTone::new(48_000.0);
        tone.set_enabled(true);
        let mut buffer = vec![0.0f32; 16];
        tone.mix_into(&mut buffer, 0);
        assert!(peak(&buffer) < f32::EPSILON);
    }
}
