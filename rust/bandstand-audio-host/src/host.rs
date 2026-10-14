//! Device enumeration and output stream construction, over `cpal`.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{FromSample, SampleFormat, SizedSample, StreamConfig};

use crate::{AudioHostError, AudioRenderer, BlockContext, StreamContext};

/// Buffer size requested when the caller has no preference, in frames.
///
/// 256 frames at 48 kHz is 5.3 ms, comfortably inside the desktop latency
/// budget of §3 and survivable on a loaded machine.
pub const DEFAULT_BUFFER_FRAMES: u32 = 256;

/// Preferred sample rate when the device offers a choice.
pub const PREFERRED_SAMPLE_RATE: u32 = 48_000;

/// A device as offered to the user.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OutputDeviceInfo {
    /// Name as reported by the backend; also the key used to reopen it.
    pub name: String,
    /// Whether this is the system default output.
    pub is_default: bool,
}

/// What to open.
#[derive(Debug, Clone, Default)]
pub struct StreamOptions {
    /// Device name, or `None` for the system default.
    pub device_name: Option<String>,
    /// Sample rate to request, or `None` to prefer [`PREFERRED_SAMPLE_RATE`].
    pub sample_rate: Option<u32>,
    /// Buffer size to request, or `None` for [`DEFAULT_BUFFER_FRAMES`].
    pub buffer_frames: Option<u32>,
}

/// Live counters a UI can poll while a stream runs.
#[derive(Debug, Default)]
pub struct StreamHealth {
    errors: AtomicU64,
    blocks: AtomicU64,
    frames: AtomicU64,
}

impl StreamHealth {
    /// Number of backend errors reported since the stream opened. Any non-zero
    /// value means audio was interrupted.
    #[must_use]
    pub fn error_count(&self) -> u64 {
        self.errors.load(Ordering::Relaxed)
    }

    /// Number of audio blocks rendered since the stream opened.
    #[must_use]
    pub fn block_count(&self) -> u64 {
        self.blocks.load(Ordering::Relaxed)
    }

    /// Number of frames rendered since the stream opened.
    #[must_use]
    pub fn frame_count(&self) -> u64 {
        self.frames.load(Ordering::Relaxed)
    }
}

/// An open output stream.
///
/// Dropping this closes the stream and returns the renderer's resources.
pub struct AudioStream {
    stream: cpal::Stream,
    device_name: String,
    config: StreamConfig,
    sample_format: SampleFormat,
    health: Arc<StreamHealth>,
}

impl std::fmt::Debug for AudioStream {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AudioStream")
            .field("device_name", &self.device_name)
            .field("config", &self.config)
            .field("sample_format", &self.sample_format)
            .finish_non_exhaustive()
    }
}

impl AudioStream {
    /// Name of the device this stream is running on.
    #[must_use]
    pub fn device_name(&self) -> &str {
        &self.device_name
    }

    /// Sample rate the stream negotiated.
    #[must_use]
    pub fn sample_rate(&self) -> u32 {
        self.config.sample_rate.0
    }

    /// Channel count the stream negotiated.
    #[must_use]
    pub fn channels(&self) -> u16 {
        self.config.channels
    }

    /// Buffer size the stream negotiated, in frames, if the backend fixed one.
    #[must_use]
    pub fn buffer_frames(&self) -> Option<u32> {
        match self.config.buffer_size {
            cpal::BufferSize::Fixed(frames) => Some(frames),
            cpal::BufferSize::Default => None,
        }
    }

    /// The device's native sample format, as a display string.
    #[must_use]
    pub fn sample_format(&self) -> String {
        format!("{:?}", self.sample_format)
    }

    /// Live counters for this stream.
    #[must_use]
    pub fn health(&self) -> &Arc<StreamHealth> {
        &self.health
    }

    /// Resume a paused stream.
    ///
    /// # Errors
    /// Returns [`AudioHostError::PlayStream`] if the backend refuses.
    pub fn play(&self) -> Result<(), AudioHostError> {
        self.stream.play().map_err(|e| AudioHostError::PlayStream {
            detail: e.to_string(),
        })
    }

    /// Pause the stream. Not all backends support this; the error is reported
    /// rather than swallowed.
    ///
    /// # Errors
    /// Returns [`AudioHostError::PlayStream`] if the backend refuses.
    pub fn pause(&self) -> Result<(), AudioHostError> {
        self.stream.pause().map_err(|e| AudioHostError::PlayStream {
            detail: e.to_string(),
        })
    }
}

