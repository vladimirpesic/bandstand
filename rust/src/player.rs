//! The play-along source: a decoded file under the transport's playhead.
//!
//! The play-along recordings put the bass in one channel and the piano in
//! the other, so the core feature is a **2×2 channel-gain matrix** — hear
//! both sides, or isolate one onto both speakers — and a matrix move must
//! never click: every coefficient is a [`Smoothed`] ramp, exactly like the
//! master gain.
//!
//! ## One clock, no drift
//!
//! The player keeps no position of its own. Every audio block, the transport
//! splits into [`BlockSegment`]s and the player reads the file at whatever
//! position the segment's ticks say (through the tempo map's
//! `tick → seconds` mapping, then `seconds × source rate`). Seek, loop wrap,
//! play, pause and a device reopen therefore cannot drift out of sync with the
//! playhead the UI reads — they are the same number.
//!
//! ## The file timeline
//!
//! A track is loaded under [`file_timeline`]: a constant tempo map where one
//! tick is one millisecond. Milliseconds are what a track's length, a scrub
//! and a loop region are naturally expressed in, and every transport control
//! — seek, loop, play — drives the file unchanged.
//!
//! ## Reading
//!
//! Positions land between source frames, so pairs are read with linear
//! interpolation; that also resamples, and a 44.1 kHz track plays on a 48 kHz
//! device with no separate resampler. Past the last frame the player reads
//! silence — when to stop is the caller's decision, and the playhead running
//! on must never read garbage.

use std::sync::Arc;

use bandstand_transport::{BlockSegment, TempoMap, DEFAULT_PPQ};

use crate::decode::DecodedTrack;
use crate::tone::Smoothed;

/// Ticks per second on the file timeline: one tick is one millisecond.
pub const FILE_TICKS_PER_SECOND: f64 = 1000.0;

/// Time constant for channel-gain glides — the same glide the master gain
/// uses, so a matrix move and a level move take off together.
const MIX_GLIDE_MS: f64 = 15.0;

/// The 2×2 channel-gain matrix, row-major by *output*: `[left←left,
/// left←right, right←left, right←right]`. Each entry is a linear gain in
/// `0.0..=1.0`.
pub type ChannelMix = [f32; 4];

/// Both sides of the recording, as recorded.
pub const MIX_BOTH: ChannelMix = [1.0, 0.0, 0.0, 1.0];

/// Only the left side of the recording, on both speakers.
///
/// The engine itself is told raw gains from Dart; the preset is kept here,
/// exercised by the tests, as the definition of what "isolate left" means.
#[allow(dead_code)]
pub const MIX_LEFT: ChannelMix = [1.0, 0.0, 1.0, 0.0];

/// Only the right side of the recording, on both speakers.
///
/// The engine itself is told raw gains from Dart; the preset is kept here,
/// exercised by the tests, as the definition of what "isolate right" means.
#[allow(dead_code)]
pub const MIX_RIGHT: ChannelMix = [0.0, 1.0, 0.0, 1.0];

/// The constant tempo map under which a track's ticks are its milliseconds.
///
/// With the transport's default resolution (960 ppq) this is a steady 62.5
/// bpm — a file has no tempo to show, so the map is an implementation detail
/// of the tick↔time conversion, never a musical claim.
#[must_use]
pub fn file_timeline() -> TempoMap {
    #[allow(clippy::cast_precision_loss)]
    let bpm = FILE_TICKS_PER_SECOND * 60.0 / f64::from(DEFAULT_PPQ);
    TempoMap::constant(DEFAULT_PPQ, bpm).expect("a constant 62.5 bpm map is always valid")
}

/// The file player: what the transport's playhead is standing on.
#[derive(Debug)]
pub struct TrackPlayer {
    track: Option<Arc<DecodedTrack>>,
    mix: [Smoothed; 4],
}

impl TrackPlayer {
    /// Create an empty player — nothing loaded, both channels passing through.
    ///
    /// # Panics
    /// Panics if `sample_rate` is not positive (see [`Smoothed::new`]).
    #[must_use]
    pub fn new(sample_rate: f64) -> Self {
        Self {
            track: None,
            mix: MIX_BOTH.map(|gain| Smoothed::new(gain, sample_rate, MIX_GLIDE_MS)),
        }
    }

    /// Reconfigure for a new sample rate. Call when a stream is opening.
    ///
    /// # Panics
    /// Panics if `sample_rate` is not positive (see [`Smoothed::set_ramp_time`]).
    pub fn set_sample_rate(&mut self, sample_rate: f64) {
        for gain in &mut self.mix {
            gain.set_ramp_time(sample_rate, MIX_GLIDE_MS);
        }
    }

    /// Make `track` the thing the transport plays.
    pub fn load(&mut self, track: Arc<DecodedTrack>) {
        self.track = Some(track);
    }

    /// Play nothing. The matrix is left as it is: an unload is not a mix move.
    pub fn unload(&mut self) {
        self.track = None;
    }

