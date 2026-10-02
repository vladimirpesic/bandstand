//! A loaded SoundFont, resolved into what a voice needs.
//!
//! Rules: `docs/rules/sf2-sampler.md` §2.

use std::sync::Arc;

use super::generators::Generator;
use super::samples::SampleSource;

/// How many generator slots a set holds. One past the highest operator
/// Bandstand reads.
pub const GENERATOR_SLOTS: usize = 59;

/// A zone's generator values, with the specification's defaults filled in.
#[derive(Debug, Clone)]
pub struct GeneratorSet {
    values: [i16; GENERATOR_SLOTS],
    present: [bool; GENERATOR_SLOTS],
}

impl GeneratorSet {
    /// A set with nothing said, so every generator has its default.
    #[must_use]
    pub fn defaults() -> Self {
        let mut values = [0i16; GENERATOR_SLOTS];
        for (operator, slot) in values.iter_mut().enumerate() {
            if let Some(generator) = Generator::from_operator(operator as u16) {
                *slot = generator.default_value();
            }
        }
        Self {
            values,
            present: [false; GENERATOR_SLOTS],
        }
    }

    /// A set with nothing said and every value zero, for accumulating offsets.
    #[must_use]
    pub const fn zeroed() -> Self {
        Self {
            values: [0; GENERATOR_SLOTS],
            present: [false; GENERATOR_SLOTS],
        }
    }

    /// The value of a generator.
    #[must_use]
    pub fn get(&self, generator: Generator) -> i16 {
        self.values[generator as usize]
    }

    /// The value as an `f32`, which is what every conversion wants.
    #[must_use]
    pub fn get_f32(&self, generator: Generator) -> f32 {
        f32::from(self.get(generator))
    }

    /// Whether the file said anything about this generator.
    #[must_use]
    pub fn has(&self, generator: Generator) -> bool {
        self.present[generator as usize]
    }

    /// Set a generator.
    pub fn set(&mut self, generator: Generator, value: i16) {
        self.values[generator as usize] = value;
        self.present[generator as usize] = true;
    }

    /// Overlay `other`'s stated generators on top of this set.
    ///
    /// Used to put a zone's own generators over its global zone's.
    pub fn overlay(&mut self, other: &Self) {
        for operator in 0..GENERATOR_SLOTS {
            if other.present[operator] {
                self.values[operator] = other.values[operator];
                self.present[operator] = true;
            }
        }
    }

    /// Add `offsets` to this set, for the generators that are additive at
    /// preset level.
    /// This is §2's rule: instrument generators say what the value *is*, preset
    /// generators say how much to *move* it.
    pub fn add_preset_offsets(&mut self, offsets: &Self) {
        for operator in 0..GENERATOR_SLOTS {
            if !offsets.present[operator] {
                continue;
            }
            let Some(generator) = Generator::from_operator(operator as u16) else {
                continue;
            };
            if !generator.is_additive_at_preset_level() {
                continue;
            }
            self.values[operator] = self.values[operator].saturating_add(offsets.values[operator]);
            self.present[operator] = true;
        }
    }
}

impl Default for GeneratorSet {
    fn default() -> Self {
        Self::defaults()
    }
}

/// An inclusive range of key or velocity values.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ByteRange {
    /// Lowest value in the range.
    pub low: u8,
    /// Highest value in the range.
    pub high: u8,
}

impl ByteRange {
    /// The whole range, 0 to 127.
    pub const FULL: Self = Self { low: 0, high: 127 };

    /// Unpack a `keyRange` or `velRange` generator, which packs low in the
    /// bottom byte and high in the top.
    #[must_use]
    pub const fn from_generator(value: i16) -> Self {
        let bits = value as u16;
        Self {
            low: (bits & 0xFF) as u8,
            high: ((bits >> 8) & 0xFF) as u8,
        }
    }

    /// Whether `value` is in the range.
    #[must_use]
    pub const fn contains(&self, value: u8) -> bool {
        value >= self.low && value <= self.high
    }
}

/// One zone of a preset or an instrument.
#[derive(Debug, Clone)]
pub struct Zone {
    /// Keys this zone covers.
    pub key_range: ByteRange,
    /// Velocities this zone covers.
    pub velocity_range: ByteRange,
    /// What the zone says, with its global zone already overlaid.
    pub generators: GeneratorSet,
    /// The instrument a preset zone plays, or the sample an instrument zone
    /// plays.
    pub target: usize,
}

