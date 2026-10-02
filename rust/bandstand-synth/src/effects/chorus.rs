//! A three-voice chorus.
//!
//! Rules: `docs/rules/sf2-sampler.md` §6. Three delay lines, each modulated by
//! an LFO at a slightly different rate and panned differently, which is what
//! turns one signal into several that are almost the same.

use crate::lfo::Lfo;

/// How long the delay lines are, in milliseconds. Long enough to detune, short
/// enough not to be an echo.
const MAX_DELAY_MS: f32 = 40.0;

/// The three taps: LFO rate in hertz, depth in milliseconds, base delay in
/// milliseconds, and pan from −1 to 1.
const TAPS: [(f32, f32, f32, f32); 3] = [
    (0.7, 2.0, 12.0, -0.8),
    (1.1, 2.6, 18.0, 0.0),
    (1.5, 2.2, 25.0, 0.8),
];

/// A stereo chorus on a bus.
#[derive(Debug)]
pub struct Chorus {
    buffer: Vec<f32>,
    write: usize,
    lfos: Vec<Lfo>,
    sample_rate: f32,
    depth: f32,
    wet: f32,
}

impl Chorus {
    /// Create a chorus for an output rate. Every buffer is allocated here.
    #[must_use]
    pub fn new(sample_rate: f32) -> Self {
        let rate = sample_rate.max(1.0);
        #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
        let length = ((MAX_DELAY_MS / 1000.0) * rate).ceil() as usize + 4;
        Self {
            buffer: vec![0.0; length],
            write: 0,
            lfos: TAPS
                .iter()
                .map(|(frequency, _, _, _)| Lfo::new(*frequency, 0.0, rate))
                .collect(),
            sample_rate: rate,
            depth: 1.0,
            wet: 0.5,
        }
    }

    /// Set how far the delays are modulated, 0 to 1.
    pub fn set_depth(&mut self, depth: f32) {
        self.depth = depth.clamp(0.0, 1.0);
    }

    /// Set how much chorus reaches the output, 0 to 1.
    pub fn set_wet(&mut self, wet: f32) {
        self.wet = wet.clamp(0.0, 1.0);
    }

    /// Add the chorus of `send` into `left` and `right`.
    ///
    /// Every buffer is the same length, and none is allocated here.
    ///
    /// The casts here convert between a tap count and a gain, and between a
    /// delay in frames and an index; both are small and deliberate.
    #[allow(clippy::cast_precision_loss, clippy::cast_possible_truncation)]
    pub fn process(&mut self, send: &[f32], left: &mut [f32], right: &mut [f32]) {
        debug_assert_eq!(
            send.len(),
            left.len(),
            "chorus buffers must be the same length"
        );
        debug_assert_eq!(
            send.len(),
            right.len(),
            "chorus buffers must be the same length"
        );
        if self.wet <= 0.0 {
            // Still advance the write head, so switching it on does not replay
            // a buffer of stale audio.
            for value in send {
                self.buffer[self.write] = *value;
                self.write = (self.write + 1) % self.buffer.len();
            }
            for lfo in &mut self.lfos {
                for _ in send {
                    lfo.next_value();
                }
            }
            return;
        }

        for i in 0..send.len() {
            self.buffer[self.write] = send[i];

            let mut out_left = 0.0;
            let mut out_right = 0.0;
            for (tap, (_, depth_ms, base_ms, pan)) in TAPS.iter().enumerate() {
                let modulation = self.lfos[tap].next_value() * self.depth;
                let delay_ms = base_ms + modulation * depth_ms;
                let delayed = self.read_delayed(delay_ms);
                let angle = (pan + 1.0) * std::f32::consts::FRAC_PI_4;
                out_left += delayed * angle.cos();
                out_right += delayed * angle.sin();
            }

            let gain = self.wet / TAPS.len() as f32;
            left[i] += out_left * gain;
            right[i] += out_right * gain;

            self.write = (self.write + 1) % self.buffer.len();
        }
    }