    /// Whether a track is loaded.
    ///
    /// The render path needs no such check (mixing nothing is a no-op); the
    /// tests use it to prove unload took.
    #[allow(dead_code)]
    #[must_use]
    pub fn is_loaded(&self) -> bool {
        self.track.is_some()
    }

    /// Aim the channel-gain matrix at a new setting. Each coefficient ramps,
    /// so an isolation move is click-free.
    pub fn set_mix(&mut self, mix: ChannelMix) {
        for (gain, target) in self.mix.iter_mut().zip(mix) {
            gain.set_target(target.clamp(0.0, 1.0));
        }
    }

    /// Mix one transport segment of the loaded track into `output`.
    ///
    /// `timeline` is the audio side's tempo map; it converts the segment's
    /// tick bounds to seconds, and thereby to positions in the file. A
    /// zero-length segment — the transport not playing — mixes nothing at
    /// all, and with no track loaded this is a no-op.
    pub fn mix_segment(
        &mut self,
        output: &mut [f32],
        channels: usize,
        segment: &BlockSegment,
        timeline: &TempoMap,
    ) {
        if channels == 0 || segment.frame_count == 0 {
            return;
        }
        if segment.start_tick == segment.end_tick {
            // Time is not passing: the bus stays silent, not frozen mid-note.
            return;
        }
        let Some(track) = self.track.as_ref() else {
            return;
        };
        let rate = f64::from(track.sample_rate());
        let start = timeline.seconds_at_tick(segment.start_tick) * rate;
        let end = timeline.seconds_at_tick(segment.end_tick) * rate;
        #[allow(clippy::cast_precision_loss)]
        let step = (end - start) / segment.frame_count as f64;

        let first = segment.frame_offset * channels;
        let block = &mut output[first..first + segment.frame_count * channels];
        let mut position = start;
        for frame in block.chunks_mut(channels) {
            let (left, right) = track.read_pair(position);
            position += step;
            let from_left_left = self.mix[0].next_value();
            let from_right_left = self.mix[1].next_value();
            let from_left_right = self.mix[2].next_value();
            let from_right_right = self.mix[3].next_value();
            let out_left = from_left_left * left + from_right_left * right;
            let out_right = from_left_right * left + from_right_right * right;
            write_frame(frame, out_left, out_right);
        }
    }
}

