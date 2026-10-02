//! The playhead: audio-thread advance, UI-thread control.
//!
//! Rules: `docs/rules/transport-clock.md` §3 and §5.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use crate::{
    LoopCell, LoopRegion, PlayState, PositionCell, PositionSnapshot, TempoMap, TempoMapSlot,
};

/// Most times one audio block can be split by loop wraps.
pub const MAX_BLOCK_SEGMENTS: usize = 8;

/// A run of frames within one audio block over which time advances linearly and
/// without a discontinuity.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct BlockSegment {
    /// Offset of this run from the start of the block, in frames.
    pub frame_offset: usize,
    /// Length of this run, in frames.
    pub frame_count: usize,
    /// Tick at `frame_offset`.
    pub start_tick: f64,
    /// Tick at `frame_offset + frame_count`. Equal to `start_tick` when the
    /// transport is not playing.
    pub end_tick: f64,
    /// Whether the playhead wrapped to the loop start immediately *after* this
    /// run.
    pub wraps_after: bool,
}

/// The segments an audio block was split into. Fixed capacity, so
/// [`Transport::advance`] never allocates.
#[derive(Debug, Clone, Copy)]
pub struct BlockSegments {
    segments: [BlockSegment; MAX_BLOCK_SEGMENTS],
    len: usize,
}

impl BlockSegments {
    const fn empty() -> Self {
        const BLANK: BlockSegment = BlockSegment {
            frame_offset: 0,
            frame_count: 0,
            start_tick: 0.0,
            end_tick: 0.0,
            wraps_after: false,
        };
        Self {
            segments: [BLANK; MAX_BLOCK_SEGMENTS],
            len: 0,
        }
    }

    fn push(&mut self, segment: BlockSegment) {
        debug_assert!(self.len < MAX_BLOCK_SEGMENTS);
        self.segments[self.len] = segment;
        self.len += 1;
    }

    /// The segments, in playback order.
    #[must_use]
    pub fn as_slice(&self) -> &[BlockSegment] {
        &self.segments[..self.len]
    }

    /// How many segments the block was split into.
    #[must_use]
    pub const fn len(&self) -> usize {
        self.len
    }

    /// Whether the block produced no segments at all (a zero-frame block).
    #[must_use]
    pub const fn is_empty(&self) -> bool {
        self.len == 0
    }
}

impl BlockSegments {
    /// Iterate the segments, in playback order.
    pub fn iter(&self) -> std::slice::Iter<'_, BlockSegment> {
        self.as_slice().iter()
    }
}

impl<'a> IntoIterator for &'a BlockSegments {
    type Item = &'a BlockSegment;
    type IntoIter = std::slice::Iter<'a, BlockSegment>;

    fn into_iter(self) -> Self::IntoIter {
        self.as_slice().iter()
    }
}

/// State shared between the UI thread and the audio thread.
///
/// Every field is either an atomic or a lock-free cell; nothing here blocks.
#[derive(Debug)]
pub struct TransportShared {
    position: PositionCell,
    loop_region: LoopCell,
    tempo_slot: TempoMapSlot,
    /// Requested [`PlayState`], as bits.
    requested_state: AtomicU64,
    /// Bits of the requested seek target, in ticks.
    seek_tick_bits: AtomicU64,
    /// Bumped on every seek request so the audio thread applies each exactly once.
    seek_seq: AtomicU64,
    /// The `seek_seq` the audio thread has actually applied.
    ///
    /// Published so that a seek outlives the [`Transport`] that would have
    /// applied it. A seek requested while no stream is open — the player
    /// scrubbing the playhead before pressing play — bumps `seek_seq` without
    /// touching `position`, so a new audio side that trusted `seek_seq` alone
    /// would start from the stale published tick and then skip the seek as
    /// already seen. It is the *applied* sequence number that a new audio side
    /// must resume from.
    applied_seek_seq: AtomicU64,
    /// Sample rate the audio thread is running at, as `f64` bits. Zero until a
    /// stream is open.
    sample_rate_bits: AtomicU64,
}

