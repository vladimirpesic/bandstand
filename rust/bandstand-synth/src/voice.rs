//! One sampler voice.
//!
//! Rules: `docs/rules/sf2-sampler.md` §4.

use std::sync::Arc;

use crate::envelope::{Envelope, EnvelopeSpec};
use crate::filter::LowPassFilter;
use crate::lfo::Lfo;
use crate::sf2::generators::{
    absolute_cents_to_hertz, centibels_to_gain, cents_to_ratio, timecents_to_seconds,
};
use crate::sf2::{Generator, LoopMode, SampleSource, SoundBank, VoiceRecipe};

/// How long a stolen or cut-off voice takes to fall silent.
///
/// Long enough not to click, short enough that the note replacing it is not
/// masked (`docs/rules/sf2-sampler.md` §4.5).
pub const FAST_RELEASE_SECONDS: f32 = 0.006;

/// What a channel contributes to every voice on it.
///
/// Worked out once a block rather than once a voice, because a channel's volume
/// and pan do not change inside one.
#[derive(Debug, Clone, Copy)]
pub struct ChannelMix {
    /// Volume times expression, and zero when muted.
    pub gain: f32,
    /// Left gain from the channel's pan.
    pub pan_left: f32,
    /// Right gain from the channel's pan.
    pub pan_right: f32,
    /// Pitch bend, as a ratio.
    pub pitch_ratio: f64,
}

impl ChannelMix {
    /// A channel at full volume, centred, unbent.
    #[must_use]
    pub const fn unity() -> Self {
        Self {
            gain: 1.0,
            pan_left: 1.0,
            pan_right: 1.0,
            pitch_ratio: 1.0,
        }
    }
}

/// Everything a voice needs, worked out once at note-on.
#[derive(Debug, Clone)]
pub struct VoiceSettings {
    /// First frame of the sample.
    pub start: u32,
    /// One past the last frame.
    pub end: u32,
    /// First frame of the loop.
    pub loop_start: u32,
    /// One past the last frame of the loop.
    pub loop_end: u32,
    /// How the sample loops.
    pub loop_mode: LoopMode,
    /// Frames per output frame at the note's pitch.
    pub base_increment: f64,
    /// Peak gain, from attenuation and velocity.
    pub gain: f32,
    /// Left and right gains, from pan.
    pub pan_left: f32,
    /// Right gain.
    pub pan_right: f32,
    /// How much of this voice goes to the reverb.
    pub reverb_send: f32,
    /// How much goes to the chorus.
    pub chorus_send: f32,
    /// The volume envelope.
    pub volume_envelope: EnvelopeSpec,
    /// The modulation envelope.
    pub modulation_envelope: EnvelopeSpec,
    /// Filter cutoff in hertz, before modulation.
    pub filter_cutoff: f32,
    /// Filter resonance in decibels.
    pub filter_resonance: f32,
    /// Modulation envelope to filter cutoff, in cents.
    pub mod_env_to_filter: f32,
    /// Modulation envelope to pitch, in cents.
    pub mod_env_to_pitch: f32,
    /// Modulation LFO to pitch, in cents.
    pub mod_lfo_to_pitch: f32,
    /// Modulation LFO to filter cutoff, in cents.
    pub mod_lfo_to_filter: f32,
    /// Modulation LFO to volume, in centibels.
    pub mod_lfo_to_volume: f32,
    /// Vibrato LFO to pitch, in cents.
    pub vib_lfo_to_pitch: f32,
    /// Modulation LFO frequency and delay.
    pub mod_lfo: (f32, f32),
    /// Vibrato LFO frequency and delay.
    pub vib_lfo: (f32, f32),
    /// Voices sharing a non-zero class on a channel cut each other off.
    pub exclusive_class: i16,
}