    /// Read the delay line `delay_ms` in the past, interpolating between
    /// samples so the modulation glides rather than steps.
    #[allow(clippy::cast_precision_loss, clippy::cast_possible_truncation)]
    fn read_delayed(&self, delay_ms: f32) -> f32 {
        let frames =
            (delay_ms / 1000.0 * self.sample_rate).clamp(1.0, (self.buffer.len() - 2) as f32);
        #[allow(clippy::cast_sign_loss)]
        let whole = frames as usize;
        let fraction = frames - whole as f32;

        let length = self.buffer.len();
        let first = (self.write + length - whole) % length;
        let second = (first + length - 1) % length;
        self.buffer[first] * (1.0 - fraction) + self.buffer[second] * fraction
    }

    /// Forget the delay line, for a transport stop.
    pub fn clear(&mut self) {
        self.buffer.fill(0.0);
        self.write = 0;
        for lfo in &mut self.lfos {
            lfo.reset();
        }
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

    fn peak(buffer: &[f32]) -> f32 {
        buffer.iter().fold(0.0f32, |acc, s| acc.max(s.abs()))
    }

    #[test]
    fn silence_in_is_silence_out() {
        let mut chorus = Chorus::new(SR);
        let send = vec![0.0f32; 512];
        let mut left = vec![0.0f32; 512];
        let mut right = vec![0.0f32; 512];
        chorus.process(&send, &mut left, &mut right);
        assert_eq!(peak(&left), 0.0);
    }

    #[test]
    fn a_signal_comes_back_delayed() {
        let mut chorus = Chorus::new(SR);
        let mut send = vec![0.0f32; 8192];
        send[0] = 1.0;
        let mut left = vec![0.0f32; 8192];
        let mut right = vec![0.0f32; 8192];
        chorus.process(&send, &mut left, &mut right);
        // Nothing in the first few milliseconds: the shortest tap is 12 ms.
        assert_eq!(peak(&left[..400]), 0.0);
        assert!(peak(&left) > 0.0, "nothing came back");
    }

    #[test]
    fn the_two_channels_differ() {
        let mut chorus = Chorus::new(SR);
        let mut send = vec![0.0f32; 8192];
        for (i, value) in send.iter_mut().enumerate() {
            *value = (i as f32 * 0.01).sin();
        }
        let mut left = vec![0.0f32; 8192];
        let mut right = vec![0.0f32; 8192];
        chorus.process(&send, &mut left, &mut right);
        let difference: f32 = left
            .iter()
            .zip(right.iter())
            .map(|(l, r)| (l - r).abs())
            .sum();
        assert!(difference > 0.0);
    }

    #[test]
    fn it_stays_finite_and_bounded() {
        let mut chorus = Chorus::new(SR);
        for _ in 0..200 {
            let send = vec![1.0f32; 1024];
            let mut left = vec![0.0f32; 1024];
            let mut right = vec![0.0f32; 1024];
            chorus.process(&send, &mut left, &mut right);
            for value in left.iter().chain(right.iter()) {
                assert!(value.is_finite());
                assert!(value.abs() < 10.0, "{value}");
            }
        }
    }

    #[test]
    fn a_dry_setting_produces_nothing_but_still_fills_the_line() {
        let mut chorus = Chorus::new(SR);
        chorus.set_wet(0.0);
        let send = vec![1.0f32; 4096];
        let mut left = vec![0.0f32; 4096];
        let mut right = vec![0.0f32; 4096];
        chorus.process(&send, &mut left, &mut right);
        assert_eq!(peak(&left), 0.0);

        // Turning it on now plays what has been going in, not stale silence
        // followed by a jump.
        chorus.set_wet(1.0);
        let quiet = vec![0.0f32; 4096];
        let mut l = vec![0.0f32; 4096];
        let mut r = vec![0.0f32; 4096];
        chorus.process(&quiet, &mut l, &mut r);
        assert!(peak(&l) > 0.0);
    }

    #[test]
    fn clearing_empties_the_line() {
        let mut chorus = Chorus::new(SR);
        let send = vec![1.0f32; 4096];
        let mut left = vec![0.0f32; 4096];
        let mut right = vec![0.0f32; 4096];
        chorus.process(&send, &mut left, &mut right);
        chorus.clear();

        let quiet = vec![0.0f32; 4096];
        let mut l = vec![0.0f32; 4096];
        let mut r = vec![0.0f32; 4096];
        chorus.process(&quiet, &mut l, &mut r);
        assert_eq!(peak(&l), 0.0);
    }
}
