//! Handing a new [`TempoMap`] from the UI thread to the audio thread without
//! allocating, locking or deallocating on the audio thread.
//!
//! Rules: `docs/rules/transport-clock.md` §5.
//!
//! The UI thread parks an `Arc<TempoMap>` in `pending`. The audio thread takes
//! it at the top of a block and hands its previous map back through `retired`.
//! The UI thread drops retired maps on its next publish, so no deallocation
//! ever happens on the audio thread.

use std::ptr;
use std::sync::atomic::{AtomicPtr, Ordering};
use std::sync::Arc;

use crate::TempoMap;

/// Number of retire slots. The audio thread only ever retires one map per
/// publish, and the UI thread drains all slots on every publish, so one slot
/// suffices; the extra slots exist so that a burst of publishes interleaved
/// with block boundaries can never force the audio thread to deallocate.
const RETIRE_SLOTS: usize = 4;

/// Lock-free single-producer / single-consumer handoff for the tempo map.
#[derive(Debug)]
pub struct TempoMapSlot {
    pending: AtomicPtr<TempoMap>,
    retired: [AtomicPtr<TempoMap>; RETIRE_SLOTS],
}

impl TempoMapSlot {
    /// An empty slot.
    #[must_use]
    pub fn new() -> Self {
        Self {
            pending: AtomicPtr::new(ptr::null_mut()),
            retired: std::array::from_fn(|_| AtomicPtr::new(ptr::null_mut())),
        }
    }

    /// Park `map` for the audio thread, and reclaim anything it handed back.
    ///
    /// UI-thread side. Allocates and deallocates freely.
    pub fn publish(&self, map: Arc<TempoMap>) {
        self.reclaim();
        let raw = Arc::into_raw(map).cast_mut();
        let previous = self.pending.swap(raw, Ordering::AcqRel);
        if !previous.is_null() {
            // The audio thread never saw it; drop it here.
            // SAFETY: `previous` came from `Arc::into_raw` in this function and
            // has been swapped out, so no other party can observe it.
            drop(unsafe { Arc::from_raw(previous.cast_const()) });
        }
    }

    /// Drop every map the audio thread has handed back. UI-thread side.
    pub fn reclaim(&self) {
        for slot in &self.retired {
            let raw = slot.swap(ptr::null_mut(), Ordering::AcqRel);
            if !raw.is_null() {
                // SAFETY: the pointer was produced by `Arc::into_raw` in
                // `retire` and has been swapped out exactly once.
                drop(unsafe { Arc::from_raw(raw.cast_const()) });
            }
        }
    }

    /// Take a newly published map, if any. Audio-thread side; wait-free.
    #[must_use]
    pub fn take(&self) -> Option<Arc<TempoMap>> {
        let raw = self.pending.swap(ptr::null_mut(), Ordering::AcqRel);
        if raw.is_null() {
            None
        } else {
            // SAFETY: the pointer was produced by `Arc::into_raw` in `publish`
            // and has been swapped out exactly once.
            Some(unsafe { Arc::from_raw(raw.cast_const()) })
        }
    }

    /// Hand a map back to the UI thread for disposal. Audio-thread side.
    ///
    /// If every retire slot is occupied — which requires the UI thread to have
    /// stalled for several tempo changes — the map is dropped here instead.
    /// That is a bounded, extremely rare deallocation, and it is preferable to
    /// leaking.
    pub fn retire(&self, map: Arc<TempoMap>) {
        let mut raw = Arc::into_raw(map).cast_mut();
        for slot in &self.retired {
            raw = slot.swap(raw, Ordering::AcqRel);
            if raw.is_null() {
                return;
            }
        }
        // SAFETY: `raw` is a pointer from `Arc::into_raw` that we own.
        drop(unsafe { Arc::from_raw(raw.cast_const()) });
    }
}

impl Default for TempoMapSlot {
    fn default() -> Self {
        Self::new()
    }
}

impl Drop for TempoMapSlot {
    fn drop(&mut self) {
        if let Some(map) = self.take() {
            drop(map);
        }
        self.reclaim();
    }
}

// SAFETY: the raw pointers are always `Arc<TempoMap>` values transferred by
// atomic swap, and `TempoMap` is `Send + Sync`.
unsafe impl Send for TempoMapSlot {}
// SAFETY: see above; every access goes through atomics.
unsafe impl Sync for TempoMapSlot {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn publishes_and_takes_once() {
        let slot = TempoMapSlot::new();
        assert!(slot.take().is_none());
        slot.publish(Arc::new(TempoMap::constant(960, 140.0).unwrap()));
        let taken = slot.take().expect("published map");
        assert!((taken.bpm_at_tick(0.0) - 140.0).abs() < f64::EPSILON);
        assert!(slot.take().is_none());
    }

    #[test]
    fn superseded_publish_drops_the_older_map() {
        let slot = TempoMapSlot::new();
        let first = Arc::new(TempoMap::constant(960, 100.0).unwrap());
        let watch = Arc::clone(&first);
        slot.publish(first);
        slot.publish(Arc::new(TempoMap::constant(960, 200.0).unwrap()));
        // Only `watch` should remain alive.
        assert_eq!(Arc::strong_count(&watch), 1);
        let taken = slot.take().unwrap();
        assert!((taken.bpm_at_tick(0.0) - 200.0).abs() < f64::EPSILON);
    }

    #[test]
    fn retired_maps_are_freed_by_the_publisher() {
        let slot = TempoMapSlot::new();
        let map = Arc::new(TempoMap::constant(960, 90.0).unwrap());
        let watch = Arc::clone(&map);
        slot.retire(map);
        assert_eq!(Arc::strong_count(&watch), 2);
        slot.reclaim();
        assert_eq!(Arc::strong_count(&watch), 1);
    }

    #[test]
    fn retiring_beyond_capacity_drops_the_oldest() {
        let slot = TempoMapSlot::new();
        let mut watches = Vec::new();
        for bpm in 0..RETIRE_SLOTS + 2 {
            #[allow(clippy::cast_precision_loss)]
            let map = Arc::new(TempoMap::constant(960, 60.0 + bpm as f64).unwrap());
            watches.push(Arc::clone(&map));
            slot.retire(map);
        }
        // The two oldest were dropped on the spot.
        assert_eq!(Arc::strong_count(&watches[0]), 1);
        assert_eq!(Arc::strong_count(&watches[1]), 1);
        assert_eq!(Arc::strong_count(&watches[2]), 2);
        slot.reclaim();
        for watch in &watches {
            assert_eq!(Arc::strong_count(watch), 1);
        }
    }
}
