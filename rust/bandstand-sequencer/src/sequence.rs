//! A whole song's worth of events, ready to play.

use bandstand_transport::{TempoMap, DEFAULT_PPQ};

use crate::event::{EventKind, TimedEvent};

/// An immutable, sorted list of events.
///
/// Built on the control thread and handed to the audio thread whole. Sorting
/// happens once, here, so the sequencer's inner loop is a walk rather than a
/// search.
#[derive(Debug, Clone)]
pub struct Sequence {
    events: Vec<TimedEvent>,
    ppq: u32,
    length_ticks: u64,
}

impl Sequence {
    /// Build a sequence, sorting the events.
    #[must_use]
    pub fn new(mut events: Vec<TimedEvent>, ppq: u32, length_ticks: u64) -> Self {
        events.sort_by(|a, b| {
            a.tick
                .cmp(&b.tick)
                .then_with(|| a.order().cmp(&b.order()))
                .then_with(|| a.channel.cmp(&b.channel))
        });
        let last = events.last().map_or(0, |event| event.tick);
        Self {
            events,
            ppq: if ppq == 0 { DEFAULT_PPQ } else { ppq },
            length_ticks: length_ticks.max(last),
        }
    }

    /// An empty sequence.
    #[must_use]
    pub fn empty() -> Self {
        Self::new(Vec::new(), DEFAULT_PPQ, 0)
    }

    /// The events, in order.
    #[must_use]
    pub fn events(&self) -> &[TimedEvent] {
        &self.events
    }

    /// Ticks per quarter note.
    #[must_use]
    pub const fn ppq(&self) -> u32 {
        self.ppq
    }

    /// How long the sequence is, in ticks.
    #[must_use]
    pub const fn length_ticks(&self) -> u64 {
        self.length_ticks
    }

    /// How many events there are.
    #[must_use]
    pub fn len(&self) -> usize {
        self.events.len()
    }

    /// Whether there are none.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.events.is_empty()
    }

    /// How long the sequence lasts, in seconds, under `tempo_map`.
    #[must_use]
    pub fn duration_seconds(&self, tempo_map: &TempoMap) -> f64 {
        #[allow(clippy::cast_precision_loss)]
        tempo_map.seconds_at_tick(self.length_ticks as f64)
    }

    /// The index of the first event at or after `tick`.
    ///
    /// A binary search, used when the playhead jumps rather than advances.
    #[must_use]
    pub fn index_at(&self, tick: u64) -> usize {
        self.events.partition_point(|event| event.tick < tick)
    }

    /// Every channel the sequence touches.
    #[must_use]
    pub fn channels(&self) -> Vec<u8> {
        let mut seen = [false; 16];
        for event in &self.events {
            seen[usize::from(event.channel) % 16] = true;
        }
        (0..16u8).filter(|c| seen[usize::from(*c)]).collect()
    }

    /// The program changes that apply at or before `tick`, one per channel,
    /// written into `out` by channel index.
    ///
    /// What a seek needs: jumping into the middle of a song must not leave the
    /// channels on whatever sound the last seek happened to set.
    ///
    /// This is the form the audio thread calls. It allocates nothing — the
    /// caller owns the array — and it walks *backwards* from `tick`, stopping
    /// as soon as every channel has been answered, rather than scanning the
    /// whole sequence from the start on every loop wrap.
    pub fn programs_at_into(&self, tick: u64, out: &mut [Option<TimedEvent>; 16]) {
        *out = [None; 16];
        // `index_at` finds the first event at or after its argument, so
        // `tick + 1` is one past the last event that applies. Saturating
        // because a sequence may legitimately hold an event at `u64::MAX`.
        let end = self.index_at(tick.saturating_add(1));
        let mut found = 0usize;
        for event in self.events[..end].iter().rev() {
            if !matches!(event.kind, EventKind::Program { .. }) {
                continue;
            }
            let channel = usize::from(event.channel) % 16;
            // Backwards, so the first one seen for a channel is the last one
            // that applies — the same event the forward scan ended on.
            if out[channel].is_none() {
                out[channel] = Some(*event);
                found += 1;
                if found == out.len() {
                    break;
                }
            }
        }
    }

    /// The program changes that apply at or before `tick`, one per channel.
    ///
    /// Allocates, so it is for the UI thread and for tests;
    /// [`Self::programs_at_into`] is the audio thread's form.
    #[must_use]
    pub fn programs_at(&self, tick: u64) -> Vec<TimedEvent> {
        let mut latest: [Option<TimedEvent>; 16] = [None; 16];
        self.programs_at_into(tick, &mut latest);
        latest.into_iter().flatten().collect()
    }
}