impl TransportShared {
    /// Create shared state parked at tick 0, stopped, with no loop.
    #[must_use]
    pub fn new() -> Self {
        Self {
            position: PositionCell::new(),
            loop_region: LoopCell::new(),
            tempo_slot: TempoMapSlot::new(),
            requested_state: AtomicU64::new(PlayState::Stopped.to_bits()),
            seek_tick_bits: AtomicU64::new(0),
            seek_seq: AtomicU64::new(0),
            applied_seek_seq: AtomicU64::new(0),
            sample_rate_bits: AtomicU64::new(0),
        }
    }
}

impl Default for TransportShared {
    fn default() -> Self {
        Self::new()
    }
}

/// UI-thread handle to the transport.
///
/// Cloneable and `Send + Sync`; every method is a handful of atomic stores.
#[derive(Debug, Clone)]
pub struct TransportHandle {
    shared: Arc<TransportShared>,
    /// The map most recently published, kept so the UI can answer tempo
    /// questions without touching the audio thread's copy.
    tempo_map: Arc<TempoMap>,
}

impl TransportHandle {
    /// Create a handle with no audio side attached yet.
    ///
    /// The audio side is created per stream with [`Self::create_audio_side`],
    /// so an engine that opens, closes and reopens streams keeps one handle —
    /// and one playhead — for its whole life.
    #[must_use]
    pub fn new(tempo_map: TempoMap) -> Self {
        Self {
            shared: Arc::new(TransportShared::new()),
            tempo_map: Arc::new(tempo_map),
        }
    }

    /// Read the latest published playhead position.
    ///
    /// Returns the default snapshot if the cell was torn on every retry, which
    /// in practice does not happen.
    #[must_use]
    pub fn position(&self) -> PositionSnapshot {
        self.shared.position.read().unwrap_or_default()
    }

    /// Start playing from the current position.
    pub fn play(&self) {
        self.shared
            .requested_state
            .store(PlayState::Playing.to_bits(), Ordering::Release);
    }

    /// Stop advancing, holding the playhead where it is.
    pub fn pause(&self) {
        self.shared
            .requested_state
            .store(PlayState::Paused.to_bits(), Ordering::Release);
    }

    /// Stop and return to the stop anchor (loop start when looping, else tick 0).
    pub fn stop(&self) {
        self.shared
            .requested_state
            .store(PlayState::Stopped.to_bits(), Ordering::Release);
    }

    /// Move the playhead to `tick`. Applied at the top of the next audio block.
    pub fn seek(&self, tick: f64) {
        let tick = if tick.is_finite() { tick.max(0.0) } else { 0.0 };
        self.shared
            .seek_tick_bits
            .store(tick.to_bits(), Ordering::Relaxed);
        self.shared.seek_seq.fetch_add(1, Ordering::Release);
    }

    /// Set the loop region.
    pub fn set_loop(&self, region: LoopRegion) {
        self.shared.loop_region.store(region);
    }

    /// The loop region currently published.
    #[must_use]
    pub fn loop_region(&self) -> LoopRegion {
        self.shared.loop_region.load().unwrap_or_default()
    }

    /// Hand a new tempo map to the audio thread.
    pub fn set_tempo_map(&mut self, map: TempoMap) {
        let map = Arc::new(map);
        self.tempo_map = Arc::clone(&map);
        self.shared.tempo_slot.publish(map);
    }

    /// The tempo map most recently published from this handle.
    #[must_use]
    pub fn tempo_map(&self) -> &Arc<TempoMap> {
        &self.tempo_map
    }

    /// Sample rate of the open audio stream, or `None` if no stream is open.
    #[must_use]
    pub fn sample_rate(&self) -> Option<f64> {
        let bits = self.shared.sample_rate_bits.load(Ordering::Acquire);
        let rate = f64::from_bits(bits);
        (rate > 0.0).then_some(rate)
    }

