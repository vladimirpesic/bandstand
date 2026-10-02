//! Rendering a sequence to a file, with no audio device involved.
//!
//! §3 lists `render_offline` on the bridge surface, for bouncing. It is also
//! how the M4 acceptance test is run: rendering the same MIDI through Bandstand
//! and through FluidSynth and comparing the two needs a file, not a speaker.

use std::fs::File;
use std::io::{BufWriter, Write};
use std::path::Path;
use std::sync::Arc;

use bandstand_sequencer::{EventKind, Sequence, Sequencer, TimedEvent};
use bandstand_synth::{SoundBank, Synth, CHANNEL_COUNT, DEFAULT_MAX_VOICES};
use bandstand_transport::{TempoMap, Transport};

/// How many frames are rendered between checks. Nothing depends on this but
/// the shape of the work.
const BLOCK: usize = 512;

/// How long to keep rendering after the last event, for tails to decay.
const TAIL_SECONDS: f64 = 3.0;

/// The lowest rate the DSP renders at. Anything below this used to be clamped
/// for the synth but written raw into the WAV header, so the file played at
/// the wrong speed; it is now refused instead.
pub(crate) const MIN_SAMPLE_RATE: u32 = 8000;

/// A bounce that could not be written.
#[derive(Debug)]
pub enum RenderError {
    /// The file could not be created or written.
    Io(String),
    /// The sequence was empty.
    NothingToRender,
    /// The sample rate is below what the synth renders at.
    SampleRateTooLow { sample_rate: u32 },
    /// The render is larger than a canonical WAV file can describe.
    TooLarge { bytes: u64 },
}

impl std::fmt::Display for RenderError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Io(message) => write!(f, "could not write the file: {message}"),
            Self::NothingToRender => write!(f, "the sequence is empty"),
            Self::SampleRateTooLow { sample_rate } => {
                write!(f, "sample rate {sample_rate} is below {MIN_SAMPLE_RATE}")
            }
            Self::TooLarge { bytes } => {
                write!(
                    f,
                    "the render is {bytes} bytes, beyond what a WAV file holds"
                )
            }
        }
    }
}

impl std::error::Error for RenderError {}

/// What a bounce produced.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RenderSummary {
    /// How many frames were written.
    pub frames: u64,
    /// The rate they were written at.
    pub sample_rate: u32,
    /// How many channels.
    pub channels: u16,
    /// How many samples were clipped on the way out.
    ///
    /// Non-zero means the mix was too loud; the file is still correct, but the
    /// user needs to know rather than wonder why it sounds hard.
    pub clipped: u64,
}

impl RenderSummary {
    /// How long the file lasts, in seconds.
    #[must_use]
    pub fn duration_seconds(&self) -> f64 {
        if self.sample_rate == 0 {
            0.0
        } else {
            #[allow(clippy::cast_precision_loss)]
            {
                self.frames as f64 / f64::from(self.sample_rate)
            }
        }
    }
}