impl VoiceSettings {
    /// Work out the settings for a note.
    ///
    /// Every unit conversion in `docs/rules/sf2-sampler.md` §3 happens here and
    /// nowhere else.
    #[must_use]
    // Long on purpose: this is the one place every generator's unit conversion
    // is visible together, and splitting it would scatter them.
    #[allow(clippy::too_many_lines)]
    pub fn resolve(
        bank: &SoundBank,
        recipe: &VoiceRecipe,
        key: u8,
        velocity: u8,
        output_rate: f32,
    ) -> Option<Self> {
        let sample = bank.samples.get(recipe.sample)?;
        let gens = &recipe.generators;

        let offset = |fine: Generator, coarse: Generator| -> i64 {
            i64::from(gens.get(fine)) + i64::from(gens.get(coarse)) * 32_768
        };
        let clamp = |value: i64| -> u32 { value.clamp(0, i64::from(u32::MAX)) as u32 };

        let start = clamp(
            i64::from(sample.start)
                + offset(
                    Generator::StartAddrsOffset,
                    Generator::StartAddrsCoarseOffset,
                ),
        );
        let end = clamp(
            i64::from(sample.end)
                + offset(Generator::EndAddrsOffset, Generator::EndAddrsCoarseOffset),
        );
        let loop_start = clamp(
            i64::from(sample.loop_start)
                + offset(
                    Generator::StartLoopAddrsOffset,
                    Generator::StartLoopAddrsCoarseOffset,
                ),
        );
        let loop_end = clamp(
            i64::from(sample.loop_end)
                + offset(
                    Generator::EndLoopAddrsOffset,
                    Generator::EndLoopAddrsCoarseOffset,
                ),
        );

        let frames = bank.data.len() as u32;
        if start >= end || end > frames {
            return None;
        }

        let mut loop_mode = LoopMode::from_value(gens.get(Generator::SampleModes));
        let loop_usable = loop_mode.loops()
            && loop_end > loop_start
            && loop_end.saturating_sub(loop_start) >= 4
            && loop_start >= start
            && loop_end <= end;
        if !loop_usable {
            loop_mode = LoopMode::NoLoop;
        }

        // `keynum` (op 46) forces the voice to play as though a different key
        // had been struck, which is how a bank pins a drum zone to one pitch
        // however it is triggered. Only 0–127 is a key; anything else means
        // the generator is absent or unusable and the played key stands.
        let sounding_key = match gens.get(Generator::Keynum) {
            valid @ 0..=127 => valid as u8,
            _ => key,
        };
        // Likewise `velocity` (op 47) forces the striking velocity.
        let sounding_velocity = match gens.get(Generator::Velocity) {
            valid @ 1..=127 => valid as u8,
            _ => velocity,
        };

        // Pitch: the sample's own rate against the output's, times the interval
        // from its root key, scaled and tuned. An `originalPitch` of 255 means
        // "undefined": the sample sounds at the key that was played, tuned only
        // by the tuning generators, rather than ~16 octaves below it. An
        // out-of-range `overridingRootKey` means the same thing — the parser
        // accepts any `i16`, and taking 255 literally roots the voice about
        // fifteen octaves off.
        let root = match gens.get(Generator::OverridingRootKey) {
            valid @ 0..=127 => i32::from(valid),
            _ if sample.original_pitch <= 127 => i32::from(sample.original_pitch),
            _ => i32::from(sounding_key),
        };
        let scale = gens.get_f32(Generator::ScaleTuning) / 100.0;
        let cents = (f32::from(sounding_key) - root as f32) * 100.0 * scale
            + gens.get_f32(Generator::CoarseTune) * 100.0
            + gens.get_f32(Generator::FineTune)
            + f32::from(sample.pitch_correction);
        let base_increment = f64::from(sample.sample_rate) / f64::from(output_rate.max(1.0))
            * f64::from(cents_to_ratio(cents));

        // Velocity to attenuation is the specification's default modulator:
        // full velocity is unattenuated, and it falls away as a square law,
        // which is what makes a keyboard feel right.
        let velocity_gain = (f32::from(sounding_velocity.max(1)) / 127.0).powi(2);
        let gain = centibels_to_gain(gens.get_f32(Generator::InitialAttenuation)) * velocity_gain;

        let pan = (gens.get_f32(Generator::Pan) / 500.0).clamp(-1.0, 1.0);
        // Equal power, so a centred voice is not louder than a panned one.
        let angle = (pan + 1.0) * std::f32::consts::FRAC_PI_4;

        Some(Self {
            start,
            end,
            loop_start,
            loop_end,
            loop_mode,
            base_increment,
            gain,
            pan_left: angle.cos(),
            pan_right: angle.sin(),
            reverb_send: (gens.get_f32(Generator::ReverbEffectsSend) / 1000.0).clamp(0.0, 1.0),
            chorus_send: (gens.get_f32(Generator::ChorusEffectsSend) / 1000.0).clamp(0.0, 1.0),
            volume_envelope: EnvelopeSpec {
                delay: timecents_to_seconds(gens.get_f32(Generator::DelayVolEnv)),
                attack: timecents_to_seconds(gens.get_f32(Generator::AttackVolEnv)),
                hold: timecents_to_seconds(gens.get_f32(Generator::HoldVolEnv)),
                decay: timecents_to_seconds(gens.get_f32(Generator::DecayVolEnv)),
                sustain: centibels_to_gain(gens.get_f32(Generator::SustainVolEnv)),
                release: timecents_to_seconds(gens.get_f32(Generator::ReleaseVolEnv)),
            },
            modulation_envelope: EnvelopeSpec {
                delay: timecents_to_seconds(gens.get_f32(Generator::DelayModEnv)),
                attack: timecents_to_seconds(gens.get_f32(Generator::AttackModEnv)),
                hold: timecents_to_seconds(gens.get_f32(Generator::HoldModEnv)),
                decay: timecents_to_seconds(gens.get_f32(Generator::DecayModEnv)),
                // The modulation envelope's sustain is tenths of a percent
                // *below* peak, not centibels.
                sustain: (1.0 - gens.get_f32(Generator::SustainModEnv) / 1000.0).clamp(0.0, 1.0),
                release: timecents_to_seconds(gens.get_f32(Generator::ReleaseModEnv)),
            },
            filter_cutoff: absolute_cents_to_hertz(gens.get_f32(Generator::InitialFilterFc)),
            filter_resonance: gens.get_f32(Generator::InitialFilterQ) / 10.0,
            mod_env_to_filter: gens.get_f32(Generator::ModEnvToFilterFc),
            mod_env_to_pitch: gens.get_f32(Generator::ModEnvToPitch),
            mod_lfo_to_pitch: gens.get_f32(Generator::ModLfoToPitch),
            mod_lfo_to_filter: gens.get_f32(Generator::ModLfoToFilterFc),
            mod_lfo_to_volume: gens.get_f32(Generator::ModLfoToVolume),
            vib_lfo_to_pitch: gens.get_f32(Generator::VibLfoToPitch),
            mod_lfo: (
                absolute_cents_to_hertz(gens.get_f32(Generator::FreqModLfo)),
                timecents_to_seconds(gens.get_f32(Generator::DelayModLfo)),
            ),
            vib_lfo: (
                absolute_cents_to_hertz(gens.get_f32(Generator::FreqVibLfo)),
                timecents_to_seconds(gens.get_f32(Generator::DelayVibLfo)),
            ),
            exclusive_class: gens.get(Generator::ExclusiveClass),
        })
    }
}

