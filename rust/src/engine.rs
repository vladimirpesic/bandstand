//! The audio engine: the one place where the transport, the sequencer, the
//! synth and the output device meet.
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
//! over a channel. That also gives Android the long-lived owner it will need
//! for audio-focus handling at M8.

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::mpsc::{self, Receiver, RecvError, SyncSender};
use std::sync::{Arc, Mutex, OnceLock};

use bandstand_audio_host::{
    list_output_devices, open_output_stream, AudioRenderer, AudioStream, BlockContext,
    OutputDeviceInfo, StreamContext, StreamOptions,
};
use bandstand_sequencer::{EventKind, Sequence, Sequencer, TimedEvent};
use bandstand_synth::{
    load_soundfont, SoundBank, Synth, TestTone, CHANNEL_COUNT, DEFAULT_MAX_VOICES,
};
use bandstand_transport::{
    init_clock, LoopRegion, PlayState, TempoMap, Transport, TransportHandle,
};

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
            frequency_bits: AtomicU32::new(bandstand_synth::DEFAULT_FREQUENCY_HZ.to_bits()),
            amplitude_bits: AtomicU32::new(bandstand_synth::DEFAULT_AMPLITUDE.to_bits()),
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
///
/// Loading a bank reads a file and allocates; building a sequence sorts. Both
/// happen off the audio thread, which only ever takes the finished value.
#[derive(Clone)]
enum AudioTask {
    /// A bank to install, or `None` to unload.
    Bank(Option<Arc<SoundBank>>),
    /// A sequence to play.
    Sequence(Arc<Sequence>),
    /// A channel's mixer settings: volume, pan, mute.
    ChannelMix(u8, f32, f32, bool),
    /// Master gain, 0 to 1.
    MasterGain(f32),
    /// Stop every note and clear the effects.
    Panic,
}

type TaskSender = SyncSender<AudioTask>;
type TaskReceiver = Receiver<AudioTask>;

/// Everything the audio thread needs that outlives any one stream.
///
/// Kept here so that closing a device and opening another does not lose the
/// bank, the sequence or the mixer — which, on a stage, is the difference
/// between a hiccup and starting again.
#[derive(Clone)]
struct EngineState {
    bank: Option<Arc<SoundBank>>,
    sequence: Arc<Sequence>,
    channels: [(f32, f32, bool); CHANNEL_COUNT],
    master_gain: f32,
}

impl EngineState {
    fn new() -> Self {
        Self {
            bank: None,
            sequence: Arc::new(Sequence::empty()),
            // The synth's own `ChannelState` starts at the GM default of
            // 100/127, and so do the `FLAT_MIX` constants the render tests
            // pass; a different number here would fight both the moment the
            // state is replayed onto a fresh synth (L-RH7).
            channels: [(100.0 / 127.0, 0.0, false); CHANNEL_COUNT],
            master_gain: 0.5,
        }
    }

    /// The tasks that put a fresh audio thread into this state.
    fn as_tasks(&self) -> Vec<AudioTask> {
        let mut tasks = Vec::with_capacity(CHANNEL_COUNT + 3);
        tasks.push(AudioTask::Bank(self.bank.clone()));
        tasks.push(AudioTask::Sequence(Arc::clone(&self.sequence)));
        tasks.push(AudioTask::MasterGain(self.master_gain));
        for (index, (volume, pan, muted)) in self.channels.iter().enumerate() {
            #[allow(clippy::cast_possible_truncation)]
            tasks.push(AudioTask::ChannelMix(index as u8, *volume, *pan, *muted));
        }
        tasks
    }
}

/// What the audio callback runs.
struct BandstandRenderer {
    transport: Transport,
    sequencer: Sequencer,
    synth: Synth,
    tone: TestTone,
    controls: Arc<ToneControls>,
    tasks: TaskReceiver,
    /// Events read this block, with the frame each lands on. Preallocated.
    pending: Vec<(usize, TimedEvent)>,
    last_state: PlayState,
    sample_rate: f64,
}

