//! Parameter ramping.
//!
//! Every user-facing gain, pan or frequency control is stepped by the UI at
//! arbitrary moments. Applying such a step directly to a sample stream produces
//! a click. A ramped parameter crosses to its new value over a fixed number of
//! samples instead, which is inaudible.
//!
//! The ramp is **linear**, not one-pole. An exponential glide in `f32` stalls:
//! once the per-sample delta falls below one unit in the last place of the
//! current value, the parameter stops moving and never reaches its target. A
//! linear ramp arrives exactly, in a known number of samples, which also makes
//! it testable.

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
    #[must_use]
    pub const fn is_settled(&self) -> bool {
        self.remaining == 0
    }

    /// How many samples the ramp takes end to end.
    #[must_use]
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reaches_the_target_exactly() {
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
    fn never_jumps_in_a_single_sample() {
        let mut p = Smoothed::new(0.0, 48_000.0, 10.0);
        p.set_target(1.0);
        assert!(p.next_value() < 0.01);
    }

    #[test]
    fn moves_monotonically_towards_the_target() {
        let mut p = Smoothed::new(1.0, 48_000.0, 10.0);
        p.set_target(0.0);
        let mut previous = p.current();
        for _ in 0..p.ramp_samples() {
            let value = p.next_value();
            assert!(value <= previous + f32::EPSILON, "{value} > {previous}");
            previous = value;
        }
        assert!((p.current() - 0.0).abs() < f32::EPSILON);
    }

    #[test]
    fn retargeting_mid_ramp_starts_a_fresh_ramp() {
        let mut p = Smoothed::new(0.0, 48_000.0, 10.0);
        p.set_target(1.0);
        for _ in 0..100 {
            p.next_value();
        }
        p.set_target(0.5);
        for _ in 0..p.ramp_samples() {
            p.next_value();
        }
        assert!((p.current() - 0.5).abs() < f32::EPSILON);
    }

    #[test]
    fn settles_at_very_small_values_without_stalling() {
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
    fn reset_bypasses_the_ramp() {
        let mut p = Smoothed::new(0.0, 48_000.0, 10.0);
        p.reset(0.5);
        assert!((p.current() - 0.5).abs() < f32::EPSILON);
        assert!(p.is_settled());
    }
}