/// A voice playing one sample.
pub struct Voice {
    settings: VoiceSettings,
    data: Arc<dyn SampleSource>,
    position: f64,
    volume: Envelope,
    modulation: Envelope,
    filter: LowPassFilter,
    mod_lfo: Lfo,
    vib_lfo: Lfo,
    sample_rate: f32,
    /// Which MIDI channel started it.
    pub channel: u8,
    /// Which key started it.
    pub key: u8,
    /// A monotonic counter, so the oldest voice can be found.
    pub age: u64,
    /// Whether the key is still down.
    held: bool,
    active: bool,
}

impl Voice {
    /// Start a voice.
    #[must_use]
    pub fn start(
        settings: VoiceSettings,
        data: Arc<dyn SampleSource>,
        channel: u8,
        key: u8,
        age: u64,
        sample_rate: f32,
    ) -> Self {
        let mut filter = LowPassFilter::new(sample_rate);
        filter.set(settings.filter_cutoff, settings.filter_resonance);
        Self {
            position: f64::from(settings.start),
            volume: Envelope::new(settings.volume_envelope, sample_rate),
            modulation: Envelope::new(settings.modulation_envelope, sample_rate),
            mod_lfo: Lfo::new(settings.mod_lfo.0, settings.mod_lfo.1, sample_rate),
            vib_lfo: Lfo::new(settings.vib_lfo.0, settings.vib_lfo.1, sample_rate),
            filter,
            settings,
            data,
            sample_rate,
            channel,
            key,
            age,
            held: true,
            active: true,
        }
    }

