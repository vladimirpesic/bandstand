//! The synthesiser: channels, voice allocation, and the mix.
//!
//! Rules: `docs/rules/sf2-sampler.md` §5 and §6.

use std::sync::Arc;

use crate::effects::{Chorus, Reverb};
use crate::sf2::{SoundBank, VoiceRecipe};
use crate::voice::{ChannelMix, Voice, VoiceSettings};

/// How many MIDI channels there are.
pub const CHANNEL_COUNT: usize = 16;

/// The channel General MIDI reserves for percussion.
pub const DRUM_CHANNEL: u8 = 9;

/// The bank number a General MIDI soundfont keeps its drum kits in.
pub const DRUM_BANK: u16 = 128;

/// How many voices the pool holds by default.
///
/// §7.2 asks for a polyphony cap with a sensible stealing policy. Two hundred
/// is far above what a five-piece rhythm section needs, and one note can start
/// several voices (`docs/rules/sf2-sampler.md` §2), so the pool has to be
/// bigger than the polyphony a user would name.
pub const DEFAULT_MAX_VOICES: usize = 200;

/// What one MIDI channel is set to.
#[derive(Debug, Clone, Copy)]
pub struct ChannelState {
    /// Selected bank.
    pub bank: u16,
    /// Selected program.
    pub program: u16,
    /// Which preset that resolved to, if the bank has one.
    pub preset: Option<usize>,
    /// Channel volume, 0 to 1.
    pub volume: f32,
    /// Channel pan, −1 to 1.
    pub pan: f32,
    /// Channel expression, 0 to 1, which multiplies volume.
    pub expression: f32,
    /// Whether the sustain pedal is down.
    pub sustain: bool,
    /// Pitch bend, −1 to 1, covering the bend range.
    pub bend: f32,
    /// How far a full bend goes, in semitones.
    pub bend_range: f32,
    /// Whether the channel is silenced by the mixer.
    pub muted: bool,
}

impl ChannelState {
    /// A channel as it is after a reset.
    #[must_use]
    pub const fn new(channel: u8) -> Self {
        Self {
            bank: if channel == DRUM_CHANNEL {
                DRUM_BANK
            } else {
                0
            },
            program: 0,
            preset: None,
            volume: 100.0 / 127.0,
            pan: 0.0,
            expression: 1.0,
            sustain: false,
            bend: 0.0,
            bend_range: 2.0,
            muted: false,
        }
    }

    /// The gain this channel applies, before the master.
    #[must_use]
    pub fn gain(&self) -> f32 {
        if self.muted {
            0.0
        } else {
            self.volume * self.expression
        }
    }

    /// What this channel contributes to every voice on it.
    #[must_use]
    pub fn mix(&self) -> ChannelMix {
        // Equal power, and scaled so a centred channel is unity rather than
        // 0.707 — a channel's pan trims a voice's, it does not attenuate it.
        let angle = (self.pan + 1.0) * std::f32::consts::FRAC_PI_4;
        let scale = std::f32::consts::SQRT_2;
        ChannelMix {
            gain: self.gain(),
            pan_left: angle.cos() * scale,
            pan_right: angle.sin() * scale,
            pitch_ratio: f64::from(2.0f32.powf(self.bend * self.bend_range / 12.0)),
        }
    }
}

/// The sampler.
///
/// Owned by the audio thread. Loading a bank happens elsewhere and is handed
/// over whole; nothing here allocates once it is running.
pub struct Synth {
    bank: Option<Arc<SoundBank>>,
    channels: [ChannelState; CHANNEL_COUNT],
    voices: Vec<Voice>,
    max_voices: usize,
    sample_rate: f32,
    next_age: u64,
    reverb: Reverb,
    chorus: Chorus,
    /// Scratch buffers, allocated once.
    left: Vec<f32>,
    right: Vec<f32>,
    reverb_send: Vec<f32>,
    chorus_send: Vec<f32>,
    /// Where a note-on resolves its recipes, reused every call. Pre-sized in
    /// [`Self::new`] so the first deep zone match does not allocate there.
    recipe_buffer: Vec<VoiceRecipe>,
    /// Keys that received note-off while a channel's sustain pedal was down,
    /// one bit per key, released when the pedal comes up.
    sustain_released: [u128; CHANNEL_COUNT],
    master_gain: f32,
}

