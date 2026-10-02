//! The SoundFont volume and modulation envelope.
//!
//! Rules: `docs/rules/sf2-sampler.md` §4.4.

/// Where an envelope is in its life.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EnvelopeStage {
    /// Waiting to start.
    Delay,
    /// Rising to full.
    Attack,
    /// Held at full.
    Hold,
    /// Falling to the sustain level.
    Decay,
    /// Held at the sustain level until release.
    Sustain,
    /// Falling to silence.
    Release,
    /// Finished; the voice can be reused.
    Finished,
}

/// How long each stage lasts, and where sustain sits.
#[derive(Debug, Clone, Copy)]
pub struct EnvelopeSpec {
    /// Seconds before the attack starts.
    pub delay: f32,
    /// Seconds to rise to full.
    pub attack: f32,
    /// Seconds held at full.
    pub hold: f32,
    /// Seconds to fall to the sustain level.
    pub decay: f32,
    /// Sustain level as a linear gain, 0 to 1.
    pub sustain: f32,
    /// Seconds to fall from wherever it is to silence.
    pub release: f32,
}

impl EnvelopeSpec {
    /// An envelope that is instantly on and instantly off.
    ///
    /// What the specification's defaults amount to.
    #[must_use]
    pub const fn instant() -> Self {
        Self {
            delay: 0.0,
            attack: 0.0,
            hold: 0.0,
            decay: 0.0,
            sustain: 1.0,
            release: 0.0,
        }
    }
}

/// A six-stage envelope: delay, attack, hold, decay, sustain, release.
///
/// Attack is linear in amplitude, which sounds convex; decay and release are
/// linear in *attenuation*, which is what makes them sound like a natural
/// decay rather than a ramp that stops suddenly.
#[derive(Debug, Clone)]
pub struct Envelope {
    spec: EnvelopeSpec,
    sample_rate: f32,
    stage: EnvelopeStage,
    /// Samples left in the current stage, where the stage is timed.
    remaining: u32,
    /// Current output, 0 to 1.
    level: f32,
    /// Per-sample step for attack.
    attack_step: f32,
    /// Per-sample multiplier for decay and release.
    decay_factor: f32,
    release_factor: f32,
}

/// The attenuation an envelope is considered finished at.
///
/// −100 dB is far below anything audible, and stopping there frees the voice
/// rather than multiplying silence for another second.
const SILENCE: f32 = 1.0e-5;

impl Envelope {
    /// Create an envelope, ready to be started.
    #[must_use]
    pub fn new(spec: EnvelopeSpec, sample_rate: f32) -> Self {
        let mut envelope = Self {
            spec,
            sample_rate: sample_rate.max(1.0),
            stage: EnvelopeStage::Finished,
            remaining: 0,
            level: 0.0,
            attack_step: 0.0,
            decay_factor: 0.0,
            release_factor: 0.0,
        };
        envelope.start();
        envelope
    }

    /// Restart the envelope from the beginning.
    pub fn start(&mut self) {
        self.level = 0.0;
        self.stage = EnvelopeStage::Delay;
        self.remaining = self.samples(self.spec.delay);
        self.attack_step = if self.spec.attack <= 0.0 {
            1.0
        } else {
            1.0 / self.samples(self.spec.attack).max(1) as f32
        };
        self.decay_factor = Self::decay_factor(
            self.spec.decay,
            self.spec.sustain.clamp(SILENCE, 1.0),
            self.sample_rate,
        );
        self.release_factor = Self::decay_factor(self.spec.release, SILENCE, self.sample_rate);
        self.advance_past_empty_stages();
    }

    /// Move to the release stage.
    pub fn release(&mut self) {
        if self.stage == EnvelopeStage::Finished {
            return;
        }
        self.stage = EnvelopeStage::Release;
        if self.spec.release <= 0.0 {
            self.level = 0.0;
            self.stage = EnvelopeStage::Finished;
        }
    }

    /// Release fast, whatever the envelope says.
    ///
    /// What voice stealing and exclusive classes use: an instant stop clicks,
    /// and a millisecond does not (`docs/rules/sf2-sampler.md` §4.5, §5).
    pub fn release_fast(&mut self, seconds: f32) {
        if self.stage == EnvelopeStage::Finished {
            return;
        }
        self.stage = EnvelopeStage::Release;
        self.release_factor = Self::decay_factor(seconds, SILENCE, self.sample_rate);
    }

    /// The stage the envelope is in.
    #[must_use]
    pub const fn stage(&self) -> EnvelopeStage {
        self.stage
    }

    /// Whether the envelope has finished and its voice can be reused.
    #[must_use]
    pub const fn is_finished(&self) -> bool {
        matches!(self.stage, EnvelopeStage::Finished)
    }

    /// Whether the envelope has been released.
    #[must_use]
    pub const fn is_releasing(&self) -> bool {
        matches!(self.stage, EnvelopeStage::Release)
    }

