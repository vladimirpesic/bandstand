//! The audio half of the bridge surface.
//!
//! Everything here is a thin wrapper over `crate::engine`. Adding a function to
//! this file is an FFI surface change and needs the justification §15 asks for.

use std::path::PathBuf;

use bandstand_audio_host::StreamOptions;
use bandstand_sequencer::{EventKind, Sequence, TimedEvent};
use bandstand_synth::CHANNEL_COUNT;
use bandstand_transport::{LoopRegion, PlayState, TempoChange, TempoMap};

use crate::engine::AudioEngine;
use crate::offline::render_to_wav;

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

// --- the soundbank -----------------------------------------------------------

/// A loaded soundbank, as the UI shows it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SoundBankInfo {
    /// Where it came from.
    pub path: String,
    /// Its name, from the file.
    pub name: String,
    /// How many presets it has.
    pub preset_count: u32,
    /// How many samples it has.
    pub sample_count: u32,
}

/// Load a SoundFont (§3, §7.2).
///
/// Reading and mapping happen off the audio thread; the audio thread only ever
/// takes the finished bank.
///
/// # Errors
/// Returns a message if the file is not a SoundFont this build can read.
pub fn load_soundbank(path: String) -> Result<SoundBankInfo, String> {
    let loaded = AudioEngine::instance().load_soundbank(PathBuf::from(path))?;
    Ok(SoundBankInfo {
        path: loaded.path.to_string_lossy().into_owned(),
        name: loaded.name,
        preset_count: u32::try_from(loaded.presets).unwrap_or(u32::MAX),
        sample_count: u32::try_from(loaded.samples).unwrap_or(u32::MAX),
    })
}

/// Unload the bank, so nothing plays.
pub fn unload_soundbank() {
    AudioEngine::instance().unload_soundbank();
}

/// The bank currently loaded, if any.
#[must_use]
pub fn loaded_soundbank() -> Option<SoundBankInfo> {
    AudioEngine::instance()
        .loaded_bank()
        .map(|loaded| SoundBankInfo {
            path: loaded.path.to_string_lossy().into_owned(),
            name: loaded.name,
            preset_count: u32::try_from(loaded.presets).unwrap_or(u32::MAX),
            sample_count: u32::try_from(loaded.samples).unwrap_or(u32::MAX),
        })
}

// --- the sequence ------------------------------------------------------------

/// What an event does. Mirrors the sequencer's own vocabulary.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MidiEventKind {
    /// Start a note.
    NoteOn,
    /// Let a note go.
    NoteOff,
    /// Select a sound.
    Program,
    /// Set the channel volume, 0–127 in `value`.
    Volume,
    /// Set the channel pan, 0–127 in `value`, 64 being centre.
    Pan,
    /// Set the channel expression, 0–127 in `value`.
    Expression,
    /// Put the sustain pedal down (`value` above 63) or up.
    Sustain,
    /// Bend the pitch, 0–16383 in `value`, 8192 being centre.
    PitchBend,
    /// Let every note on the channel go.
    AllNotesOff,
}

/// One event in a sequence, as Dart sends it.
///
/// Deliberately flat and made only of numbers: this crosses the FFI boundary
/// tens of thousands of times for one song, and a shape with strings or
/// options in it would cost more to marshal than to play.
///
/// Every field is range-checked by [`load_sequence`]: values outside the
/// ranges below are a caller bug and are rejected with an error rather than
/// wrapped into range.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MidiEvent {
    /// Where it happens, in ticks.
    pub tick: u64,
    /// Which MIDI channel, 0–15.
    pub channel: u8,
    /// What it does.
    pub kind: MidiEventKind,
    /// The key (at most 127), for notes; the program (at most 127), for a
    /// program change.
    pub data1: u16,
    /// The velocity (at most 127), for notes; the bank (at most 16383), for a
    /// program change; the value (at most 127), for a controller; the bend (at
    /// most 16383), for a pitch bend.
    pub data2: u16,
}