impl Zone {
    /// Whether this zone answers a note.
    #[must_use]
    pub const fn matches(&self, key: u8, velocity: u8) -> bool {
        self.key_range.contains(key) && self.velocity_range.contains(velocity)
    }
}

/// A sample's header: where it is and how it is tuned.
#[derive(Debug, Clone)]
pub struct SampleHeader {
    /// Its name.
    pub name: String,
    /// First frame, in the sample data.
    pub start: u32,
    /// One past the last frame.
    pub end: u32,
    /// First frame of the loop.
    pub loop_start: u32,
    /// One past the last frame of the loop.
    pub loop_end: u32,
    /// The rate it was recorded at.
    pub sample_rate: u32,
    /// The key it sounds at its own rate.
    pub original_pitch: u8,
    /// Fine tuning, in cents.
    pub pitch_correction: i8,
    /// The other half of a stereo pair, if there is one.
    pub link: u16,
    /// Mono, left, right, linked, and the ROM variants.
    pub sample_type: u16,
}

impl SampleHeader {
    /// How many frames the sample has.
    #[must_use]
    pub const fn frame_count(&self) -> u32 {
        self.end.saturating_sub(self.start)
    }

    /// Whether the loop points are usable.
    ///
    /// A loop outside the sample, or too short for the four points cubic
    /// interpolation needs, is treated as no loop rather than as a crash
    /// (`docs/rules/sf2-sampler.md` §4.3).
    #[must_use]
    pub const fn has_usable_loop(&self) -> bool {
        self.loop_end > self.loop_start
            && self.loop_end.saturating_sub(self.loop_start) >= 4
            && self.loop_start >= self.start
            && self.loop_end <= self.end
    }
}

/// An instrument: a set of zones over samples.
#[derive(Debug, Clone)]
pub struct Instrument {
    /// Its name.
    pub name: String,
    /// Its zones.
    pub zones: Vec<Zone>,
}

/// A preset: what a bank-and-program selects.
#[derive(Debug, Clone)]
pub struct Preset {
    /// Its name.
    pub name: String,
    /// MIDI bank.
    pub bank: u16,
    /// MIDI program.
    pub program: u16,
    /// Its zones, each naming an instrument.
    pub zones: Vec<Zone>,
}

/// One layer a note starts: a sample, and the generators that shape it.
#[derive(Debug, Clone)]
pub struct VoiceRecipe {
    /// Which sample to play.
    pub sample: usize,
    /// Every generator, resolved.
    pub generators: GeneratorSet,
}

/// A loaded SoundFont.
pub struct SoundBank {
    /// The bank's name, from its `INFO` chunk.
    pub name: String,
    /// Every preset, in file order.
    pub presets: Vec<Preset>,
    /// Every instrument.
    pub instruments: Vec<Instrument>,
    /// Every sample header.
    pub samples: Vec<SampleHeader>,
    /// The sample data.
    pub data: Arc<dyn SampleSource>,
}

// Every field is covered: the sample data is summarised by its length rather
// than printed, which is the point of a manual implementation here.
#[allow(clippy::missing_fields_in_debug)]
impl std::fmt::Debug for SoundBank {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SoundBank")
            .field("name", &self.name)
            .field("presets", &self.presets.len())
            .field("instruments", &self.instruments.len())
            .field("samples", &self.samples.len())
            .field("frames", &self.data.len())
            .finish()
    }
}

impl SoundBank {
    /// The index of the preset for `(bank, program)`, or `None`.
    #[must_use]
    pub fn find_preset(&self, bank: u16, program: u16) -> Option<usize> {
        self.presets
            .iter()
            .position(|preset| preset.bank == bank && preset.program == program)
    }

    /// The index of the preset for `(bank, program)`, falling back the way a
    /// General MIDI player has to.
    ///
    /// A bank that has no such program in the bank asked for falls back to
    /// bank 0, and then to the first preset there is. A missing program must
    /// make *a* sound: silence on stage looks like a broken app, not like a
    /// missing patch.
    #[must_use]
    pub fn find_preset_or_fallback(&self, bank: u16, program: u16) -> Option<usize> {
        self.find_preset(bank, program)
            .or_else(|| self.find_preset(0, program))
            .or_else(|| (!self.presets.is_empty()).then_some(0))
    }

