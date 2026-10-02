//! Event scheduling, loops, count-in and the metronome.
//!
//! The transport (`bandstand-transport`) says where the playhead is; this says
//! what happens there. It knows nothing about audio devices or samples: it
//! turns a block of the timeline into events with sample offsets, and hands
//! them to whatever is listening.
//!
//! Rules: `docs/rules/transport-clock.md` §3 for the block segments it reads.

#![forbid(unsafe_code)]
#![allow(clippy::doc_markdown)]

mod event;
mod metronome;
mod sequence;
mod sequencer;

pub use event::{EventKind, EventSink, TimedEvent};
pub use metronome::{
    click_track, count_in_seconds, count_in_ticks, MetronomeSpec, ACCENT_KEY, CLICK_KEY,
    DRUM_CHANNEL,
};
pub use sequence::Sequence;
pub use sequencer::Sequencer;