impl MidiEvent {
    /// The kind this event selects, with its fields range-checked.
    ///
    /// # Errors
    /// Returns a message naming the first field outside its documented range.
    /// Values used to wrap silently (`data1 = 300` became key 44); now the
    /// caller hears about it.
    fn checked_kind(&self) -> Result<EventKind, String> {
        #[allow(clippy::cast_possible_truncation)]
        let key = self.data1 as u8;
        #[allow(clippy::cast_possible_truncation)]
        let value = self.data2 as u8;
        let kind = match self.kind {
            MidiEventKind::NoteOn => {
                self.require("note key", self.data1, 127)?;
                self.require("velocity", self.data2, 127)?;
                EventKind::NoteOn {
                    key,
                    velocity: value,
                }
            }
            MidiEventKind::NoteOff => {
                self.require("note key", self.data1, 127)?;
                EventKind::NoteOff { key }
            }
            MidiEventKind::Program => {
                self.require("program", self.data1, 127)?;
                self.require("bank", self.data2, 16_383)?;
                EventKind::Program {
                    bank: self.data2,
                    program: self.data1,
                }
            }
            MidiEventKind::Volume => {
                self.require("volume", self.data2, 127)?;
                EventKind::Volume(f32::from(value) / 127.0)
            }
            MidiEventKind::Pan => {
                self.require("pan", self.data2, 127)?;
                // Value 0 maps to −64/63 ≈ −1.016, below the −1 the synth
                // clamps to, leaving the left half of the pot a step coarser
                // than the right. Clamping keeps both ends exact.
                EventKind::Pan(((f32::from(value) - 64.0) / 63.0).clamp(-1.0, 1.0))
            }
            MidiEventKind::Expression => {
                self.require("expression", self.data2, 127)?;
                EventKind::Expression(f32::from(value) / 127.0)
            }
            MidiEventKind::Sustain => {
                self.require("sustain", self.data2, 127)?;
                EventKind::Sustain(value >= 64)
            }
            MidiEventKind::PitchBend => {
                self.require("pitch bend", self.data2, 16_383)?;
                EventKind::PitchBend((f32::from(self.data2) - 8192.0) / 8192.0)
            }
            MidiEventKind::AllNotesOff => EventKind::AllNotesOff,
        };
        Ok(kind)
    }

    /// One named field, checked against its inclusive maximum.
    fn require(&self, what: &str, got: u16, max: u16) -> Result<(), String> {
        if got > max {
            return Err(format!(
                "event at tick {} has {what} {got}, above the maximum {max}",
                self.tick
            ));
        }
        Ok(())
    }

    fn to_timed(self) -> Result<TimedEvent, String> {
        if usize::from(self.channel) >= CHANNEL_COUNT {
            return Err(format!(
                "event at tick {} uses channel {}, above the maximum {}",
                self.tick,
                self.channel,
                CHANNEL_COUNT - 1
            ));
        }
        let kind = self.checked_kind()?;
        Ok(TimedEvent::new(self.tick, self.channel, kind))
    }
}

/// Hand the audio thread a whole sequence to play (§3).
///
/// Replaces whatever was there. Notes sounding from the old sequence are let
/// go, so nothing hangs.
///
/// With no tempo markers the tempo the user hears is kept, but the tempo map
/// is rebuilt at `ppq` — the resolution the sequence's ticks are counted on —
/// so playback timing matches the sequence grid. Note that this *flattens* a
/// map that held several tempos: the rebuilt map is constant at the tempo in
/// force at tick 0, so a sequence loaded without markers over a song that had
/// a ritardando loses it. Pass the markers to keep it.
///
/// # Errors
/// Returns a message if a tempo marker is not one the transport accepts, or
/// an event carries a value outside its documented range. Nothing is installed
/// unless everything validates.
pub fn load_sequence(
    events: Vec<MidiEvent>,
    ppq: u32,
    length_ticks: u64,
    tempo_markers: Vec<TempoMarker>,
) -> Result<(), String> {
    let engine = AudioEngine::instance();
    // Everything fallible happens before anything is installed. Building the
    // map first and validating the events afterwards left a rejected load
    // having already changed the tempo, so the *old* sequence carried on at
    // the new song's speed while the caller was told the load had failed.
    let map = if tempo_markers.is_empty() {
        let current_bpm = engine.transport().tempo_map().bpm_at_tick(0.0);
        TempoMap::constant(ppq, current_bpm).map_err(|e| e.to_string())?
    } else {
        build_tempo_map(ppq, tempo_markers)?
    };
    let timed: Vec<TimedEvent> = events
        .into_iter()
        .map(MidiEvent::to_timed)
        .collect::<Result<_, _>>()?;

    engine.set_tempo_map(map);
    engine.set_sequence(Sequence::new(timed, ppq, length_ticks));
    Ok(())
}

/// Forget the sequence, so nothing plays.
pub fn clear_sequence() {
    AudioEngine::instance().set_sequence(Sequence::empty());
}

/// How many events are loaded, and how long they last in ticks.
#[flutter_rust_bridge::frb(sync)]
#[must_use]
pub fn sequence_status() -> SequenceStatus {
    let (events, length) = AudioEngine::instance().sequence_length();
    SequenceStatus {
        event_count: u32::try_from(events).unwrap_or(u32::MAX),
        length_ticks: length,
    }
}

/// What is loaded.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SequenceStatus {
    /// How many events.
    pub event_count: u32,
    /// How long they last, in ticks.
    pub length_ticks: u64,
}

// --- the mixer ---------------------------------------------------------------

/// Set a channel's level, position and mute (§3).
pub fn set_channel_mix(channel: u8, volume: f32, pan: f32, muted: bool) {
    AudioEngine::instance().set_channel_mix(channel, volume, pan, muted);
}