/// Add one mixed frame to an output frame of any channel count.
///
/// A stereo device gets the two sides; a mono device gets their mid (a mono
/// bus cannot carry isolation, and one side alone would lose whatever the
/// other held); further channels of a surround device get the mid as well,
/// the same every-channel-something convention the test tone mixes by.
fn write_frame(frame: &mut [f32], left: f32, right: f32) {
    let mid = (left + right) * 0.5;
    match frame.len() {
        0 => {}
        1 => frame[0] += mid,
        _ => {
            frame[0] += left;
            frame[1] += right;
            for slot in &mut frame[2..] {
                *slot += mid;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use bandstand_transport::{Transport, TransportHandle};

    const DEVICE_RATE: f64 = 48_000.0;

    /// A track whose left side climbs and whose right side mirrors it, so a
    /// swapped or isolated channel is visible at a glance.
    fn ramp_track(frames: usize, rate: u32) -> Arc<DecodedTrack> {
        let mut samples = Vec::with_capacity(frames * 2);
        for i in 0..frames {
            #[allow(clippy::cast_precision_loss)]
            let value = i as f32 * 0.001;
            samples.push(value);
            samples.push(-value);
        }
        Arc::new(DecodedTrack::from_interleaved_stereo(samples, rate))
    }

    fn constant_track(left: f32, right: f32, frames: usize, rate: u32) -> Arc<DecodedTrack> {
        let mut samples = Vec::with_capacity(frames * 2);
        for _ in 0..frames {
            samples.push(left);
            samples.push(right);
        }
        Arc::new(DecodedTrack::from_interleaved_stereo(samples, rate))
    }

    fn file_transport() -> (Transport, TransportHandle) {
        let (mut transport, handle) = Transport::new(file_timeline());
        transport.set_sample_rate(DEVICE_RATE);
        (transport, handle)
    }

    /// Render one block through the player exactly as the engine's renderer
    /// would: advance, then mix every segment.
    fn render(player: &mut TrackPlayer, transport: &mut Transport, frames: usize) -> Vec<f32> {
        let mut output = vec![0.0f32; frames * 2];
        let segments = transport.advance(frames, 0);
        for segment in segments.iter() {
            player.mix_segment(&mut output, 2, segment, transport.tempo_map());
        }
        output
    }

    #[test]
    fn the_file_timeline_makes_ticks_milliseconds() {
        let map = file_timeline();
        assert!((map.seconds_at_tick(1000.0) - 1.0).abs() < 1e-9);
        assert!((map.tick_at_seconds(1.0) - 1000.0).abs() < 1e-6);
    }

    #[test]
    fn passes_a_track_through_the_identity_mix() {
        let track = ramp_track(480, 48_000);
        let mut player = TrackPlayer::new(DEVICE_RATE);
        player.load(Arc::clone(&track));
        let (mut transport, handle) = file_transport();
        handle.play();
        let output = render(&mut player, &mut transport, 480);
        for i in 0..480 {
            #[allow(clippy::cast_precision_loss)]
            let expected = i as f32 * 0.001;
            assert!(
                (output[i * 2] - expected).abs() < 1e-5
                    && (output[i * 2 + 1] + expected).abs() < 1e-5,
                "frame {i}: {} / {}",
                output[i * 2],
                output[i * 2 + 1]
            );
        }
    }

    #[test]
    fn isolating_a_channel_puts_it_on_both_sides() {
        let mut player = TrackPlayer::new(DEVICE_RATE);
        player.load(constant_track(0.1, 0.3, 48_000, 48_000));
        let (mut transport, handle) = file_transport();
        handle.play();
        // Let the matrix glide settle (15 ms at 48 kHz).
        let _ = render(&mut player, &mut transport, 960);
        player.set_mix(MIX_RIGHT);
        let _ = render(&mut player, &mut transport, 960);
        let output = render(&mut player, &mut transport, 10);
        for sample in output {
            assert!((sample - 0.3).abs() < 1e-3, "{sample}");
        }
    }

    #[test]
    fn a_mix_change_ramps_rather_than_steps() {
        let mut player = TrackPlayer::new(DEVICE_RATE);
        player.load(constant_track(0.1, 0.9, 960, 48_000));
        let (mut transport, handle) = file_transport();
        handle.play();
        let _ = render(&mut player, &mut transport, 960);
        player.set_mix(MIX_RIGHT);
        let output = render(&mut player, &mut transport, 100);
        // The left output moves from 0.1 towards 0.9: after a hundredth of
        // the glide it must be nowhere near arrived, and strictly on its way.
        let first = output[0];
        assert!(first < 0.15, "{first}");
        for pair in output.windows(2) {
            assert!(
                pair[1] >= pair[0],
                "not monotonic: {} → {}",
                pair[0],
                pair[1]
            );
        }
        assert!(output[99] < 0.2, "{}", output[99]);
    }

    #[test]
    fn resamples_when_the_track_rate_differs_from_the_device() {
        let track = Arc::new(DecodedTrack::from_interleaved_stereo(
            vec![0.0, 0.0, 1.0, -1.0, 2.0, -2.0],
            24_000,
        ));
        let mut player = TrackPlayer::new(DEVICE_RATE);
        player.load(Arc::clone(&track));
        let (mut transport, handle) = file_transport();
        handle.play();
        // Three device frames are 1.5 source frames at 24 kHz: the middle
        // one lands halfway between the first two source frames.
        let output = render(&mut player, &mut transport, 3);
        assert!((output[0] - 0.0).abs() < 1e-6 && (output[1] - 0.0).abs() < 1e-6);
        assert!((output[2] - 0.5).abs() < 1e-6 && (output[3] + 0.5).abs() < 1e-6);
        assert!((output[4] - 1.0).abs() < 1e-6 && (output[5] + 1.0).abs() < 1e-6);
    }

    #[test]
    fn reads_silence_past_the_end_of_the_track() {
        let track = ramp_track(10, 48_000);
        let mut player = TrackPlayer::new(DEVICE_RATE);
        player.load(Arc::clone(&track));
        let (mut transport, handle) = file_transport();
        handle.play();
        let output = render(&mut player, &mut transport, 20);
        for i in 0..10 {
            #[allow(clippy::cast_precision_loss)]
            let expected = i as f32 * 0.001;
            assert!((output[i * 2] - expected).abs() < 1e-5);
        }
        for sample in &output[20..] {
            assert!(sample.abs() < f32::EPSILON, "{sample}");
        }
    }

    #[test]
    fn an_unloaded_player_mixes_nothing() {
        let mut player = TrackPlayer::new(DEVICE_RATE);
        player.load(ramp_track(480, 48_000));
        player.unload();
        let (mut transport, handle) = file_transport();
        handle.play();
        let output = render(&mut player, &mut transport, 480);
        assert!(output.iter().all(|sample| sample.abs() < f32::EPSILON));
        assert!(!player.is_loaded());
    }

    #[test]
    fn a_mono_device_hears_the_mid_side() {
        let mut player = TrackPlayer::new(DEVICE_RATE);
        player.load(constant_track(0.2, 0.6, 480, 48_000));
        let (mut transport, handle) = file_transport();
        handle.play();
        let mut output = vec![0.0f32; 480];
        let segments = transport.advance(480, 0);
        for segment in segments.iter() {
            player.mix_segment(&mut output, 1, segment, transport.tempo_map());
        }
        for sample in output {
            assert!((sample - 0.4).abs() < 1e-3, "{sample}");
        }
    }
}