/// List the output devices the platform offers.
///
/// # Errors
/// Returns [`AudioHostError::Enumeration`] if the backend cannot be queried.
pub fn list_output_devices() -> Result<Vec<OutputDeviceInfo>, AudioHostError> {
    let host = cpal::default_host();
    let default_name = host.default_output_device().and_then(|d| d.name().ok());
    let devices = host
        .output_devices()
        .map_err(|e| AudioHostError::Enumeration {
            detail: e.to_string(),
        })?;

    let mut out = Vec::new();
    for device in devices {
        let Ok(name) = device.name() else { continue };
        // A device with no output configuration cannot be selected; hide it
        // rather than letting the user pick something that always fails.
        if device.supported_output_configs().is_err() {
            continue;
        }
        let is_default = default_name.as_deref() == Some(name.as_str());
        out.push(OutputDeviceInfo { name, is_default });
    }
    Ok(out)
}

fn find_device(name: Option<&str>) -> Result<cpal::Device, AudioHostError> {
    let host = cpal::default_host();
    match name {
        None => host
            .default_output_device()
            .ok_or(AudioHostError::NoOutputDevice),
        Some(wanted) => {
            let devices = host
                .output_devices()
                .map_err(|e| AudioHostError::Enumeration {
                    detail: e.to_string(),
                })?;
            for device in devices {
                if device.name().is_ok_and(|n| n == wanted) {
                    return Ok(device);
                }
            }
            Err(AudioHostError::DeviceNotFound {
                name: wanted.to_owned(),
            })
        }
    }
}

/// Pick the configuration closest to what the caller asked for.
///
/// Preference order: the requested sample rate if the device supports it, then
/// [`PREFERRED_SAMPLE_RATE`], then the device's own default. Stereo is
/// preferred, then any layout with the fewest channels at or above one.
fn choose_config(
    device: &cpal::Device,
    options: &StreamOptions,
) -> Result<(StreamConfig, SampleFormat), AudioHostError> {
    let supported: Vec<_> = device
        .supported_output_configs()
        .map_err(|e| AudioHostError::NoSupportedConfig {
            detail: e.to_string(),
        })?
        .collect();
    if supported.is_empty() {
        return Err(AudioHostError::NoSupportedConfig {
            detail: "device reported an empty configuration list".to_owned(),
        });
    }

    let wanted_rate = options.sample_rate.unwrap_or(PREFERRED_SAMPLE_RATE);

    let score = |range: &cpal::SupportedStreamConfigRange| -> (u32, u32, u32) {
        let channels = u32::from(range.channels());
        let channel_score = match channels {
            2 => 0,
            1 => 1,
            n => 2 + n,
        };
        let min = range.min_sample_rate().0;
        let max = range.max_sample_rate().0;
        let rate_score = if (min..=max).contains(&wanted_rate) {
            0
        } else if (min..=max).contains(&PREFERRED_SAMPLE_RATE) {
            1
        } else {
            2
        };
        let format_score = u32::from(range.sample_format() != SampleFormat::F32);
        (rate_score, channel_score, format_score)
    };

    let best = supported
        .iter()
        .min_by_key(|range| score(range))
        .expect("supported list is non-empty");

    let min = best.min_sample_rate().0;
    let max = best.max_sample_rate().0;
    let rate = if (min..=max).contains(&wanted_rate) {
        wanted_rate
    } else if (min..=max).contains(&PREFERRED_SAMPLE_RATE) {
        PREFERRED_SAMPLE_RATE
    } else {
        max.min(PREFERRED_SAMPLE_RATE.max(min))
    };

    let supported_config = (*best).with_sample_rate(cpal::SampleRate(rate));
    let sample_format = supported_config.sample_format();
    let mut config: StreamConfig = supported_config.into();

    let frames = options.buffer_frames.unwrap_or(DEFAULT_BUFFER_FRAMES);
    config.buffer_size = match best.buffer_size() {
        cpal::SupportedBufferSize::Range { min, max } => {
            cpal::BufferSize::Fixed(frames.clamp(*min, *max))
        }
        cpal::SupportedBufferSize::Unknown => cpal::BufferSize::Default,
    };

    Ok((config, sample_format))
}

