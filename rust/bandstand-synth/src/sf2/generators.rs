//! SoundFont generators: what they are, what they mean, and their units.
//!
//! Rules: `docs/rules/sf2-sampler.md` §2 and §3.

/// The generators Bandstand reads.
///
/// The SoundFont specification defines sixty; the ones missing here either
/// duplicate a modulator's job or were never implemented by any synth. A
/// generator the file uses and this list does not is ignored, not an error —
/// banks in the wild carry all sorts.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[repr(u16)]
pub enum Generator {
    /// Offset to the sample's start, in samples.
    StartAddrsOffset = 0,
    /// Offset to the sample's end.
    EndAddrsOffset = 1,
    /// Offset to the loop start.
    StartLoopAddrsOffset = 2,
    /// Offset to the loop end.
    EndLoopAddrsOffset = 3,
    /// Offset to the sample's start, in units of 32768 samples.
    StartAddrsCoarseOffset = 4,
    /// Modulation LFO to pitch, in cents.
    ModLfoToPitch = 5,
    /// Vibrato LFO to pitch, in cents.
    VibLfoToPitch = 6,
    /// Modulation envelope to pitch, in cents.
    ModEnvToPitch = 7,
    /// Filter cutoff, in absolute cents.
    InitialFilterFc = 8,
    /// Filter resonance, in centibels.
    InitialFilterQ = 9,
    /// Modulation LFO to filter cutoff, in cents.
    ModLfoToFilterFc = 10,
    /// Modulation envelope to filter cutoff, in cents.
    ModEnvToFilterFc = 11,
    /// Offset to the sample's end, coarse.
    EndAddrsCoarseOffset = 12,
    /// Modulation LFO to volume, in centibels.
    ModLfoToVolume = 13,
    /// Chorus send, in tenths of a percent.
    ChorusEffectsSend = 15,
    /// Reverb send, in tenths of a percent.
    ReverbEffectsSend = 16,
    /// Pan, −500 (left) to +500 (right).
    Pan = 17,
    /// Delay before the modulation LFO starts, in timecents.
    DelayModLfo = 21,
    /// Modulation LFO frequency, in absolute cents.
    FreqModLfo = 22,
    /// Delay before the vibrato LFO starts, in timecents.
    DelayVibLfo = 23,
    /// Vibrato LFO frequency, in absolute cents.
    FreqVibLfo = 24,
    /// Modulation envelope delay, in timecents.
    DelayModEnv = 25,
    /// Modulation envelope attack, in timecents.
    AttackModEnv = 26,
    /// Modulation envelope hold, in timecents.
    HoldModEnv = 27,
    /// Modulation envelope decay, in timecents.
    DecayModEnv = 28,
    /// Modulation envelope sustain, in tenths of a percent below peak.
    SustainModEnv = 29,
    /// Modulation envelope release, in timecents.
    ReleaseModEnv = 30,
    /// How key number scales the modulation envelope's hold.
    KeynumToModEnvHold = 31,
    /// How key number scales the modulation envelope's decay.
    KeynumToModEnvDecay = 32,
    /// Volume envelope delay, in timecents.
    DelayVolEnv = 33,
    /// Volume envelope attack, in timecents.
    AttackVolEnv = 34,
    /// Volume envelope hold, in timecents.
    HoldVolEnv = 35,
    /// Volume envelope decay, in timecents.
    DecayVolEnv = 36,
    /// Volume envelope sustain, in centibels of attenuation below peak.
    SustainVolEnv = 37,
    /// Volume envelope release, in timecents.
    ReleaseVolEnv = 38,
    /// How key number scales the volume envelope's hold.
    KeynumToVolEnvHold = 39,
    /// How key number scales the volume envelope's decay.
    KeynumToVolEnvDecay = 40,
    /// The instrument a preset zone plays. Preset zones only.
    Instrument = 41,
    /// The keys this zone covers.
    KeyRange = 43,
    /// The velocities this zone covers.
    VelRange = 44,
    /// Offset to the loop start, coarse.
    StartLoopAddrsCoarseOffset = 45,
    /// Forces the key number, ignoring the note played.
    Keynum = 46,
    /// Forces the velocity, ignoring the note played.
    Velocity = 47,
    /// Attenuation, in centibels.
    InitialAttenuation = 48,
    /// Offset to the loop end, coarse.
    EndLoopAddrsCoarseOffset = 50,
    /// Tuning, in semitones.
    CoarseTune = 51,
    /// Tuning, in cents.
    FineTune = 52,
    /// The sample an instrument zone plays. Instrument zones only.
    SampleId = 53,
    /// Whether and how the sample loops.
    SampleModes = 54,
    /// How much key number affects pitch, in percent. 100 is normal.
    ScaleTuning = 56,
    /// Voices sharing a non-zero class on a channel cut each other off.
    ExclusiveClass = 57,
    /// Overrides the sample's own root key.
    OverridingRootKey = 58,
}