impl BandstandRenderer {
    /// Take whatever has been left for us. Never blocks.
    fn drain_tasks(&mut self) {
        while let Ok(task) = self.tasks.try_recv() {
            match task {
                AudioTask::Bank(bank) => self.synth.set_bank(bank),
                AudioTask::Sequence(sequence) => {
                    let pending = &mut self.pending;
                    let mut sink = |frame: usize, event: &TimedEvent| {
                        pending.push((frame, *event));
                    };
                    self.sequencer.set_sequence(sequence, &mut sink);
                }
                AudioTask::ChannelMix(channel, volume, pan, muted) => {
                    self.synth.set_channel_volume(channel, volume);
                    self.synth.set_channel_pan(channel, pan);
                    self.synth.set_channel_muted(channel, muted);
                }
                AudioTask::MasterGain(gain) => self.synth.set_master_gain(gain),
                AudioTask::Panic => self.synth.panic(),
            }
        }
    }

    fn apply(&mut self, event: &TimedEvent) {
        match event.kind {
            EventKind::NoteOn { key, velocity } => {
                self.synth.note_on(event.channel, key, velocity);
            }
            EventKind::NoteOff { key } => self.synth.note_off(event.channel, key),
            EventKind::Program { bank, program } => {
                self.synth.set_program(event.channel, bank, program);
            }
            EventKind::Volume(value) => {
                self.synth.set_channel_volume(event.channel, value);
            }
            EventKind::Pan(value) => self.synth.set_channel_pan(event.channel, value),
            EventKind::Expression(value) => {
                self.synth.set_channel_expression(event.channel, value);
            }
            EventKind::Sustain(down) => self.synth.set_sustain(event.channel, down),
            EventKind::PitchBend(value) => {
                self.synth.set_pitch_bend(event.channel, value);
            }
            EventKind::AllNotesOff => self.synth.all_notes_off(event.channel),
        }
    }
}

impl AudioRenderer for BandstandRenderer {
    fn prepare(&mut self, context: &StreamContext) {
        self.transport.set_sample_rate(context.sample_rate);
        self.tone.set_sample_rate(context.sample_rate);
        self.sample_rate = context.sample_rate;
        #[allow(clippy::cast_possible_truncation)]
        let rate = context.sample_rate as f32;
        self.synth = Synth::new(rate, context.max_block_frames, DEFAULT_MAX_VOICES);
        self.drain_tasks();
    }

    fn render(&mut self, output: &mut [f32], context: &BlockContext) {
        self.drain_tasks();

        // Advance the playhead first: everything downstream is positioned
        // against the segments this returns.
        let segments = self.transport.advance(context.frames, context.host_time_ns);

        // A transport that has just stopped must not ring on.
        let state = self.transport.state();
        if state != self.last_state {
            if state == PlayState::Stopped {
                self.synth.reset();
            }
            self.last_state = state;
        }

        let rate = self.sample_rate;
        {
            let pending = &mut self.pending;
            let mut sink = |frame: usize, event: &TimedEvent| {
                pending.push((frame, *event));
            };
            self.sequencer
                .process(&segments, self.transport.tempo_map(), rate, &mut sink);
        }

        // Events are applied where they fall: the block is rendered in runs
        // between them, which is what "sample-accurate scheduling" means (§7.3).
        let mut rendered = 0usize;
        let mut index = 0usize;
        while index < self.pending.len() {
            let frame = self.pending[index].0.min(context.frames);
            if frame > rendered {
                let start = rendered * context.channels;
                let end = frame * context.channels;
                self.synth.render(&mut output[start..end], context.channels);
                rendered = frame;
            }
            while index < self.pending.len() && self.pending[index].0.min(context.frames) == frame {
                let event = self.pending[index].1;
                self.apply(&event);
                index += 1;
            }
        }
        if rendered < context.frames {
            let start = rendered * context.channels;
            self.synth.render(&mut output[start..], context.channels);
        }
        self.pending.clear();

        self.controls.apply(&mut self.tone);
        self.tone.mix_into(output, context.channels);
    }
}