impl Synth {
    /// Create a synth for an output rate and a maximum block size.
    ///
    /// Every buffer it will ever need is allocated here.
    #[must_use]
    pub fn new(sample_rate: f32, max_block_frames: usize, max_voices: usize) -> Self {
        let block = max_block_frames.max(64);
        Self {
            bank: None,
            channels: std::array::from_fn(|i| {
                #[allow(clippy::cast_possible_truncation)]
                ChannelState::new(i as u8)
            }),
            voices: Vec::with_capacity(max_voices),
            max_voices: max_voices.max(1),
            sample_rate: sample_rate.max(1.0),
            next_age: 0,
            reverb: Reverb::new(sample_rate),
            chorus: Chorus::new(sample_rate),
            left: vec![0.0; block],
            right: vec![0.0; block],
            reverb_send: vec![0.0; block],
            chorus_send: vec![0.0; block],
            // Pre-sized for the deepest zone match a real preset offers, so
            // a note-on never grows this on the audio thread. It is a hint,
            // not a cap: a deeper match grows the buffer once and it stays
            // grown (L-RS4).
            recipe_buffer: Vec::with_capacity(32),
            sustain_released: [0; CHANNEL_COUNT],
            master_gain: 0.5,
        }
    }

    /// Install a bank, silencing everything that was playing on the old one.
    ///
    /// A voice holds an `Arc` to the sample data, so a note sounding when the
    /// bank changes would keep playing from a bank nobody can see. Stopping
    /// them is both simpler and what a user expects when they change sound.
    pub fn set_bank(&mut self, bank: Option<Arc<SoundBank>>) {
        self.voices.clear();
        self.sustain_released = [0; CHANNEL_COUNT];
        self.bank = bank;
        for channel in 0..CHANNEL_COUNT {
            self.resolve_preset(channel);
        }
    }

    /// The bank currently loaded.
    #[must_use]
    pub fn bank(&self) -> Option<&Arc<SoundBank>> {
        self.bank.as_ref()
    }

    /// How many voices are sounding.
    #[must_use]
    pub fn active_voices(&self) -> usize {
        self.voices.len()
    }

    /// The most voices that will sound at once.
    #[must_use]
    pub const fn max_voices(&self) -> usize {
        self.max_voices
    }

    /// Read a channel's state.
    #[must_use]
    pub fn channel(&self, channel: u8) -> &ChannelState {
        &self.channels[usize::from(channel) % CHANNEL_COUNT]
    }

    /// Set the master gain, 0 to 1.
    pub fn set_master_gain(&mut self, gain: f32) {
        self.master_gain = gain.clamp(0.0, 1.0);
    }

    /// Set a channel's volume, 0 to 1.
    pub fn set_channel_volume(&mut self, channel: u8, volume: f32) {
        self.channels[usize::from(channel) % CHANNEL_COUNT].volume = volume.clamp(0.0, 1.0);
    }

    /// Set a channel's pan, −1 to 1.
    pub fn set_channel_pan(&mut self, channel: u8, pan: f32) {
        self.channels[usize::from(channel) % CHANNEL_COUNT].pan = pan.clamp(-1.0, 1.0);
    }

    /// Bend a channel's pitch, −1 to 1 across its bend range.
    pub fn set_pitch_bend(&mut self, channel: u8, bend: f32) {
        self.channels[usize::from(channel) % CHANNEL_COUNT].bend = bend.clamp(-1.0, 1.0);
    }

    /// Set how far a full bend goes, in semitones.
    pub fn set_bend_range(&mut self, channel: u8, semitones: f32) {
        self.channels[usize::from(channel) % CHANNEL_COUNT].bend_range = semitones.clamp(0.0, 48.0);
    }

    /// Set a channel's expression, 0 to 1, which multiplies its volume.
    pub fn set_channel_expression(&mut self, channel: u8, expression: f32) {
        self.channels[usize::from(channel) % CHANNEL_COUNT].expression = expression.clamp(0.0, 1.0);
    }