/// Set the master level.
pub fn set_master_gain(gain: f32) {
    AudioEngine::instance().set_master_gain(gain);
}

/// Stop every note at once, without moving the playhead.
pub fn all_notes_off() {
    AudioEngine::instance().panic();
}

// --- bouncing ----------------------------------------------------------------

/// What a bounce produced.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RenderResult {
    /// How many frames were written.
    pub frames: u64,
    /// How long the file lasts, in seconds.
    pub seconds: f64,
    /// How many samples clipped. Non-zero means the mix was too loud.
    pub clipped_samples: u64,
}

/// Render the loaded sequence to a WAV file (§3, §5.3).
///
/// Runs as fast as the machine allows — there is no device and no clock. The
/// bounce carries the live mix: per-channel volume, pan and mute, and the
/// master gain, so a muted channel is silent in the file.
///
/// # Errors
/// Returns a message if there is no bank, no sequence, the sample rate is
/// below what the DSP renders at, or the file cannot be written.
pub fn render_offline(path: String, sample_rate: u32) -> Result<RenderResult, String> {
    let engine = AudioEngine::instance();
    let bank = engine
        .bank_for_render()
        .ok_or_else(|| "no soundbank is loaded".to_owned())?;
    let sequence = engine.sequence_for_render();
    let map = engine.transport().tempo_map().clone();
    let (channels, master_gain) = engine.mix_for_render();
    let summary = render_to_wav(
        std::path::Path::new(&path),
        bank,
        &sequence,
        &map,
        sample_rate,
        master_gain,
        channels,
    )
    .map_err(|error| error.to_string())?;
    Ok(RenderResult {
        frames: summary.frames,
        seconds: summary.duration_seconds(),
        clipped_samples: summary.clipped,
    })
}

#[cfg(test)]
// Comparing the mapped pan floats against the exact endpoints is the point of
// the pan test, not a mistake.
#[allow(clippy::float_cmp)]
mod tests {
    use super::*;

    fn event(kind: MidiEventKind, data1: u16, data2: u16) -> MidiEvent {
        MidiEvent {
            tick: 0,
            channel: 0,
            kind,
            data1,
            data2,
        }
    }

    #[test]
    fn out_of_range_events_error_rather_than_wrapping() {
        let cases = [
            (
                "channel 16",
                MidiEvent {
                    tick: 0,
                    channel: 16,
                    kind: MidiEventKind::NoteOn,
                    data1: 60,
                    data2: 100,
                },
            ),
            ("note key above 127", event(MidiEventKind::NoteOn, 300, 100)),
            (
                "note off key above 127",
                event(MidiEventKind::NoteOff, 128, 0),
            ),
            ("program above 127", event(MidiEventKind::Program, 128, 0)),
            ("bank above 16383", event(MidiEventKind::Program, 0, 20_000)),
            ("volume above 127", event(MidiEventKind::Volume, 0, 200)),
            ("pan above 127", event(MidiEventKind::Pan, 0, 200)),
            (
                "expression above 127",
                event(MidiEventKind::Expression, 0, 200),
            ),
            ("sustain above 127", event(MidiEventKind::Sustain, 0, 200)),
            (
                "pitch bend above 16383",
                event(MidiEventKind::PitchBend, 0, 20_000),
            ),
        ];
        for (name, bad) in cases {
            assert!(bad.to_timed().is_err(), "{name} was not rejected");
        }
        // The boundary values themselves stay legal.
        assert!(MidiEvent {
            channel: 15,
            ..event(MidiEventKind::NoteOn, 127, 127)
        }
        .to_timed()
        .is_ok());
        assert!(event(MidiEventKind::PitchBend, 0, 16_383)
            .to_timed()
            .is_ok());
    }

    #[test]
    fn pan_maps_the_full_pot_into_range_with_exact_ends() {
        let pan = |value: u16| match event(MidiEventKind::Pan, 0, value).to_timed().unwrap().kind {
            EventKind::Pan(pan) => pan,
            _ => panic!("expected a pan event"),
        };
        // 0 used to map to −64/63 ≈ −1.016, below the clamped range, leaving
        // the left half of the pot a step coarser than the right.
        assert_eq!(pan(0), -1.0);
        assert_eq!(pan(64), 0.0);
        assert_eq!(pan(127), 1.0);
    }

    // The one test here that touches the process-wide engine: the tempo map
    // assertions must not interleave with another test's map changes.
    #[test]
    fn load_sequence_with_no_markers_rebuilds_the_map_at_the_sequence_ppq() {
        transport_set_tempo_map(
            960,
            vec![TempoMarker {
                tick: 0,
                bpm: 120.0,
            }],
        )
        .unwrap();
        load_sequence(vec![], 480, 480, vec![]).unwrap();
        let position = transport_position();
        assert_eq!(position.ppq, 480, "the map keeps the sequence's resolution");
        assert_eq!(position.bpm, 120.0, "the tempo the user hears is kept");
    }
}
