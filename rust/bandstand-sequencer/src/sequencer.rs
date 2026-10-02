//! Turning a block of the timeline into events with sample offsets.
//!
//! Rules: `docs/rules/transport-clock.md` §3 for the block segments this reads,
//! and §7.3 of the plan for what it must do at a loop.

use std::sync::Arc;

use bandstand_transport::{BlockSegment, BlockSegments, TempoMap};

use crate::event::{EventKind, EventSink, TimedEvent};
use crate::sequence::Sequence;

/// The most notes the sequencer will track as sounding.
///
/// Sixteen channels of 128 keys. Fixed, so nothing allocates on the audio
/// thread.
const NOTE_SLOTS: usize = 16 * 128;

/// How many overlapping notes on one key the table can tell apart.
const MAX_OVERLAP: u16 = u16::MAX;

/// Reads a [`Sequence`] against the transport's block segments.
///
/// Audio-thread side. Allocation-free and wait-free: the sequence arrives whole
/// and the cursor only ever walks or is re-found by binary search.
pub struct Sequencer {
    sequence: Arc<Sequence>,
    cursor: usize,
    /// The tick the last block ended at, to notice a jump.
    last_end_tick: f64,
    /// How many notes are sounding per (channel, key) slot, so a loop or a
    /// seek can let them go. Overlapping notes on the same key count
    /// separately: a boolean per slot would lose a note that is still
    /// sounding when its neighbour on the same key is let go.
    sounding: [u16; NOTE_SLOTS],
    sounding_count: usize,
}

impl Sequencer {
    /// Create a sequencer over a sequence.
    #[must_use]
    pub fn new(sequence: Arc<Sequence>) -> Self {
        Self {
            sequence,
            cursor: 0,
            last_end_tick: f64::NAN,
            sounding: [0; NOTE_SLOTS],
            sounding_count: 0,
        }
    }

    /// Replace the sequence, letting go of anything sounding.
    ///
    /// The caller gets the note-offs through `sink`, so the synth is left in a
    /// state that matches what the listener heard.
    pub fn set_sequence(&mut self, sequence: Arc<Sequence>, sink: &mut impl EventSink) {
        self.release_all(0, sink);
        self.sequence = sequence;
        self.cursor = 0;
        self.last_end_tick = f64::NAN;
    }

    /// The sequence being played.
    #[must_use]
    pub fn sequence(&self) -> &Arc<Sequence> {
        &self.sequence
    }

    /// How many notes are sounding, as far as the sequencer knows.
    #[must_use]
    pub const fn sounding_notes(&self) -> usize {
        self.sounding_count
    }

    /// Read one audio block.
    ///
    /// `segments` comes from the transport and already accounts for loop wraps;
    /// this walks each one, emits the events inside it, and lets every sounding
    /// note go at a wrap so a loop does not leave notes hanging (§7.3).
    pub fn process(
        &mut self,
        segments: &BlockSegments,
        tempo_map: &TempoMap,
        sample_rate: f64,
        sink: &mut impl EventSink,
    ) {
        for segment in segments {
            self.process_segment(segment, tempo_map, sample_rate, sink);
        }
    }