/// Facts about a running stream, as reported to the UI.
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

/// What was loaded, for the UI to show.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LoadedBank {
    /// Where it came from.
    pub path: PathBuf,
    /// Its name, from the file.
    pub name: String,
    /// How many presets it has.
    pub presets: usize,
    /// How many samples it has.
    pub samples: usize,
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
    /// The bank currently loaded, for display.
    bank: Mutex<Option<LoadedBank>>,
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
            bank: Mutex::new(None),
        }
    }

    /// The process-wide engine, created on first use.
    pub fn instance() -> &'static Self {
        static ENGINE: OnceLock<AudioEngine> = OnceLock::new();
        ENGINE.get_or_init(Self::new)
    }

    /// Open (or reopen) the output stream.
    ///
    /// The bank, the sequence and the mixer are re-sent to the new audio
    /// thread, so changing device does not lose the sound. Changes posted
    /// while the open was in flight are re-posted after the swap
    /// ([`Self::repost_delta`]).
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
        self.transport
            .lock()
            .expect("engine state lock")
            .set_tempo_map(map);
    }

    /// Set the loop region.
    pub fn set_loop(&self, region: LoopRegion) {
        self.transport
            .lock()
            .expect("engine state lock")
            .set_loop(region);
    }

    /// Test-tone controls.
    pub fn tone(&self) -> &Arc<ToneControls> {
        &self.tone
    }

    /// Load a soundfont and hand it to the audio thread (§7.2).
    ///
    /// The file is read and mapped on this thread; the audio thread only ever
    /// takes the finished bank.
    ///
    /// # Errors
    /// Returns a human-readable message if the file cannot be read.
    pub fn load_soundbank(&self, path: PathBuf) -> Result<LoadedBank, String> {
        let bank = load_soundfont(&path).map_err(|error| error.to_string())?;
        let loaded = LoadedBank {
            name: if bank.name.is_empty() {
                path.file_stem()
                    .map(|stem| stem.to_string_lossy().into_owned())
                    .unwrap_or_else(|| "soundbank".to_owned())
            } else {
                bank.name.clone()
            },
            path,
            presets: bank.presets.len(),
            samples: bank.samples.len(),
        };
        let bank = Arc::new(bank);
        self.state.lock().expect("engine state lock").bank = Some(Arc::clone(&bank));
        self.post(AudioTask::Bank(Some(bank)));
        *self.bank.lock().expect("engine state lock") = Some(loaded.clone());
        Ok(loaded)
    }

    /// Unload the bank, so nothing plays.
    pub fn unload_soundbank(&self) {
        self.state.lock().expect("engine state lock").bank = None;
        self.post(AudioTask::Bank(None));
        *self.bank.lock().expect("engine state lock") = None;
    }

    /// The bank currently loaded.
    pub fn loaded_bank(&self) -> Option<LoadedBank> {
        self.bank.lock().expect("engine state lock").clone()
    }

    /// Give the audio thread a sequence to play.
    ///
    /// Warms the presets the sequence will use before handing it over
    /// (`docs/rules/sf2-sampler.md` §9). This is the right moment: the control
    /// thread is here, nothing is playing yet, and the sequence names every
    /// program it will ever select — so the first note of each sound has its
    /// pages already in memory rather than taking a fault on the audio thread.
    pub fn set_sequence(&self, sequence: Sequence) {
        self.warm_presets_of(&sequence);
        let sequence = Arc::new(sequence);
        self.state.lock().expect("engine state lock").sequence = Arc::clone(&sequence);
        self.post(AudioTask::Sequence(sequence));
    }

    /// Touch the sample pages of every program a sequence selects.
    ///
    /// Best effort: a sequence with no bank loaded, or one naming a program the
    /// bank does not have, simply warms less.
    fn warm_presets_of(&self, sequence: &Sequence) {
        let Some(bank) = self.bank_for_render() else {
            return;
        };
        // A tune uses a handful of programs, so a small scan beats a set.
        let mut warmed: Vec<usize> = Vec::new();
        for event in sequence.events() {
            let EventKind::Program {
                bank: bank_number,
                program,
            } = event.kind
            else {
                continue;
            };
            let Some(preset) = bank.find_preset_or_fallback(bank_number, program) else {
                continue;
            };
            if warmed.contains(&preset) {
                continue;
            }
            warmed.push(preset);
            bank.warm_preset(preset);
        }
    }

    /// The bank, for an offline render.
    pub fn bank_for_render(&self) -> Option<Arc<SoundBank>> {
        self.state.lock().expect("engine state lock").bank.clone()
    }

    /// The sequence, for an offline render.
    pub fn sequence_for_render(&self) -> Sequence {
        (*self.state.lock().expect("engine state lock").sequence).clone()
    }

    /// The mixer, for an offline render: per-channel volume, pan and mute,
    /// and the master gain.
    pub fn mix_for_render(&self) -> ([(f32, f32, bool); CHANNEL_COUNT], f32) {
        let state = self.state.lock().expect("engine state lock");
        (state.channels, state.master_gain)
    }

    /// How many events the sequence currently loaded holds.
    pub fn sequence_length(&self) -> (usize, u64) {
        let state = self.state.lock().expect("engine state lock");
        (state.sequence.len(), state.sequence.length_ticks())
    }

    /// Set a channel's level, position and mute.
    ///
    /// A channel outside 0–15 is ignored. The event path rejects those with an
    /// error (`api::audio::MidiEvent::to_timed`), and this path used to wrap
    /// them with a modulo — so asking for channel 16 quietly reset channel 0's
    /// level instead. Silently moving a fader the caller did not name is worse
    /// than doing nothing, and this signature has no way to say "no".
    pub fn set_channel_mix(&self, channel: u8, volume: f32, pan: f32, muted: bool) {
        let index = usize::from(channel);
        if index >= CHANNEL_COUNT {
            return;
        }
        let volume = volume.clamp(0.0, 1.0);
        let pan = pan.clamp(-1.0, 1.0);
        self.state.lock().expect("engine state lock").channels[index] = (volume, pan, muted);
        #[allow(clippy::cast_possible_truncation)]
        self.post(AudioTask::ChannelMix(index as u8, volume, pan, muted));
    }

    /// Set the master level.
    pub fn set_master_gain(&self, gain: f32) {
        let gain = gain.clamp(0.0, 1.0);
        self.state.lock().expect("engine state lock").master_gain = gain;
        self.post(AudioTask::MasterGain(gain));
    }

    /// Stop every note at once.
    pub fn panic(&self) {
        self.post(AudioTask::Panic);
    }

    /// Post work to the audio thread.
    ///
    /// With no stream open there is nothing to post to; the state is kept, and
    /// opening a stream replays it.
    ///
    /// A full queue is a different matter: `EngineState` has already recorded
    /// the change, so dropping the task silently leaves the engine claiming a
    /// setting the audio thread was never told about — a muted channel that
    /// still sounds, with nothing anywhere to explain it. The queue is 256
    /// deep and drained every block, so this should be unreachable; if it ever
    /// is reached it is said out loud rather than swallowed.
    fn post(&self, task: AudioTask) {
        if let Some(sender) = self.tasks.lock().expect("engine state lock").as_ref() {
            if let Err(error) = sender.try_send(task) {
                eprintln!(
                    "bandstand: the audio thread task queue is full; \
                     a mixer or sequence change was dropped ({error})"
                );
            }
        }
    }

    /// Re-post what changed in [`EngineState`] since `before`, onto a freshly
    /// opened stream.
    ///
    /// [`Self::open`] replays a snapshot taken before the swap, and anything
    /// posted in between went nowhere — there was no sender to take it. This
    /// closes that window (L-RH4).
    ///
    /// The state lock is held across both the diff and the send: every poster
    /// writes the state *before* it posts, so a concurrent post has either
    /// finished before this diff ran — its change is re-posted here — or it
    /// queues behind this lock and then finds the new sender installed.
    /// Either way the audio thread ends on the final state, and no queue
    /// ordering can put an older value after a newer one.
    ///
    /// The float diffs are bit-wise on purpose: an epsilon compare would
    /// re-send nothing for a change smaller than the epsilon. Bits are
    /// exact, and the values here are the ones the setters wrote.
    fn repost_delta(&self, before: &EngineState, sender: &TaskSender) {
        let state = self.state.lock().expect("engine state lock");
        if state.bank.as_ref().map(Arc::as_ptr) != before.bank.as_ref().map(Arc::as_ptr) {
            let _ = sender.try_send(AudioTask::Bank(state.bank.clone()));
        }
        if !Arc::ptr_eq(&state.sequence, &before.sequence) {
            let _ = sender.try_send(AudioTask::Sequence(Arc::clone(&state.sequence)));
        }
        if state.master_gain.to_bits() != before.master_gain.to_bits() {
            let _ = sender.try_send(AudioTask::MasterGain(state.master_gain));
        }
        for index in 0..CHANNEL_COUNT {
            let (volume, pan, muted) = state.channels[index];
            let (was_volume, was_pan, was_muted) = before.channels[index];
            if volume.to_bits() != was_volume.to_bits()
                || pan.to_bits() != was_pan.to_bits()
                || muted != was_muted
            {
                #[allow(clippy::cast_possible_truncation)]
                let _ = sender.try_send(AudioTask::ChannelMix(index as u8, volume, pan, muted));
            }
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
                    sequencer: Sequencer::new(Arc::new(Sequence::empty())),
                    synth: Synth::new(48_000.0, 1024, DEFAULT_MAX_VOICES),
                    tone: TestTone::new(48_000.0),
                    controls: Arc::clone(tone),
                    tasks: task_receiver,
                    pending: Vec::with_capacity(1024),
                    last_state: PlayState::Stopped,
                    sample_rate: 48_000.0,
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

/// The output devices the platform offers.
///
/// # Errors
/// Returns a human-readable message if the platform cannot be queried.
pub fn output_devices() -> Result<Vec<OutputDeviceInfo>, String> {
    list_output_devices().map_err(|e| e.to_string())
}

#[cfg(test)]
// These tests assert the exact values the code produces — a silence that is
// zero, a gain that is one — so comparing floats is the point rather than a
// mistake. Casts in test arithmetic are likewise deliberate.
#[allow(
    clippy::float_cmp,
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    clippy::cast_precision_loss
)]
mod tests {
    use super::*;
    use bandstand_transport::{PlayState, TempoMap};

