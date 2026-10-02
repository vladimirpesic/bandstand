//! Reading and playing SoundFont banks.
//!
//! Rules: `docs/rules/sf2-sampler.md`.

pub mod bank;
pub mod generators;
pub mod parse;
pub mod riff;
pub mod samples;

pub use bank::{
    ByteRange, GeneratorSet, Instrument, Preset, SampleHeader, SoundBank, VoiceRecipe, Zone,
    GENERATOR_SLOTS,
};
pub use generators::{
    absolute_cents_to_hertz, centibels_to_gain, cents_to_ratio, timecents_to_seconds, Generator,
    LoopMode,
};
pub use parse::{load_soundfont, parse_soundfont};
pub use riff::SoundFontError;
pub use samples::{MappedSamples, ResidentSamples, SampleSource};