    /// Build the audio-thread side bound to this handle's shared state.
    ///
    /// A stream that is opened, closed and reopened needs a fresh [`Transport`]
    /// each time, but the handle the UI holds — and the position, loop region
    /// and tempo map it has published — must survive. Call this once per
    /// stream, and drop the previous [`Transport`] before calling it again:
    /// two live transports would fight over one playhead.
    #[must_use]
    pub fn create_audio_side(&self) -> Transport {
        // One snapshot: three separate reads could mix fields from different
        // publishes.
        let position = self.position();
        Transport {
            shared: Arc::clone(&self.shared),
            tempo_map: Arc::clone(&self.tempo_map),
            sample_rate: 0.0,
            tick: position.tick,
            state: position.state,
            // The *applied* sequence number, not the requested one: a seek
            // that arrived while the stream was closed has bumped `seek_seq`
            // but nothing has acted on it, and starting from `seek_seq` here
            // would mark it seen and discard it.
            last_seek_seq: self.shared.applied_seek_seq.load(Ordering::Acquire),
            loop_generation: position.loop_generation,
            loop_region: self.loop_region(),
        }
    }
}

/// Audio-thread side of the transport.
///
/// Owned by the audio callback. Not `Clone`: there is exactly one.
#[derive(Debug)]
pub struct Transport {
    shared: Arc<TransportShared>,
    tempo_map: Arc<TempoMap>,
    sample_rate: f64,
    tick: f64,
    state: PlayState,
    last_seek_seq: u64,
    loop_generation: u32,
    loop_region: LoopRegion,
}

impl Transport {
    /// Create a transport and its UI-side handle.
    #[must_use]
    pub fn new(tempo_map: TempoMap) -> (Self, TransportHandle) {
        let handle = TransportHandle::new(tempo_map);
        let transport = handle.create_audio_side();
        (transport, handle)
    }

    /// Tell the transport what sample rate the stream runs at.
    ///
    /// Called when a stream opens, before the first block.
    ///
    /// # Panics
    /// Panics if `sample_rate` is not finite and positive. A backend that
    /// reports a nonsensical rate is a bug worth failing loudly on, before it
    /// becomes a silently wrong playhead.
    pub fn set_sample_rate(&mut self, sample_rate: f64) {
        assert!(
            sample_rate.is_finite() && sample_rate > 0.0,
            "sample rate must be positive and finite"
        );
        self.sample_rate = sample_rate;
        self.shared
            .sample_rate_bits
            .store(sample_rate.to_bits(), Ordering::Release);
    }

    /// The tempo map the audio thread is currently using.
    #[must_use]
    pub fn tempo_map(&self) -> &TempoMap {
        &self.tempo_map
    }

    /// Current playhead, in ticks.
    #[must_use]
    pub const fn tick(&self) -> f64 {
        self.tick
    }

    /// Current play state.
    #[must_use]
    pub const fn state(&self) -> PlayState {
        self.state
    }

    /// Advance the playhead over one audio block and publish the position.
    ///
    /// `host_time_ns` is when the first frame of this block will be heard.
    /// Returns the segments the block was split into; a caller that does not
    /// care about loop wraps can ignore them.
    ///
    /// Allocation-free, lock-free and wait-free.
    pub fn advance(&mut self, frames: usize, host_time_ns: u64) -> BlockSegments {
        self.pick_up_new_tempo_map();
        self.apply_requested_state();
        self.apply_requested_seek();
        if let Some(region) = self.shared.loop_region.load() {
            self.loop_region = region;
        }

        // A playing playhead must never sit at or past the end of an active
        // loop: a block that ran out of wrap segments, a seek that landed on
        // the end, or a loop enabled while the playhead was past it would
        // otherwise strand it outside the loop for the rest of playback.
        #[allow(clippy::cast_precision_loss)]
        if self.state == PlayState::Playing && self.loop_region.is_active() {
            let loop_end = self.loop_region.end_tick as f64;
            if self.tick >= loop_end {
                self.tick = self.loop_region.start_tick as f64;
                self.loop_generation = self.loop_generation.wrapping_add(1);
            }
        }

        let block_start_tick = self.tick;
        let block_start_generation = self.loop_generation;
        let segments = self.split_block(frames);

        self.shared.position.publish(PositionSnapshot {
            tick: block_start_tick,
            host_time_ns,
            state: self.state,
            loop_generation: block_start_generation,
        });

        segments
    }

