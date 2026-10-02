//! Reference test tone.
//!
//! The audio path — device, buffer size, channel layout, sample format, the FFI
//! boundary — is verified by playing a known signal and listening to it. This
//! is that signal, and it stays in the shipping build as the audio diagnostic
//! in Settings.
//!
//! It is a phase-accumulator sine, not a table lookup: exact frequency at any
//! sample rate, no interpolation error, and cheap enough that its cost is
//! irrelevant next to the sampler.

use std::f32::consts::TAU;

use crate::Smoothed;

/// Amplitude the tone uses when enabled, in linear gain. −18 dBFS: clearly
/// audible, and safe on headphones.
pub const DEFAULT_AMPLITUDE: f32 = 0.125;

/// Default frequency: A440, the reference every musician recognises instantly.
pub const DEFAULT_FREQUENCY_HZ: f32 = 440.0;

/// Time constant for gain and frequency glides, in milliseconds.
const GLIDE_MS: f64 = 15.0;

/// A click-free sine oscillator.
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
    fn silent_when_disabled() {
        let mut tone = TestTone::new(48_000.0);
        let mut buffer = vec![0.0f32; 512];
        tone.mix_into(&mut buffer, 2);
        assert!(peak(&buffer) < f32::EPSILON);
    }

    #[test]
    fn produces_signal_when_enabled() {
        let mut tone = TestTone::new(48_000.0);
        tone.set_enabled(true);
        let mut buffer = vec![0.0f32; 48_000 * 2];
        tone.mix_into(&mut buffer, 2);
        let p = peak(&buffer);
        assert!(p > 0.1 && p <= DEFAULT_AMPLITUDE + 1e-6, "peak {p}");
    }

    #[test]
    fn ramps_rather_than_stepping() {
        let mut tone = TestTone::new(48_000.0);
        tone.set_enabled(true);
        let mut buffer = vec![0.0f32; 64];
        tone.mix_into(&mut buffer, 1);
        // Within the first 64 samples the ramp is nowhere near full scale.
        assert!(peak(&buffer) < DEFAULT_AMPLITUDE * 0.5);
    }

    #[test]
    fn frequency_is_accurate() {
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
    fn sums_into_existing_content() {
        let mut tone = TestTone::new(48_000.0);
        tone.set_amplitude(1.0);
        let mut buffer = vec![0.5f32; 16];
        tone.mix_into(&mut buffer, 1);
        assert!(buffer.iter().any(|s| (*s - 0.5).abs() > 1e-9));
    }

    #[test]
    fn zero_channels_is_a_no_op() {
        let mut tone = TestTone::new(48_000.0);
        tone.set_enabled(true);
        let mut buffer = vec![0.0f32; 16];
        tone.mix_into(&mut buffer, 0);
        assert!(peak(&buffer) < f32::EPSILON);
    }
}
