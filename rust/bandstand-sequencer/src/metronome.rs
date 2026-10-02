//! The metronome and the count-in.
//!
//! §7.3: *"Count-in and metronome as scheduled events, not a special case."*
//! So they are — this builds the events, and from there they are ordinary
//! sequence entries that loop, seek and mix like any other.

use bandstand_transport::TempoMap;

use crate::event::TimedEvent;

/// The General MIDI percussion channel.
pub const DRUM_CHANNEL: u8 = 9;

/// A side stick, for the beats that are not the downbeat.
pub const CLICK_KEY: u8 = 37;

/// A cowbell, for the downbeat.
pub const ACCENT_KEY: u8 = 56;

/// How a click track is built.
#[derive(Debug, Clone, Copy)]
pub struct MetronomeSpec {
    /// Beats to a bar.
    pub beats_per_bar: u32,
    /// How long one beat is, in quarter notes. A quarter is 1.0.
    pub beat_in_quarters: f64,
    /// How hard the downbeat is hit.
    pub accent_velocity: u8,
    /// How hard the other beats are hit.
    pub click_velocity: u8,
}

impl MetronomeSpec {
    /// Four beats to a bar, a quarter note each.
    #[must_use]
    pub const fn four_four() -> Self {
        Self {
            beats_per_bar: 4,
            beat_in_quarters: 1.0,
            accent_velocity: 110,
            click_velocity: 80,
        }
    }

    /// How long one beat is, in ticks.
    #[must_use]
    pub fn beat_ticks(&self, ppq: u32) -> u64 {
        #[allow(
            clippy::cast_possible_truncation,
            clippy::cast_sign_loss,
            clippy::cast_precision_loss
        )]
        {
            (self.beat_in_quarters * f64::from(ppq)).round().max(1.0) as u64
        }
    }
}

/// Click events for `bars` bars, starting at `start_tick`.
///
/// Each click is a note on immediately followed by a note off a sixteenth
/// later, so nothing is left hanging when the sequence loops.
#[must_use]
pub fn click_track(spec: MetronomeSpec, ppq: u32, start_tick: u64, bars: u32) -> Vec<TimedEvent> {
    let beat = spec.beat_ticks(ppq);
    let length = (beat / 4).max(1);
    // In u64 throughout: `bars * beats_per_bar` overflows u32 long before the
    // vec itself becomes unbuildable, and the per-click tick must stay exact
    // for any track that does fit.
    let beats = u64::from(bars) * u64::from(spec.beats_per_bar);
    let mut events = Vec::new();
    // The reservation is an optimisation only; cap it so an absurd request
    // fails by allocation, not by an arithmetic overflow.
    if let Ok(reserve) = usize::try_from(beats.saturating_mul(2)) {
        events.reserve(reserve.min(1 << 20));
    }
    for bar in 0..bars {
        for index in 0..spec.beats_per_bar {
            let tick = start_tick
                + (u64::from(bar) * u64::from(spec.beats_per_bar) + u64::from(index)) * beat;
            let (key, velocity) = if index == 0 {
                (ACCENT_KEY, spec.accent_velocity)
            } else {
                (CLICK_KEY, spec.click_velocity)
            };
            events.push(TimedEvent::note_on(tick, DRUM_CHANNEL, key, velocity));
            events.push(TimedEvent::note_off(tick + length, DRUM_CHANNEL, key));
        }
    }
    events
}

/// How many ticks a count-in of `bars` takes.
#[must_use]
pub fn count_in_ticks(spec: MetronomeSpec, ppq: u32, bars: u32) -> u64 {
    spec.beat_ticks(ppq) * u64::from(spec.beats_per_bar) * u64::from(bars)
}

