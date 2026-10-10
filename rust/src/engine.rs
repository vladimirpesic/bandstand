//! The audio engine: the one place where the transport, the test tone, the
//! master gain and the output device meet.
//!
//! This module is deliberately *not* under `crate::api`, so it is not part of
//! the generated bridge surface (§15: keep the FFI surface small). The bridge
//! functions in `crate::api::audio` are thin wrappers over it.
//!
//! ## Why a dedicated engine thread
//!
//! A `cpal::Stream` is not `Send` on every backend, so it cannot be parked in a
//! global and touched from whichever thread Dart happens to call on. Instead a
//! single engine thread owns the stream for its whole life and takes commands
//! over a channel. That also gives Android the long-lived owner it needs for
//! audio-focus handling.
//!
//! ## Where the file player is
//!
//! After the pivot of ADR 0012 the engine renders the reference test tone, the
//! master gain and the file player: a cached file, decoded up front by
//! [`crate::decode`] and read by [`crate::player`] at the position the
//! transport's segments dictate, through the per-channel gain matrix that
//! isolates one side of a play-along track. It is another source mixed in
//! `render`, driven over the same task queue and the same ramped-parameter
//! discipline as everything else.

use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::mpsc::{self, Receiver, RecvError, SyncSender};
use std::sync::{Arc, Mutex, OnceLock};

use bandstand_audio_host::{
    list_output_devices, open_output_stream, AudioRenderer, AudioStream, BlockContext,
    OutputDeviceInfo, StreamContext, StreamOptions,
};
use bandstand_transport::{init_clock, LoopRegion, TempoMap, Transport, TransportHandle};

use crate::decode::DecodedTrack;
use crate::player::{file_timeline, ChannelMix, TrackPlayer, MIX_BOTH};
use crate::tone::{Smoothed, TestTone, DEFAULT_AMPLITUDE, DEFAULT_FREQUENCY_HZ};

/// Time constant for the master-gain glide, in milliseconds.
const GAIN_GLIDE_MS: f64 = 15.0;

/// Test-tone settings, written by the UI and read by the audio thread.
///
/// Three independent atomics: a torn read would at worst pair a new frequency
/// with an old amplitude for one block, and both are ramped, so it is
/// inaudible. Nothing here needs the stronger guarantee a seqlock provides.
#[derive(Debug)]
pub struct ToneControls {
    enabled: AtomicBool,
    frequency_bits: AtomicU32,
    amplitude_bits: AtomicU32,
    dirty: AtomicBool,
}

impl ToneControls {
    fn new() -> Self {
        Self {
            enabled: AtomicBool::new(false),
            frequency_bits: AtomicU32::new(DEFAULT_FREQUENCY_HZ.to_bits()),
            amplitude_bits: AtomicU32::new(DEFAULT_AMPLITUDE.to_bits()),
            dirty: AtomicBool::new(true),
        }
    }

    /// Update the tone from the UI thread.
    pub fn set(&self, enabled: bool, frequency_hz: f32, amplitude: f32) {
        self.frequency_bits
            .store(frequency_hz.to_bits(), Ordering::Relaxed);
        self.amplitude_bits
            .store(amplitude.to_bits(), Ordering::Relaxed);
        self.enabled.store(enabled, Ordering::Relaxed);
        self.dirty.store(true, Ordering::Release);
    }

    /// Frequency in hertz.
    pub fn frequency_hz(&self) -> f32 {
        f32::from_bits(self.frequency_bits.load(Ordering::Relaxed))
    }

    /// Amplitude in linear gain.
    pub fn amplitude(&self) -> f32 {
        f32::from_bits(self.amplitude_bits.load(Ordering::Relaxed))
    }

    /// Apply pending changes to the oscillator. Audio-thread side.
    fn apply(&self, tone: &mut TestTone) {
        if !self.dirty.swap(false, Ordering::Acquire) {
            return;
        }
        tone.set_frequency(self.frequency_hz());
        tone.set_amplitude(if self.enabled.load(Ordering::Relaxed) {
            self.amplitude()
        } else {
            0.0
        });
    }
}

