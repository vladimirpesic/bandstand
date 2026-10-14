//! Audio device enumeration and output stream setup.
//!
//! Wraps `cpal`, which reaches ALSA/PipeWire on Linux, WASAPI on Windows,
//! `CoreAudio` on macOS and iOS, and Oboe on Android (§7.4). Nothing above this
//! crate mentions `cpal`.

#![forbid(unsafe_code)]

mod error;
mod host;
mod renderer;

pub use error::AudioHostError;
pub use host::{
    list_output_devices, open_output_stream, AudioStream, OutputDeviceInfo, StreamHealth,
    StreamOptions, DEFAULT_BUFFER_FRAMES, PREFERRED_SAMPLE_RATE,
};
pub use renderer::{AudioRenderer, BlockContext, StreamContext};