    fn pick_up_new_tempo_map(&mut self) {
        if let Some(map) = self.shared.tempo_slot.take() {
            let previous = std::mem::replace(&mut self.tempo_map, map);
            self.shared.tempo_slot.retire(previous);
        }
    }

    fn apply_requested_state(&mut self) {
        let requested = PlayState::from_bits(self.shared.requested_state.load(Ordering::Acquire));
        if requested == self.state {
            return;
        }
        if requested == PlayState::Stopped {
            #[allow(clippy::cast_precision_loss)]
            let anchor = if self.loop_region.is_active() {
                self.loop_region.start_tick as f64
            } else {
                0.0
            };
            self.tick = anchor;
        }
        self.state = requested;
    }

    fn apply_requested_seek(&mut self) {
        // `seek()` stores the tick and then bumps the sequence number, so the
        // tick must be read first and the sequence number with Acquire, and
        // the tick re-read: if it changed, a seek landed between the loads
        // and the pair is not coherent. Reading the sequence number first
        // could instead consume a new sequence number with the previous
        // tick, applying the same seek twice and snapping the playhead back.
        loop {
            let tick_bits = self.shared.seek_tick_bits.load(Ordering::Relaxed);
            let seq = self.shared.seek_seq.load(Ordering::Acquire);
            if self.shared.seek_tick_bits.load(Ordering::Relaxed) != tick_bits {
                continue;
            }
            if seq == self.last_seek_seq {
                return;
            }
            self.last_seek_seq = seq;
            // Published so a stream that is closed and reopened does not
            // re-apply this seek, and so one that arrives while no stream is
            // open is not mistaken for one already applied.
            self.shared.applied_seek_seq.store(seq, Ordering::Release);
            self.tick = f64::from_bits(tick_bits).max(0.0);
            return;
        }
    }

    fn split_block(&mut self, frames: usize) -> BlockSegments {
        let mut segments = BlockSegments::empty();
        if frames == 0 {
            return segments;
        }
        if self.state != PlayState::Playing || self.sample_rate <= 0.0 {
            segments.push(BlockSegment {
                frame_offset: 0,
                frame_count: frames,
                start_tick: self.tick,
                end_tick: self.tick,
                wraps_after: false,
            });
            return segments;
        }

        let mut offset = 0usize;
        let mut remaining = frames;

        while remaining > 0 {
            #[allow(clippy::cast_precision_loss)]
            let seconds_available = remaining as f64 / self.sample_rate;
            let current_seconds = self.tempo_map.seconds_at_tick(self.tick);
            let loop_active = self.loop_region.is_active();
            #[allow(clippy::cast_precision_loss)]
            let loop_end = self.loop_region.end_tick as f64;

            if loop_active && segments.len() + 1 < MAX_BLOCK_SEGMENTS && self.tick < loop_end {
                let seconds_to_wrap = self.tempo_map.seconds_at_tick(loop_end) - current_seconds;
                if seconds_to_wrap <= seconds_available {
                    #[allow(
                        clippy::cast_possible_truncation,
                        clippy::cast_sign_loss,
                        clippy::cast_precision_loss
                    )]
                    let wrap_frames = ((seconds_to_wrap * self.sample_rate).floor().max(0.0)
                        as usize)
                        .min(remaining);
                    segments.push(BlockSegment {
                        frame_offset: offset,
                        frame_count: wrap_frames,
                        start_tick: self.tick,
                        end_tick: loop_end,
                        wraps_after: true,
                    });
                    offset += wrap_frames;
                    remaining -= wrap_frames;
                    #[allow(clippy::cast_precision_loss)]
                    {
                        self.tick = self.loop_region.start_tick as f64;
                    }
                    self.loop_generation = self.loop_generation.wrapping_add(1);
                    continue;
                }
            }

