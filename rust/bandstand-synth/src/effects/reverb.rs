//! A Freeverb-class reverb.
//!
//! Rules: `docs/rules/sf2-sampler.md` §6. Eight parallel comb filters into four
//! series all-passes, per channel, with the right channel's delays offset so
//! the two sides decorrelate.
//!
//! Nothing fancy, and deliberately so: §7.2 asks for "a decent reverb
//! (Freeverb-class is fine)". What it must be is cheap, stable, and allocated
//! once.

/// Comb delay lengths, in frames at 44.1 kHz, from the original Freeverb.
const COMB_TUNING: [usize; 8] = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617];

/// All-pass delay lengths, in frames at 44.1 kHz.
const ALLPASS_TUNING: [usize; 4] = [556, 441, 341, 225];

/// How much the right channel's delays are offset, in frames at 44.1 kHz.
const STEREO_SPREAD: usize = 23;

/// The rate the tunings above were chosen at.
const TUNING_RATE: f32 = 44_100.0;

const FIXED_GAIN: f32 = 0.015;
const DAMP_SCALE: f32 = 0.4;
const ROOM_SCALE: f32 = 0.28;
const ROOM_OFFSET: f32 = 0.7;

/// A comb filter with a one-pole damper in its feedback path.
#[derive(Debug)]
struct Comb {
    buffer: Vec<f32>,
    index: usize,
    filter_store: f32,
    feedback: f32,
    damp1: f32,
    damp2: f32,
}

impl Comb {
    fn new(length: usize) -> Self {
        Self {
            buffer: vec![0.0; length.max(1)],
            index: 0,
            filter_store: 0.0,
            feedback: 0.5,
            damp1: 0.5,
            damp2: 0.5,
        }
    }

    fn set_damping(&mut self, damping: f32) {
        self.damp1 = damping;
        self.damp2 = 1.0 - damping;
    }

    fn process(&mut self, input: f32) -> f32 {
        let output = self.buffer[self.index];
        self.filter_store = output * self.damp2 + self.filter_store * self.damp1;
        if !self.filter_store.is_finite() {
            self.filter_store = 0.0;
        }
        let value = input + self.filter_store * self.feedback;
        self.buffer[self.index] = if value.is_finite() { value } else { 0.0 };
        self.index += 1;
        if self.index >= self.buffer.len() {
            self.index = 0;
        }
        output
    }

    fn clear(&mut self) {
        self.buffer.fill(0.0);
        self.filter_store = 0.0;
        self.index = 0;
    }
}

/// A Schroeder all-pass.
#[derive(Debug)]
struct AllPass {
    buffer: Vec<f32>,
    index: usize,
    feedback: f32,
}

impl AllPass {
    fn new(length: usize) -> Self {
        Self {
            buffer: vec![0.0; length.max(1)],
            index: 0,
            feedback: 0.5,
        }
    }

    fn process(&mut self, input: f32) -> f32 {
        let buffered = self.buffer[self.index];
        let output = -input + buffered;
        let value = input + buffered * self.feedback;
        self.buffer[self.index] = if value.is_finite() { value } else { 0.0 };
        self.index += 1;
        if self.index >= self.buffer.len() {
            self.index = 0;
        }
        output
    }

    fn clear(&mut self) {
        self.buffer.fill(0.0);
        self.index = 0;
    }
}

/// A stereo reverb on a bus.
#[derive(Debug)]
pub struct Reverb {
    combs_left: Vec<Comb>,
    combs_right: Vec<Comb>,
    allpasses_left: Vec<AllPass>,
    allpasses_right: Vec<AllPass>,
    wet: f32,
    room_size: f32,
    damping: f32,
    width: f32,
}