/// Work handed to the audio thread that must not be done on it.
#[derive(Clone)]
enum AudioTask {
    /// Master gain, 0 to 1.
    MasterGain(f32),
    /// Make this decoded track the thing the transport plays.
    LoadTrack(Arc<DecodedTrack>),
    /// Play nothing.
    UnloadTrack,
    /// The channel-gain matrix, row-major by output.
    ChannelMix(ChannelMix),
}

type TaskSender = SyncSender<AudioTask>;
type TaskReceiver = Receiver<AudioTask>;

/// Everything the audio thread needs that outlives any one stream.
///
/// Kept here so that closing a device and opening another does not lose the
/// mix — which, on a stage, is the difference between a hiccup and starting
/// again.
#[derive(Clone)]
struct EngineState {
    master_gain: f32,
    track: Option<Arc<DecodedTrack>>,
    mix: ChannelMix,
}

impl EngineState {
    fn new() -> Self {
        Self {
            master_gain: 0.5,
            track: None,
            mix: MIX_BOTH,
        }
    }

    /// The tasks that put a fresh audio thread into this state.
    fn as_tasks(&self) -> Vec<AudioTask> {
        let mut tasks = Vec::with_capacity(3);
        if let Some(track) = &self.track {
            tasks.push(AudioTask::LoadTrack(Arc::clone(track)));
        }
        tasks.push(AudioTask::ChannelMix(self.mix));
        tasks.push(AudioTask::MasterGain(self.master_gain));
        tasks
    }
}

/// Info about the stream currently open.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StreamInfo {
    /// Device the stream opened on.
    pub device_name: String,
    /// Negotiated sample rate.
    pub sample_rate: u32,
    /// Negotiated channel count.
    pub channels: u16,
    /// Negotiated buffer size in frames, if the backend fixed one.
    pub buffer_frames: Option<u32>,
    /// The device's native sample format.
    pub sample_format: String,
}

/// Live counters for a running stream.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct StreamStats {
    /// Backend errors since the stream opened. Non-zero means audio dropped.
    pub error_count: u64,
    /// Audio blocks rendered.
    pub block_count: u64,
    /// Frames rendered.
    pub frame_count: u64,
}

/// What the audio callback runs.
struct BandstandRenderer {
    transport: Transport,
    tone: TestTone,
    gain: Smoothed,
    player: TrackPlayer,
    controls: Arc<ToneControls>,
    tasks: TaskReceiver,
}

impl BandstandRenderer {
    /// Take whatever has been left for us. Never blocks.
    fn drain_tasks(&mut self) {
        while let Ok(task) = self.tasks.try_recv() {
            match task {
                AudioTask::MasterGain(gain) => self.gain.set_target(gain.clamp(0.0, 1.0)),
                AudioTask::LoadTrack(track) => self.player.load(track),
                AudioTask::UnloadTrack => self.player.unload(),
                AudioTask::ChannelMix(mix) => self.player.set_mix(mix),
            }
        }
    }
}

impl AudioRenderer for BandstandRenderer {
    fn prepare(&mut self, context: &StreamContext) {
        self.transport.set_sample_rate(context.sample_rate);
        self.tone.set_sample_rate(context.sample_rate);
        self.gain.set_ramp_time(context.sample_rate, GAIN_GLIDE_MS);
        self.player.set_sample_rate(context.sample_rate);
        self.drain_tasks();
    }

    fn render(&mut self, output: &mut [f32], context: &BlockContext) {
        self.drain_tasks();

        // Advance the playhead first: everything downstream is positioned
        // against the segments this returns.
        let segments = self.transport.advance(context.frames, context.host_time_ns);

        self.controls.apply(&mut self.tone);
        self.tone.mix_into(output, context.channels);

        // The play-along source, read at the positions the transport dictates.
        for segment in segments.iter() {
            self.player.mix_segment(
                output,
                context.channels,
                segment,
                self.transport.tempo_map(),
            );
        }

        // Master gain, ramped per sample so a step never clicks.
        for frame in output.chunks_mut(context.channels.max(1)) {
            let gain = self.gain.next_value();
            for slot in frame.iter_mut() {
                *slot *= gain;
            }
        }
    }
}