impl Generator {
    /// The generator with this operator number, or `None` if it is one
    /// Bandstand does not read.
    #[must_use]
    pub const fn from_operator(operator: u16) -> Option<Self> {
        Some(match operator {
            0 => Self::StartAddrsOffset,
            1 => Self::EndAddrsOffset,
            2 => Self::StartLoopAddrsOffset,
            3 => Self::EndLoopAddrsOffset,
            4 => Self::StartAddrsCoarseOffset,
            5 => Self::ModLfoToPitch,
            6 => Self::VibLfoToPitch,
            7 => Self::ModEnvToPitch,
            8 => Self::InitialFilterFc,
            9 => Self::InitialFilterQ,
            10 => Self::ModLfoToFilterFc,
            11 => Self::ModEnvToFilterFc,
            12 => Self::EndAddrsCoarseOffset,
            13 => Self::ModLfoToVolume,
            15 => Self::ChorusEffectsSend,
            16 => Self::ReverbEffectsSend,
            17 => Self::Pan,
            21 => Self::DelayModLfo,
            22 => Self::FreqModLfo,
            23 => Self::DelayVibLfo,
            24 => Self::FreqVibLfo,
            25 => Self::DelayModEnv,
            26 => Self::AttackModEnv,
            27 => Self::HoldModEnv,
            28 => Self::DecayModEnv,
            29 => Self::SustainModEnv,
            30 => Self::ReleaseModEnv,
            31 => Self::KeynumToModEnvHold,
            32 => Self::KeynumToModEnvDecay,
            33 => Self::DelayVolEnv,
            34 => Self::AttackVolEnv,
            35 => Self::HoldVolEnv,
            36 => Self::DecayVolEnv,
            37 => Self::SustainVolEnv,
            38 => Self::ReleaseVolEnv,
            39 => Self::KeynumToVolEnvHold,
            40 => Self::KeynumToVolEnvDecay,
            41 => Self::Instrument,
            43 => Self::KeyRange,
            44 => Self::VelRange,
            45 => Self::StartLoopAddrsCoarseOffset,
            46 => Self::Keynum,
            47 => Self::Velocity,
            48 => Self::InitialAttenuation,
            50 => Self::EndLoopAddrsCoarseOffset,
            51 => Self::CoarseTune,
            52 => Self::FineTune,
            53 => Self::SampleId,
            54 => Self::SampleModes,
            56 => Self::ScaleTuning,
            57 => Self::ExclusiveClass,
            58 => Self::OverridingRootKey,
            _ => return None,
        })
    }

    /// The value a zone has when the file says nothing.
    ///
    /// From the specification's default table. The ones that matter most:
    /// envelope times default to −12000 timecents, which is one millisecond and
    /// is effectively instant; `ScaleTuning` defaults to 100, meaning a
    /// semitone per key.
    #[must_use]
    pub const fn default_value(self) -> i16 {
        match self {
            Self::InitialFilterFc => 13500,
            Self::DelayModLfo
            | Self::FreqModLfo
            | Self::DelayVibLfo
            | Self::FreqVibLfo
            | Self::DelayModEnv
            | Self::AttackModEnv
            | Self::HoldModEnv
            | Self::DecayModEnv
            | Self::ReleaseModEnv
            | Self::DelayVolEnv
            | Self::AttackVolEnv
            | Self::HoldVolEnv
            | Self::DecayVolEnv
            | Self::ReleaseVolEnv => -12000,
            Self::Keynum | Self::Velocity | Self::OverridingRootKey => -1,
            Self::ScaleTuning => 100,
            Self::KeyRange | Self::VelRange => 0x7F00,
            _ => 0,
        }
    }

    /// Whether a preset-level value of this generator is an offset added to the
    /// instrument's, rather than something that selects or replaces.
    ///
    /// See `docs/rules/sf2-sampler.md` §2: this is the rule everyone gets
    /// backwards.
    #[must_use]
    pub const fn is_additive_at_preset_level(self) -> bool {
        !matches!(
            self,
            Self::KeyRange | Self::VelRange | Self::SampleId | Self::Instrument
        )
    }
}

/// How a sample loops.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LoopMode {
    /// Play once and stop.
    NoLoop,
    /// Loop for as long as the voice sounds.
    Continuous,
    /// Loop until the key is released, then play to the end.
    UntilRelease,
}

impl LoopMode {
    /// Read a `sampleModes` value. Anything unrecognised means no loop, which
    /// is what every other synth does with it.
    #[must_use]
    pub const fn from_value(value: i16) -> Self {
        match value & 3 {
            1 => Self::Continuous,
            3 => Self::UntilRelease,
            _ => Self::NoLoop,
        }
    }

    /// Whether the sample loops at all.
    #[must_use]
    pub const fn loops(self) -> bool {
        matches!(self, Self::Continuous | Self::UntilRelease)
    }
}