/// How long a count-in lasts, in seconds, under `tempo_map`.
#[must_use]
pub fn count_in_seconds(spec: MetronomeSpec, ppq: u32, bars: u32, tempo_map: &TempoMap) -> f64 {
    #[allow(clippy::cast_precision_loss)]
    tempo_map.seconds_at_tick(count_in_ticks(spec, ppq, bars) as f64)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::event::EventKind;

    #[test]
    fn a_bar_of_four_four_clicks_four_times() {
        let events = click_track(MetronomeSpec::four_four(), 960, 0, 1);
        let ons: Vec<&TimedEvent> = events
            .iter()
            .filter(|e| matches!(e.kind, EventKind::NoteOn { .. }))
            .collect();
        assert_eq!(ons.len(), 4);
        assert_eq!(
            ons.iter().map(|e| e.tick).collect::<Vec<_>>(),
            vec![0, 960, 1920, 2880]
        );
    }

    #[test]
    fn the_downbeat_is_a_different_sound_and_louder() {
        let events = click_track(MetronomeSpec::four_four(), 960, 0, 1);
        let EventKind::NoteOn { key, velocity } = events[0].kind else {
            panic!("the first event is not a note on");
        };
        assert_eq!(key, ACCENT_KEY);
        let EventKind::NoteOn {
            key: other,
            velocity: quieter,
        } = events[2].kind
        else {
            panic!("the third event is not a note on");
        };
        assert_eq!(other, CLICK_KEY);
        assert!(velocity > quieter);
    }

    #[test]
    fn every_click_is_let_go_so_nothing_hangs_at_a_loop() {
        let events = click_track(MetronomeSpec::four_four(), 960, 0, 4);
        let ons = events
            .iter()
            .filter(|e| matches!(e.kind, EventKind::NoteOn { .. }))
            .count();
        let offs = events
            .iter()
            .filter(|e| matches!(e.kind, EventKind::NoteOff { .. }))
            .count();
        assert_eq!(ons, offs);
        assert_eq!(ons, 16);
    }

    #[test]
    fn clicks_land_on_the_drum_channel() {
        for event in click_track(MetronomeSpec::four_four(), 960, 0, 2) {
            assert_eq!(event.channel, DRUM_CHANNEL);
        }
    }

    #[test]
    fn a_count_in_starts_the_music_after_it() {
        let spec = MetronomeSpec::four_four();
        assert_eq!(count_in_ticks(spec, 960, 1), 3840);
        assert_eq!(count_in_ticks(spec, 960, 2), 7680);
        assert_eq!(count_in_ticks(spec, 480, 1), 1920);
        let map = TempoMap::constant(960, 120.0).unwrap();
        // A bar of 4/4 at 120 bpm is two seconds.
        assert!((count_in_seconds(spec, 960, 1, &map) - 2.0).abs() < 1e-9);
    }

    #[test]
    fn compound_meters_click_where_they_are_felt() {
        // Six eight, felt in two: two dotted-crotchet beats to the bar.
        let spec = MetronomeSpec {
            beats_per_bar: 2,
            beat_in_quarters: 1.5,
            ..MetronomeSpec::four_four()
        };
        assert_eq!(spec.beat_ticks(960), 1440);
        let events = click_track(spec, 960, 0, 1);
        let ticks: Vec<u64> = events
            .iter()
            .filter(|e| matches!(e.kind, EventKind::NoteOn { .. }))
            .map(|e| e.tick)
            .collect();
        assert_eq!(ticks, vec![0, 1440]);
    }

    #[test]
    fn a_click_track_can_start_partway_through() {
        let events = click_track(MetronomeSpec::four_four(), 960, 3840, 1);
        assert_eq!(events[0].tick, 3840);
    }

    #[test]
    fn zero_bars_is_empty_whatever_the_meter_says() {
        // An extreme meter with no bars exercises the capacity arithmetic
        // without materialising anything; it must not overflow the u32
        // multiplication the old code did.
        let spec = MetronomeSpec {
            beats_per_bar: u32::MAX,
            ..MetronomeSpec::four_four()
        };
        assert!(click_track(spec, 960, 0, 0).is_empty());
    }

    #[test]
    fn ticks_past_the_u32_range_stay_exact() {
        // A ppq of 1 000 000 makes every beat a million ticks, so even a
        // short track crosses the 32-bit range; the per-click arithmetic must
        // stay in u64 and stay exact.
        let events = click_track(MetronomeSpec::four_four(), 1_000_000, 0, 2_000);
        assert_eq!(events.len(), 2_000 * 4 * 2);
        // The first click past 2^32 ticks, and the very last one.
        assert_eq!(events[2 * (4 * 1074)].tick, 4_296 * 1_000_000);
        assert_eq!(events[events.len() - 1].tick, 7_999 * 1_000_000 + 250_000);
    }
}
