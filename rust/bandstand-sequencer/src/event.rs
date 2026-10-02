//! What a sequence is made of.

/// What an event does.
///
/// Deliberately smaller than MIDI: this is the vocabulary Bandstand's
/// generators speak, and everything in it has a defined effect on the synth.
/// A wider surface would be one nobody could test.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum EventKind {
    /// Start a note.
    NoteOn {
        /// MIDI key, 0–127.
        key: u8,
        /// MIDI velocity, 1–127. Zero is a note off, as MIDI allows.
        velocity: u8,
    },
    /// Let a note go.
    NoteOff {
        /// MIDI key.
        key: u8,
    },
    /// Select a sound.
    Program {
        /// Bank.
        bank: u16,
        /// Program.
        program: u16,
    },
    /// Set the channel's volume, 0 to 1.
    Volume(f32),
    /// Set the channel's pan, −1 to 1.
    Pan(f32),
    /// Set the channel's expression, 0 to 1.
    Expression(f32),
    /// Put the sustain pedal down or up.
    Sustain(bool),
    /// Bend the channel's pitch, −1 to 1.
    PitchBend(f32),
    /// Let every note on the channel go.
    AllNotesOff,
}

/// One event, at a place in the sequence.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TimedEvent {
    /// Where it happens, in ticks.
    pub tick: u64,
    /// Which MIDI channel it is on.
    pub channel: u8,
    /// What it does.
    pub kind: EventKind,
}

impl TimedEvent {
    /// Create an event.
    #[must_use]
    pub const fn new(tick: u64, channel: u8, kind: EventKind) -> Self {
        Self {
            tick,
            channel,
            kind,
        }
    }

    /// A note on.
    #[must_use]
    pub const fn note_on(tick: u64, channel: u8, key: u8, velocity: u8) -> Self {
        Self::new(tick, channel, EventKind::NoteOn { key, velocity })
    }

    /// A note off.
    #[must_use]
    pub const fn note_off(tick: u64, channel: u8, key: u8) -> Self {
        Self::new(tick, channel, EventKind::NoteOff { key })
    }

    /// How events are ordered at the same tick.
    ///
    /// Note-offs before program changes before note-ons: a note must be let go
    /// before the same key is struck again, and a program change must land
    /// before the notes that use it. A note-on with zero velocity is a note
    /// off (as MIDI allows), so it sorts with the note-offs.
    #[must_use]
    pub const fn order(&self) -> u8 {
        match self.kind {
            EventKind::NoteOff { .. }
            | EventKind::AllNotesOff
            | EventKind::NoteOn { velocity: 0, .. } => 0,
            EventKind::NoteOn { .. } => 3,
            _ => 1,
        }
    }
}

/// Where a sequencer sends the events it reads.
///
/// Called on the audio thread, once per event, with the frame inside the block
/// the event lands on.
pub trait EventSink {
    /// Deliver an event at `frame` frames into the block.
    fn dispatch(&mut self, frame: usize, event: &TimedEvent);
}

impl<F: FnMut(usize, &TimedEvent)> EventSink for F {
    fn dispatch(&mut self, frame: usize, event: &TimedEvent) {
        self(frame, event);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn events_at_one_tick_are_ordered_so_notes_do_not_collide() {
        let off = TimedEvent::note_off(0, 0, 60);
        let on = TimedEvent::note_on(0, 0, 60, 100);
        let program = TimedEvent::new(
            0,
            0,
            EventKind::Program {
                bank: 0,
                program: 1,
            },
        );
        assert!(off.order() < program.order());
        assert!(program.order() < on.order());
        assert_eq!(
            TimedEvent::new(0, 0, EventKind::AllNotesOff).order(),
            off.order()
        );
    }

    #[test]
    fn a_zero_velocity_note_on_is_ordered_as_a_note_off() {
        let off = TimedEvent::note_off(0, 0, 60);
        let zero = TimedEvent::note_on(0, 0, 60, 0);
        assert_eq!(zero.order(), off.order());
    }

    #[test]
    fn a_closure_is_a_sink() {
        let mut seen = Vec::new();
        {
            let mut sink = |frame: usize, event: &TimedEvent| {
                seen.push((frame, event.tick));
            };
            sink.dispatch(7, &TimedEvent::note_on(100, 0, 60, 90));
        }
        assert_eq!(seen, vec![(7, 100)]);
    }
}
