//! Bus effects.
//!
//! Rules: `docs/rules/sf2-sampler.md` §6. Both are on a bus rather than per
//! voice: a hundred voices share one reverb.

mod chorus;
mod reverb;

pub use chorus::Chorus;
pub use reverb::Reverb;
