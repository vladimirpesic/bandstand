//! Lock-free `(tick, host_time)` publication from the audio thread.
//!
//! Rules: `docs/rules/transport-clock.md` §4.

use std::sync::atomic::{fence, AtomicU64, Ordering};

/// How many times a reader retries a torn read before giving up and reporting
/// the last value it managed to read coherently.
const MAX_READ_RETRIES: u32 = 16;

/// What the transport is doing, as published to readers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PlayState {
    /// Not playing; playhead parked at the stop anchor.
    Stopped,
    /// Not playing; playhead held where it was.
    Paused,
    /// Playing.
    Playing,
}

impl PlayState {
    pub(crate) const fn to_bits(self) -> u64 {
        match self {
            Self::Stopped => 0,
            Self::Paused => 1,
            Self::Playing => 2,
        }
    }

    pub(crate) const fn from_bits(bits: u64) -> Self {
        match bits {
            2 => Self::Playing,
            1 => Self::Paused,
            _ => Self::Stopped,
        }
    }
}

/// A coherent snapshot of the playhead.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PositionSnapshot {
    /// Playhead in ticks at the moment `host_time_ns` was taken.
    pub tick: f64,
    /// Value of [`crate::monotonic_now_ns`] when the audio thread published.
    pub host_time_ns: u64,
    /// Transport state at publication time.
    pub state: PlayState,
    /// Increments on every loop wrap; lets a consumer detect that the playhead
    /// jumped backwards deliberately rather than by a seek.
    pub loop_generation: u32,
}

impl Default for PositionSnapshot {
    fn default() -> Self {
        Self {
            tick: 0.0,
            host_time_ns: 0,
            state: PlayState::Stopped,
            loop_generation: 0,
        }
    }
}

/// Seqlock-protected position cell.
///
/// Exactly one writer (the audio thread); any number of readers. The writer is
/// wait-free: it never spins, never allocates and never blocks.
#[derive(Debug)]
pub struct PositionCell {
    seq: AtomicU64,
    tick_bits: AtomicU64,
    host_time_ns: AtomicU64,
    /// `state` in the low 8 bits, `loop_generation` in bits 32..64.
    flags: AtomicU64,
}

impl PositionCell {
    /// A cell parked at tick 0, stopped.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            seq: AtomicU64::new(0),
            tick_bits: AtomicU64::new(0),
            host_time_ns: AtomicU64::new(0),
            flags: AtomicU64::new(0),
        }
    }

    /// Publish a snapshot. Audio-thread side; wait-free.
    pub fn publish(&self, snapshot: PositionSnapshot) {
        let seq = self.seq.load(Ordering::Relaxed);
        self.seq.store(seq.wrapping_add(1), Ordering::Relaxed);
        fence(Ordering::Release);

        self.tick_bits
            .store(snapshot.tick.to_bits(), Ordering::Relaxed);
        self.host_time_ns
            .store(snapshot.host_time_ns, Ordering::Relaxed);
        self.flags.store(
            snapshot.state.to_bits() | (u64::from(snapshot.loop_generation) << 32),
            Ordering::Relaxed,
        );

        fence(Ordering::Release);
        self.seq.store(seq.wrapping_add(2), Ordering::Relaxed);
    }

    /// Read a coherent snapshot, or `None` if the writer kept the cell torn for
    /// [`MAX_READ_RETRIES`] attempts (in practice: never).
    #[must_use]
    pub fn read(&self) -> Option<PositionSnapshot> {
        for _ in 0..MAX_READ_RETRIES {
            let before = self.seq.load(Ordering::Relaxed);
            if before % 2 != 0 {
                std::hint::spin_loop();
                continue;
            }
            fence(Ordering::Acquire);

            let tick = f64::from_bits(self.tick_bits.load(Ordering::Relaxed));
            let host_time_ns = self.host_time_ns.load(Ordering::Relaxed);
            let flags = self.flags.load(Ordering::Relaxed);

            fence(Ordering::Acquire);
            if self.seq.load(Ordering::Relaxed) == before {
                #[allow(clippy::cast_possible_truncation)]
                return Some(PositionSnapshot {
                    tick,
                    host_time_ns,
                    state: PlayState::from_bits(flags & 0xFF),
                    loop_generation: (flags >> 32) as u32,
                });
            }
            std::hint::spin_loop();
        }
        None
    }
}

impl Default for PositionCell {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicBool;
    use std::sync::Arc;

    #[test]
    fn round_trips_a_snapshot() {
        let cell = PositionCell::new();
        let snapshot = PositionSnapshot {
            tick: 1234.5,
            host_time_ns: 987_654_321,
            state: PlayState::Playing,
            loop_generation: 7,
        };
        cell.publish(snapshot);
        assert_eq!(cell.read().unwrap(), snapshot);
    }

    #[test]
    fn fresh_cell_reads_as_stopped_at_zero() {
        let cell = PositionCell::new();
        assert_eq!(cell.read().unwrap(), PositionSnapshot::default());
    }

    #[test]
    fn concurrent_reads_are_never_torn() {
        let cell = Arc::new(PositionCell::new());
        let stop = Arc::new(AtomicBool::new(false));

        let writer = {
            let cell = Arc::clone(&cell);
            let stop = Arc::clone(&stop);
            std::thread::spawn(move || {
                for i in 0..200_000u64 {
                    #[allow(clippy::cast_precision_loss)]
                    cell.publish(PositionSnapshot {
                        tick: i as f64,
                        host_time_ns: i * 1000,
                        state: PlayState::Playing,
                        #[allow(clippy::cast_possible_truncation)]
                        loop_generation: i as u32,
                    });
                }
                stop.store(true, Ordering::Release);
            })
        };

        let mut reads = 0u64;
        while !stop.load(Ordering::Acquire) {
            if let Some(s) = cell.read() {
                #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
                let i = s.tick as u64;
                assert_eq!(s.host_time_ns, i * 1000, "torn tick/host_time pair");
                #[allow(clippy::cast_possible_truncation)]
                let gen_expected = i as u32;
                assert_eq!(s.loop_generation, gen_expected, "torn tick/flags pair");
                reads += 1;
            }
        }
        writer.join().unwrap();
        assert!(reads > 0, "reader never observed a snapshot");
    }
}