impl Reverb {
    /// Create a reverb for an output rate. Every buffer is allocated here.
    #[must_use]
    pub fn new(sample_rate: f32) -> Self {
        let scale = |length: usize, offset: usize| -> usize {
            #[allow(
                clippy::cast_possible_truncation,
                clippy::cast_sign_loss,
                clippy::cast_precision_loss
            )]
            {
                (((length + offset) as f32) * sample_rate.max(1.0) / TUNING_RATE).round() as usize
            }
        };
        let mut reverb = Self {
            combs_left: COMB_TUNING
                .iter()
                .map(|&l| Comb::new(scale(l, 0)))
                .collect(),
            combs_right: COMB_TUNING
                .iter()
                .map(|&l| Comb::new(scale(l, STEREO_SPREAD)))
                .collect(),
            allpasses_left: ALLPASS_TUNING
                .iter()
                .map(|&l| AllPass::new(scale(l, 0)))
                .collect(),
            allpasses_right: ALLPASS_TUNING
                .iter()
                .map(|&l| AllPass::new(scale(l, STEREO_SPREAD)))
                .collect(),
            wet: 0.3,
            room_size: 0.7,
            damping: 0.4,
            width: 1.0,
        };
        reverb.apply();
        reverb
    }

    /// Set the room size, 0 to 1.
    pub fn set_room_size(&mut self, size: f32) {
        self.room_size = size.clamp(0.0, 1.0);
        self.apply();
    }

    /// Set the high-frequency damping, 0 to 1.
    pub fn set_damping(&mut self, damping: f32) {
        self.damping = damping.clamp(0.0, 1.0);
        self.apply();
    }

    /// Set how much reverb reaches the output, 0 to 1.
    pub fn set_wet(&mut self, wet: f32) {
        self.wet = wet.clamp(0.0, 1.0);
    }

    /// Set the stereo width, 0 (mono) to 1.
    pub fn set_width(&mut self, width: f32) {
        self.width = width.clamp(0.0, 1.0);
    }

    fn apply(&mut self) {
        let feedback = self.room_size * ROOM_SCALE + ROOM_OFFSET;
        let damping = self.damping * DAMP_SCALE;
        for comb in self
            .combs_left
            .iter_mut()
            .chain(self.combs_right.iter_mut())
        {
            comb.feedback = feedback;
            comb.set_damping(damping);
        }
    }

    /// Add the reverb of `send` into `left` and `right`.
    /// The send is mono; the reverb is stereo, which is where the sense of
    /// space comes from. Every buffer is the same length, and none is
    /// allocated here.
    pub fn process(&mut self, send: &[f32], left: &mut [f32], right: &mut [f32]) {
        debug_assert_eq!(
            send.len(),
            left.len(),
            "reverb buffers must be the same length"
        );
        debug_assert_eq!(
            send.len(),
            right.len(),
            "reverb buffers must be the same length"
        );
        let wet1 = self.wet * (self.width / 2.0 + 0.5);
        let wet2 = self.wet * ((1.0 - self.width) / 2.0);

        for i in 0..send.len() {
            let input = send[i] * FIXED_GAIN;
            let mut out_left = 0.0;
            let mut out_right = 0.0;
            for comb in &mut self.combs_left {
                out_left += comb.process(input);
            }
            for comb in &mut self.combs_right {
                out_right += comb.process(input);
            }
            for allpass in &mut self.allpasses_left {
                out_left = allpass.process(out_left);
            }
            for allpass in &mut self.allpasses_right {
                out_right = allpass.process(out_right);
            }
            left[i] += out_left * wet1 + out_right * wet2;
            right[i] += out_right * wet1 + out_left * wet2;
        }
    }

    /// Forget the tail, for a transport stop.
    pub fn clear(&mut self) {
        for comb in self
            .combs_left
            .iter_mut()
            .chain(self.combs_right.iter_mut())
        {
            comb.clear();
        }
        for allpass in self
            .allpasses_left
            .iter_mut()
            .chain(self.allpasses_right.iter_mut())
        {
            allpass.clear();
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
        let mut reverb = Reverb::new(SR);
        let send = vec![0.0f32; 512];
        let mut left = vec![0.0f32; 512];
        let mut right = vec![0.0f32; 512];
        reverb.process(&send, &mut left, &mut right);
        assert_eq!(peak(&left), 0.0);
        assert_eq!(peak(&right), 0.0);
    }

    #[test]
    fn an_impulse_becomes_a_tail_that_outlasts_it() {
        let mut reverb = Reverb::new(SR);
        let mut send = vec![0.0f32; 4096];
        send[0] = 1.0;
        let mut left = vec![0.0f32; 4096];
        let mut right = vec![0.0f32; 4096];
        reverb.process(&send, &mut left, &mut right);
        // Sound arrives after the shortest comb delay, not immediately.
        assert!(peak(&left[2000..]) > 0.0, "no tail");

        // And it is still going in the next block.
        let quiet = vec![0.0f32; 4096];
        let mut left2 = vec![0.0f32; 4096];
        let mut right2 = vec![0.0f32; 4096];
        reverb.process(&quiet, &mut left2, &mut right2);
        assert!(peak(&left2) > 0.0, "the tail stopped at the block boundary");
    }

    #[test]
    fn the_two_channels_differ_so_it_sounds_like_a_room() {
        let mut reverb = Reverb::new(SR);
        let mut send = vec![0.0f32; 8192];
        send[0] = 1.0;
        let mut left = vec![0.0f32; 8192];
        let mut right = vec![0.0f32; 8192];
        reverb.process(&send, &mut left, &mut right);
        let difference: f32 = left
            .iter()
            .zip(right.iter())
            .map(|(l, r)| (l - r).abs())
            .sum();
        assert!(difference > 0.0, "the channels are identical");
    }

    #[test]
    fn the_tail_decays_rather_than_running_away() {
        let mut reverb = Reverb::new(SR);
        let mut send = vec![0.0f32; 8192];
        send[0] = 1.0;
        let mut left = vec![0.0f32; 8192];
        let mut right = vec![0.0f32; 8192];
        reverb.process(&send, &mut left, &mut right);
        let early = peak(&left[..4096]);

        let mut later = early;
        for _ in 0..40 {
            let quiet = vec![0.0f32; 8192];
            let mut l = vec![0.0f32; 8192];
            let mut r = vec![0.0f32; 8192];
            reverb.process(&quiet, &mut l, &mut r);
            later = peak(&l);
        }
        assert!(later < early * 0.5, "early {early}, later {later}");
    }

    #[test]
    fn it_stays_finite_under_a_loud_continuous_input() {
        let mut reverb = Reverb::new(SR);
        reverb.set_room_size(1.0);
        for _ in 0..100 {
            let send = vec![1.0f32; 1024];
            let mut left = vec![0.0f32; 1024];
            let mut right = vec![0.0f32; 1024];
            reverb.process(&send, &mut left, &mut right);
            for value in left.iter().chain(right.iter()) {
                assert!(value.is_finite(), "{value}");
                assert!(value.abs() < 50.0, "{value}");
            }
        }
    }

    #[test]
    fn clearing_stops_the_tail() {
        let mut reverb = Reverb::new(SR);
        let mut send = vec![0.0f32; 4096];
        send[0] = 1.0;
        let mut left = vec![0.0f32; 4096];
        let mut right = vec![0.0f32; 4096];
        reverb.process(&send, &mut left, &mut right);
        reverb.clear();

        let quiet = vec![0.0f32; 4096];
        let mut l = vec![0.0f32; 4096];
        let mut r = vec![0.0f32; 4096];
        reverb.process(&quiet, &mut l, &mut r);
        assert_eq!(peak(&l), 0.0);
    }

    #[test]
    fn a_dry_setting_produces_nothing() {
        let mut reverb = Reverb::new(SR);
        reverb.set_wet(0.0);
        let mut send = vec![0.0f32; 4096];
        send[0] = 1.0;
        let mut left = vec![0.0f32; 4096];
        let mut right = vec![0.0f32; 4096];
        reverb.process(&send, &mut left, &mut right);
        assert_eq!(peak(&left), 0.0);
    }
}