/// Render `sequence` through `bank` to a 16-bit stereo WAV file.
///
/// Runs as fast as the machine allows: there is no device and no clock, just
/// blocks. The per-channel `volume`/`pan`/`muted` settings and the
/// `master_gain` are applied, so a bounce reflects what the live mix would
/// sound like — a muted channel is silent in the file.
///
/// # Errors
/// Returns [`RenderError`] if the sequence is empty, the sample rate is below
/// [`MIN_SAMPLE_RATE`], the render is larger than a WAV file can describe, or
/// the file cannot be written.
pub fn render_to_wav(
    path: &Path,
    bank: Arc<SoundBank>,
    sequence: &Sequence,
    tempo_map: &TempoMap,
    sample_rate: u32,
    master_gain: f32,
    channels: [(f32, f32, bool); CHANNEL_COUNT],
) -> Result<RenderSummary, RenderError> {
    if sequence.is_empty() {
        return Err(RenderError::NothingToRender);
    }
    if sample_rate < MIN_SAMPLE_RATE {
        return Err(RenderError::SampleRateTooLow { sample_rate });
    }

    #[allow(clippy::cast_precision_loss)]
    let rate = f64::from(sample_rate);
    #[allow(clippy::cast_possible_truncation)]
    let mut synth = Synth::new(rate as f32, BLOCK, DEFAULT_MAX_VOICES);
    synth.set_bank(Some(bank));
    for (index, &(volume, pan, muted)) in channels.iter().enumerate() {
        #[allow(clippy::cast_possible_truncation)]
        let channel = index as u8;
        synth.set_channel_volume(channel, volume);
        synth.set_channel_pan(channel, pan);
        synth.set_channel_muted(channel, muted);
    }
    synth.set_master_gain(master_gain);

    let mut sequencer = Sequencer::new(Arc::new(sequence.clone()));
    let (mut transport, handle) = Transport::new(tempo_map.clone());
    transport.set_sample_rate(rate);
    handle.play();

    #[allow(clippy::cast_precision_loss)]
    let music_seconds = tempo_map.seconds_at_tick(sequence.length_ticks() as f64);
    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    let total_frames = ((music_seconds + TAIL_SECONDS) * rate).ceil() as u64;

    // A canonical WAV header carries 32-bit lengths, so the file cannot
    // honestly describe more than about four gibibytes — refuse before
    // creating it rather than writing lengths that wrap.
    let bytes_per_frame = 2_u64 * 2; // 16-bit stereo
    let data_bytes = total_frames.saturating_mul(bytes_per_frame);
    if data_bytes > u64::from(u32::MAX - 36) {
        return Err(RenderError::TooLarge {
            bytes: data_bytes.saturating_add(HEADER_BYTES),
        });
    }

    let file = File::create(path).map_err(|e| RenderError::Io(e.to_string()))?;
    let mut writer = BufWriter::new(file);
    write_wav_header(&mut writer, sample_rate, 2, 0)?;

    let mut buffer = vec![0.0f32; BLOCK * 2];
    let mut pending: Vec<(usize, TimedEvent)> = Vec::with_capacity(256);
    let mut written = 0u64;
    let mut clipped = 0u64;

    while written < total_frames {
        #[allow(clippy::cast_possible_truncation)]
        let frames = BLOCK.min((total_frames - written) as usize);
        buffer[..frames * 2].fill(0.0);

        let segments = transport.advance(frames, 0);
        pending.clear();
        {
            let events = &mut pending;
            let mut sink = |frame: usize, event: &TimedEvent| {
                events.push((frame, *event));
            };
            sequencer.process(&segments, tempo_map, rate, &mut sink);
        }

        let mut rendered = 0usize;
        let mut index = 0usize;
        while index < pending.len() {
            let frame = pending[index].0.min(frames);
            if frame > rendered {
                synth.render(&mut buffer[rendered * 2..frame * 2], 2);
                rendered = frame;
            }
            while index < pending.len() && pending[index].0.min(frames) == frame {
                apply(&mut synth, &pending[index].1);
                index += 1;
            }
        }
        if rendered < frames {
            synth.render(&mut buffer[rendered * 2..frames * 2], 2);
        }

        for value in &buffer[..frames * 2] {
            let clean = if value.is_finite() { *value } else { 0.0 };
            if clean > 1.0 || clean < -1.0 {
                clipped += 1;
            }
            #[allow(clippy::cast_possible_truncation)]
            let sample = (clean.clamp(-1.0, 1.0) * 32767.0).round() as i16;
            writer
                .write_all(&sample.to_le_bytes())
                .map_err(|e| RenderError::Io(e.to_string()))?;
        }

        written += frames as u64;
    }

    writer.flush().map_err(|e| RenderError::Io(e.to_string()))?;
    let mut file = writer
        .into_inner()
        .map_err(|e| RenderError::Io(e.to_string()))?;
    // The header was written with a zero length; now that the length is known,
    // go back and put it in.
    rewrite_wav_lengths(&mut file, sample_rate, 2, written)?;

    Ok(RenderSummary {
        frames: written,
        sample_rate,
        channels: 2,
        clipped,
    })
}