    fn process_segment(
        &mut self,
        segment: &BlockSegment,
        tempo_map: &TempoMap,
        sample_rate: f64,
        sink: &mut impl EventSink,
    ) {
        // A jump — a seek, a loop wrap, or the first block — means the cursor
        // is somewhere else entirely.
        let continued = self.last_end_tick.is_finite()
            && (segment.start_tick - self.last_end_tick).abs() < 1e-6;
        if !continued {
            self.seek_to(segment.start_tick, segment.frame_offset, sink);
        }

        if segment.end_tick > segment.start_tick {
            let start_seconds = tempo_map.seconds_at_tick(segment.start_tick);
            // The sequence is behind an `Arc`, so taking a handle to it costs a
            // refcount bump and frees the borrow on `self` for `remember`.
            let sequence = Arc::clone(&self.sequence);
            let events = sequence.events();
            while self.cursor < events.len() {
                let event = events[self.cursor];
                #[allow(clippy::cast_precision_loss)]
                let tick = event.tick as f64;
                if tick >= segment.end_tick {
                    break;
                }
                if tick < segment.start_tick {
                    self.cursor += 1;
                    continue;
                }
                let seconds = tempo_map.seconds_at_tick(tick) - start_seconds;
                #[allow(
                    clippy::cast_possible_truncation,
                    clippy::cast_sign_loss,
                    clippy::cast_precision_loss
                )]
                let offset = ((seconds * sample_rate).floor().max(0.0) as usize)
                    .min(segment.frame_count.saturating_sub(1));
                self.remember(&event);
                sink.dispatch(segment.frame_offset + offset, &event);
                self.cursor += 1;
            }
        }

        self.last_end_tick = segment.end_tick;

        if segment.wraps_after {
            // A note started before the wrap would otherwise sound through it
            // and never be let go, because its note-off is past the loop end.
            let frame = segment.frame_offset + segment.frame_count.saturating_sub(1);
            self.release_all(frame, sink);
            self.last_end_tick = f64::NAN;
        }
    }

    /// Move the cursor to a tick, letting go of whatever was sounding.
    ///
    /// Also re-sends the program changes that apply there: seeking into the
    /// middle of a song must not leave the channels on the wrong sound.
    /// Changes at or after the start tick are left to the walk in `process`,
    /// so nothing is dispatched twice. Everything is dispatched at `frame`,
    /// the segment's offset inside the block: after a mid-block loop wrap
    /// that is the wrap frame, not the start of the block.
    fn seek_to(&mut self, tick: f64, frame: usize, sink: &mut impl EventSink) {
        self.release_all(frame, sink);
        #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
        let target = tick.max(0.0) as u64;
        self.cursor = self.sequence.index_at(target);
        if tick > 0.0 {
            // Re-send only what the walk in `process` cannot dispatch itself.
            // The walk sends every event at or after the segment's start
            // tick, so the re-send stops one short of `ceil(tick)`: a program
            // change sitting exactly on the loop start would otherwise be
            // dispatched twice on every pass — once here, once by the walk
            // (L-RT2). `ceil`, not truncation, keeps a fractional start
            // right: a segment starting at 1900.5 still re-sends the program
            // at 1900, which the walk skips because 1900 < 1900.5.
            #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
            let through = (tick.max(0.0).ceil() as u64).saturating_sub(1);
            // A caller-owned array, not the `Vec` that `programs_at` returns:
            // this runs on the audio thread after every loop wrap, and the
            // crate's contract above is that nothing here allocates.
            let mut programs: [Option<TimedEvent>; 16] = [None; 16];
            self.sequence.programs_at_into(through, &mut programs);
            for event in programs.iter().flatten() {
                sink.dispatch(frame, event);
            }
        }
    }

    fn remember(&mut self, event: &TimedEvent) {
        let channel = usize::from(event.channel) % 16;
        match event.kind {
            EventKind::NoteOn { key, velocity } if velocity > 0 => {
                let slot = channel * 128 + usize::from(key % 128);
                // Both counters move together or neither does. Bumping the
                // total while the slot was saturated left `sounding_count`
                // above what `release_all` could ever drain, so the sequencer
                // believed notes were sounding for the rest of the stream.
                if self.sounding[slot] < MAX_OVERLAP {
                    self.sounding[slot] += 1;
                    self.sounding_count += 1;
                }
            }
            EventKind::NoteOn { key, .. } | EventKind::NoteOff { key } => {
                let slot = channel * 128 + usize::from(key % 128);
                if self.sounding[slot] > 0 {
                    self.sounding[slot] -= 1;
                    self.sounding_count -= 1;
                }
            }
            EventKind::AllNotesOff => {
                for key in 0..128 {
                    let slot = channel * 128 + key;
                    self.sounding_count -= usize::from(self.sounding[slot]);
                    self.sounding[slot] = 0;
                }
            }
            _ => {}
        }
    }

    /// Let go of every note the sequencer believes is sounding.
    fn release_all(&mut self, frame: usize, sink: &mut impl EventSink) {
        if self.sounding_count == 0 {
            return;
        }
        for slot in 0..NOTE_SLOTS {
            if self.sounding[slot] == 0 {
                continue;
            }
            self.sounding[slot] = 0;
            #[allow(clippy::cast_possible_truncation)]
            let channel = (slot / 128) as u8;
            #[allow(clippy::cast_possible_truncation)]
            let key = (slot % 128) as u8;
            sink.dispatch(frame, &TimedEvent::note_off(0, channel, key));
        }
        self.sounding_count = 0;
    }
}

// The sounding-note table is 2048 booleans; its count is what is worth
// printing.
#[allow(clippy::missing_fields_in_debug)]
impl std::fmt::Debug for Sequencer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Sequencer")
            .field("events", &self.sequence.len())
            .field("cursor", &self.cursor)
            .field("sounding", &self.sounding_count)
            .finish()
    }
}
