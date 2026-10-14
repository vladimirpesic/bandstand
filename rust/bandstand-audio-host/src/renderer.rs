//! The contract between the audio host and whatever produces sound.

/// Everything a renderer needs to know when a stream opens.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct StreamContext {
    /// Frames per second.
    pub sample_rate: f64,
    /// Interleaved channel count of the output buffer.
    pub channels: usize,
    /// Largest block the backend is expected to ask for. Advisory: a renderer
    /// must cope with a larger block, but may preallocate for this size.
    pub max_block_frames: usize,
}

/// Per-block information.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BlockContext {
    /// Frames in this block.
    pub frames: usize,
    /// Interleaved channel count.
    pub channels: usize,
    /// Value of `bandstand_transport::monotonic_now_ns` at which the first
    /// frame of this block is expected to reach the speakers.
    pub host_time_ns: u64,
}

/// Produces audio for an output stream.
///
/// Implementations run on the real-time audio thread. They must not allocate,
/// lock, block, perform I/O, or panic.
pub trait AudioRenderer: Send + 'static {
    /// Called once, before the first block, whenever a stream opens.
    fn prepare(&mut self, context: &StreamContext);

    /// Fill `output`, an interleaved buffer of `context.frames * context.channels`
    /// samples. The buffer arrives zeroed.
    fn render(&mut self, output: &mut [f32], context: &BlockContext);
}