            let end_seconds = current_seconds + seconds_available;
            let mut end_tick = self.tempo_map.tick_at_seconds(end_seconds);

            if loop_active && end_tick > loop_end {
                // The wrap budget is spent but the block still reaches past
                // the loop end: fold the excess back into the loop so the
                // playhead ends the block inside it and the next block wraps
                // again, instead of abandoning the loop for good.
                #[allow(clippy::cast_precision_loss)]
                let loop_start = self.loop_region.start_tick as f64;
                let loop_end_seconds = self.tempo_map.seconds_at_tick(loop_end);
                let loop_seconds = loop_end_seconds - self.tempo_map.seconds_at_tick(loop_start);
                if loop_seconds > 0.0 {
                    let mut folded = end_seconds;
                    while folded > loop_end_seconds {
                        folded -= loop_seconds;
                        self.loop_generation = self.loop_generation.wrapping_add(1);
                    }
                    end_tick = self.tempo_map.tick_at_seconds(folded).min(loop_end);
                } else {
                    // A loop with no duration in time: park at the end; the
                    // next block's wrap pulls the playhead back to the start.
                    end_tick = loop_end;
                }
            }

            segments.push(BlockSegment {
                frame_offset: offset,
                frame_count: remaining,
                start_tick: self.tick,
                end_tick,
                wraps_after: false,
            });
            self.tick = end_tick;
            offset += remaining;
            remaining = 0;
        }

        segments
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::TempoChange;

    const SR: f64 = 48_000.0;

    fn transport_at(bpm: f64) -> (Transport, TransportHandle) {
        let (mut transport, handle) = Transport::new(TempoMap::constant(960, bpm).unwrap());
        transport.set_sample_rate(SR);
        (transport, handle)
    }

    #[test]
    fn stopped_transport_does_not_advance() {
        let (mut transport, _handle) = transport_at(120.0);
        let segments = transport.advance(512, 0);
        assert_eq!(segments.len(), 1);
        assert!((transport.tick() - 0.0).abs() < f64::EPSILON);
        assert!((segments.as_slice()[0].end_tick - 0.0).abs() < f64::EPSILON);
    }

    #[test]
    fn playing_advances_by_the_right_number_of_ticks() {
        let (mut transport, handle) = transport_at(120.0);
        handle.play();
        // 24 000 frames at 48 kHz = 0.5 s = one quarter note at 120 bpm = 960 ticks.
        transport.advance(24_000, 0);
        assert!(
            (transport.tick() - 960.0).abs() < 1e-6,
            "{}",
            transport.tick()
        );
    }

    #[test]
    fn many_small_blocks_do_not_drift() {
        let (mut transport, handle) = transport_at(137.0);
        handle.play();
        // Five minutes of 256-frame blocks.
        #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
        let blocks = (SR * 300.0 / 256.0).round() as usize;
        for _ in 0..blocks {
            transport.advance(256, 0);
        }
        #[allow(clippy::cast_precision_loss)]
        let elapsed_seconds = (blocks * 256) as f64 / SR;
        let expected = transport.tempo_map().tick_at_seconds(elapsed_seconds);
        let drift_ticks = (transport.tick() - expected).abs();
        let drift_seconds = drift_ticks * 60.0 / (137.0 * 960.0);
        // Budget from §3: cursor drift under 10 ms over 5 minutes.
        assert!(drift_seconds < 0.010, "drift {drift_seconds} s");
    }

    #[test]
    fn position_is_published_for_the_ui() {
        let (mut transport, handle) = transport_at(120.0);
        handle.play();
        transport.advance(24_000, 111);
        let snapshot = handle.position();
        assert_eq!(snapshot.state, PlayState::Playing);
        assert_eq!(snapshot.host_time_ns, 111);
        // The published tick is the *start* of the block.
        assert!((snapshot.tick - 0.0).abs() < f64::EPSILON);
        transport.advance(24_000, 222);
        assert!((handle.position().tick - 960.0).abs() < 1e-6);
    }

    #[test]
    fn seek_is_applied_once_at_the_next_block() {
        let (mut transport, handle) = transport_at(120.0);
        handle.seek(4800.0);
        transport.advance(64, 0);
        assert!((transport.tick() - 4800.0).abs() < f64::EPSILON);
        handle.play();
        transport.advance(24_000, 0);
        assert!((transport.tick() - 5760.0).abs() < 1e-6);
    }

    #[test]
    fn stop_returns_to_the_anchor() {
        let (mut transport, handle) = transport_at(120.0);
        handle.play();
        transport.advance(24_000, 0);
        handle.stop();
        transport.advance(64, 0);
        assert!((transport.tick() - 0.0).abs() < f64::EPSILON);
        assert_eq!(transport.state(), PlayState::Stopped);
    }

    #[test]
    fn stop_anchors_to_the_loop_start_when_looping() {
        let (mut transport, handle) = transport_at(120.0);
        handle.set_loop(LoopRegion {
            start_tick: 1920,
            end_tick: 5760,
            enabled: true,
        });
        handle.play();
        transport.advance(1024, 0);
        handle.stop();
        transport.advance(64, 0);
        assert!((transport.tick() - 1920.0).abs() < f64::EPSILON);
    }

    #[test]
    fn pause_holds_the_playhead() {
        let (mut transport, handle) = transport_at(120.0);
        handle.play();
        transport.advance(24_000, 0);
        handle.pause();
        transport.advance(24_000, 0);
        assert!((transport.tick() - 960.0).abs() < 1e-6);
        assert_eq!(transport.state(), PlayState::Paused);
    }

    #[test]
    fn block_splits_at_a_loop_wrap() {
        let (mut transport, handle) = transport_at(120.0);
        // Loop one quarter note long: ticks 0..960 = 0.5 s = 24 000 frames.
        handle.set_loop(LoopRegion {
            start_tick: 0,
            end_tick: 960,
            enabled: true,
        });
        handle.play();
        handle.seek(480.0);
        // 0.25 s remaining to the wrap, then 0.25 s after it.
        let segments = transport.advance(24_000, 0);
        assert_eq!(segments.len(), 2);
        let first = segments.as_slice()[0];
        assert_eq!(first.frame_offset, 0);
        assert_eq!(first.frame_count, 12_000);
        assert!(first.wraps_after);
        assert!((first.end_tick - 960.0).abs() < 1e-9);
        let second = segments.as_slice()[1];
        assert_eq!(second.frame_offset, 12_000);
        assert_eq!(second.frame_count, 12_000);
        assert!((second.start_tick - 0.0).abs() < f64::EPSILON);
        assert!((second.end_tick - 480.0).abs() < 1e-6);
    }

    #[test]
    fn loop_generation_increments_on_every_wrap() {
        let (mut transport, handle) = transport_at(240.0);
        handle.set_loop(LoopRegion {
            start_tick: 0,
            end_tick: 240,
            enabled: true,
        });
        handle.play();
        // At 240 bpm, 240 ticks = 0.0625 s = 3000 frames. A 12 000-frame block
        // therefore wraps four times.
        let segments = transport.advance(12_000, 0);
        let wraps = segments.into_iter().filter(|s| s.wraps_after).count();
        assert_eq!(wraps, 4);
        assert_eq!(
            segments
                .as_slice()
                .iter()
                .map(|s| s.frame_count)
                .sum::<usize>(),
            12_000
        );
    }

    #[test]
    fn a_loop_shorter_than_a_block_is_bounded() {
        let (mut transport, handle) = transport_at(400.0);
        // One tick long: far shorter than any audio block.
        handle.set_loop(LoopRegion {
            start_tick: 0,
            end_tick: 1,
            enabled: true,
        });
        handle.play();
        for block in 0..4 {
            let segments = transport.advance(4096, 0);
            assert!(segments.len() <= MAX_BLOCK_SEGMENTS);
            assert_eq!(
                segments
                    .as_slice()
                    .iter()
                    .map(|s| s.frame_count)
                    .sum::<usize>(),
                4096
            );
            // The wrap budget cannot express this loop, but the playhead must
            // end every block back inside it, never stranded outside forever.
            assert!(
                transport.tick() < 1.0,
                "block {block} left the playhead at {} outside the loop",
                transport.tick()
            );
        }
    }

    #[test]
    fn a_seek_landing_on_the_loop_end_stays_in_the_loop() {
        let (mut transport, handle) = transport_at(120.0);
        handle.set_loop(LoopRegion {
            start_tick: 0,
            end_tick: 960,
            enabled: true,
        });
        handle.play();
        transport.advance(64, 0);
        handle.seek(960.0);
        transport.advance(24_000, 0);
        assert!(
            transport.tick() < 960.0,
            "a seek on the loop end escaped the loop: {}",
            transport.tick()
        );
    }

    #[test]
    fn a_loop_enabled_past_its_end_pulls_the_playhead_back() {
        let (mut transport, handle) = transport_at(120.0);
        handle.play();
        transport.advance(24_000, 0);
        assert!((transport.tick() - 960.0).abs() < 1e-6);
        handle.set_loop(LoopRegion {
            start_tick: 0,
            end_tick: 960,
            enabled: true,
        });
        transport.advance(64, 0);
        assert!(
            transport.tick() < 960.0,
            "enabling a loop past its end left the playhead outside it: {}",
            transport.tick()
        );
    }

    #[test]
    fn hammering_seeks_never_leaves_the_published_set() {
        use std::sync::atomic::AtomicBool;

        // A 24 000-frame block is exactly 960 ticks at 120 bpm.
        const BLOCK_TICKS: f64 = 960.0;
        // The seeker only ever publishes these two targets.
        const TARGETS: [f64; 2] = [4800.0, 9600.0];

        let (mut transport, handle) = transport_at(120.0);
        handle.play();
        handle.seek(TARGETS[0]);
        transport.advance(24_000, 0);
        assert!((transport.tick() - (TARGETS[0] + BLOCK_TICKS)).abs() < 1e-6);

        let stop = Arc::new(AtomicBool::new(false));
        let seeker = {
            let handle = handle.clone();
            let stop = Arc::clone(&stop);
            std::thread::spawn(move || {
                let mut i = 0u64;
                while !stop.load(Ordering::Relaxed) {
                    handle.seek(TARGETS[usize::try_from(i % 2).unwrap()]);
                    i += 1;
                }
            })
        };

        let mut previous = transport.tick();
        for _ in 0..100_000 {
            transport.advance(24_000, 0);
            let tick = transport.tick();
            let applied = tick - BLOCK_TICKS;
            assert!(
                (tick - previous - BLOCK_TICKS).abs() < 1e-6
                    || TARGETS
                        .iter()
                        .any(|&target| (applied - target).abs() < 1e-6),
                "block ended at {tick}, which matches no published seek"
            );
            previous = tick;
        }
        stop.store(true, Ordering::Relaxed);
        seeker.join().unwrap();

        // After the storm, an ordinary seek still applies exactly once.
        handle.seek(TARGETS[0]);
        transport.advance(24_000, 0);
        assert!(
            (transport.tick() - (TARGETS[0] + BLOCK_TICKS)).abs() < 1e-6,
            "a calm seek after the hammering landed at {}",
            transport.tick()
        );
    }

    #[test]
    fn tempo_map_swap_takes_effect_on_the_audio_thread() {
        let (mut transport, mut handle) = transport_at(120.0);
        handle.play();
        transport.advance(24_000, 0);
        assert!((transport.tick() - 960.0).abs() < 1e-6);

        handle.set_tempo_map(TempoMap::new(960, &[TempoChange::new(0, 240.0)]).unwrap());
        transport.advance(24_000, 0);
        // At 240 bpm, 0.5 s is two quarter notes.
        assert!(
            (transport.tick() - 2880.0).abs() < 1e-6,
            "{}",
            transport.tick()
        );
    }

    #[test]
    fn sample_rate_is_visible_to_the_ui() {
        let (transport, handle) = transport_at(120.0);
        assert_eq!(handle.sample_rate(), Some(SR));
        drop(transport);
    }

    #[test]
    fn a_reopened_stream_resumes_where_the_handle_left_off() {
        let (mut transport, handle) = transport_at(120.0);
        handle.play();
        transport.advance(24_000, 0);
        transport.advance(24_000, 0);
        let before = handle.position().tick;
        drop(transport);

        let mut reopened = handle.create_audio_side();
        reopened.set_sample_rate(SR);
        assert!((reopened.tick() - before).abs() < 1e-6);
        assert_eq!(reopened.state(), PlayState::Playing);
        reopened.advance(24_000, 0);
        assert!((reopened.tick() - (before + 960.0)).abs() < 1e-6);
    }

    #[test]
    fn a_seek_requested_while_no_stream_is_open_is_applied_when_one_opens() {
        // The player scrubs the playhead before pressing play. `seek()` bumps
        // the sequence number but publishes no position, so an audio side that
        // started from `seek_seq` took the stale tick and then skipped the
        // seek as already seen — the playhead never moved.
        let (mut transport, handle) = transport_at(120.0);
        transport.set_sample_rate(SR);
        drop(transport);

        handle.seek(5000.0);
        let mut reopened = handle.create_audio_side();
        reopened.set_sample_rate(SR);
        reopened.advance(480, 0);
        assert!(
            (reopened.tick() - 5000.0).abs() < 1e-6,
            "the seek was dropped"
        );
    }

    #[test]
    fn a_seek_already_applied_is_not_applied_again_on_reopen() {
        // The other half: a seek the previous audio side consumed must not be
        // replayed by the next one, or a reopened stream would snap backwards
        // to wherever the last seek pointed.
        let (mut transport, handle) = transport_at(120.0);
        transport.set_sample_rate(SR);
        handle.seek(1920.0);
        handle.play();
        // Twice, so the published block-start tick is past the seek target and
        // "resumed where the handle left off" is distinguishable from "applied
        // the old seek again".
        transport.advance(24_000, 0);
        transport.advance(24_000, 0);
        let before = handle.position().tick;
        assert!(
            before > 1920.0,
            "the seek should have been applied and then advanced past"
        );
        drop(transport);

        let mut reopened = handle.create_audio_side();
        reopened.set_sample_rate(SR);
        reopened.advance(0, 0);
        assert!(
            (reopened.tick() - before).abs() < 1e-6,
            "a consumed seek was replayed: {before} became {}",
            reopened.tick()
        );
    }

    #[test]
    fn zero_frame_block_is_a_no_op() {
        let (mut transport, handle) = transport_at(120.0);
        handle.play();
        let segments = transport.advance(0, 0);
        assert!(segments.is_empty());
        assert!((transport.tick() - 0.0).abs() < f64::EPSILON);
    }
}