    /// The current level, without advancing.
    #[must_use]
    pub const fn level(&self) -> f32 {
        self.level
    }

    /// Advance one sample and return the new level.
    pub fn next_value(&mut self) -> f32 {
        match self.stage {
            EnvelopeStage::Delay => {
                // Level first: if the delay has just expired and the attack
                // is instant, `enter_attack` leaves the level at full, and it
                // must not be clobbered back to silence for this sample.
                self.level = 0.0;
                if self.remaining == 0 {
                    self.enter_attack();
                } else {
                    self.remaining -= 1;
                }
            }
            EnvelopeStage::Attack => {
                self.level += self.attack_step;
                if self.level >= 1.0 {
                    self.level = 1.0;
                    self.enter_hold();
                }
            }
            EnvelopeStage::Hold => {
                self.level = 1.0;
                if self.remaining == 0 {
                    self.enter_decay();
                } else {
                    self.remaining -= 1;
                }
            }
            EnvelopeStage::Decay => {
                self.level *= self.decay_factor;
                // The decay is exponential, so it approaches the sustain level
                // without reaching it. A sustain of zero would decay forever;
                // the floor is what ends it.
                if self.level <= self.spec.sustain.max(SILENCE) {
                    self.level = self.spec.sustain;
                    self.stage = if self.spec.sustain <= SILENCE {
                        EnvelopeStage::Finished
                    } else {
                        EnvelopeStage::Sustain
                    };
                }
            }
            EnvelopeStage::Sustain => {
                self.level = self.spec.sustain;
            }
            EnvelopeStage::Release => {
                self.level *= self.release_factor;
                if self.level <= SILENCE {
                    self.level = 0.0;
                    self.stage = EnvelopeStage::Finished;
                }
            }
            EnvelopeStage::Finished => {
                self.level = 0.0;
            }
        }
        self.level
    }

    fn enter_attack(&mut self) {
        self.stage = EnvelopeStage::Attack;
        if self.spec.attack <= 0.0 {
            self.level = 1.0;
            self.enter_hold();
        }
    }

    fn enter_hold(&mut self) {
        self.stage = EnvelopeStage::Hold;
        self.remaining = self.samples(self.spec.hold);
        if self.remaining == 0 {
            self.enter_decay();
        }
    }

    fn enter_decay(&mut self) {
        self.stage = EnvelopeStage::Decay;
        if self.spec.decay <= 0.0 || self.spec.sustain >= 1.0 {
            self.level = self.spec.sustain.min(1.0);
            self.stage = if self.level <= SILENCE {
                EnvelopeStage::Finished
            } else {
                EnvelopeStage::Sustain
            };
        }
    }

    /// Skip stages that take no time, so a fully default envelope is on
    /// immediately rather than after six samples.
    fn advance_past_empty_stages(&mut self) {
        if self.stage == EnvelopeStage::Delay && self.remaining == 0 {
            self.enter_attack();
        }
    }

    fn samples(&self, seconds: f32) -> u32 {
        if seconds <= 0.0 {
            return 0;
        }
        #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
        {
            (seconds * self.sample_rate).round().max(0.0) as u32
        }
    }

