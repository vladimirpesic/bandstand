//! The audio half of the bridge surface.
//!
//! Everything here is a thin wrapper over `crate::engine`. Adding a function to
//! this file is an FFI surface change and needs the justification §15 asks for.

use bandstand_audio_host::StreamOptions;
use bandstand_transport::{LoopRegion, PlayState, TempoChange, TempoMap};

use crate::engine::AudioEngine;

/// An output device the user can choose.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AudioDevice {
    /// Backend name; also the key used to reopen the device.
    pub name: String,
    /// Whether this is the system default output.
    pub is_default: bool,
}

/// What to ask the platform for when opening a stream.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AudioStreamRequest {
    /// Device name, or `None` for the system default.
    pub device_name: Option<String>,
    /// Sample rate to request, or `None` to let Bandstand prefer 48 kHz.
    pub sample_rate: Option<u32>,
    /// Buffer size in frames, or `None` for Bandstand's default of 256.
    pub buffer_frames: Option<u32>,
}

/// What the platform actually gave us.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AudioStreamStatus {
    /// Device the stream is running on.
    pub device_name: String,
    /// Negotiated sample rate.
    pub sample_rate: u32,
    /// Negotiated channel count.
    pub channels: u16,
    /// Negotiated buffer size in frames, if the backend fixed one.
    pub buffer_frames: Option<u32>,
    /// The device's native sample format.
    pub sample_format: String,
    /// Backend errors since the stream opened. Non-zero means audio dropped.
    pub error_count: u64,
    /// Audio blocks rendered since the stream opened.
    pub block_count: u64,
    /// Frames rendered since the stream opened.
    pub frame_count: u64,
}

/// What the transport is doing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransportState {
    /// Not playing; playhead parked at the stop anchor.
    Stopped,
    /// Not playing; playhead held where it was.
    Paused,
    /// Playing.
    Playing,
}

impl From<PlayState> for TransportState {
    fn from(state: PlayState) -> Self {
        match state {
            PlayState::Stopped => Self::Stopped,
            PlayState::Paused => Self::Paused,
            PlayState::Playing => Self::Playing,
        }
    }
}

/// A coherent read of the playhead, for the UI to extrapolate from.
///
/// This is the shared-atomic readback of §3: no callback, no message, just a
/// direct read of the cell the audio thread publishes into once per block.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TransportPosition {
    /// Playhead in ticks when the audio thread published.
    pub tick: f64,
    /// Monotonic nanoseconds at which the published block reaches the speakers.
    pub host_time_ns: u64,
    /// Monotonic nanoseconds at the moment of this read, so Dart can compute
    /// the elapsed time without a second call.
    pub read_at_ns: u64,
    /// Transport state.
    pub state: TransportState,
    /// Increments on every loop wrap.
    pub loop_generation: u32,
    /// Ticks per nanosecond at `tick`, for extrapolation.
    pub ticks_per_nanosecond: f64,
    /// Tempo in effect at `tick`.
    pub bpm: f64,
    /// Ticks per quarter note.
    pub ppq: u32,
}

/// A tempo marker: from `tick` onwards, the tempo is `bpm`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TempoMarker {
    /// Position in ticks.
    pub tick: u64,
    /// Beats (quarter notes) per minute.
    pub bpm: f64,
}

/// The output devices the platform offers.
///
/// # Errors
/// Returns a message if the platform cannot be queried.
pub fn audio_devices() -> Result<Vec<AudioDevice>, String> {
    ensure_android_context()?;
    Ok(crate::engine::output_devices()?
        .into_iter()
        .map(|d| AudioDevice {
            name: d.name,
            is_default: d.is_default,
        })
        .collect())
}

/// Open (or reopen) the output stream.
///
/// # Errors
/// Returns a message if the device cannot be opened.
pub fn audio_start(request: AudioStreamRequest) -> Result<AudioStreamStatus, String> {
    ensure_android_context()?;
    let options = StreamOptions {
        device_name: request.device_name,
        sample_rate: request.sample_rate,
        buffer_frames: request.buffer_frames,
    };
    AudioEngine::instance().open(options)?;
    // `open` succeeded, so the stream is running whatever the status read says.
    // Reporting a missing status as "the stream closed" told the player their
    // audio had failed while the band was in fact playing; the honest answer is
    // that the statistics are not available yet.
    audio_status().ok_or_else(|| "the stream opened but reported no status yet".to_owned())
}

/// On Android the audio backend reaches the platform through a context
/// installed from Kotlin (`crate::android`); without it the first device call
/// panics inside JNI. Everywhere else this is a no-op.
#[cfg(target_os = "android")]
fn ensure_android_context() -> Result<(), String> {
    if crate::android::is_initialised() {
        Ok(())
    } else {
        Err("the Android audio context has not been installed".to_owned())
    }
}

#[cfg(not(target_os = "android"))]
fn ensure_android_context() -> Result<(), String> {
    Ok(())
}

/// Close the output stream.
pub fn audio_stop() {
    AudioEngine::instance().close();
}

/// The state of the stream currently open, or `None` if there is none.
#[must_use]
pub fn audio_status() -> Option<AudioStreamStatus> {
    let engine = AudioEngine::instance();
    let info = engine.current_stream()?;
    let stats = engine.stats().unwrap_or_default();
    Some(AudioStreamStatus {
        device_name: info.device_name,
        sample_rate: info.sample_rate,
        channels: info.channels,
        buffer_frames: info.buffer_frames,
        sample_format: info.sample_format,
        error_count: stats.error_count,
        block_count: stats.block_count,
        frame_count: stats.frame_count,
    })
}

