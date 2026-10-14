//! Transport clock, tempo map and lock-free position readback.
//!
//! This crate owns the *timeline*: where the playhead is, how ticks map to
//! seconds, and how that position reaches the UI. It knows nothing about audio
//! devices, samples or MIDI, and it has no dependencies beyond `std`.
//!
//! The written rules this implements are in `docs/rules/transport-clock.md`.
//!
//! ```
//! use bandstand_transport::{LoopRegion, PlayState, TempoMap, Transport};
//!
//! let (mut transport, handle) = Transport::new(TempoMap::constant(960, 120.0).unwrap());
//! transport.set_sample_rate(48_000.0);
//! handle.play();
//!
//! // One audio block of 24 000 frames = 0.5 s = one quarter note at 120 bpm.
//! transport.advance(24_000, 0);
//! assert!((transport.tick() - 960.0).abs() < 1e-6);
//! assert_eq!(handle.position().state, PlayState::Playing);
//!
//! handle.set_loop(LoopRegion { start_tick: 0, end_tick: 3840, enabled: true });
//! ```

#![forbid(unsafe_op_in_unsafe_fn)]

mod clock;
mod loop_region;
mod position;
mod tempo_map;
mod tempo_slot;
mod transport;

pub use clock::{init_clock, monotonic_now_ns};
pub use loop_region::{LoopCell, LoopRegion};
pub use position::{PlayState, PositionCell, PositionSnapshot};
pub use tempo_map::{TempoChange, TempoMap, TempoMapError, DEFAULT_PPQ, MAX_BPM, MIN_BPM};
pub use tempo_slot::TempoMapSlot;
pub use transport::{
    BlockSegment, BlockSegments, Transport, TransportHandle, TransportShared, MAX_BLOCK_SEGMENTS,
};