    /// Whether the voice is still making sound.
    #[must_use]
    pub const fn is_active(&self) -> bool {
        self.active
    }

    /// Whether the key is still down.
    #[must_use]
    pub const fn is_held(&self) -> bool {
        self.held
    }

    /// Whether the voice is fading out.
    #[must_use]
    pub const fn is_releasing(&self) -> bool {
        !self.held
    }

    /// How loud the voice is now, for voice stealing.
    #[must_use]
    pub fn level(&self) -> f32 {
        self.volume.level() * self.settings.gain
    }

    /// The exclusive class this voice belongs to, or zero.
    #[must_use]
    pub const fn exclusive_class(&self) -> i16 {
        self.settings.exclusive_class
    }

    /// Let the key go.
    pub fn release(&mut self) {
        if !self.held {
            return;
        }
        self.held = false;
        self.volume.release();
        self.modulation.release();
    }

    /// Cut the voice off quickly, for stealing or an exclusive class.
    pub fn cut(&mut self) {
        self.held = false;
        self.volume.release_fast(FAST_RELEASE_SECONDS);
        self.modulation.release();
    }

    /// Stop making sound at once. Only for a reset, where a click cannot be
    /// heard because everything else stopped too.
    pub fn kill(&mut self) {
        self.active = false;
        self.held = false;
    }

    /// Add this voice into the mix.
    ///
    /// `left` and `right` are the dry bus; `reverb` and `chorus` are mono sends.
    /// Every buffer is the same length, and none is allocated here.
    pub fn render(
        &mut self,
        left: &mut [f32],
        right: &mut [f32],
        reverb: &mut [f32],
        chorus: &mut [f32],
        channel: ChannelMix,
    ) {
        if !self.active {
            return;
        }
        let settings = &self.settings;
        let loops = settings.loop_mode == LoopMode::Continuous
            || (settings.loop_mode == LoopMode::UntilRelease && self.held);

        for i in 0..left.len() {
            let volume = self.volume.next_value();
            if self.volume.is_finished() {
                self.active = false;
                return;
            }
            let modulation = self.modulation.next_value();
            let mod_lfo = self.mod_lfo.next_value();
            let vib_lfo = self.vib_lfo.next_value();

            // Pitch, in cents, then as a ratio.
            let cents = settings.mod_env_to_pitch * modulation
                + settings.mod_lfo_to_pitch * mod_lfo
                + settings.vib_lfo_to_pitch * vib_lfo;
            let increment = if cents.abs() < 0.01 {
                settings.base_increment * channel.pitch_ratio
            } else {
                settings.base_increment * f64::from(cents_to_ratio(cents)) * channel.pitch_ratio
            };

            let sample = self.interpolate();

            // The filter's cutoff is recomputed at most once a block's worth of
            // samples; per sample would cost more than it is worth.
            if i % 32 == 0 {
                let cutoff_cents =
                    settings.mod_env_to_filter * modulation + settings.mod_lfo_to_filter * mod_lfo;
                let cutoff = if cutoff_cents.abs() < 1.0 {
                    settings.filter_cutoff
                } else {
                    settings.filter_cutoff * cents_to_ratio(cutoff_cents)
                };
                self.filter.set(cutoff, settings.filter_resonance);
            }
            let filtered = self.filter.process(sample);

            let lfo_gain = if settings.mod_lfo_to_volume.abs() < 0.01 {
                1.0
            } else {
                // `mod_lfo` is bipolar and the generator is in centibels, so
                // the signed product already swings the gain both ways; the
                // negative half clamps to unity. Taking the absolute value
                // here would attenuate on both halves and double the rate.
                centibels_to_gain(settings.mod_lfo_to_volume * mod_lfo)
            };
            let value = filtered * volume * settings.gain * lfo_gain * channel.gain;

            left[i] += value * settings.pan_left * channel.pan_left;
            right[i] += value * settings.pan_right * channel.pan_right;
            if settings.reverb_send > 0.0 {
                reverb[i] += value * settings.reverb_send;
            }
            if settings.chorus_send > 0.0 {
                chorus[i] += value * settings.chorus_send;
            }

            self.position += increment;
            if loops {
                if self.position >= f64::from(settings.loop_end) {
                    // `rem_euclid`, not one subtraction: an increment larger
                    // than the loop (an extreme key on a short loop) would
                    // otherwise leave the position past the end forever, and
                    // the voice would read silence while burning CPU.
                    let length = f64::from(settings.loop_end) - f64::from(settings.loop_start);
                    self.position = f64::from(settings.loop_start)
                        + (self.position - f64::from(settings.loop_start)).rem_euclid(length);
                }
            } else if self.position >= f64::from(settings.end) {
                self.active = false;
                return;
            }
        }
    }

