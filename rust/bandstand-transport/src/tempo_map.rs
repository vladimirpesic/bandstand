//! Tempo map: tick <-> seconds conversion across tempo changes.
//!
//! Rules: `docs/rules/transport-clock.md` §2.

use std::fmt;

/// Lowest tempo the model accepts, in beats per minute.
pub const MIN_BPM: f64 = 10.0;
/// Highest tempo the model accepts, in beats per minute.
pub const MAX_BPM: f64 = 400.0;
/// Default pulses-per-quarter-note resolution (see `docs/rules/transport-clock.md` §1).
pub const DEFAULT_PPQ: u32 = 960;

/// A tempo marker: from `tick` onwards, the tempo is `bpm`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TempoChange {
    /// Position of the marker, in ticks.
    pub tick: u64,
    /// Tempo in beats (quarter notes) per minute.
    pub bpm: f64,
}

impl TempoChange {
    /// Construct a tempo change.
    #[must_use]
    pub const fn new(tick: u64, bpm: f64) -> Self {
        Self { tick, bpm }
    }
}

/// Why a tempo map could not be built.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TempoMapError {
    /// The change list was empty.
    Empty,
    /// A tempo value was not finite, or outside `[MIN_BPM, MAX_BPM]`.
    BpmOutOfRange {
        /// Index of the offending change in the input list.
        index: usize,
    },
    /// The change list was not sorted by ascending tick.
    NotSorted {
        /// Index of the first change whose tick went backwards.
        index: usize,
    },
    /// `ppq` was zero.
    ZeroPpq,
}

impl fmt::Display for TempoMapError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Empty => write!(f, "tempo map needs at least one tempo change"),
            Self::BpmOutOfRange { index } => write!(
                f,
                "tempo change {index} is not a finite bpm in [{MIN_BPM}, {MAX_BPM}]"
            ),
            Self::NotSorted { index } => {
                write!(f, "tempo change {index} goes backwards in time")
            }
            Self::ZeroPpq => write!(f, "ppq must be greater than zero"),
        }
    }
}

impl std::error::Error for TempoMapError {}

/// One constant-tempo span of the timeline.
#[derive(Debug, Clone, Copy)]
struct Segment {
    start_tick: f64,
    start_seconds: f64,
    /// Seconds per tick within this segment.
    seconds_per_tick: f64,
    bpm: f64,
}

/// An immutable tempo map.
///
/// Built once on the control thread and handed to the audio thread whole; all
/// lookups are a binary search plus one multiply, with no allocation.
#[derive(Debug, Clone)]
pub struct TempoMap {
    ppq: u32,
    segments: Vec<Segment>,
}

impl TempoMap {
    /// Build a map from an ascending list of tempo changes.
    ///
    /// A change at tick 0 is synthesised from the first entry if absent, and
    /// entries sharing a tick collapse to the last one in list order.
    ///
    /// # Errors
    /// Returns [`TempoMapError`] if the list is empty, unsorted, contains a bpm
    /// outside `[MIN_BPM, MAX_BPM]`, or `ppq` is zero.
    pub fn new(ppq: u32, changes: &[TempoChange]) -> Result<Self, TempoMapError> {
        if ppq == 0 {
            return Err(TempoMapError::ZeroPpq);
        }
        if changes.is_empty() {
            return Err(TempoMapError::Empty);
        }
        for (index, change) in changes.iter().enumerate() {
            if !change.bpm.is_finite() || change.bpm < MIN_BPM || change.bpm > MAX_BPM {
                return Err(TempoMapError::BpmOutOfRange { index });
            }
            if index > 0 && change.tick < changes[index - 1].tick {
                return Err(TempoMapError::NotSorted { index });
            }
        }

        let ppq_f = f64::from(ppq);
        let mut segments: Vec<Segment> = Vec::with_capacity(changes.len() + 1);

        for change in changes {
            let tick = if segments.is_empty() { 0 } else { change.tick };
            #[allow(clippy::cast_precision_loss)]
            let tick_f = tick as f64;
            let seconds_per_tick = 60.0 / (change.bpm * ppq_f);

            // Collapse changes that land on the same tick: the later one wins.
            if let Some(last) = segments.last_mut() {
                if (last.start_tick - tick_f).abs() < f64::EPSILON {
                    last.seconds_per_tick = seconds_per_tick;
                    last.bpm = change.bpm;
                    continue;
                }
            }

            let start_seconds = segments.last().map_or(0.0, |last| {
                last.start_seconds + (tick_f - last.start_tick) * last.seconds_per_tick
            });
            segments.push(Segment {
                start_tick: tick_f,
                start_seconds,
                seconds_per_tick,
                bpm: change.bpm,
            });
        }

        Ok(Self { ppq, segments })
    }