    /// Silence or unsilence a channel.
    pub fn set_channel_muted(&mut self, channel: u8, muted: bool) {
        self.channels[usize::from(channel) % CHANNEL_COUNT].muted = muted;
    }

    /// Select a bank and program on a channel.
    pub fn set_program(&mut self, channel: u8, bank: u16, program: u16) {
        let index = usize::from(channel) % CHANNEL_COUNT;
        self.channels[index].bank = bank;
        self.channels[index].program = program;
        self.resolve_preset(index);
    }

    fn resolve_preset(&mut self, index: usize) {
        let state = self.channels[index];
        self.channels[index].preset = self
            .bank
            .as_ref()
            .and_then(|bank| bank.find_preset_or_fallback(state.bank, state.program));
    }

    /// Start a note.
    ///
    /// A velocity of zero is a note off, as the MIDI specification allows and
    /// as half the files in the world rely on.
    pub fn note_on(&mut self, channel: u8, key: u8, velocity: u8) {
        if velocity == 0 {
            self.note_off(channel, key);
            return;
        }
        let Some(bank) = self.bank.clone() else {
            return;
        };
        let index = usize::from(channel) % CHANNEL_COUNT;
        let bit = 1u128 << u128::from(key);
        if self.sustain_released[index] & bit != 0 {
            // The key went up during sustain and is down again: the voice
            // that note-off left held is superseded — let it go now, and
            // clear the mark so the new voice survives the pedal lifting.
            self.sustain_released[index] &= !bit;
            #[allow(clippy::cast_possible_truncation)]
            let owner = index as u8;
            for voice in &mut self.voices {
                if voice.channel == owner && voice.key == key && voice.is_held() {
                    voice.release();
                }
            }
        }
        let Some(preset) = self.channels[index].preset else {
            return;
        };

        self.recipe_buffer.clear();
        bank.voices_for(preset, key, velocity, &mut self.recipe_buffer);
        for recipe in 0..self.recipe_buffer.len() {
            let Some(settings) = VoiceSettings::resolve(
                &bank,
                &self.recipe_buffer[recipe],
                key,
                velocity,
                self.sample_rate,
            ) else {
                continue;
            };

            // An exclusive class cuts the others off *before* the new voice is
            // made, so a hi-hat does not briefly play both.
            if settings.exclusive_class != 0 {
                let class = settings.exclusive_class;
                #[allow(clippy::cast_possible_truncation)]
                let owner = index as u8;
                for voice in &mut self.voices {
                    if voice.channel == owner && voice.exclusive_class() == class {
                        voice.cut();
                    }
                }
            }

            if self.voices.len() >= self.max_voices && !self.steal() {
                return;
            }
            let age = self.next_age;
            self.next_age += 1;
            #[allow(clippy::cast_possible_truncation)]
            let owner = index as u8;
            self.voices.push(Voice::start(
                settings,
                Arc::clone(&bank.data),
                owner,
                key,
                age,
                self.sample_rate,
            ));
        }
    }

    /// Let a note go.
    pub fn note_off(&mut self, channel: u8, key: u8) {
        let index = usize::from(channel) % CHANNEL_COUNT;
        if self.channels[index].sustain {
            // Swallowed, but remembered: the voice releases when the pedal
            // comes up, not while other keys are still held.
            self.sustain_released[index] |= 1u128 << u128::from(key);
            return;
        }
        #[allow(clippy::cast_possible_truncation)]
        let owner = index as u8;
        for voice in &mut self.voices {
            if voice.channel == owner && voice.key == key && voice.is_held() {
                voice.release();
            }
        }
    }

    /// Put the sustain pedal down or up.
    pub fn set_sustain(&mut self, channel: u8, down: bool) {
        let index = usize::from(channel) % CHANNEL_COUNT;
        self.channels[index].sustain = down;
        if down {
            return;
        }
        let released = std::mem::take(&mut self.sustain_released[index]);
        if released == 0 {
            return;
        }
        #[allow(clippy::cast_possible_truncation)]
        let owner = index as u8;
        for voice in &mut self.voices {
            if voice.channel == owner
                && voice.is_held()
                && released & (1u128 << u128::from(voice.key)) != 0
            {
                voice.release();
            }
        }
    }