/// The output devices the platform offers, in stable host order.
///
/// # Errors
/// Returns a human-readable message if the platform cannot be queried.
pub fn output_devices() -> Result<Vec<OutputDeviceInfo>, String> {
    list_output_devices().map_err(|e| e.to_string())
}

enum Command {
    Open {
        options: Box<StreamOptions>,
        state: Vec<AudioTask>,
        reply: SyncSender<Result<(StreamInfo, TaskSender), String>>,
    },
    Close {
        reply: SyncSender<()>,
    },
    Stats {
        reply: SyncSender<Option<StreamStats>>,
    },
}

/// The process-wide audio engine.
pub struct AudioEngine {
    commands: SyncSender<Command>,
    transport: Mutex<TransportHandle>,
    tone: Arc<ToneControls>,
    /// Info for the stream currently open, if any.
    current: Mutex<Option<StreamInfo>>,
    /// Where work for the audio thread goes, or `None` with no stream open.
    tasks: Mutex<Option<TaskSender>>,
    /// Everything that outlives a stream.
    state: Mutex<EngineState>,
}

impl AudioEngine {
    fn new() -> Self {
        init_clock();

        // The handle outlives every stream; the audio side is created per
        // stream by `create_audio_side`.
        let handle = TransportHandle::new(TempoMap::default());
        let tone = Arc::new(ToneControls::new());
        let (commands, receiver) = mpsc::sync_channel::<Command>(16);

        {
            let tone = Arc::clone(&tone);
            let handle = handle.clone();
            let spawned = std::thread::Builder::new()
                .name("bandstand-audio-engine".to_owned())
                .spawn(move || engine_thread(&receiver, &handle, &tone));
            if let Err(error) = spawned {
                // The failed spawn dropped the closure — and with it the
                // command receiver — so `commands` below is disconnected and
                // every command fails with "the audio engine thread has
                // stopped". That is an error a caller can report, not a panic
                // across the FFI.
                eprintln!("bandstand: the audio engine thread could not start: {error}");
            }
        }

        Self {
            commands,
            transport: Mutex::new(handle),
            tone,
            current: Mutex::new(None),
            tasks: Mutex::new(None),
            state: Mutex::new(EngineState::new()),
        }
    }