impl Default for Sequence {
    fn default() -> Self {
        Self::empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn events_are_sorted_by_tick_then_by_kind() {
        let sequence = Sequence::new(
            vec![
                TimedEvent::note_on(100, 0, 60, 90),
                TimedEvent::note_off(100, 0, 62),
                TimedEvent::note_on(0, 0, 62, 90),
            ],
            960,
            200,
        );
        let ticks: Vec<u64> = sequence.events().iter().map(|e| e.tick).collect();
        assert_eq!(ticks, vec![0, 100, 100]);
        // At tick 100 the note off comes before the note on.
        assert!(matches!(
            sequence.events()[1].kind,
            EventKind::NoteOff { .. }
        ));
    }

    #[test]
    fn the_length_covers_the_last_event_even_if_it_was_understated() {
        let sequence = Sequence::new(vec![TimedEvent::note_on(5000, 0, 60, 90)], 960, 10);
        assert_eq!(sequence.length_ticks(), 5000);
    }

    #[test]
    fn a_ppq_of_zero_falls_back_to_the_default() {
        assert_eq!(Sequence::new(Vec::new(), 0, 0).ppq(), DEFAULT_PPQ);
    }

    #[test]
    fn an_empty_sequence_is_empty() {
        let sequence = Sequence::empty();
        assert!(sequence.is_empty());
        assert_eq!(sequence.len(), 0);
        assert_eq!(sequence.length_ticks(), 0);
        assert!(sequence.channels().is_empty());
    }

    #[test]
    fn finding_a_tick_lands_on_the_first_event_at_or_after_it() {
        let sequence = Sequence::new(
            vec![
                TimedEvent::note_on(0, 0, 60, 90),
                TimedEvent::note_on(480, 0, 62, 90),
                TimedEvent::note_on(960, 0, 64, 90),
            ],
            960,
            1920,
        );
        assert_eq!(sequence.index_at(0), 0);
        assert_eq!(sequence.index_at(1), 1);
        assert_eq!(sequence.index_at(480), 1);
        assert_eq!(sequence.index_at(961), 3);
    }

    #[test]
    fn the_channels_it_touches_are_listed_once_each() {
        let sequence = Sequence::new(
            vec![
                TimedEvent::note_on(0, 3, 60, 90),
                TimedEvent::note_on(0, 9, 35, 90),
                TimedEvent::note_on(10, 3, 62, 90),
            ],
            960,
            100,
        );
        assert_eq!(sequence.channels(), vec![3, 9]);
    }

    #[test]
    fn a_seek_can_find_the_sound_each_channel_should_be_on() {
        let sequence = Sequence::new(
            vec![
                TimedEvent::new(
                    0,
                    0,
                    EventKind::Program {
                        bank: 0,
                        program: 1,
                    },
                ),
                TimedEvent::new(
                    500,
                    0,
                    EventKind::Program {
                        bank: 0,
                        program: 2,
                    },
                ),
                TimedEvent::new(
                    100,
                    9,
                    EventKind::Program {
                        bank: 128,
                        program: 0,
                    },
                ),
                TimedEvent::new(
                    900,
                    0,
                    EventKind::Program {
                        bank: 0,
                        program: 3,
                    },
                ),
            ],
            960,
            1920,
        );
        let at = sequence.programs_at(600);
        assert_eq!(at.len(), 2);
        assert!(at
            .iter()
            .any(|event| matches!(event.kind, EventKind::Program { program: 2, .. })));
        assert!(at
            .iter()
            .any(|event| matches!(event.kind, EventKind::Program { bank: 128, .. })));
    }

    #[test]
    fn the_allocation_free_form_agrees_with_the_allocating_one() {
        // `programs_at_into` is what the audio thread calls; `programs_at` is
        // the convenience wrapper. They must never disagree about which
        // program a channel is on, so the wrapper is defined in terms of it
        // and this pins the pair across a range of seek targets.
        let sequence = Sequence::new(
            vec![
                TimedEvent::new(
                    0,
                    0,
                    EventKind::Program {
                        bank: 0,
                        program: 1,
                    },
                ),
                TimedEvent::new(
                    100,
                    9,
                    EventKind::Program {
                        bank: 128,
                        program: 0,
                    },
                ),
                TimedEvent::new(
                    500,
                    0,
                    EventKind::Program {
                        bank: 0,
                        program: 2,
                    },
                ),
                TimedEvent::new(
                    500,
                    1,
                    EventKind::NoteOn {
                        key: 60,
                        velocity: 80,
                    },
                ),
                TimedEvent::new(
                    900,
                    0,
                    EventKind::Program {
                        bank: 0,
                        program: 3,
                    },
                ),
            ],
            960,
            1920,
        );
        for tick in [0, 1, 99, 100, 499, 500, 899, 900, 1920, u64::MAX] {
            let mut out: [Option<TimedEvent>; 16] = [None; 16];
            sequence.programs_at_into(tick, &mut out);
            let flattened: Vec<TimedEvent> = out.into_iter().flatten().collect();
            assert_eq!(flattened, sequence.programs_at(tick), "at tick {tick}");
        }
    }

    #[test]
    fn the_last_program_before_the_tick_is_the_one_that_applies() {
        // The backwards scan has to find the *last* program change at or
        // before the tick, not the first: a channel that changes sound twice
        // before the seek point must arrive on the second sound.
        let sequence = Sequence::new(
            vec![
                TimedEvent::new(
                    0,
                    0,
                    EventKind::Program {
                        bank: 0,
                        program: 1,
                    },
                ),
                TimedEvent::new(
                    500,
                    0,
                    EventKind::Program {
                        bank: 0,
                        program: 2,
                    },
                ),
                TimedEvent::new(
                    900,
                    0,
                    EventKind::Program {
                        bank: 0,
                        program: 3,
                    },
                ),
            ],
            960,
            1920,
        );
        let mut out: [Option<TimedEvent>; 16] = [None; 16];
        sequence.programs_at_into(950, &mut out);
        assert!(matches!(
            out[0].unwrap().kind,
            EventKind::Program { program: 3, .. }
        ));
        // Exactly on a change, that change applies.
        sequence.programs_at_into(500, &mut out);
        assert!(matches!(
            out[0].unwrap().kind,
            EventKind::Program { program: 2, .. }
        ));
        // Before any change, nothing does.
        let empty = Sequence::new(Vec::new(), 960, 1920);
        empty.programs_at_into(500, &mut out);
        assert!(out.iter().all(Option::is_none));
    }

    #[test]
    fn duration_follows_the_tempo_map() {
        let sequence = Sequence::new(Vec::new(), 960, 1920);
        let map = TempoMap::constant(960, 120.0).unwrap();
        // Two quarter notes at 120 bpm is one second.
        assert!((sequence.duration_seconds(&map) - 1.0).abs() < 1e-9);
    }
}