    /// Cubic interpolation over four points (`docs/rules/sf2-sampler.md` §4.2).
    ///
    /// Catmull-Rom. Linear interpolation is audibly worse on anything played
    /// far from its root key, and this is four multiplies.
    fn interpolate(&self) -> f32 {
        #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
        let index = self.position as usize;
        #[allow(clippy::cast_possible_truncation)]
        let fraction = (self.position - self.position.floor()) as f32;

        let start = self.settings.start as usize;
        let end = self.settings.end as usize;
        let previous = if index > start { index - 1 } else { index };
        let next = (index + 1).min(end.saturating_sub(1));
        let after = (index + 2).min(end.saturating_sub(1));

        let p0 = self.data.sample(previous);
        let p1 = self.data.sample(index);
        let p2 = self.data.sample(next);
        let p3 = self.data.sample(after);

        let a = -0.5 * p0 + 1.5 * p1 - 1.5 * p2 + 0.5 * p3;
        let b = p0 - 2.5 * p1 + 2.0 * p2 - 0.5 * p3;
        let c = -0.5 * p0 + 0.5 * p2;
        ((a * fraction + b) * fraction + c) * fraction + p1
    }

    /// The sample rate the voice was started at.
    #[must_use]
    pub const fn sample_rate(&self) -> f32 {
        self.sample_rate
    }
}

impl std::fmt::Debug for Voice {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Voice")
            .field("channel", &self.channel)
            .field("key", &self.key)
            .field("active", &self.active)
            .field("held", &self.held)
            .finish_non_exhaustive()
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
    use crate::sf2::{
        ByteRange, GeneratorSet, Instrument, Preset, ResidentSamples, SampleHeader, Zone,
    };

    const SR: f32 = 48_000.0;

    /// Settings over a usable loop, with nothing modulating anything.
    fn base_settings() -> VoiceSettings {
        VoiceSettings {
            start: 0,
            end: 16,
            loop_start: 0,
            loop_end: 8,
            loop_mode: LoopMode::Continuous,
            base_increment: 1.0,
            gain: 1.0,
            pan_left: 1.0,
            pan_right: 1.0,
            reverb_send: 0.0,
            chorus_send: 0.0,
            volume_envelope: EnvelopeSpec::instant(),
            modulation_envelope: EnvelopeSpec::instant(),
            filter_cutoff: 20_000.0,
            filter_resonance: 0.0,
            mod_env_to_filter: 0.0,
            mod_env_to_pitch: 0.0,
            mod_lfo_to_pitch: 0.0,
            mod_lfo_to_filter: 0.0,
            mod_lfo_to_volume: 0.0,
            vib_lfo_to_pitch: 0.0,
            mod_lfo: (5.0, 0.0),
            vib_lfo: (5.0, 0.0),
            exclusive_class: 0,
        }
    }

    /// A voice rendering a constant sample, so the output is the processing
    /// chain itself: pitch is irrelevant to a DC input.
    fn dc_voice(settings: VoiceSettings) -> Voice {
        Voice::start(
            settings,
            Arc::new(ResidentSamples::new(vec![16_384; 16])),
            0,
            60,
            0,
            SR,
        )
    }