    /// The per-sample multiplier that falls from 1 to `target` over `seconds`.
    fn decay_factor(seconds: f32, target: f32, sample_rate: f32) -> f32 {
        if seconds <= 0.0 {
            return 0.0;
        }
        let samples = (seconds * sample_rate).max(1.0);
        target.max(SILENCE).powf(1.0 / samples)
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

    fn spec(attack: f32, decay: f32, sustain: f32, release: f32) -> EnvelopeSpec {
        EnvelopeSpec {
            delay: 0.0,
            attack,
            hold: 0.0,
            decay,
            sustain,
            release,
        }
    }

    fn run(envelope: &mut Envelope, seconds: f32) -> f32 {
        let samples = (seconds * SR) as usize;
        let mut last = 0.0;
        for _ in 0..samples {
            last = envelope.next_value();
        }
        last
    }

    #[test]
    fn a_default_envelope_is_on_immediately() {
        let mut envelope = Envelope::new(EnvelopeSpec::instant(), SR);
        assert_eq!(envelope.next_value(), 1.0);
        assert_eq!(envelope.stage(), EnvelopeStage::Sustain);
    }

    #[test]
    fn the_attack_rises_to_full_in_the_time_it_says() {
        let mut envelope = Envelope::new(spec(0.1, 0.0, 1.0, 0.0), SR);
        assert!(envelope.next_value() < 0.01);
        assert!((run(&mut envelope, 0.05) - 0.5).abs() < 0.02);
        run(&mut envelope, 0.06);
        assert!((envelope.level() - 1.0).abs() < 1e-6);
    }

    #[test]
    fn the_delay_holds_silence_first() {
        let mut envelope = Envelope::new(
            EnvelopeSpec {
                delay: 0.05,
                ..spec(0.0, 0.0, 1.0, 0.0)
            },
            SR,
        );
        assert_eq!(envelope.stage(), EnvelopeStage::Delay);
        assert_eq!(run(&mut envelope, 0.04), 0.0);
        run(&mut envelope, 0.02);
        assert!(envelope.level() > 0.9);
    }

    #[test]
    fn an_instant_attack_after_the_delay_is_on_at_once() {
        // The sample where the delay expires must not report a level a
        // finished attack already discarded — that delays an instant attack
        // by one sample and returns the wrong level for the sample.
        let mut envelope = Envelope::new(
            EnvelopeSpec {
                delay: 0.05,
                ..spec(0.0, 0.0, 1.0, 0.0)
            },
            SR,
        );
        run(&mut envelope, 0.05);
        assert_eq!(envelope.stage(), EnvelopeStage::Delay);
        assert_eq!(envelope.next_value(), 1.0);
    }

    #[test]
    fn the_hold_keeps_full_level_before_the_decay() {
        let mut envelope = Envelope::new(
            EnvelopeSpec {
                hold: 0.1,
                ..spec(0.0, 0.2, 0.5, 0.0)
            },
            SR,
        );
        assert!((run(&mut envelope, 0.05) - 1.0).abs() < 1e-6);
        assert_eq!(envelope.stage(), EnvelopeStage::Hold);
        run(&mut envelope, 0.1);
        assert_eq!(envelope.stage(), EnvelopeStage::Decay);
    }

    #[test]
    fn the_decay_reaches_the_sustain_level_and_stays() {
        let mut envelope = Envelope::new(spec(0.0, 0.2, 0.25, 0.0), SR);
        run(&mut envelope, 0.25);
        assert!(
            (envelope.level() - 0.25).abs() < 0.02,
            "{}",
            envelope.level()
        );
        assert_eq!(envelope.stage(), EnvelopeStage::Sustain);
        run(&mut envelope, 1.0);
        assert!((envelope.level() - 0.25).abs() < 1e-6);
    }

    #[test]
    fn a_sustain_of_zero_finishes_at_the_end_of_the_decay() {
        let mut envelope = Envelope::new(spec(0.0, 0.05, 0.0, 0.0), SR);
        run(&mut envelope, 0.2);
        assert!(envelope.is_finished());
    }

    #[test]
    fn release_falls_to_silence_and_finishes() {
        let mut envelope = Envelope::new(spec(0.0, 0.0, 1.0, 0.1), SR);
        run(&mut envelope, 0.01);
        envelope.release();
        assert!(envelope.is_releasing());
        run(&mut envelope, 0.05);
        assert!(envelope.level() < 0.5 && envelope.level() > 0.0);
        run(&mut envelope, 0.2);
        assert!(envelope.is_finished());
        assert_eq!(envelope.level(), 0.0);
    }

    #[test]
    fn a_release_of_zero_stops_at_once() {
        let mut envelope = Envelope::new(spec(0.0, 0.0, 1.0, 0.0), SR);
        envelope.next_value();
        envelope.release();
        assert!(envelope.is_finished());
    }

    #[test]
    fn a_fast_release_is_faster_than_the_envelope_asked_for() {
        let mut slow = Envelope::new(spec(0.0, 0.0, 1.0, 2.0), SR);
        let mut fast = Envelope::new(spec(0.0, 0.0, 1.0, 2.0), SR);
        slow.next_value();
        fast.next_value();
        slow.release();
        fast.release_fast(0.005);
        run(&mut slow, 0.02);
        run(&mut fast, 0.02);
        assert!(fast.level() < slow.level());
        assert!(fast.is_finished());
    }

    #[test]
    fn releasing_a_finished_envelope_does_nothing() {
        let mut envelope = Envelope::new(spec(0.0, 0.01, 0.0, 0.0), SR);
        run(&mut envelope, 0.1);
        assert!(envelope.is_finished());
        envelope.release();
        assert!(envelope.is_finished());
    }

    #[test]
    fn the_level_never_leaves_zero_to_one() {
        let mut envelope = Envelope::new(spec(0.01, 0.05, 0.4, 0.05), SR);
        for i in 0..(SR as usize / 2) {
            let level = envelope.next_value();
            assert!((0.0..=1.0).contains(&level), "level {level} at sample {i}");
            if i == 5000 {
                envelope.release();
            }
        }
    }

    #[test]
    fn restarting_puts_it_back_at_the_beginning() {
        let mut envelope = Envelope::new(spec(0.05, 0.0, 1.0, 0.0), SR);
        run(&mut envelope, 0.1);
        envelope.release();
        run(&mut envelope, 0.1);
        envelope.start();
        assert!(!envelope.is_finished());
        assert!(envelope.level() < 0.1);
    }
}