    /// The sample frame ranges a preset can reach.
    ///
    /// Its zones name instruments, and those zones name samples; a preset with
    /// a layered piano and a stereo pair reaches several. Deduplicated, because
    /// a preset commonly reaches one sample from more than one zone and warming
    /// it twice is wasted work.
    #[must_use]
    pub fn sample_ranges_for_preset(&self, preset: usize) -> Vec<(usize, usize)> {
        let mut ranges = Vec::new();
        let Some(preset) = self.presets.get(preset) else {
            return ranges;
        };
        let mut seen = Vec::new();
        for preset_zone in &preset.zones {
            let Some(instrument) = self.instruments.get(preset_zone.target) else {
                continue;
            };
            for zone in &instrument.zones {
                if seen.contains(&zone.target) {
                    continue;
                }
                seen.push(zone.target);
                if let Some(header) = self.samples.get(zone.target) {
                    ranges.push((header.start as usize, header.frame_count() as usize));
                }
            }
        }
        ranges
    }

    /// Bring a preset's samples into memory before it is played.
    ///
    /// `docs/rules/sf2-sampler.md` §9. Call this on the **control thread** when
    /// a program is selected: ADR 0007 puts the sample data behind an `mmap`,
    /// which means the first note of a newly chosen sound would otherwise take
    /// its page faults on the audio thread and click.
    ///
    /// Best effort. A preset warmed and then evicted before it sounds is no
    /// worse off than one never warmed.
    pub fn warm_preset(&self, preset: usize) {
        for (start, frames) in self.sample_ranges_for_preset(preset) {
            self.data.warm(start, frames);
        }
    }

    /// How many frames a preset would bring in, for the report.
    ///
    /// A preset is megabytes where a bank is hundreds, which is the whole
    /// reason warming one is affordable and prefaulting the file is not.
    #[must_use]
    pub fn frames_for_preset(&self, preset: usize) -> usize {
        self.sample_ranges_for_preset(preset)
            .iter()
            .map(|(_, frames)| frames)
            .sum()
    }