fn apply(synth: &mut Synth, event: &TimedEvent) {
    match event.kind {
        EventKind::NoteOn { key, velocity } => synth.note_on(event.channel, key, velocity),
        EventKind::NoteOff { key } => synth.note_off(event.channel, key),
        EventKind::Program { bank, program } => {
            synth.set_program(event.channel, bank, program);
        }
        EventKind::Volume(value) => synth.set_channel_volume(event.channel, value),
        EventKind::Pan(value) => synth.set_channel_pan(event.channel, value),
        EventKind::Expression(value) => synth.set_channel_expression(event.channel, value),
        EventKind::Sustain(down) => synth.set_sustain(event.channel, down),
        EventKind::PitchBend(value) => synth.set_pitch_bend(event.channel, value),
        EventKind::AllNotesOff => synth.all_notes_off(event.channel),
    }
}

/// The size of a canonical WAV header.
const HEADER_BYTES: u64 = 44;

fn write_wav_header(
    writer: &mut impl Write,
    sample_rate: u32,
    channels: u16,
    frames: u64,
) -> Result<(), RenderError> {
    let bytes_per_frame = u64::from(channels) * 2;
    let data_bytes = frames.saturating_mul(bytes_per_frame);
    let byte_rate = u64::from(sample_rate).saturating_mul(bytes_per_frame);
    // Every length field in a canonical header is a u32; refuse sizes that
    // would wrap rather than writing a header that lies.
    if data_bytes > u64::from(u32::MAX - 36) || byte_rate > u64::from(u32::MAX) {
        return Err(RenderError::TooLarge {
            bytes: data_bytes.max(byte_rate),
        });
    }
    let riff_bytes = data_bytes + 36;
    let mut header = Vec::with_capacity(HEADER_BYTES as usize);
    header.extend_from_slice(b"RIFF");
    header.extend_from_slice(&(riff_bytes as u32).to_le_bytes());
    header.extend_from_slice(b"WAVE");
    header.extend_from_slice(b"fmt ");
    header.extend_from_slice(&16u32.to_le_bytes());
    header.extend_from_slice(&1u16.to_le_bytes()); // PCM
    header.extend_from_slice(&channels.to_le_bytes());
    header.extend_from_slice(&sample_rate.to_le_bytes());
    header.extend_from_slice(&(byte_rate as u32).to_le_bytes());
    #[allow(clippy::cast_possible_truncation)]
    header.extend_from_slice(&(bytes_per_frame as u16).to_le_bytes());
    header.extend_from_slice(&16u16.to_le_bytes()); // bits per sample
    header.extend_from_slice(b"data");
    header.extend_from_slice(&(data_bytes as u32).to_le_bytes());
    writer
        .write_all(&header)
        .map_err(|e| RenderError::Io(e.to_string()))
}

