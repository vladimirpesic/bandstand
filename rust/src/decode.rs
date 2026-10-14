//! Decoding a cached library file into memory.
//!
//! The player of ADR 0012 refuses to stream: a track is downloaded before it
//! can be played, and decoded in full before its first sample is mixed. That
//! keeps the audio thread free of I/O — it reads an in-memory buffer and
//! nothing else — and it keeps playback position exact: the playhead is derived
//! from the transport's timeline, never from how far a decoder has happened to
//! get.
//!
//! Decoding normalises every source to interleaved stereo `f32` at the original
//! sample rate: mono is doubled to both sides, and a surround source keeps its
//! first two channels. Nothing is resampled here — the engine's read side
//! interpolates, so a 44.1 kHz track plays on a 48 kHz device without a
//! resampling pass or a second buffer.
//!
//! Decoding runs wherever [`decode_file`] is called (the bridge's worker, off
//! both the UI and the audio thread); the result is handed to the engine as an
//! `Arc` the audio thread can read without owning.

use std::fs::File;
use std::path::Path;

use symphonia::core::codecs::audio::AudioDecoderOptions;
use symphonia::core::errors::Error;
use symphonia::core::formats::probe::Hint;
use symphonia::core::formats::{FormatOptions, TrackType};
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;

/// A decoded track: interleaved stereo `f32` at the source sample rate.
#[derive(Debug)]
pub struct DecodedTrack {
    samples: Vec<f32>,
    sample_rate: u32,
    frame_count: usize,
}

impl DecodedTrack {
    /// Wrap already-interleaved stereo samples.
    ///
    /// # Panics
    /// Panics if `samples` has an odd length (a broken half-frame).
    #[must_use]
    pub fn from_interleaved_stereo(samples: Vec<f32>, sample_rate: u32) -> Self {
        assert!(
            samples.len() % 2 == 0,
            "an interleaved stereo buffer cannot hold a half frame"
        );
        let frame_count = samples.len() / 2;
        Self {
            samples,
            sample_rate,
            frame_count,
        }
    }

    /// The source sample rate.
    #[must_use]
    pub const fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    /// Frames of stereo audio in the track.
    ///
    /// Unused by the engine, which positions by time; the tests use it to
    /// check what a file decoded to.
    #[allow(dead_code)]
    pub const fn frame_count(&self) -> usize {
        self.frame_count
    }

    /// Duration in milliseconds, rounded up so the last tick is inside the
    /// track rather than one beyond its end.
    #[must_use]
    pub fn duration_ms(&self) -> u64 {
        #[allow(clippy::cast_precision_loss, clippy::cast_possible_truncation)]
        {
            ((self.frame_count as f64) * 1000.0 / f64::from(self.sample_rate)).ceil() as u64
        }
    }

    /// Read the (left, right) pair at `frame`, interpolating linearly between
    /// the two neighbouring frames.
    ///
    /// A position past the end reads as silence — the transport may run on
    /// past the last sample (stopping is the caller's decision), and gaps must
    /// never read as garbage. The final frame is held, not interpolated into
    /// nothing.
    #[must_use]
    pub fn read_pair(&self, frame: f64) -> (f32, f32) {
        if !frame.is_finite() || frame < 0.0 {
            return (0.0, 0.0);
        }
        #[allow(clippy::cast_precision_loss)]
        let last_frame = self.frame_count.saturating_sub(1) as f64;
        if frame >= last_frame {
            #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
            if frame >= self.frame_count as f64 {
                return (0.0, 0.0);
            }
            let last = self.frame_count * 2 - 2;
            return (self.samples[last], self.samples[last + 1]);
        }
        #[allow(
            clippy::cast_possible_truncation,
            clippy::cast_sign_loss,
            clippy::cast_precision_loss
        )]
        let base = frame.floor() as usize;
        let frac = (frame - frame.floor()) as f32;
        let index = base * 2;
        let (a, b) = (self.samples[index], self.samples[index + 1]);
        let (c, d) = (self.samples[index + 2], self.samples[index + 3]);
        (a + (c - a) * frac, b + (d - b) * frac)
    }
}