    /// Stop every note on a channel at once.
    pub fn all_notes_off(&mut self, channel: u8) {
        let index = usize::from(channel) % CHANNEL_COUNT;
        self.sustain_released[index] = 0;
        #[allow(clippy::cast_possible_truncation)]
        let owner = index as u8;
        for voice in &mut self.voices {
            if voice.channel == owner {
                voice.release();
            }
        }
    }

    /// Stop everything, everywhere, and clear the effects.
    ///
    /// What a transport stop does. Voices are cut rather than released, because
    /// a stop that rings on for two seconds is not a stop.
    pub fn reset(&mut self) {
        for voice in &mut self.voices {
            voice.cut();
        }
        self.sustain_released = [0; CHANNEL_COUNT];
        self.reverb.clear();
        self.chorus.clear();
    }

    /// Stop everything immediately, including the effects tails.
    pub fn panic(&mut self) {
        self.voices.clear();
        self.sustain_released = [0; CHANNEL_COUNT];
        self.reverb.clear();
        self.chorus.clear();
        for channel in &mut self.channels {
            channel.sustain = false;
        }
    }

    /// The reverb, for setting its size and level.
    pub fn reverb_mut(&mut self) -> &mut Reverb {
        &mut self.reverb
    }

    /// The chorus, for setting its depth and level.
    pub fn chorus_mut(&mut self) -> &mut Chorus {
        &mut self.chorus
    }