    /// The process-wide engine, created on first use.
    pub fn instance() -> &'static Self {
        static ENGINE: OnceLock<AudioEngine> = OnceLock::new();
        ENGINE.get_or_init(Self::new)
    }

    /// Open (or reopen) the output stream.
    ///
    /// The mix is re-sent to the new audio thread, so changing device does not
    /// lose the sound. Changes posted while the open was in flight are re-posted
    /// after the swap ([`Self::repost_delta`]).
    ///
    /// # Errors
    /// Returns a human-readable message if the device cannot be opened.
    pub fn open(&self, options: StreamOptions) -> Result<StreamInfo, String> {
        let before = self.state.lock().expect("engine state lock").clone();
        let snapshot = before.as_tasks();
        // Detach the old task sender before the swap below: a `post` that
        // lands while the open is in flight would otherwise sit in the dead
        // stream's queue (or bounce off a full one) and be lost. With no
        // sender, `post` keeps the state, which the next open replays.
        *self.tasks.lock().expect("engine state lock") = None;
        let (reply, response) = mpsc::sync_channel(1);
        self.commands
            .send(Command::Open {
                options: Box::new(options),
                state: snapshot,
                reply,
            })
            .map_err(|_| "the audio engine thread has stopped".to_owned())?;
        let result = response
            .recv()
            .map_err(|_| "the audio engine thread did not answer".to_owned())?;
        match result {
            Ok((info, sender)) => {
                *self.current.lock().expect("engine state lock") = Some(info.clone());
                *self.tasks.lock().expect("engine state lock") = Some(sender.clone());
                // A post that landed while the open was in flight changed
                // the state after the snapshot was taken; the new stream
                // replayed the older snapshot, so without this that change
                // would never reach the audio thread (L-RH4).
                self.repost_delta(&before, &sender);
                Ok(info)
            }
            Err(message) => {
                *self.current.lock().expect("engine state lock") = None;
                *self.tasks.lock().expect("engine state lock") = None;
                Err(message)
            }
        }
    }

    /// Close the output stream, if one is open.
    pub fn close(&self) {
        let (reply, response) = mpsc::sync_channel(1);
        if self.commands.send(Command::Close { reply }).is_ok() {
            let _ = response.recv();
        }
        *self.current.lock().expect("engine state lock") = None;
        *self.tasks.lock().expect("engine state lock") = None;
    }

    /// Info for the stream currently open.
    pub fn current_stream(&self) -> Option<StreamInfo> {
        self.current.lock().expect("engine state lock").clone()
    }

    /// Live counters for the stream currently open.
    pub fn stats(&self) -> Option<StreamStats> {
        let (reply, response) = mpsc::sync_channel(1);
        if self.commands.send(Command::Stats { reply }).is_err() {
            return None;
        }
        response.recv().unwrap_or(None)
    }

    /// The transport, for the UI thread.
    pub fn transport(&self) -> TransportHandle {
        self.transport.lock().expect("engine state lock").clone()
    }

    /// Replace the tempo map.
    pub fn set_tempo_map(&self, map: TempoMap) {
        self.transport().set_tempo_map(map);
    }

    /// Set the loop region.
    pub fn set_loop(&self, region: LoopRegion) {
        self.transport().set_loop(region);
    }

    /// Test-tone controls.
    pub fn tone(&self) -> &Arc<ToneControls> {
        &self.tone
    }

    /// Set the master level.
    pub fn set_master_gain(&self, gain: f32) {
        self.state.lock().expect("engine state lock").master_gain = gain;
        self.post(AudioTask::MasterGain(gain));
    }

    /// Make a decoded track the thing the transport plays.
    ///
    /// The timeline becomes the file's — ticks are its milliseconds — so the
    /// playhead, loops and seeks all speak the track's time directly. A loop
    /// left over from the previous track is meaningless in the new timeline
    /// and is cleared; the transport stops, parked at the top.
    pub fn load_track(&self, track: Arc<DecodedTrack>) {
        {
            let mut transport = self.transport.lock().expect("engine state lock");
            transport.set_tempo_map(file_timeline());
            transport.set_loop(LoopRegion {
                start_tick: 0,
                end_tick: 0,
                enabled: false,
            });
            transport.stop();
            transport.seek(0.0);
        }
        self.state.lock().expect("engine state lock").track = Some(Arc::clone(&track));
        self.post(AudioTask::LoadTrack(track));
    }

    /// Play nothing, forgetting the track and its timeline.
    pub fn unload_track(&self) {
        {
            let transport = self.transport.lock().expect("engine state lock");
            transport.set_loop(LoopRegion {
                start_tick: 0,
                end_tick: 0,
                enabled: false,
            });
            transport.stop();
            transport.seek(0.0);
        }
        self.state.lock().expect("engine state lock").track = None;
        self.post(AudioTask::UnloadTrack);
    }

    /// Set the channel-gain matrix, clamped like every gain on the bus.
    pub fn set_channel_mix(&self, mix: ChannelMix) {
        let mix = mix.map(|gain| gain.clamp(0.0, 1.0));
        self.state.lock().expect("engine state lock").mix = mix;
        self.post(AudioTask::ChannelMix(mix));
    }

    /// Hand work to the audio thread, if a stream is open.
    ///
    /// With no stream the state alone is updated; the next open replays it.
    fn post(&self, task: AudioTask) {
        let tasks = self.tasks.lock().expect("engine state lock");
        if let Some(sender) = tasks.as_ref() {
            let _ = sender.try_send(task);
        }
    }

    /// Re-post what changed between `before` and now onto `sender`.
    ///
    /// Called right after a stream swap: anything posted while the open was in
    /// flight must catch up with the new audio thread.
    fn repost_delta(&self, before: &EngineState, sender: &TaskSender) {
        let state = self.state.lock().expect("engine state lock");
        if state.master_gain.to_bits() != before.master_gain.to_bits() {
            let _ = sender.try_send(AudioTask::MasterGain(state.master_gain));
        }
        let same_track = state
            .track
            .as_ref()
            .map(Arc::as_ptr)
            .eq(&before.track.as_ref().map(Arc::as_ptr));
        if !same_track {
            match &state.track {
                Some(track) => {
                    let _ = sender.try_send(AudioTask::LoadTrack(Arc::clone(track)));
                }
                None => {
                    let _ = sender.try_send(AudioTask::UnloadTrack);
                }
            }
        }
        if state.mix != before.mix {
            let _ = sender.try_send(AudioTask::ChannelMix(state.mix));
        }
    }
}