    /// Build the renderer the audio callback runs, without opening a device.
    fn renderer(
        handle: &TransportHandle,
        controls: &Arc<ToneControls>,
    ) -> (BandstandRenderer, TaskSender) {
        let (sender, receiver) = mpsc::sync_channel::<AudioTask>(64);
        let mut renderer = BandstandRenderer {
            transport: handle.create_audio_side(),
            sequencer: Sequencer::new(Arc::new(Sequence::empty())),
            synth: Synth::new(48_000.0, 256, 64),
            tone: TestTone::new(48_000.0),
            controls: Arc::clone(controls),
            tasks: receiver,
            pending: Vec::with_capacity(256),
            last_state: PlayState::Stopped,
            sample_rate: 48_000.0,
        };
        renderer.prepare(&StreamContext {
            sample_rate: 48_000.0,
            channels: 2,
            max_block_frames: 256,
        });
        (renderer, sender)
    }

    fn render_block(
        renderer: &mut BandstandRenderer,
        frames: usize,
        host_time_ns: u64,
    ) -> Vec<f32> {
        let mut buffer = vec![0.0f32; frames * 2];
        renderer.render(
            &mut buffer,
            &BlockContext {
                frames,
                channels: 2,
                host_time_ns,
            },
        );
        buffer
    }