/// Decode the audio file at `path` into a [`DecodedTrack`].
///
/// The first audio track is used; a mid-file change of sample rate or channel
/// count is refused rather than half-obeyed.
///
/// # Errors
/// Returns a human-readable message if the file cannot be opened, is not a
/// recognisable media container, has no audio track, or decodes to nothing.
pub fn decode_file(path: &Path) -> Result<DecodedTrack, String> {
    let name = path.display();
    let source = File::open(path).map_err(|error| format!("{name}: {error}"))?;
    let media = MediaSourceStream::new(Box::new(source), Default::default());

    let mut hint = Hint::new();
    if let Some(extension) = path.extension().and_then(|extension| extension.to_str()) {
        hint.with_extension(extension);
    }

    let mut format = symphonia::default::get_probe()
        .probe(
            &hint,
            media,
            FormatOptions::default(),
            MetadataOptions::default(),
        )
        .map_err(|error| format!("{name}: {error}"))?;

    let track = format
        .default_track(TrackType::Audio)
        .ok_or_else(|| format!("{name}: no audio track"))?;
    let decoder_parameters = track
        .codec_params
        .as_ref()
        .and_then(|parameters| parameters.audio())
        .ok_or_else(|| format!("{name}: the audio track has no codec parameters"))?;
    let track_id = track.id;

    let mut decoder = symphonia::default::get_codecs()
        .make_audio_decoder(decoder_parameters, &AudioDecoderOptions::default())
        .map_err(|error| format!("{name}: {error}"))?;

    let mut samples: Vec<f32> = Vec::new();
    let mut sample_rate = 0u32;
    let mut channels = 0usize;

    loop {
        let packet = match format.next_packet() {
            Ok(Some(packet)) => packet,
            Ok(None) => break,
            // Some format readers still report the end as an EOF error rather
            // than an empty packet.
            Err(Error::IoError(error)) if error.kind() == std::io::ErrorKind::UnexpectedEof => {
                break;
            }
            // Chained physical streams (OGG) would need a fresh decoder chain;
            // the library has none. Treat the chain break as the end.
            Err(Error::ResetRequired) => break,
            Err(error) => return Err(format!("{name}: {error}")),
        };
        if packet.track_id != track_id {
            continue;
        }

        match decoder.decode(&packet) {
            Ok(decoded) => {
                let spec = decoded.spec();
                let packet_rate = spec.rate();
                let packet_channels = spec.channels().count();
                if sample_rate == 0 {
                    sample_rate = packet_rate;
                    channels = packet_channels;
                } else if packet_rate != sample_rate || packet_channels != channels {
                    return Err(format!("{name}: the stream changes format mid-file"));
                }
                let mut block = Vec::new();
                decoded.copy_to_vec_interleaved(&mut block);
                push_stereo(&mut samples, &block, channels);
            }
            // A packet that fails to decode is a gap in the source, not the
            // end of it: skip and carry on.
            Err(Error::IoError(_) | Error::DecodeError(_)) => continue,
            Err(error) => return Err(format!("{name}: {error}")),
        }
    }

    if samples.is_empty() {
        return Err(format!("{name}: no audio decoded"));
    }
    Ok(DecodedTrack::from_interleaved_stereo(samples, sample_rate))
}