    /// Free a voice, by the policy in `docs/rules/sf2-sampler.md` §5.
    ///
    /// Returns whether one was freed. A voice started in this block is never
    /// stolen: a note cut before it is heard costs the CPU and gives nothing.
    fn steal(&mut self) -> bool {
        // 1. Anything finished.
        if let Some(index) = self.voices.iter().position(|v| !v.is_active()) {
            self.voices.remove(index);
            return true;
        }
        // 2. The oldest voice already in release.
        let releasing = self
            .voices
            .iter()
            .enumerate()
            .filter(|(_, v)| v.is_releasing())
            .min_by_key(|(_, v)| v.age)
            .map(|(i, _)| i);
        if let Some(index) = releasing {
            self.voices.remove(index);
            return true;
        }
        // 3. The quietest.
        let quietest = self
            .voices
            .iter()
            .enumerate()
            .min_by(|(_, a), (_, b)| {
                a.level()
                    .partial_cmp(&b.level())
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
            .map(|(i, _)| i);
        if let Some(index) = quietest {
            self.voices.remove(index);
            return true;
        }
        false
    }

    /// Render one block into an interleaved stereo buffer.
    ///
    /// The buffer is *added to*, not overwritten, so the synth can share a bus.
    /// Allocation-free: everything it uses was allocated in [`Synth::new`].
    pub fn render(&mut self, output: &mut [f32], channels: usize) {
        if channels == 0 || output.is_empty() {
            return;
        }
        let frames = output.len() / channels;
        if frames == 0 {
            return;
        }
        if self.left.len() < frames {
            // A backend asking for more than it promised. Grow once; from then
            // on the buffers are big enough.
            self.left.resize(frames, 0.0);
            self.right.resize(frames, 0.0);
            self.reverb_send.resize(frames, 0.0);
            self.chorus_send.resize(frames, 0.0);
        }

        let left = &mut self.left[..frames];
        let right = &mut self.right[..frames];
        let reverb_send = &mut self.reverb_send[..frames];
        let chorus_send = &mut self.chorus_send[..frames];
        left.fill(0.0);
        right.fill(0.0);
        reverb_send.fill(0.0);
        chorus_send.fill(0.0);

        // A channel's contribution is worked out once a block, not once a
        // voice: it does not change inside one.
        let mixes: [ChannelMix; CHANNEL_COUNT] = std::array::from_fn(|i| self.channels[i].mix());
        for voice in &mut self.voices {
            let mix = mixes[usize::from(voice.channel) % CHANNEL_COUNT];
            voice.render(left, right, reverb_send, chorus_send, mix);
        }
        self.voices.retain(Voice::is_active);

        self.reverb.process(reverb_send, left, right);
        self.chorus.process(chorus_send, left, right);

        for frame in 0..frames {
            let l = left[frame] * self.master_gain;
            let r = right[frame] * self.master_gain;
            let base = frame * channels;
            if channels == 1 {
                output[base] += (l + r) * 0.5;
            } else {
                output[base] += l;
                output[base + 1] += r;
                for extra in 2..channels {
                    output[base + extra] += (l + r) * 0.5;
                }
            }
        }
    }
}

impl std::fmt::Debug for Synth {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Synth")
            .field("bank", &self.bank.as_ref().map(|b| &b.name))
            .field("voices", &self.voices.len())
            .field("max_voices", &self.max_voices)
            .finish_non_exhaustive()
    }
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
    use crate::sf2::{
        ByteRange, GeneratorSet, Instrument, Preset, ResidentSamples, SampleHeader, Zone,
    };

    #[test]
    fn a_fresh_channel_is_what_a_reset_leaves() {
        let melodic = ChannelState::new(0);
        assert_eq!(melodic.bank, 0);
        assert_eq!(melodic.program, 0);
        assert!(!melodic.muted);
        // General MIDI puts percussion on channel 10, which is index 9, and
        // every GM soundfont keeps its kits in bank 128.
        assert_eq!(ChannelState::new(DRUM_CHANNEL).bank, DRUM_BANK);
    }

    #[test]
    fn a_muted_channel_contributes_no_gain() {
        let mut channel = ChannelState::new(0);
        channel.volume = 1.0;
        assert!((channel.gain() - 1.0).abs() < 1e-6);
        channel.muted = true;
        assert_eq!(channel.gain(), 0.0);
        assert_eq!(channel.mix().gain, 0.0);
    }

    #[test]
    fn expression_multiplies_volume() {
        let mut channel = ChannelState::new(0);
        channel.volume = 0.5;
        channel.expression = 0.5;
        assert!((channel.gain() - 0.25).abs() < 1e-6);
    }

    #[test]
    fn a_centred_pan_is_unity_on_both_sides() {
        let channel = ChannelState::new(0);
        let mix = channel.mix();
        assert!((mix.pan_left - 1.0).abs() < 1e-5, "{}", mix.pan_left);
        assert!((mix.pan_right - 1.0).abs() < 1e-5, "{}", mix.pan_right);
    }

    #[test]
    fn panning_hard_silences_the_other_side() {
        let mut channel = ChannelState::new(0);
        channel.pan = -1.0;
        let left = channel.mix();
        assert!(left.pan_left > 1.3, "{}", left.pan_left);
        assert!(left.pan_right.abs() < 1e-5, "{}", left.pan_right);

        channel.pan = 1.0;
        let right = channel.mix();
        assert!(right.pan_right > 1.3);
        assert!(right.pan_left.abs() < 1e-5);
    }

    #[test]
    fn pitch_bend_is_two_to_the_semitones_over_twelve() {
        let mut channel = ChannelState::new(0);
        channel.bend_range = 2.0;

        assert!((channel.mix().pitch_ratio - 1.0).abs() < 1e-9);

        channel.bend = 1.0;
        // A whole tone up.
        assert!(
            (channel.mix().pitch_ratio - 2.0f64.powf(2.0 / 12.0)).abs() < 1e-6,
            "{}",
            channel.mix().pitch_ratio
        );

        channel.bend = -1.0;
        assert!((channel.mix().pitch_ratio - 2.0f64.powf(-2.0 / 12.0)).abs() < 1e-6);

        channel.bend_range = 12.0;
        channel.bend = 1.0;
        assert!((channel.mix().pitch_ratio - 2.0).abs() < 1e-6);
    }

    #[test]
    fn a_synth_with_no_bank_answers_without_panicking() {
        let mut synth = Synth::new(48_000.0, 256, 32);
        synth.set_program(0, 0, 40);
        synth.note_on(0, 60, 100);
        synth.note_off(0, 60);
        synth.set_sustain(0, true);
        synth.all_notes_off(0);
        synth.reset();
        synth.panic();
        assert_eq!(synth.active_voices(), 0);

        let mut buffer = vec![0.0f32; 512];
        synth.render(&mut buffer, 2);
        assert!(buffer.iter().all(|value| *value == 0.0));
    }

    #[test]
    fn channel_numbers_wrap_rather_than_panicking() {
        let mut synth = Synth::new(48_000.0, 256, 32);
        // A malformed file can carry a channel above fifteen; wrapping is what
        // every other synth does with it, and it must not be a crash.
        synth.set_channel_volume(200, 0.5);
        assert!((synth.channel(200).volume - 0.5).abs() < 1e-6);
        assert!((synth.channel(200 % 16).volume - 0.5).abs() < 1e-6);
    }

    #[test]
    fn rendering_nothing_is_not_an_error() {
        let mut synth = Synth::new(48_000.0, 256, 32);
        let mut empty: Vec<f32> = Vec::new();
        synth.render(&mut empty, 2);
        let mut buffer = vec![0.0f32; 16];
        synth.render(&mut buffer, 0);
        assert!(buffer.iter().all(|value| *value == 0.0));
    }

    /// A bank whose one zone answers every note with one sample.
    fn one_voice_bank() -> Arc<SoundBank> {
        let zone = Zone {
            key_range: ByteRange::FULL,
            velocity_range: ByteRange::FULL,
            generators: GeneratorSet::defaults(),
            target: 0,
        };
        Arc::new(SoundBank {
            name: "test".to_owned(),
            presets: vec![Preset {
                name: "preset".to_owned(),
                bank: 0,
                program: 0,
                zones: vec![zone.clone()],
            }],
            instruments: vec![Instrument {
                name: "instrument".to_owned(),
                zones: vec![zone],
            }],
            samples: vec![SampleHeader {
                name: "sample".to_owned(),
                start: 0,
                end: 1_000,
                loop_start: 0,
                loop_end: 0,
                sample_rate: 44_100,
                original_pitch: 60,
                pitch_correction: 0,
                link: 0,
                sample_type: 1,
            }],
            data: Arc::new(ResidentSamples::new(vec![0; 1_000])),
        })
    }

    fn synth_with_bank() -> Synth {
        let mut synth = Synth::new(48_000.0, 256, 32);
        synth.set_bank(Some(one_voice_bank()));
        synth.set_program(0, 0, 0);
        synth
    }

    #[test]
    fn the_pedal_releases_only_keys_that_went_up_during_it() {
        let mut synth = synth_with_bank();
        synth.note_on(0, 60, 100);
        synth.note_on(0, 64, 100);
        synth.set_sustain(0, true);
        synth.note_off(0, 60);
        synth.set_sustain(0, false);

        let held: Vec<u8> = synth
            .voices
            .iter()
            .filter(|voice| voice.is_held())
            .map(|voice| voice.key)
            .collect();
        assert_eq!(held, vec![64], "a still-held key was cut by the pedal");
    }

    #[test]
    fn a_pedal_tap_leaves_held_notes_sounding() {
        let mut synth = synth_with_bank();
        for key in [60u8, 67, 72] {
            synth.note_on(0, key, 100);
        }
        // Down and up again while every key is held: nothing was released
        // during the pedal, so nothing may stop when it lifts.
        synth.set_sustain(0, true);
        synth.set_sustain(0, false);
        assert_eq!(
            synth.voices.iter().filter(|voice| voice.is_held()).count(),
            3,
            "the pedal's release cut notes whose keys are still down"
        );

        for key in [60u8, 67, 72] {
            synth.note_off(0, key);
        }
        assert!(
            synth.voices.iter().all(|voice| !voice.is_held()),
            "a note-off after the pedal did not end the note"
        );
    }

    #[test]
    fn a_key_replayed_during_sustain_survives_the_pedal() {
        let mut synth = synth_with_bank();
        synth.note_on(0, 60, 100);
        synth.set_sustain(0, true);
        synth.note_off(0, 60);
        // The key is down again: the voice the earlier note-off left held is
        // superseded, and the new one must not die when the pedal lifts.
        synth.note_on(0, 60, 100);
        synth.set_sustain(0, false);
        assert_eq!(
            synth.voices.iter().filter(|voice| voice.is_held()).count(),
            1
        );
    }
}