fn rewrite_wav_lengths(
    file: &mut File,
    sample_rate: u32,
    channels: u16,
    frames: u64,
) -> Result<(), RenderError> {
    use std::io::{Seek, SeekFrom};
    file.seek(SeekFrom::Start(0))
        .map_err(|e| RenderError::Io(e.to_string()))?;
    write_wav_header(file, sample_rate, channels, frames)?;
    file.flush().map_err(|e| RenderError::Io(e.to_string()))
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
    use bandstand_synth::sf2::{parse_soundfont, ResidentSamples};

    #[test]
    fn an_empty_sequence_is_refused_rather_than_writing_a_silent_file() {
        let path = std::env::temp_dir().join("bandstand-empty-render.wav");
        let result = render_to_wav(
            &path,
            empty_bank(),
            &Sequence::empty(),
            &TempoMap::default(),
            48_000,
            0.5,
            [(1.0, 0.0, false); CHANNEL_COUNT],
        );
        assert!(matches!(result, Err(RenderError::NothingToRender)));
        assert!(!path.exists());
    }

    fn empty_bank() -> Arc<SoundBank> {
        Arc::new(SoundBank {
            name: "empty".to_owned(),
            presets: Vec::new(),
            instruments: Vec::new(),
            samples: Vec::new(),
            data: Arc::new(ResidentSamples::new(Vec::new())),
        })
    }

    fn one_note() -> Sequence {
        Sequence::new(vec![TimedEvent::note_on(0, 0, 60, 100)], 960, 960)
    }

    #[test]
    fn a_sample_rate_below_the_dsp_minimum_is_refused_not_relabelled() {
        let path = std::env::temp_dir().join("bandstand-low-rate-render.wav");
        let result = render_to_wav(
            &path,
            empty_bank(),
            &one_note(),
            &TempoMap::default(),
            4000,
            0.5,
            [(1.0, 0.0, false); CHANNEL_COUNT],
        );
        assert!(matches!(
            result,
            Err(RenderError::SampleRateTooLow { sample_rate: 4000 })
        ));
        assert!(!path.exists(), "no file may be created for a refused rate");
    }

    #[test]
    fn a_render_larger_than_wav_can_describe_is_refused_before_writing() {
        let path = std::env::temp_dir().join("bandstand-huge-render.wav");
        // A century at 48 kHz is far past the four-gibibyte ceiling; the point
        // is that the length fields refuse to wrap, not how the music sounds.
        let centuries = Sequence::new(vec![TimedEvent::note_on(0, 0, 60, 100)], 960, u64::MAX / 4);
        let result = render_to_wav(
            &path,
            empty_bank(),
            &centuries,
            &TempoMap::default(),
            48_000,
            0.5,
            [(1.0, 0.0, false); CHANNEL_COUNT],
        );
        assert!(matches!(result, Err(RenderError::TooLarge { .. })));
        assert!(
            !path.exists(),
            "no file may be created for an impossible render"
        );
    }

    #[test]
    fn a_header_for_an_impossible_size_is_refused_rather_than_wrapping() {
        let mut bytes = Vec::new();
        let result = write_wav_header(&mut bytes, 48_000, 2, u64::from(u32::MAX));
        assert!(matches!(result, Err(RenderError::TooLarge { .. })));
        let result = write_wav_header(&mut bytes, u32::MAX, 2, 1000);
        assert!(matches!(result, Err(RenderError::TooLarge { .. })));
    }

    #[test]
    fn the_header_says_what_the_file_holds() {
        let mut bytes = Vec::new();
        write_wav_header(&mut bytes, 48_000, 2, 1000).unwrap();
        assert_eq!(bytes.len(), HEADER_BYTES as usize);
        assert_eq!(&bytes[0..4], b"RIFF");
        assert_eq!(&bytes[8..12], b"WAVE");
        assert_eq!(&bytes[36..40], b"data");
        // 1000 frames of 16-bit stereo is 4000 bytes.
        assert_eq!(
            u32::from_le_bytes([bytes[40], bytes[41], bytes[42], bytes[43]]),
            4000
        );
        assert_eq!(
            u32::from_le_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]),
            4036
        );
        // Sample rate and byte rate.
        assert_eq!(
            u32::from_le_bytes([bytes[24], bytes[25], bytes[26], bytes[27]]),
            48_000
        );
        assert_eq!(
            u32::from_le_bytes([bytes[28], bytes[29], bytes[30], bytes[31]]),
            48_000 * 4
        );
    }

    #[test]
    fn a_file_that_is_not_a_soundfont_does_not_become_a_bank() {
        assert!(parse_soundfont(b"nope").is_err());
    }
}