    fn render(voice: &mut Voice, frames: usize) -> Vec<f32> {
        let mut left = vec![0.0; frames];
        let mut right = vec![0.0; frames];
        let mut reverb = vec![0.0; frames];
        let mut chorus = vec![0.0; frames];
        voice.render(
            &mut left,
            &mut right,
            &mut reverb,
            &mut chorus,
            ChannelMix::unity(),
        );
        left
    }

    #[test]
    fn tremolo_dips_once_per_mod_lfo_period() {
        // `modLfoToVolume` is in centibels and the LFO is bipolar: the signed
        // product dips the gain once per period, and the negative half clamps
        // back to unity. A dip on both halves — what `abs()` of the product
        // produces — is a tremolo running at double the rate it should.
        let mut settings = base_settings();
        settings.mod_lfo_to_volume = 200.0; // tenfold attenuation at the peak
        let mut voice = dc_voice(settings);

        let left = render(&mut voice, 3 * 9_600);
        let minima: Vec<usize> = (1..left.len() - 1)
            .filter(|&i| left[i] < 0.5 && left[i] <= left[i - 1] && left[i] <= left[i + 1])
            .collect();
        assert!(minima.len() >= 2, "no tremolo dips found");

        let period = SR / 5.0;
        let spacing = (minima[1] - minima[0]) as f32;
        assert!(
            (spacing - period).abs() < period * 0.1,
            "dips are {spacing} samples apart; the LFO period is {period}"
        );
        assert!(
            minima.len() <= 4,
            "{} dips in three periods is double-rate tremolo",
            minima.len()
        );
    }

    #[test]
    fn a_loop_survives_an_increment_bigger_than_itself() {
        // An extreme key on a short loop steps several loop lengths per
        // sample; the position must wrap back inside the loop every sample,
        // not run off the end and read silence.
        let mut settings = base_settings();
        settings.base_increment = 100.0;
        let mut voice = dc_voice(settings);

        let mut audible = false;
        for _ in 0..100 {
            let left = render(&mut voice, 64);
            assert!(
                voice.position < f64::from(voice.settings.loop_end),
                "position {} escaped the loop",
                voice.position
            );
            audible |= left.iter().any(|sample| sample.abs() > 0.01);
        }
        assert!(audible, "an in-loop voice went silent");
    }

    /// A bank holding one sample at the given root key, so `resolve` can be
    /// exercised end to end.
    fn bank_with_pitch(original_pitch: u8) -> SoundBank {
        let zone = || Zone {
            key_range: ByteRange::FULL,
            velocity_range: ByteRange::FULL,
            generators: GeneratorSet::defaults(),
            target: 0,
        };
        SoundBank {
            name: "test".to_owned(),
            presets: vec![Preset {
                name: "preset".to_owned(),
                bank: 0,
                program: 0,
                zones: vec![zone()],
            }],
            instruments: vec![Instrument {
                name: "instrument".to_owned(),
                zones: vec![zone()],
            }],
            samples: vec![SampleHeader {
                name: "sample".to_owned(),
                start: 0,
                end: 1_000,
                loop_start: 0,
                loop_end: 0,
                sample_rate: 44_100,
                original_pitch,
                pitch_correction: 0,
                link: 0,
                sample_type: 1,
            }],
            data: Arc::new(ResidentSamples::new(vec![0; 1_000])),
        }
    }

    fn recipe() -> VoiceRecipe {
        VoiceRecipe {
            sample: 0,
            generators: GeneratorSet::defaults(),
        }
    }