/// Open an output stream and start it.
///
/// The renderer is moved onto the audio thread and lives as long as the stream.
///
/// # Errors
/// Returns [`AudioHostError`] if no device matches, the device offers no usable
/// configuration, its sample format is unsupported, or the backend refuses to
/// build or start the stream.
pub fn open_output_stream<R: AudioRenderer>(
    options: &StreamOptions,
    renderer: R,
) -> Result<AudioStream, AudioHostError> {
    let device = find_device(options.device_name.as_deref())?;
    let device_name = device.name().unwrap_or_else(|_| "unknown".to_owned());
    let (config, sample_format) = choose_config(&device, options)?;

    let health = Arc::new(StreamHealth::default());

    let stream = match sample_format {
        SampleFormat::F32 => build::<f32, R>(&device, &config, renderer, &health),
        SampleFormat::I16 => build::<i16, R>(&device, &config, renderer, &health),
        SampleFormat::U16 => build::<u16, R>(&device, &config, renderer, &health),
        SampleFormat::I32 => build::<i32, R>(&device, &config, renderer, &health),
        SampleFormat::F64 => build::<f64, R>(&device, &config, renderer, &health),
        SampleFormat::I8 => build::<i8, R>(&device, &config, renderer, &health),
        SampleFormat::U8 => build::<u8, R>(&device, &config, renderer, &health),
        other => {
            return Err(AudioHostError::UnsupportedSampleFormat {
                format: format!("{other:?}"),
            })
        }
    }?;

    stream.play().map_err(|e| AudioHostError::PlayStream {
        detail: e.to_string(),
    })?;

    Ok(AudioStream {
        stream,
        device_name,
        config,
        sample_format,
        health,
    })
}

fn build<T, R>(
    device: &cpal::Device,
    config: &StreamConfig,
    mut renderer: R,
    health: &Arc<StreamHealth>,
) -> Result<cpal::Stream, AudioHostError>
where
    T: SizedSample + FromSample<f32>,
    R: AudioRenderer,
{
    let channels = config.channels as usize;
    let sample_rate = f64::from(config.sample_rate.0);
    let max_block_frames = match config.buffer_size {
        cpal::BufferSize::Fixed(frames) => frames as usize,
        cpal::BufferSize::Default => DEFAULT_BUFFER_FRAMES as usize * 4,
    };

    renderer.prepare(&StreamContext {
        sample_rate,
        channels,
        max_block_frames,
    });

    // Scratch buffer for the f32 mix, sized generously so that a backend asking
    // for more than it promised does not force an allocation on the audio
    // thread. If it ever does, `resize` reallocates once and the buffer stays
    // large enough thereafter.
    let mut scratch = vec![0.0f32; max_block_frames.max(64) * channels * 4];
    // Measured on the first callback and kept for the life of the stream; see
    // `playback_latency_ns`.
    let mut latency_ns: Option<u64> = None;

    let health_render = Arc::clone(health);
    let health_error = Arc::clone(health);

    let stream = device
        .build_output_stream(
            config,
            move |output: &mut [T], info: &cpal::OutputCallbackInfo| {
                let frames = output.len() / channels.max(1);
                if frames == 0 {
                    return;
                }
                let needed = frames * channels;
                if scratch.len() < needed {
                    scratch.resize(needed, 0.0);
                }
                let mix = &mut scratch[..needed];
                mix.fill(0.0);

                let host_time_ns = bandstand_transport::monotonic_now_ns().saturating_add(
                    *latency_ns
                        .get_or_insert_with(|| playback_latency_ns(info, frames, sample_rate)),
                );
                renderer.render(
                    mix,
                    &BlockContext {
                        frames,
                        channels,
                        host_time_ns,
                    },
                );

                for (slot, sample) in output.iter_mut().zip(mix.iter()) {
                    // Hard-clip before conversion: a NaN or an out-of-range
                    // value reaching an integer format is a loud, destructive
                    // artefact, and silently clipping is the least bad
                    // response on a stage.
                    let clean = if sample.is_finite() {
                        sample.clamp(-1.0, 1.0)
                    } else {
                        0.0
                    };
                    *slot = T::from_sample(clean);
                }

                health_render.blocks.fetch_add(1, Ordering::Relaxed);
                health_render
                    .frames
                    .fetch_add(frames as u64, Ordering::Relaxed);
            },
            move |_error| {
                health_error.errors.fetch_add(1, Ordering::Relaxed);
            },
            None,
        )
        .map_err(|e| AudioHostError::BuildStream {
            detail: e.to_string(),
        })?;

    Ok(stream)
}

/// The stream's output latency, measured once.
///
/// `cpal` reports both the callback instant and the playback instant on its own
/// clock; only their *difference* is portable, so the latency is what is taken,
/// and it is added to a reading of our own clock inside the callback.
///
/// **Measured once, and then kept.** Output latency is a property of the stream
/// configuration — a buffer depth — not of the moment, so a stable estimate
/// matters far more than an exact one: a constant error shifts the cursor by
/// that amount, where a varying one makes it jitter, and §3 budgets drift
/// rather than offset.
///
/// Keeping it is the fix rather than a refinement. The Android backend was
/// measured reporting a playback instant 1148 seconds after the callback on
/// some blocks and a plausible one on others, so recomputing per block made the
/// published host time jump — and run *backwards* — by most of a second. That
/// is 700 ms of cursor error against a 20 ms budget.
fn playback_latency_ns(info: &cpal::OutputCallbackInfo, frames: usize, sample_rate: f64) -> u64 {
    let timestamp = info.timestamp();
    let reported = timestamp
        .playback
        .duration_since(&timestamp.callback)
        .map_or(0, |d| u64::try_from(d.as_nanos()).unwrap_or(u64::MAX));
    plausible_latency_ns(reported, frames, sample_rate)
}