    fn peak(buffer: &[f32]) -> f32 {
        buffer.iter().fold(0.0f32, |acc, s| acc.max(s.abs()))
    }

    #[test]
    fn renderer_is_silent_until_the_tone_is_switched_on() {
        let handle = TransportHandle::new(TempoMap::default());
        let controls = Arc::new(ToneControls::new());
        let (mut renderer, _sender) = renderer(&handle, &controls);
        assert!(peak(&render_block(&mut renderer, 256, 0)) < f32::EPSILON);
    }

    #[test]
    fn renderer_produces_the_test_tone() {
        let handle = TransportHandle::new(TempoMap::default());
        let controls = Arc::new(ToneControls::new());
        let (mut renderer, _sender) = renderer(&handle, &controls);
        controls.set(true, 440.0, 0.5);
        let mut loudest = 0.0f32;
        for block in 0..187u64 {
            loudest = loudest.max(peak(&render_block(&mut renderer, 256, block * 5_333_333)));
        }
        assert!(loudest > 0.4 && loudest <= 0.5 + 1e-6, "peak {loudest}");
    }

    #[test]
    fn renderer_advances_and_publishes_the_playhead() {
        let handle = TransportHandle::new(TempoMap::constant(960, 120.0).unwrap());
        let controls = Arc::new(ToneControls::new());
        let (mut renderer, _sender) = renderer(&handle, &controls);

        handle.play();
        const BLOCKS: u64 = 24_000 / 256;
        for block in 0..BLOCKS {
            render_block(&mut renderer, 256, block);
        }
        let position = handle.position();
        assert_eq!(position.state, PlayState::Playing);
        // The published tick is the *start* of the most recent block, so after
        // `BLOCKS` blocks it reports `BLOCKS - 1` blocks' worth of time.
        #[allow(clippy::cast_precision_loss)]
        let elapsed_seconds = ((BLOCKS - 1) * 256) as f64 / 48_000.0;
        let expected = handle.tempo_map().tick_at_seconds(elapsed_seconds);
        assert!(
            (position.tick - expected).abs() < 1.0,
            "tick {} expected {expected}",
            position.tick
        );
    }

