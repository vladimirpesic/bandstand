//! The SoundFont modulation and vibrato LFOs.
//!
//! Rules: `docs/rules/sf2-sampler.md` §4.
//!
//! Triangle, as the specification says, running −1 to +1, with a delay before
//! it starts. Both LFOs a voice has are this.

/// A triangle LFO with a delay.
#[derive(Debug, Clone)]
pub struct Lfo {
    sample_rate: f32,
    increment: f32,
    phase: f32,
    delay_samples: u32,
    waited: u32,
}

impl Lfo {
    /// Create an LFO at `frequency` hertz, starting after `delay` seconds.
    #[must_use]
    pub fn new(frequency_hz: f32, delay_seconds: f32, sample_rate: f32) -> Self {
        let mut lfo = Self {
            sample_rate: sample_rate.max(1.0),
            increment: 0.0,
            phase: 0.0,
            delay_samples: 0,
            waited: 0,
        };
        lfo.set(frequency_hz, delay_seconds);
        lfo
    }

    /// Set the frequency and delay, and restart.
    pub fn set(&mut self, frequency_hz: f32, delay_seconds: f32) {
        self.increment = frequency_hz.clamp(0.0, 100.0) / self.sample_rate;
        #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
        {
            self.delay_samples = (delay_seconds.max(0.0) * self.sample_rate).round() as u32;
        }
        self.phase = 0.0;
        self.waited = 0;
    }

    /// The current output, without advancing.
    ///
    /// A triangle from 0, rising to +1, down through 0 to −1, and back. Starting
    /// at zero matters: an LFO that starts at its peak makes every note begin
    /// detuned.
    #[must_use]
    pub fn value(&self) -> f32 {
        if self.waited < self.delay_samples {
            return 0.0;
        }
        let phase = self.phase;
        if phase < 0.25 {
            phase * 4.0
        } else if phase < 0.75 {
            2.0 - phase * 4.0
        } else {
            phase * 4.0 - 4.0
        }
    }

    /// Advance one sample and return the new output.
    pub fn next_value(&mut self) -> f32 {
        if self.waited < self.delay_samples {
            self.waited += 1;
            return 0.0;
        }
        self.phase += self.increment;
        if self.phase >= 1.0 {
            self.phase -= 1.0;
        }
        self.value()
    }

    /// Restart from the beginning of the delay.
    pub fn reset(&mut self) {
        self.phase = 0.0;
        self.waited = 0;
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

    #[test]
    fn it_starts_at_zero_so_a_note_does_not_begin_detuned() {
        let lfo = Lfo::new(5.0, 0.0, SR);
        assert_eq!(lfo.value(), 0.0);
    }

    #[test]
    fn it_traces_a_triangle_between_minus_one_and_one() {
        let mut lfo = Lfo::new(1.0, 0.0, SR);
        let quarter = (SR / 4.0) as usize;
        for _ in 0..quarter {
            lfo.next_value();
        }
        assert!((lfo.value() - 1.0).abs() < 0.01, "peak {}", lfo.value());
        for _ in 0..(quarter * 2) {
            lfo.next_value();
        }
        assert!((lfo.value() + 1.0).abs() < 0.01, "trough {}", lfo.value());
        for _ in 0..quarter {
            lfo.next_value();
        }
        assert!(lfo.value().abs() < 0.01, "back to zero {}", lfo.value());
    }

    #[test]
    fn it_never_leaves_minus_one_to_one() {
        let mut lfo = Lfo::new(7.3, 0.0, SR);
        for _ in 0..(SR as usize) {
            let value = lfo.next_value();
            assert!((-1.0..=1.0).contains(&value), "{value}");
        }
    }

    #[test]
    fn the_delay_holds_it_at_zero() {
        let mut lfo = Lfo::new(10.0, 0.1, SR);
        for _ in 0..4000 {
            assert_eq!(lfo.next_value(), 0.0);
        }
        let mut moved = false;
        for _ in 0..4000 {
            if lfo.next_value().abs() > 0.1 {
                moved = true;
            }
        }
        assert!(moved, "the LFO never started");
    }

    #[test]
    fn a_frequency_of_zero_stays_still() {
        let mut lfo = Lfo::new(0.0, 0.0, SR);
        for _ in 0..1000 {
            assert_eq!(lfo.next_value(), 0.0);
        }
    }

    #[test]
    fn reset_puts_it_back_to_the_start_of_the_delay() {
        let mut lfo = Lfo::new(5.0, 0.05, SR);
        for _ in 0..10_000 {
            lfo.next_value();
        }
        lfo.reset();
        assert_eq!(lfo.next_value(), 0.0);
    }
}
