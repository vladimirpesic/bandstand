//! Audio host errors.

use std::fmt;

/// Everything that can go wrong opening or running an output stream.
#[derive(Debug)]
pub enum AudioHostError {
    /// The platform reported no output device at all.
    NoOutputDevice,
    /// A device was requested by name and no device matches.
    DeviceNotFound {
        /// The requested name.
        name: String,
    },
    /// The device exposes no supported output configuration.
    NoSupportedConfig {
        /// What the backend said, if anything.
        detail: String,
    },
    /// The device's sample format is one Bandstand does not convert to.
    UnsupportedSampleFormat {
        /// The format the backend reported.
        format: String,
    },
    /// The backend refused to build the stream.
    BuildStream {
        /// Backend message.
        detail: String,
    },
    /// The backend refused to start the stream.
    PlayStream {
        /// Backend message.
        detail: String,
    },
    /// Enumerating devices failed.
    Enumeration {
        /// Backend message.
        detail: String,
    },
}

impl fmt::Display for AudioHostError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NoOutputDevice => write!(f, "no audio output device is available"),
            Self::DeviceNotFound { name } => write!(f, "no audio output device named {name:?}"),
            Self::NoSupportedConfig { detail } => {
                write!(f, "device has no usable output configuration: {detail}")
            }
            Self::UnsupportedSampleFormat { format } => {
                write!(f, "unsupported device sample format: {format}")
            }
            Self::BuildStream { detail } => {
                write!(f, "could not build the output stream: {detail}")
            }
            Self::PlayStream { detail } => write!(f, "could not start the output stream: {detail}"),
            Self::Enumeration { detail } => {
                write!(f, "could not enumerate audio devices: {detail}")
            }
        }
    }
}

impl std::error::Error for AudioHostError {}