/// The reported latency, or an estimate when it cannot be one.
///
/// A device's output latency is on the order of the buffer it is filling. Two
/// blocks is already generous — one in flight and one being filled — and
/// anything beyond it says more about the backend's clock than about the
/// hardware.
fn plausible_latency_ns(reported_ns: u64, frames: usize, sample_rate: f64) -> u64 {
    if sample_rate <= 0.0 || frames == 0 {
        return if reported_ns > MAX_PLAUSIBLE_LATENCY_NS {
            0
        } else {
            reported_ns
        };
    }
    #[allow(clippy::cast_precision_loss)]
    let seconds = frames as f64 / sample_rate;
    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    let block_ns = (seconds * 1e9).clamp(0.0, MAX_PLAUSIBLE_LATENCY_F64) as u64;
    let ceiling = block_ns
        .saturating_mul(2)
        .min(MAX_PLAUSIBLE_LATENCY_NS)
        .max(block_ns);
    if reported_ns <= ceiling {
        reported_ns
    } else {
        // Fall back to the block duration: it is the one figure we know is
        // true, and it is the right order of magnitude for an output latency.
        block_ns
    }
}

/// No output path Bandstand can play along with has a latency beyond this.
///
/// Two seconds is far past unusable; it exists only to stop a nonsense
/// timestamp propagating into the playhead.
const MAX_PLAUSIBLE_LATENCY_NS: u64 = 2_000_000_000;

/// The same bound, for the floating-point clamp above.
const MAX_PLAUSIBLE_LATENCY_F64: f64 = 2_000_000_000.0;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_reported_latency_within_reason_is_kept() {
        // 256 frames at 48 kHz is 5.33 ms a block; a 10 ms latency is two
        // blocks and entirely ordinary.
        assert_eq!(plausible_latency_ns(10_000_000, 256, 48_000.0), 10_000_000);
    }

    /// The duration of `frames` at `rate`, in nanoseconds.
    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    fn block_ns(frames: usize, rate: f64) -> u64 {
        #[allow(clippy::cast_precision_loss)]
        let seconds = frames as f64 / rate;
        (seconds * 1e9) as u64
    }

    #[test]
    fn a_nonsense_latency_falls_back_to_the_block_duration() {
        // The Android backend was measured reporting 1148 *seconds*, which put
        // the playhead nineteen minutes into the future.
        assert_eq!(
            plausible_latency_ns(1_148_000_000_000, 256, 48_000.0),
            block_ns(256, 48_000.0)
        );
    }

    #[test]
    fn a_large_buffer_is_allowed_a_proportionally_large_latency() {
        // The Android emulator negotiates a 34 880-frame buffer — 727 ms — and
        // a latency of a few of those blocks is real rather than nonsense.
        let block = block_ns(34_880, 48_000.0);
        assert_eq!(plausible_latency_ns(block * 2, 34_880, 48_000.0), block * 2);
    }

    #[test]
    fn nothing_survives_the_absolute_ceiling() {
        // Even a huge block cannot licence a latency beyond what a person could
        // play along with.
        let reported = MAX_PLAUSIBLE_LATENCY_NS + 1;
        assert!(plausible_latency_ns(reported, 1_000_000, 48_000.0) <= MAX_PLAUSIBLE_LATENCY_NS);
    }

    #[test]
    fn a_stream_with_no_rate_yet_still_rejects_nonsense() {
        assert_eq!(plausible_latency_ns(10_000_000, 0, 0.0), 10_000_000);
        assert_eq!(plausible_latency_ns(1_148_000_000_000, 0, 0.0), 0);
    }

    #[test]
    fn enumeration_does_not_panic_without_a_device() {
        // On a headless machine this returns either an empty list or an error;
        // both are acceptable, a panic is not.
        let _ = list_output_devices();
    }

    #[test]
    fn missing_device_is_reported_by_name() {
        let Err(error) = find_device(Some("no such device exists anywhere")) else {
            panic!("a device with that name cannot exist");
        };
        match error {
            AudioHostError::DeviceNotFound { name } => {
                assert_eq!(name, "no such device exists anywhere");
            }
            AudioHostError::Enumeration { .. } | AudioHostError::NoOutputDevice => {}
            other => panic!("unexpected error: {other}"),
        }
    }
}