    #[test]
    fn tone_changes_do_not_step_the_signal() {
        let handle = TransportHandle::new(TempoMap::default());
        let controls = Arc::new(ToneControls::new());
        let (mut renderer, _sender) = renderer(&handle, &controls);
        controls.set(true, 440.0, 1.0);
        let first = render_block(&mut renderer, 64, 0);
        assert!(peak(&first) < 0.5, "peak {}", peak(&first));
    }

    #[test]
    fn a_sequence_with_no_bank_renders_silence_rather_than_failing() {
        let handle = TransportHandle::new(TempoMap::constant(960, 120.0).unwrap());
        let controls = Arc::new(ToneControls::new());
        let (mut renderer, sender) = renderer(&handle, &controls);

        sender
            .try_send(AudioTask::Sequence(Arc::new(Sequence::new(
                vec![
                    TimedEvent::note_on(0, 0, 60, 100),
                    TimedEvent::note_off(480, 0, 60),
                ],
                960,
                960,
            ))))
            .expect("the queue has room");
        handle.play();
        for block in 0..40u64 {
            assert!(peak(&render_block(&mut renderer, 256, block)) < f32::EPSILON);
        }
    }

    #[test]
    fn engine_state_replays_onto_a_fresh_audio_thread() {
        let mut state = EngineState::new();
        state.master_gain = 0.9;
        state.channels[3] = (0.25, -0.5, true);
        let tasks = state.as_tasks();
        // A bank, a sequence, a master gain, and one per channel.
        assert_eq!(tasks.len(), CHANNEL_COUNT + 3);
        assert!(tasks.iter().any(|task| matches!(
            task,
            AudioTask::ChannelMix(3, v, p, true) if (*v - 0.25).abs() < 1e-6 && (*p + 0.5).abs() < 1e-6
        )));
        assert!(tasks
            .iter()
            .any(|task| matches!(task, AudioTask::MasterGain(g) if (*g - 0.9).abs() < 1e-6)));
    }