    /// A map with a single constant tempo.
    ///
    /// # Errors
    /// Returns [`TempoMapError`] if `bpm` is out of range or `ppq` is zero.
    pub fn constant(ppq: u32, bpm: f64) -> Result<Self, TempoMapError> {
        Self::new(ppq, &[TempoChange::new(0, bpm)])
    }

    /// Ticks per quarter note.
    #[must_use]
    pub const fn ppq(&self) -> u32 {
        self.ppq
    }

    /// Tempo changes as `(tick, bpm)` pairs, in ascending tick order.
    #[must_use]
    pub fn changes(&self) -> Vec<TempoChange> {
        self.segments
            .iter()
            .map(|s| {
                #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
                TempoChange::new(s.start_tick as u64, s.bpm)
            })
            .collect()
    }

    fn segment_at_tick(&self, tick: f64) -> &Segment {
        let mut lo = 0usize;
        let mut hi = self.segments.len();
        while lo + 1 < hi {
            let mid = lo + (hi - lo) / 2;
            if self.segments[mid].start_tick <= tick {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        &self.segments[lo]
    }

    fn segment_at_seconds(&self, seconds: f64) -> &Segment {
        let mut lo = 0usize;
        let mut hi = self.segments.len();
        while lo + 1 < hi {
            let mid = lo + (hi - lo) / 2;
            if self.segments[mid].start_seconds <= seconds {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        &self.segments[lo]
    }

    /// Tempo in effect at `tick`.
    #[must_use]
    pub fn bpm_at_tick(&self, tick: f64) -> f64 {
        self.segment_at_tick(tick.max(0.0)).bpm
    }

    /// Seconds elapsed from tick 0 to `tick`.
    #[must_use]
    pub fn seconds_at_tick(&self, tick: f64) -> f64 {
        let tick = tick.max(0.0);
        let seg = self.segment_at_tick(tick);
        seg.start_seconds + (tick - seg.start_tick) * seg.seconds_per_tick
    }

    /// Inverse of [`Self::seconds_at_tick`].
    #[must_use]
    pub fn tick_at_seconds(&self, seconds: f64) -> f64 {
        let seconds = seconds.max(0.0);
        let seg = self.segment_at_seconds(seconds);
        seg.start_tick + (seconds - seg.start_seconds) / seg.seconds_per_tick
    }

    /// Ticks per nanosecond at `tick` — what the UI needs to extrapolate the
    /// cursor between position publications.
    #[must_use]
    pub fn ticks_per_nanosecond_at(&self, tick: f64) -> f64 {
        1.0 / (self.segment_at_tick(tick.max(0.0)).seconds_per_tick * 1.0e9)
    }
}

impl Default for TempoMap {
    fn default() -> Self {
        Self::constant(DEFAULT_PPQ, 120.0).expect("120 bpm at the default ppq is always valid")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn approx(a: f64, b: f64) {
        assert!((a - b).abs() < 1e-9, "{a} != {b}");
    }

    #[test]
    fn constant_tempo_converts_both_ways() {
        let map = TempoMap::constant(960, 120.0).unwrap();
        // 120 bpm: one quarter note = 0.5 s, so 960 ticks = 0.5 s.
        approx(map.seconds_at_tick(960.0), 0.5);
        approx(map.seconds_at_tick(0.0), 0.0);
        approx(map.tick_at_seconds(0.5), 960.0);
        approx(map.tick_at_seconds(2.0), 3840.0);
    }

    #[test]
    fn tempo_change_shifts_later_positions() {
        let map = TempoMap::new(
            960,
            &[TempoChange::new(0, 120.0), TempoChange::new(1920, 60.0)],
        )
        .unwrap();
        // Two quarter notes at 120 bpm = 1.0 s.
        approx(map.seconds_at_tick(1920.0), 1.0);
        // Then one quarter note at 60 bpm = 1.0 s more.
        approx(map.seconds_at_tick(2880.0), 2.0);
        approx(map.tick_at_seconds(2.0), 2880.0);
        approx(map.bpm_at_tick(1919.0), 120.0);
        approx(map.bpm_at_tick(1920.0), 60.0);
    }

    #[test]
    fn round_trips_through_seconds_at_many_points() {
        let map = TempoMap::new(
            480,
            &[
                TempoChange::new(0, 92.0),
                TempoChange::new(1000, 180.0),
                TempoChange::new(5000, 63.5),
                TempoChange::new(20_000, 240.0),
            ],
        )
        .unwrap();
        for tick in (0..40_000).step_by(37) {
            let t = f64::from(tick);
            approx(map.tick_at_seconds(map.seconds_at_tick(t)), t);
        }
    }

    #[test]
    fn first_change_is_pinned_to_tick_zero() {
        let map = TempoMap::new(960, &[TempoChange::new(4800, 90.0)]).unwrap();
        approx(map.bpm_at_tick(0.0), 90.0);
        approx(map.seconds_at_tick(0.0), 0.0);
    }

    #[test]
    fn duplicate_ticks_collapse_to_the_later_change() {
        let map = TempoMap::new(
            960,
            &[
                TempoChange::new(0, 120.0),
                TempoChange::new(960, 100.0),
                TempoChange::new(960, 200.0),
            ],
        )
        .unwrap();
        approx(map.bpm_at_tick(960.0), 200.0);
        assert_eq!(map.changes().len(), 2);
    }

    #[test]
    fn negative_positions_clamp_to_zero() {
        let map = TempoMap::constant(960, 120.0).unwrap();
        approx(map.seconds_at_tick(-5.0), 0.0);
        approx(map.tick_at_seconds(-5.0), 0.0);
    }

    #[test]
    fn rejects_bad_input() {
        assert_eq!(TempoMap::new(960, &[]).unwrap_err(), TempoMapError::Empty);
        assert_eq!(
            TempoMap::new(0, &[TempoChange::new(0, 120.0)]).unwrap_err(),
            TempoMapError::ZeroPpq
        );
        assert_eq!(
            TempoMap::new(960, &[TempoChange::new(0, f64::NAN)]).unwrap_err(),
            TempoMapError::BpmOutOfRange { index: 0 }
        );
        assert_eq!(
            TempoMap::new(960, &[TempoChange::new(0, 1000.0)]).unwrap_err(),
            TempoMapError::BpmOutOfRange { index: 0 }
        );
        assert_eq!(
            TempoMap::new(
                960,
                &[TempoChange::new(100, 120.0), TempoChange::new(50, 120.0)]
            )
            .unwrap_err(),
            TempoMapError::NotSorted { index: 1 }
        );
    }

    #[test]
    fn ticks_per_nanosecond_matches_seconds_per_tick() {
        let map = TempoMap::constant(960, 120.0).unwrap();
        let tpn = map.ticks_per_nanosecond_at(0.0);
        // 0.5 s per 960 ticks => 1920 ticks per second => 1.92e-6 ticks per ns.
        approx(tpn, 1.92e-6);
    }
}
