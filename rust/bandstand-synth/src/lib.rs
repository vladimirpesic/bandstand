//! Sound generation for Bandstand.
//!
//! Holds the SoundFont reader and sampler (§7.2), the parameter-smoothing
//! primitive, and the reference test tone that verifies the audio path
//! (§10 M0).
//!
//! Nothing in this crate allocates, locks or blocks on the audio thread.

#![forbid(unsafe_op_in_unsafe_fn)]
// `SoundFont`, `General MIDI`, `Freeverb` and `Catmull-Rom` are proper nouns in
// this domain, not code, and back-ticking them would make the documentation
// read like a type index.
#![allow(clippy::doc_markdown)]
// Audio code converts between sizes constantly: frame counts to floats, the
// SoundFont format's `i16` fields to the `u16` bit patterns it packs ranges
// into, sample indices to `u32`. Every one of these is bounded by the format or
// by the block size, and the checks are where the values are read, not where
// they are converted.
#![allow(
    clippy::cast_possible_truncation,
    clippy::cast_precision_loss,
    clippy::cast_sign_loss,
    clippy::cast_possible_wrap
)]

pub mod effects;
mod envelope;
mod filter;
mod lfo;
pub mod sf2;
mod smoothed;
mod synth;
mod test_tone;
mod voice;

pub use effects::{Chorus, Reverb};
pub use envelope::{Envelope, EnvelopeSpec, EnvelopeStage};
pub use filter::LowPassFilter;
pub use lfo::Lfo;
pub use sf2::{load_soundfont, parse_soundfont, SoundBank, SoundFontError, VoiceRecipe};
pub use smoothed::Smoothed;
pub use synth::{ChannelState, Synth, CHANNEL_COUNT, DEFAULT_MAX_VOICES, DRUM_BANK, DRUM_CHANNEL};
pub use test_tone::{TestTone, DEFAULT_AMPLITUDE, DEFAULT_FREQUENCY_HZ};
pub use voice::{ChannelMix, Voice, VoiceSettings, FAST_RELEASE_SECONDS};