fn engine_thread(
    receiver: &Receiver<Command>,
    transport: &TransportHandle,
    tone: &Arc<ToneControls>,
) {
    let mut stream: Option<AudioStream> = None;
    loop {
        match receiver.recv() {
            Ok(Command::Open {
                options,
                state,
                reply,
            }) => {
                // Drop the old stream first: its `Transport` must be gone
                // before a new one is created for the same shared state.
                stream = None;

                // A fresh queue per stream, so a stream that has gone cannot
                // leave stale work for the next one.
                let (sender, task_receiver) = mpsc::sync_channel::<AudioTask>(256);
                for task in state.iter() {
                    let _ = sender.try_send(task.clone());
                }

                let renderer = BandstandRenderer {
                    transport: transport.create_audio_side(),
                    tone: TestTone::new(48_000.0),
                    gain: Smoothed::new(0.5, 48_000.0, GAIN_GLIDE_MS),
                    player: TrackPlayer::new(48_000.0),
                    controls: Arc::clone(tone),
                    tasks: task_receiver,
                };

                let result = open_output_stream(&options, renderer).map(|open| {
                    let info = StreamInfo {
                        device_name: open.device_name().to_owned(),
                        sample_rate: open.sample_rate(),
                        channels: open.channels(),
                        buffer_frames: open.buffer_frames(),
                        sample_format: open.sample_format(),
                    };
                    stream = Some(open);
                    (info, sender)
                });
                let _ = reply.send(result.map_err(|e| e.to_string()));
            }
            Ok(Command::Close { reply }) => {
                stream = None;
                let _ = reply.send(());
            }
            Ok(Command::Stats { reply }) => {
                let stats = stream.as_ref().map(|s| {
                    let health = s.health();
                    StreamStats {
                        error_count: health.error_count(),
                        block_count: health.block_count(),
                        frame_count: health.frame_count(),
                    }
                });
                let _ = reply.send(stats);
            }
            Err(RecvError) => {
                // The engine was dropped; close the device and retire.
                drop(stream);
                return;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn repost_delta_sends_only_a_changed_master_gain() {
        // A stream reopened after posts landed mid-open must receive exactly
        // what changed since the snapshot — no more, no less (L-RH4).
        let (commands, _receiver) = mpsc::sync_channel::<Command>(16);
        let engine = AudioEngine {
            commands,
            transport: Mutex::new(TransportHandle::new(TempoMap::default())),
            tone: Arc::new(ToneControls::new()),
            current: Mutex::new(None),
            tasks: Mutex::new(None),
            state: Mutex::new(EngineState::new()),
        };
        let before = EngineState::new();
        // What `set_master_gain` would have recorded while the open was in
        // flight.
        {
            let mut state = engine.state.lock().expect("engine state lock");
            state.master_gain = 0.25;
        }
        let (sender, receiver) = mpsc::sync_channel::<AudioTask>(64);
        engine.repost_delta(&before, &sender);
        let delivered: Vec<AudioTask> = receiver.try_iter().collect();
        // Exactly the one change.
        assert_eq!(delivered.len(), 1);
        assert!(
            matches!(&delivered[0], AudioTask::MasterGain(gain) if (*gain - 0.25).abs() < 1e-6)
        );
        // And with no further changes, a second re-post sends nothing.
        let now = engine.state.lock().expect("engine state lock").clone();
        let (sender, receiver) = mpsc::sync_channel::<AudioTask>(64);
        engine.repost_delta(&now, &sender);
        assert_eq!(receiver.try_iter().count(), 0);
    }

    #[test]
    fn reopening_while_posts_land_keeps_the_state_consistent() {
        // Needs a real output device; on a headless box the first open fails
        // and there is nothing to exercise. The race this guards — a post
        // landing while an open is in flight — used to leave the audio thread
        // on the stale snapshot indefinitely; `repost_delta` now re-posts it,
        // so this is both a no-panic, no-deadlock exercise of the reopen path
        // and a soak that the state mutex stays the source of truth.
        let engine = AudioEngine::instance();
        if engine.open(StreamOptions::default()).is_err() {
            return; // no device
        }
        let poster = std::thread::spawn(|| {
            for i in 0..200u32 {
                #[allow(clippy::cast_precision_loss)]
                let gain = i as f32 / 200.0;
                AudioEngine::instance().set_master_gain(gain);
            }
        });
        for _ in 0..10 {
            assert!(engine.open(StreamOptions::default()).is_ok());
        }
        poster.join().expect("the posting thread finishes");
        let state = engine.state.lock().expect("engine state lock").clone();
        assert!((state.master_gain - 0.995).abs() < 1e-3);
        engine.close();
    }

    // --- the file player ----------------------------------------------------

    use crate::decode::DecodedTrack;
    use crate::player::MIX_RIGHT;
    use bandstand_transport::PlayState;

    /// A 48 kHz track of 48 000 frames: one second, one millisecond per tick,
    /// left climbing and right mirroring it.
    fn one_second_track() -> Arc<DecodedTrack> {
        let mut samples = Vec::with_capacity(48_000 * 2);
        for i in 0..48_000u32 {
            #[allow(clippy::cast_precision_loss)]
            let value = i as f32 * 0.000_1;
            samples.push(value);
            samples.push(-value);
        }
        Arc::new(DecodedTrack::from_interleaved_stereo(samples, 48_000))
    }

    /// A renderer wired like the engine thread wires it, with a track loaded
    /// and the master gain aimed at unity, plus its transport handle.
    fn track_renderer() -> (BandstandRenderer, TransportHandle) {
        let (transport, handle) = Transport::new(crate::player::file_timeline());
        let (sender, receiver) = mpsc::sync_channel::<AudioTask>(64);
        let mut renderer = BandstandRenderer {
            transport,
            tone: TestTone::new(48_000.0),
            gain: Smoothed::new(0.5, 48_000.0, GAIN_GLIDE_MS),
            player: TrackPlayer::new(48_000.0),
            controls: Arc::new(ToneControls::new()),
            tasks: receiver,
        };
        renderer.prepare(&StreamContext {
            sample_rate: 48_000.0,
            channels: 2,
            max_block_frames: 512,
        });
        sender
            .try_send(AudioTask::LoadTrack(one_second_track()))
            .expect("the queue takes the load");
        sender
            .try_send(AudioTask::MasterGain(1.0))
            .expect("the queue takes the gain");
        (renderer, handle)
    }

    fn block(renderer: &mut BandstandRenderer, frames: usize) -> Vec<f32> {
        let mut output = vec![0.0f32; frames * 2];
        renderer.render(
            &mut output,
            &BlockContext {
                frames,
                channels: 2,
                host_time_ns: 0,
            },
        );
        output
    }

    #[test]
    fn renderer_plays_a_loaded_track_under_master_gain() {
        let (mut renderer, handle) = track_renderer();
        handle.play();
        // Four blocks of 256: more than the 720 frames the gain glide takes.
        for _ in 0..4 {
            let _ = block(&mut renderer, 256);
        }
        let output = block(&mut renderer, 256);
        for i in 0..256u32 {
            #[allow(clippy::cast_precision_loss)]
            let expected = (1024 + i) as f32 * 0.000_1;
            assert!(
                (output[(i * 2) as usize] - expected).abs() < 1e-5,
                "frame {i}: {}",
                output[(i * 2) as usize]
            );
        }
    }

    #[test]
    fn renderer_wraps_a_loop_seamlessly() {
        let (mut renderer, handle) = track_renderer();
        handle.set_loop(LoopRegion {
            start_tick: 0,
            end_tick: 5,
            enabled: true,
        });
        handle.play();
        // 5 ms is exactly 240 frames at 48 kHz: settle the gain over whole
        // loop passes, then cross the seam inside a block.
        for _ in 0..4 {
            let _ = block(&mut renderer, 240);
        }
        let output = block(&mut renderer, 241);
        assert!((output[240 * 2] - 0.0).abs() < 1e-5, "{}", output[240 * 2]);
        // The block before the seam ended at file frame 239, the seam frame
        // is file frame 0 again: continuity, not a jump.
        let expected = 239.0 * 0.000_1;
        assert!((output[239 * 2] - expected).abs() < 1e-4);
        let position = handle.position();
        // Five wraps have happened, but the position cell publishes the
        // generation as of block start, so the last publish lags by one.
        assert!(position.loop_generation >= 4);
    }

    #[test]
    fn a_seek_lands_the_file_at_the_right_frame() {
        let (mut renderer, handle) = track_renderer();
        handle.play();
        for _ in 0..4 {
            let _ = block(&mut renderer, 256);
        }
        handle.seek(100.0); // 100 ms = frame 4800
        let output = block(&mut renderer, 256);
        for i in 0..8u32 {
            #[allow(clippy::cast_precision_loss)]
            let expected = (4800 + i) as f32 * 0.000_1;
            assert!((output[(i * 2) as usize] - expected).abs() < 1e-5);
        }
    }

    #[test]
    fn loading_a_track_retimes_the_transport_and_stops_it() {
        let (commands, _receiver) = mpsc::sync_channel::<Command>(16);
        let engine = AudioEngine {
            commands,
            transport: Mutex::new(TransportHandle::new(TempoMap::default())),
            tone: Arc::new(ToneControls::new()),
            current: Mutex::new(None),
            tasks: Mutex::new(None),
            state: Mutex::new(EngineState::new()),
        };
        engine.transport().play();
        engine.load_track(one_second_track());
        let position = engine.transport().position();
        assert!(position.state == PlayState::Stopped);
        assert!(position.tick.abs() < f64::EPSILON);
        let transport = engine.transport();
        let map = transport.tempo_map();
        assert!((map.seconds_at_tick(1000.0) - 1.0).abs() < 1e-9);
        let state = engine.state.lock().expect("engine state lock");
        assert!(state.track.is_some());
    }

    #[test]
    fn repost_delta_sends_only_what_changed() {
        let (commands, _receiver) = mpsc::sync_channel::<Command>(16);
        let engine = AudioEngine {
            commands,
            transport: Mutex::new(TransportHandle::new(TempoMap::default())),
            tone: Arc::new(ToneControls::new()),
            current: Mutex::new(None),
            tasks: Mutex::new(None),
            state: Mutex::new(EngineState::new()),
        };
        let before = EngineState::new();
        {
            let mut state = engine.state.lock().expect("engine state lock");
            state.track = Some(one_second_track());
            state.mix = MIX_RIGHT;
            state.master_gain = 0.25;
        }
        let (sender, receiver) = mpsc::sync_channel::<AudioTask>(64);
        engine.repost_delta(&before, &sender);
        let delivered: Vec<AudioTask> = receiver.try_iter().collect();
        assert_eq!(delivered.len(), 3);
        assert!(delivered
            .iter()
            .any(|task| matches!(task, AudioTask::LoadTrack(_))));
        assert!(delivered
            .iter()
            .any(|task| matches!(task, AudioTask::ChannelMix(mix) if *mix == MIX_RIGHT)));
        assert!(delivered.iter().any(
            |task| matches!(task, AudioTask::MasterGain(gain) if (*gain - 0.25).abs() < 1e-6)
        ));
        let now = engine.state.lock().expect("engine state lock").clone();
        let (sender, receiver) = mpsc::sync_channel::<AudioTask>(64);
        engine.repost_delta(&now, &sender);
        assert_eq!(receiver.try_iter().count(), 0);
    }
}