/// Timecents to seconds (`docs/rules/sf2-sampler.md` §3).
#[must_use]
pub fn timecents_to_seconds(timecents: f32) -> f32 {
    // −32768 is the specification's "never", and 2^(−32768/1200) underflows to
    // zero anyway; this just says so plainly.
    if timecents <= -32768.0 {
        return 0.0;
    }
    (timecents / 1200.0).exp2()
}

/// Absolute cents to hertz.
#[must_use]
pub fn absolute_cents_to_hertz(cents: f32) -> f32 {
    8.176 * (cents / 1200.0).exp2()
}

/// Cents to a frequency ratio.
#[must_use]
pub fn cents_to_ratio(cents: f32) -> f32 {
    (cents / 1200.0).exp2()
}

/// Centibels of attenuation to a linear gain.
#[must_use]
pub fn centibels_to_gain(centibels: f32) -> f32 {
    if centibels >= 960.0 {
        return 0.0;
    }
    10.0f32.powf(-centibels.max(0.0) / 200.0)
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

    fn approx(a: f32, b: f32, tolerance: f32) {
        assert!((a - b).abs() < tolerance, "{a} != {b}");
    }

    #[test]
    fn operators_map_to_generators() {
        assert_eq!(Generator::from_operator(41), Some(Generator::Instrument));
        assert_eq!(Generator::from_operator(53), Some(Generator::SampleId));
        assert_eq!(
            Generator::from_operator(58),
            Some(Generator::OverridingRootKey)
        );
        // 14, 18, 19, 20, 42, 49, 55 and 59 are unused in the specification.
        assert_eq!(Generator::from_operator(14), None);
        assert_eq!(Generator::from_operator(60), None);
    }

    #[test]
    fn defaults_are_the_specification_table() {
        assert_eq!(Generator::InitialFilterFc.default_value(), 13500);
        assert_eq!(Generator::AttackVolEnv.default_value(), -12000);
        assert_eq!(Generator::SustainVolEnv.default_value(), 0);
        assert_eq!(Generator::ScaleTuning.default_value(), 100);
        assert_eq!(Generator::Keynum.default_value(), -1);
        assert_eq!(Generator::Pan.default_value(), 0);
        // 0x7F00 is 0..127 packed as low, high.
        assert_eq!(Generator::KeyRange.default_value(), 0x7F00);
    }

    #[test]
    fn only_selecting_generators_are_absolute_at_preset_level() {
        assert!(!Generator::KeyRange.is_additive_at_preset_level());
        assert!(!Generator::VelRange.is_additive_at_preset_level());
        assert!(!Generator::SampleId.is_additive_at_preset_level());
        assert!(!Generator::Instrument.is_additive_at_preset_level());
        assert!(Generator::InitialAttenuation.is_additive_at_preset_level());
        assert!(Generator::CoarseTune.is_additive_at_preset_level());
    }

    #[test]
    fn timecents_are_seconds() {
        approx(timecents_to_seconds(0.0), 1.0, 1e-6);
        approx(timecents_to_seconds(1200.0), 2.0, 1e-6);
        approx(timecents_to_seconds(-1200.0), 0.5, 1e-6);
        // The default of −12000 is one millisecond.
        approx(timecents_to_seconds(-12000.0), 0.000_977, 1e-5);
        assert_eq!(timecents_to_seconds(-32768.0), 0.0);
    }

    #[test]
    fn absolute_cents_are_hertz() {
        // 6900 absolute cents is A440.
        approx(absolute_cents_to_hertz(6900.0), 440.0, 0.2);
        // The filter default of 13500 is above hearing.
        assert!(absolute_cents_to_hertz(13500.0) > 19_000.0);
    }

    #[test]
    fn cents_are_ratios() {
        approx(cents_to_ratio(0.0), 1.0, 1e-6);
        approx(cents_to_ratio(1200.0), 2.0, 1e-6);
        approx(cents_to_ratio(100.0), 1.059_463, 1e-5);
    }

    #[test]
    fn centibels_are_attenuation() {
        approx(centibels_to_gain(0.0), 1.0, 1e-6);
        approx(centibels_to_gain(200.0), 0.1, 1e-6);
        approx(centibels_to_gain(60.0), 0.501_187, 1e-5);
        // The specification treats 960 centibels as silence.
        assert_eq!(centibels_to_gain(960.0), 0.0);
        // Negative attenuation would be gain; the format does not mean that.
        approx(centibels_to_gain(-100.0), 1.0, 1e-6);
    }

    #[test]
    fn loop_modes_are_read_from_the_low_two_bits() {
        assert_eq!(LoopMode::from_value(0), LoopMode::NoLoop);
        assert_eq!(LoopMode::from_value(1), LoopMode::Continuous);
        assert_eq!(LoopMode::from_value(2), LoopMode::NoLoop);
        assert_eq!(LoopMode::from_value(3), LoopMode::UntilRelease);
        assert!(LoopMode::Continuous.loops());
        assert!(!LoopMode::NoLoop.loops());
    }
}