/// Fold one decoded packet's interleaved samples into the stereo buffer.
fn push_stereo(samples: &mut Vec<f32>, block: &[f32], channels: usize) {
    match channels {
        1 => {
            for sample in block {
                samples.push(*sample);
                samples.push(*sample);
            }
        }
        2 => samples.extend_from_slice(block),
        // A surround source: its first two channels become the stereo pair.
        _ => {
            for frame in block.chunks(channels) {
                samples.push(frame[0]);
                samples.push(*frame.get(1).unwrap_or(&frame[0]));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Write a minimal 16-bit PCM WAV, the format the library actually ships.
    fn wav_bytes(channels: u16, sample_rate: u32, samples: &[i16]) -> Vec<u8> {
        let data_len = samples.len() * 2;
        let mut out = Vec::with_capacity(44 + data_len);
        out.extend_from_slice(b"RIFF");
        out.extend_from_slice(&u32::try_from(36 + data_len).unwrap().to_le_bytes());
        out.extend_from_slice(b"WAVE");
        out.extend_from_slice(b"fmt ");
        out.extend_from_slice(&16u32.to_le_bytes());
        out.extend_from_slice(&1u16.to_le_bytes());
        out.extend_from_slice(&channels.to_le_bytes());
        out.extend_from_slice(&sample_rate.to_le_bytes());
        out.extend_from_slice(&(sample_rate * u32::from(channels) * 2).to_le_bytes());
        out.extend_from_slice(&(channels * 2).to_le_bytes());
        out.extend_from_slice(&16u16.to_le_bytes());
        out.extend_from_slice(b"data");
        out.extend_from_slice(&u32::try_from(data_len).unwrap().to_le_bytes());
        for sample in samples {
            out.extend_from_slice(&sample.to_le_bytes());
        }
        out
    }

    fn temp_wav(name: &str, bytes: &[u8]) -> std::path::PathBuf {
        let path = std::env::temp_dir().join(format!(
            "bandstand-decode-{}-{name}.wav",
            std::process::id()
        ));
        std::fs::write(&path, bytes).expect("the test WAV can be written");
        path
    }

    #[test]
    fn decodes_a_stereo_wav() {
        // A recognisable ramp: left climbs, right falls.
        #[allow(clippy::cast_possible_truncation)]
        let samples: Vec<i16> = (0..100).flat_map(|i| [i * 100, -i * 100]).collect();
        let path = temp_wav("stereo", &wav_bytes(2, 44_100, &samples));
        let track = decode_file(&path).expect("the WAV decodes");
        assert_eq!(track.sample_rate(), 44_100);
        assert_eq!(track.frame_count(), 100);
        assert_eq!(track.duration_ms(), 3);
        for i in 0..100 {
            let (left, right) = track.read_pair(f64::from(i));
            #[allow(clippy::cast_precision_loss)]
            let expected = i as f32 * 100.0 / 32_768.0;
            assert!(
                (left - expected).abs() < 1e-4 && (right + expected).abs() < 1e-4,
                "frame {i}: {left} / {right}"
            );
        }
    }

    #[test]
    fn decodes_a_mono_wav_to_both_channels() {
        let samples: Vec<i16> = (0..50).map(|i| (i * 200) as i16).collect();
        let path = temp_wav("mono", &wav_bytes(1, 22_050, &samples));
        let track = decode_file(&path).expect("the WAV decodes");
        assert_eq!(track.sample_rate(), 22_050);
        assert_eq!(track.frame_count(), 50);
        let (left, right) = track.read_pair(10.0);
        assert!((left - right).abs() < f32::EPSILON);
        #[allow(clippy::cast_precision_loss)]
        let expected = 10.0f32 * 200.0 / 32_768.0;
        assert!((left - expected).abs() < 1e-4);
    }

    #[test]
    fn rejects_something_that_is_not_audio() {
        let path = temp_wav("garbage", b"this is not a media file at all");
        assert!(decode_file(&path).is_err());
    }

    #[test]
    fn rejects_a_file_that_decodes_to_nothing() {
        let path = temp_wav("empty", &wav_bytes(2, 44_100, &[]));
        assert!(decode_file(&path).is_err());
    }

    #[test]
    fn reading_past_the_end_is_silence_and_the_last_frame_holds() {
        let track = DecodedTrack::from_interleaved_stereo(vec![0.25, -0.25, 0.5, -0.5], 48_000);
        assert_eq!(track.read_pair(1.0), (0.5, -0.5));
        assert_eq!(track.read_pair(1.9), (0.5, -0.5));
        assert_eq!(track.read_pair(2.0), (0.0, 0.0));
        assert_eq!(track.read_pair(1e9), (0.0, 0.0));
    }

    #[test]
    fn reading_interpolates_between_frames() {
        let track = DecodedTrack::from_interleaved_stereo(vec![0.0, 0.0, 1.0, -1.0], 48_000);
        let (left, right) = track.read_pair(0.5);
        assert!((left - 0.5).abs() < 1e-6 && (right + 0.5).abs() < 1e-6);
    }
}