/// Switch the reference test tone on or off, and set its frequency and gain.
///
/// `amplitude` is linear gain in `0.0..=1.0`; `frequency_hz` is clamped to the
/// audible range.
pub fn set_test_tone(enabled: bool, frequency_hz: f32, amplitude: f32) {
    AudioEngine::instance()
        .tone()
        .set(enabled, frequency_hz, amplitude);
}

/// Start playing from the current position.
pub fn transport_play() {
    AudioEngine::instance().transport().play();
}

/// Stop advancing, holding the playhead where it is.
pub fn transport_pause() {
    AudioEngine::instance().transport().pause();
}

/// Stop and return to the stop anchor.
pub fn transport_stop() {
    AudioEngine::instance().transport().stop();
}

/// Move the playhead.
pub fn transport_seek(tick: f64) {
    AudioEngine::instance().transport().seek(tick);
}

/// Set the loop region, in ticks.
pub fn transport_set_loop(start_tick: u64, end_tick: u64, enabled: bool) {
    AudioEngine::instance().set_loop(LoopRegion {
        start_tick,
        end_tick,
        enabled,
    });
}

/// Replace the whole tempo map.
///
/// # Errors
/// Returns a message if the markers are empty, out of order, or carry a tempo
/// outside 10–400 bpm.
pub fn transport_set_tempo_map(ppq: u32, markers: Vec<TempoMarker>) -> Result<(), String> {
    let map = build_tempo_map(ppq, markers)?;
    AudioEngine::instance().set_tempo_map(map);
    Ok(())
}

/// Build a tempo map from markers without installing it.
///
/// Split out so [`load_sequence`] can validate its whole payload before it
/// changes any engine state.
fn build_tempo_map(ppq: u32, markers: Vec<TempoMarker>) -> Result<TempoMap, String> {
    let changes: Vec<TempoChange> = markers
        .iter()
        .map(|m| TempoChange::new(m.tick, m.bpm))
        .collect();
    TempoMap::new(ppq, &changes).map_err(|e| e.to_string())
}

/// Set a single constant tempo, keeping the current resolution.
///
/// # Errors
/// Returns a message if `bpm` is outside 10–400.
pub fn transport_set_tempo(bpm: f64) -> Result<(), String> {
    let engine = AudioEngine::instance();
    let ppq = engine.transport().tempo_map().ppq();
    let map = TempoMap::constant(ppq, bpm).map_err(|e| e.to_string())?;
    engine.set_tempo_map(map);
    Ok(())
}

/// Read the playhead. Cheap enough to call once per rendered frame.
#[flutter_rust_bridge::frb(sync)]
#[must_use]
pub fn transport_position() -> TransportPosition {
    let handle = AudioEngine::instance().transport();
    let snapshot = handle.position();
    let map = handle.tempo_map();
    TransportPosition {
        tick: snapshot.tick,
        host_time_ns: snapshot.host_time_ns,
        read_at_ns: bandstand_transport::monotonic_now_ns(),
        state: snapshot.state.into(),
        loop_generation: snapshot.loop_generation,
        ticks_per_nanosecond: map.ticks_per_nanosecond_at(snapshot.tick),
        bpm: map.bpm_at_tick(snapshot.tick),
        ppq: map.ppq(),
    }
}

/// Bandstand's monotonic clock, in nanoseconds.
///
/// The same clock `TransportPosition::host_time_ns` is expressed in.
#[flutter_rust_bridge::frb(sync)]
#[must_use]
pub fn monotonic_now_ns() -> u64 {
    bandstand_transport::monotonic_now_ns()
}

// --- the mixer ---------------------------------------------------------------

/// Set the master level.
pub fn set_master_gain(gain: f32) {
    AudioEngine::instance().set_master_gain(gain);
}

// --- the player ----------------------------------------------------------------

/// A track loaded into the engine, ready to play.
///
/// Durations are milliseconds: on the file timeline a tick is a millisecond,
/// so [`transport_seek`], [`transport_set_loop`] and [`transport_position`]
/// speak the track's time directly (divide ticks by 1000 for the UI).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TrackInfo {
    /// Duration in milliseconds — also the track's length in ticks.
    pub duration_ms: u64,
    /// The source sample rate; the engine reads across rate differences.
    pub sample_rate: u32,
}

/// Decode a cached audio file and make it the thing the transport plays.
///
/// Runs the whole decode before answering — it is a worker-thread call, never
/// the UI thread and never the audio thread. Loading stops the transport at
/// the top of the new track and clears any loop left from the previous one.
///
/// # Errors
/// Returns a human-readable message if the file cannot be opened or decoded.
pub fn player_load(path: String) -> Result<TrackInfo, String> {
    let track = crate::decode::decode_file(std::path::Path::new(&path))?;
    let info = TrackInfo {
        duration_ms: track.duration_ms(),
        sample_rate: track.sample_rate(),
    };
    AudioEngine::instance().load_track(std::sync::Arc::new(track));
    Ok(info)
}

/// Forget the loaded track and its timeline.
pub fn player_unload() {
    AudioEngine::instance().unload_track();
}

/// Set the channel-gain matrix — the isolation control at the heart of the
/// player (the recordings carry bass on one side, piano on the other).
///
/// The four gains are `[left←left, left←right, right←left, right←right]`,
/// row-major by output; each is clamped to `0.0..=1.0` and ramps, so moving
/// between both-sides, left-only and right-only never clicks. Stereo
/// `(1, 0, 0, 1)` passes the recording through; `(0, 1, 0, 1)` puts only the
/// right side on both speakers.
pub fn player_set_channel_mix(
    left_from_left: f32,
    left_from_right: f32,
    right_from_left: f32,
    right_from_right: f32,
) {
    AudioEngine::instance().set_channel_mix([
        left_from_left,
        left_from_right,
        right_from_left,
        right_from_right,
    ]);
}
