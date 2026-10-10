//! The loop region, published from the UI thread to the audio thread.

use std::sync::atomic::{fence, AtomicU64, Ordering};

/// A loop span in ticks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct LoopRegion {
    /// First tick of the loop.
    pub start_tick: u64,
    /// Tick the playhead wraps at (exclusive).
    pub end_tick: u64,
    /// Whether wrapping is armed.
    pub enabled: bool,
}

impl LoopRegion {
    /// Whether this region can actually wrap a playhead.
    #[must_use]
    pub const fn is_active(&self) -> bool {
        self.enabled && self.end_tick > self.start_tick
    }
}

/// Seqlock cell holding a [`LoopRegion`], written by the UI thread and read
/// once per block by the audio thread.
///
/// The same protocol as [`crate::PositionCell`], with the roles reversed: here
/// the *reader* is the audio thread, so the read path is the one that must not
/// block. It cannot: the writer holds the cell torn for a handful of
/// instructions, and the reader gives up after a bounded number of retries and
/// keeps using the value it last read successfully.
#[derive(Debug)]
pub struct LoopCell {
    seq: AtomicU64,
    start_tick: AtomicU64,
    end_tick: AtomicU64,
    enabled: AtomicU64,
}

const MAX_READ_RETRIES: u32 = 8;

impl LoopCell {
    /// A disabled, empty loop region.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            seq: AtomicU64::new(0),
            start_tick: AtomicU64::new(0),
            end_tick: AtomicU64::new(0),
            enabled: AtomicU64::new(0),
        }
    }

    /// Publish a region. UI-thread side.
    pub fn store(&self, region: LoopRegion) {
        let seq = self.seq.load(Ordering::Relaxed);
        self.seq.store(seq.wrapping_add(1), Ordering::Relaxed);
        fence(Ordering::Release);

        self.start_tick.store(region.start_tick, Ordering::Relaxed);
        self.end_tick.store(region.end_tick, Ordering::Relaxed);
        self.enabled
            .store(u64::from(region.enabled), Ordering::Relaxed);

        fence(Ordering::Release);
        self.seq.store(seq.wrapping_add(2), Ordering::Relaxed);
    }

    /// Read a coherent region, or `None` if the cell was torn on every attempt.
    #[must_use]
    pub fn load(&self) -> Option<LoopRegion> {
        for _ in 0..MAX_READ_RETRIES {
            let before = self.seq.load(Ordering::Relaxed);
            if before % 2 != 0 {
                std::hint::spin_loop();
                continue;
            }
            fence(Ordering::Acquire);

            let region = LoopRegion {
                start_tick: self.start_tick.load(Ordering::Relaxed),
                end_tick: self.end_tick.load(Ordering::Relaxed),
                enabled: self.enabled.load(Ordering::Relaxed) != 0,
            };

            fence(Ordering::Acquire);
            if self.seq.load(Ordering::Relaxed) == before {
                return Some(region);
            }
            std::hint::spin_loop();
        }
        None
    }
}

impl Default for LoopCell {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips() {
        let cell = LoopCell::new();
        let region = LoopRegion {
            start_tick: 960,
            end_tick: 8640,
            enabled: true,
        };
        cell.store(region);
        assert_eq!(cell.load().unwrap(), region);
        assert!(region.is_active());
    }

    #[test]
    fn empty_or_inverted_regions_are_inactive() {
        assert!(!LoopRegion {
            start_tick: 100,
            end_tick: 100,
            enabled: true
        }
        .is_active());
        assert!(!LoopRegion {
            start_tick: 200,
            end_tick: 100,
            enabled: true
        }
        .is_active());
        assert!(!LoopRegion {
            start_tick: 0,
            end_tick: 100,
            enabled: false
        }
        .is_active());
    }
}