    #[test]
    fn an_undefined_root_key_plays_at_the_keyed_pitch() {
        // `originalPitch` 255 means "undefined". Without the special case the
        // sample would sound (key − 255) semitones away — for key 69 that is
        // more than fifteen octaves down, inaudible. It must sound at the key
        // that was played, exactly like a sample rooted there.
        let keyed = VoiceSettings::resolve(&bank_with_pitch(69), &recipe(), 69, 100, SR)
            .expect("the rooted bank resolves");
        let undefined = VoiceSettings::resolve(&bank_with_pitch(255), &recipe(), 69, 100, SR)
            .expect("the undefined bank resolves");
        assert!(
            (undefined.base_increment - keyed.base_increment).abs() < 1e-9,
            "{} vs {}",
            undefined.base_increment,
            keyed.base_increment
        );
        // And the shared value really is the keyed pitch: the sample's own
        // rate against the output's, with no interval applied.
        assert!((keyed.base_increment - 44_100.0f64 / f64::from(SR)).abs() < 1e-9);
    }

    /// A recipe with one generator set.
    fn recipe_with(generator: Generator, value: i16) -> VoiceRecipe {
        let mut generators = GeneratorSet::defaults();
        generators.set(generator, value);
        VoiceRecipe {
            sample: 0,
            generators,
        }
    }

    #[test]
    fn an_out_of_range_overriding_root_key_plays_at_the_keyed_pitch() {
        // The parser accepts any `i16` for `overridingRootKey`, and 255 is a
        // representable one that banks do write. Taking it literally rooted
        // the voice about fifteen octaves off; only the sample-header form of
        // "undefined" used to be handled.
        let keyed = VoiceSettings::resolve(&bank_with_pitch(69), &recipe(), 69, 100, SR)
            .expect("the rooted bank resolves");
        for absurd in [255i16, 128, -2, i16::MAX] {
            let settings = VoiceSettings::resolve(
                &bank_with_pitch(69),
                &recipe_with(Generator::OverridingRootKey, absurd),
                69,
                100,
                SR,
            )
            .expect("the bank resolves");
            assert!(
                (settings.base_increment - keyed.base_increment).abs() < 1e-9,
                "overridingRootKey {absurd} gave {} rather than {}",
                settings.base_increment,
                keyed.base_increment
            );
        }
        // A root key that *is* in range still applies: an octave below the
        // played key doubles the rate at which the sample is read.
        let rooted = VoiceSettings::resolve(
            &bank_with_pitch(69),
            &recipe_with(Generator::OverridingRootKey, 57),
            69,
            100,
            SR,
        )
        .expect("the bank resolves");
        assert!((rooted.base_increment - keyed.base_increment * 2.0).abs() < 1e-6);
    }

    #[test]
    fn keynum_forces_the_pitch_the_voice_sounds_at() {
        // `keynum` (op 46) makes a zone sound at a fixed key however it was
        // triggered — how a drum bank pins a kit piece. It was parsed and
        // then ignored, so those banks played chromatically.
        let rooted_at_69 = bank_with_pitch(69);
        let played = VoiceSettings::resolve(&rooted_at_69, &recipe(), 81, 100, SR)
            .expect("the bank resolves");
        let forced = VoiceSettings::resolve(
            &rooted_at_69,
            &recipe_with(Generator::Keynum, 69),
            81,
            100,
            SR,
        )
        .expect("the bank resolves");
        // Key 81 over a root of 69 is an octave up; forced back to 69 it is
        // the sample's own pitch.
        assert!((played.base_increment - forced.base_increment * 2.0).abs() < 1e-6);
        assert!((forced.base_increment - 44_100.0f64 / f64::from(SR)).abs() < 1e-9);
    }

    #[test]
    fn velocity_forces_the_loudness_the_voice_sounds_at() {
        // `velocity` (op 47), the same story for loudness.
        let bank = bank_with_pitch(69);
        let soft = VoiceSettings::resolve(&bank, &recipe(), 69, 40, SR).expect("the bank resolves");
        let forced =
            VoiceSettings::resolve(&bank, &recipe_with(Generator::Velocity, 40), 69, 127, SR)
                .expect("the bank resolves");
        assert!(
            (soft.gain - forced.gain).abs() < 1e-6,
            "{} vs {}",
            soft.gain,
            forced.gain
        );
        // And it really did override: struck at 127 without the generator the
        // voice is much louder.
        let loud =
            VoiceSettings::resolve(&bank, &recipe(), 69, 127, SR).expect("the bank resolves");
        assert!(loud.gain > forced.gain * 2.0);
    }
}