    #[test]
    fn an_engine_whose_thread_never_started_errors_instead_of_panicking() {
        // What a failed spawn leaves behind: the command sender, with the
        // receiver dropped. `AudioEngine::new` now degrades to exactly this
        // instead of panicking across the FFI.
        let (commands, receiver) = mpsc::sync_channel::<Command>(16);
        drop(receiver);
        let engine = AudioEngine {
            commands,
            transport: Mutex::new(TransportHandle::new(TempoMap::default())),
            tone: Arc::new(ToneControls::new()),
            current: Mutex::new(None),
            tasks: Mutex::new(None),
            state: Mutex::new(EngineState::new()),
            bank: Mutex::new(None),
        };
        assert!(engine.open(StreamOptions::default()).is_err());
        assert!(engine.stats().is_none());
        assert!(engine.current_stream().is_none());
        // Posts into the void must be no-ops, not panics.
        engine.set_channel_mix(0, 0.5, 0.0, false);
        engine.set_master_gain(0.5);
        engine.panic();
        engine.close();
    }

    #[test]
    fn posts_that_land_while_an_open_is_in_flight_are_re_posted() {
        // The heart of L-RH4 without needing a device: the delta between the
        // snapshot a fresh stream replayed and the state as it now stands is
        // posted onto the new stream's queue — and nothing else is.
        let (commands, _receiver) = mpsc::sync_channel::<Command>(16);
        let engine = AudioEngine {
            commands,
            transport: Mutex::new(TransportHandle::new(TempoMap::default())),
            tone: Arc::new(ToneControls::new()),
            current: Mutex::new(None),
            tasks: Mutex::new(None),
            state: Mutex::new(EngineState::new()),
            bank: Mutex::new(None),
        };
        let before = EngineState::new();
        // What `set_master_gain`, `set_channel_mix` and `set_sequence` would
        // have recorded while the open was in flight.
        {
            let mut state = engine.state.lock().expect("engine state lock");
            state.master_gain = 0.25;
            state.channels[7] = (0.5, -0.25, true);
            state.sequence = Arc::new(Sequence::empty());
        }
        let (sender, receiver) = mpsc::sync_channel::<AudioTask>(64);
        engine.repost_delta(&before, &sender);
        let delivered: Vec<AudioTask> = receiver.try_iter().collect();
        // Exactly the three changes: no bank task, no untouched channel.
        assert_eq!(delivered.len(), 3);
        assert!(delivered.iter().any(|task| matches!(
            task,
            AudioTask::MasterGain(gain) if (*gain - 0.25).abs() < 1e-6
        )));
        assert!(delivered.iter().any(|task| matches!(
            task,
            AudioTask::ChannelMix(7, volume, pan, true)
                if (*volume - 0.5).abs() < 1e-6 && (*pan + 0.25).abs() < 1e-6
        )));
        assert!(delivered
            .iter()
            .any(|task| matches!(task, AudioTask::Sequence(_))));
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
                #[allow(clippy::cast_possible_truncation)]
                let channel = (i % 16) as u8;
                AudioEngine::instance().set_channel_mix(channel, i as f32 / 200.0, 0.0, i % 2 == 0);
                AudioEngine::instance().set_master_gain(0.25);
            }
        });
        for _ in 0..10 {
            assert!(engine.open(StreamOptions::default()).is_ok());
        }
        poster.join().expect("the posting thread finishes");
        let (_, master) = engine.mix_for_render();
        assert!((master - 0.25).abs() < 1e-6);
        engine.close();
    }
}