    /// Every voice a note on this preset starts.
    ///
    /// One note can start several: a layered piano, a round robin, a stereo
    /// pair (`docs/rules/sf2-sampler.md` §2). The recipes are pushed onto
    /// `out`, which the caller owns and clears between calls, so the audio
    /// thread does not allocate a fresh `Vec` on every note-on. Returns how
    /// many recipes were pushed.
    pub fn voices_for(
        &self,
        preset: usize,
        key: u8,
        velocity: u8,
        out: &mut Vec<VoiceRecipe>,
    ) -> usize {
        let mut started = 0;
        let Some(preset) = self.presets.get(preset) else {
            return started;
        };
        for preset_zone in &preset.zones {
            if !preset_zone.matches(key, velocity) {
                continue;
            }
            let Some(instrument) = self.instruments.get(preset_zone.target) else {
                continue;
            };
            for instrument_zone in &instrument.zones {
                if !instrument_zone.matches(key, velocity) {
                    continue;
                }
                if instrument_zone.target >= self.samples.len() {
                    continue;
                }
                let mut generators = instrument_zone.generators.clone();
                generators.add_preset_offsets(&preset_zone.generators);
                out.push(VoiceRecipe {
                    sample: instrument_zone.target,
                    generators,
                });
                started += 1;
            }
        }
        started
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
    use crate::sf2::samples::ResidentSamples;

    #[test]
    fn a_fresh_set_holds_the_specification_defaults() {
        let set = GeneratorSet::defaults();
        assert_eq!(set.get(Generator::InitialFilterFc), 13500);
        assert_eq!(set.get(Generator::AttackVolEnv), -12000);
        assert_eq!(set.get(Generator::ScaleTuning), 100);
        assert!(!set.has(Generator::Pan));
    }

    #[test]
    fn overlaying_replaces_only_what_was_stated() {
        let mut base = GeneratorSet::defaults();
        base.set(Generator::Pan, -200);
        base.set(Generator::InitialAttenuation, 50);

        let mut zone = GeneratorSet::zeroed();
        zone.set(Generator::Pan, 300);

        base.overlay(&zone);
        assert_eq!(base.get(Generator::Pan), 300);
        assert_eq!(base.get(Generator::InitialAttenuation), 50);
    }

    #[test]
    fn preset_generators_add_and_instrument_generators_state() {
        let mut instrument = GeneratorSet::defaults();
        instrument.set(Generator::InitialAttenuation, 100);
        instrument.set(Generator::CoarseTune, 2);

        let mut preset = GeneratorSet::zeroed();
        preset.set(Generator::InitialAttenuation, 60);
        preset.set(Generator::CoarseTune, -1);

        instrument.add_preset_offsets(&preset);
        assert_eq!(instrument.get(Generator::InitialAttenuation), 160);
        assert_eq!(instrument.get(Generator::CoarseTune), 1);
    }

    #[test]
    fn selecting_generators_are_not_added_at_preset_level() {
        let mut instrument = GeneratorSet::defaults();
        instrument.set(Generator::KeyRange, 0x4830);
        instrument.set(Generator::SampleId, 7);

        let mut preset = GeneratorSet::zeroed();
        preset.set(Generator::KeyRange, 0x7F00);
        preset.set(Generator::SampleId, 3);

        instrument.add_preset_offsets(&preset);
        assert_eq!(instrument.get(Generator::KeyRange), 0x4830);
        assert_eq!(instrument.get(Generator::SampleId), 7);
    }

    #[test]
    fn ranges_unpack_low_then_high() {
        let range = ByteRange::from_generator(0x4830);
        assert_eq!(range.low, 0x30);
        assert_eq!(range.high, 0x48);
        assert!(range.contains(0x30));
        assert!(range.contains(0x48));
        assert!(!range.contains(0x29));
        assert!(!range.contains(0x49));

        let full = ByteRange::from_generator(0x7F00);
        assert_eq!(full, ByteRange::FULL);
    }

    /// Records what was asked to be warmed (`docs/rules/sf2-sampler.md` §9).
    #[derive(Default)]
    struct RecordingSamples {
        warmed: std::sync::Mutex<Vec<(usize, usize)>>,
    }

    impl SampleSource for RecordingSamples {
        fn len(&self) -> usize {
            1_000
        }
        fn read(&self, _start: usize, out: &mut [f32]) {
            out.fill(0.0);
        }
        fn sample(&self, _index: usize) -> f32 {
            0.0
        }
        fn warm(&self, start: usize, frames: usize) {
            self.warmed.lock().expect("warm log").push((start, frames));
        }
    }

    #[test]
    fn warming_a_preset_reaches_every_sample_it_can_play() {
        let bank = bank_with(
            vec![zone(0, 127, 0)],
            vec![zone(0, 127, 0), zone(0, 127, 1)],
        );
        let ranges = bank.sample_ranges_for_preset(0);
        // Both samples, at the offsets and lengths their headers give.
        assert_eq!(ranges, vec![(0, 100), (100, 100)]);
        assert_eq!(bank.frames_for_preset(0), 200);
    }

    #[test]
    fn a_sample_reached_twice_is_warmed_once() {
        // A preset commonly reaches one sample from more than one zone — a
        // key split, a velocity layer — and warming it twice is wasted work.
        let bank = bank_with(
            vec![zone(0, 127, 0)],
            vec![zone(0, 60, 0), zone(61, 127, 0)],
        );
        assert_eq!(bank.sample_ranges_for_preset(0), vec![(0, 100)]);
    }

    #[test]
    fn warming_asks_the_source_for_each_range() {
        let recorder = Arc::new(RecordingSamples::default());
        let mut bank = bank_with(
            vec![zone(0, 127, 0)],
            vec![zone(0, 127, 0), zone(0, 127, 1)],
        );
        bank.data = Arc::clone(&recorder) as Arc<dyn SampleSource>;
        bank.warm_preset(0);
        assert_eq!(
            *recorder.warmed.lock().expect("warm log"),
            vec![(0, 100), (100, 100)]
        );
    }

    #[test]
    fn warming_a_preset_that_is_not_there_does_nothing() {
        let recorder = Arc::new(RecordingSamples::default());
        let mut bank = bank_with(vec![zone(0, 127, 0)], vec![]);
        bank.data = Arc::clone(&recorder) as Arc<dyn SampleSource>;
        bank.warm_preset(99);
        assert!(recorder.warmed.lock().expect("warm log").is_empty());
        assert_eq!(bank.frames_for_preset(99), 0);
    }

    fn bank_with(zones: Vec<Zone>, instrument_zones: Vec<Zone>) -> SoundBank {
        SoundBank {
            name: "test".to_owned(),
            presets: vec![Preset {
                name: "p".to_owned(),
                bank: 0,
                program: 0,
                zones,
            }],
            instruments: vec![Instrument {
                name: "i".to_owned(),
                zones: instrument_zones,
            }],
            samples: vec![
                SampleHeader {
                    name: "s0".to_owned(),
                    start: 0,
                    end: 100,
                    loop_start: 10,
                    loop_end: 90,
                    sample_rate: 44_100,
                    original_pitch: 60,
                    pitch_correction: 0,
                    link: 0,
                    sample_type: 1,
                },
                SampleHeader {
                    name: "s1".to_owned(),
                    start: 100,
                    end: 200,
                    loop_start: 0,
                    loop_end: 0,
                    sample_rate: 44_100,
                    original_pitch: 72,
                    pitch_correction: 0,
                    link: 0,
                    sample_type: 1,
                },
            ],
            data: Arc::new(ResidentSamples::new(vec![0; 200])),
        }
    }

    fn zone(low: u8, high: u8, target: usize) -> Zone {
        Zone {
            key_range: ByteRange { low, high },
            velocity_range: ByteRange::FULL,
            generators: GeneratorSet::defaults(),
            target,
        }
    }

    fn collect(bank: &SoundBank, preset: usize, key: u8, velocity: u8) -> Vec<VoiceRecipe> {
        let mut out = Vec::new();
        bank.voices_for(preset, key, velocity, &mut out);
        out
    }

    #[test]
    fn a_note_selects_every_zone_that_covers_it() {
        let bank = bank_with(
            vec![zone(0, 127, 0)],
            vec![zone(0, 59, 0), zone(60, 127, 1), zone(0, 127, 0)],
        );
        // Key 40 matches the low zone and the full-range one.
        assert_eq!(collect(&bank, 0, 40, 100).len(), 2);
        // Key 70 matches the high zone and the full-range one.
        let high = collect(&bank, 0, 70, 100);
        assert_eq!(high.len(), 2);
        assert_eq!(high[0].sample, 1);
    }

    #[test]
    fn a_note_outside_every_zone_starts_nothing() {
        let bank = bank_with(vec![zone(60, 72, 0)], vec![zone(60, 72, 0)]);
        assert!(collect(&bank, 0, 30, 100).is_empty());
        assert_eq!(collect(&bank, 0, 60, 100).len(), 1);
    }

    #[test]
    fn a_zone_pointing_at_a_sample_that_is_not_there_is_skipped() {
        let bank = bank_with(vec![zone(0, 127, 0)], vec![zone(0, 127, 99)]);
        assert!(collect(&bank, 0, 60, 100).is_empty());
    }

    #[test]
    fn voices_for_reuses_the_callers_buffer() {
        let bank = bank_with(
            vec![zone(0, 127, 0)],
            vec![zone(0, 59, 0), zone(60, 127, 1)],
        );
        let mut out = Vec::with_capacity(4);
        assert_eq!(bank.voices_for(0, 40, 100, &mut out), 1);
        assert_eq!(out[0].sample, 0);
        out.clear();
        assert_eq!(bank.voices_for(0, 70, 100, &mut out), 1);
        // Only the second call's recipe is there: the buffer is cleared by
        // the caller, and the capacity survives to be reused.
        assert_eq!(out.len(), 1);
        assert!(out.capacity() >= 4);
        assert_eq!(out[0].sample, 1);
    }

    #[test]
    fn programs_fall_back_rather_than_falling_silent() {
        let mut bank = bank_with(vec![zone(0, 127, 0)], vec![zone(0, 127, 0)]);
        bank.presets.push(Preset {
            name: "second".to_owned(),
            bank: 0,
            program: 5,
            zones: vec![zone(0, 127, 0)],
        });
        assert_eq!(bank.find_preset(0, 5), Some(1));
        assert_eq!(bank.find_preset(3, 5), None);
        // A program missing from bank 3 falls back to bank 0.
        assert_eq!(bank.find_preset_or_fallback(3, 5), Some(1));
        // A program missing everywhere falls back to the first preset.
        assert_eq!(bank.find_preset_or_fallback(3, 99), Some(0));
    }

    #[test]
    fn loop_points_are_checked_before_they_are_trusted() {
        let good = SampleHeader {
            name: "g".to_owned(),
            start: 0,
            end: 100,
            loop_start: 10,
            loop_end: 90,
            sample_rate: 44_100,
            original_pitch: 60,
            pitch_correction: 0,
            link: 0,
            sample_type: 1,
        };
        assert!(good.has_usable_loop());
        assert_eq!(good.frame_count(), 100);

        let inverted = SampleHeader {
            loop_start: 90,
            loop_end: 10,
            ..good.clone()
        };
        assert!(!inverted.has_usable_loop());

        let too_short = SampleHeader {
            loop_start: 10,
            loop_end: 12,
            ..good.clone()
        };
        assert!(!too_short.has_usable_loop());

        let outside = SampleHeader {
            loop_start: 10,
            loop_end: 400,
            ..good
        };
        assert!(!outside.has_usable_loop());
    }
}
