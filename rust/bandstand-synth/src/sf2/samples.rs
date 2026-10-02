//! Where sample data comes from.
//!
//! Rules: `docs/decisions/0007-sample-access.md`. The shipping implementation
//! memory-maps the soundfont so the OS page cache does the work; a resident one
//! exists for tests and for banks built in memory.

use std::fmt;
use std::sync::Arc;

/// A source of 16-bit sample frames.
///
/// Read on the audio thread, so implementations must not allocate, lock or do
/// anything a page fault does not already do.
pub trait SampleSource: Send + Sync {
    /// How many frames there are.
    fn len(&self) -> usize;

    /// Whether there are none.
    fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Read `out.len()` frames from `start`, as `-1.0..1.0`.
    ///
    /// Reads past the end are filled with silence rather than clamped, so a
    /// voice that runs off the end fades rather than repeating its last frame.
    fn read(&self, start: usize, out: &mut [f32]);

    /// One frame, as `-1.0..1.0`. Out of range reads as silence.
    fn sample(&self, index: usize) -> f32;

    /// Ask the operating system to bring `frames` from `start` into memory.
    ///
    /// Called on the **control thread**, never from `read` and never from the
    /// audio callback: the whole point is to pay for the fault somewhere it
    /// does not matter (`docs/rules/sf2-sampler.md` §9).
    ///
    /// Best effort, and a no-op for a source that cannot fault.
    fn warm(&self, start: usize, frames: usize) {
        let _ = (start, frames);
    }
}

/// Samples held in memory.
///
/// What a test uses, and what a bank built in memory uses.
pub struct ResidentSamples {
    data: Vec<i16>,
}

impl ResidentSamples {
    /// Take ownership of sample data.
    #[must_use]
    pub const fn new(data: Vec<i16>) -> Self {
        Self { data }
    }

    /// Read little-endian 16-bit PCM out of a byte slice.
    #[must_use]
    pub fn from_bytes(bytes: &[u8]) -> Self {
        let mut data = Vec::with_capacity(bytes.len() / 2);
        for pair in bytes.chunks_exact(2) {
            data.push(i16::from_le_bytes([pair[0], pair[1]]));
        }
        Self { data }
    }
}

impl SampleSource for ResidentSamples {
    fn len(&self) -> usize {
        self.data.len()
    }

    fn read(&self, start: usize, out: &mut [f32]) {
        for (offset, slot) in out.iter_mut().enumerate() {
            *slot = self.sample(start + offset);
        }
    }

    fn sample(&self, index: usize) -> f32 {
        self.data
            .get(index)
            .map_or(0.0, |value| f32::from(*value) / 32768.0)
    }
}

impl fmt::Debug for ResidentSamples {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ResidentSamples")
            .field("frames", &self.data.len())
            .finish()
    }
}

/// Samples read straight out of a memory-mapped file.
///
/// Holds the mapping, so the file stays open for as long as the bank does
/// (ADR 0007). The file must not be truncated or replaced while this exists:
/// a mapped read from a file that shrank underneath it is a `SIGBUS`, not an
/// error that can be returned. `load_soundfont` documents the constraint and
/// where it is enforced.
pub struct MappedSamples {
    mapping: Arc<memmap2::Mmap>,
    start: usize,
    frames: usize,
}

impl MappedSamples {
    /// Map the `smpl` chunk at `start` for `frames` 16-bit frames.
    ///
    /// # Errors
    /// Returns the byte range asked for if it is outside the mapping.
    pub fn new(
        mapping: Arc<memmap2::Mmap>,
        start: usize,
        frames: usize,
    ) -> Result<Self, (usize, usize)> {
        let end = start + frames * 2;
        if end > mapping.len() {
            return Err((start, end));
        }
        Ok(Self {
            mapping,
            start,
            frames,
        })
    }
}

impl SampleSource for MappedSamples {
    fn len(&self) -> usize {
        self.frames
    }

    fn read(&self, start: usize, out: &mut [f32]) {
        for (offset, slot) in out.iter_mut().enumerate() {
            *slot = self.sample(start + offset);
        }
    }

    fn sample(&self, index: usize) -> f32 {
        if index >= self.frames {
            return 0.0;
        }
        let at = self.start + index * 2;
        let value = i16::from_le_bytes([self.mapping[at], self.mapping[at + 1]]);
        f32::from(value) / 32768.0
    }

    fn warm(&self, start: usize, frames: usize) {
        if start >= self.frames {
            return;
        }
        let frames = frames.min(self.frames - start);
        let first = self.start + start * 2;
        let last = first + frames * 2;

        // One byte a page is what asks the kernel to fault it in; reading every
        // byte would do the same work a thousand times over. `read_volatile`
        // so the reads cannot be optimised away — the value is discarded and
        // the fault is the entire point.
        let mut at = first;
        let mut total: u8 = 0;
        while at < last {
            // SAFETY: `at` is inside the mapping, which `new` checked and which
            // lives as long as `self`.
            total = total.wrapping_add(unsafe { self.mapping.as_ptr().add(at).read_volatile() });
            at += PAGE_BYTES;
        }
        // Touch the final page too: a range that does not end on a boundary
        // would otherwise leave its last page cold, which is the page the
        // release tail reads from.
        if last > first {
            // SAFETY: as above; `last - 1` is the mapping's last touched byte.
            total =
                total.wrapping_add(unsafe { self.mapping.as_ptr().add(last - 1).read_volatile() });
        }
        // Keep the reads observable to the optimiser without keeping the data.
        std::hint::black_box(total);
    }
}

/// The page size warming steps by.
///
/// 4 KB is the smallest page any target uses, so stepping by it touches every
/// page on a 16 KB-page device too — three redundant reads per page, which is
/// nothing against a fault. Asking the OS for the real size at runtime would
/// buy a syscall and no correctness.
const PAGE_BYTES: usize = 4096;

// The mapping itself is megabytes of PCM; its length is what is worth printing.
#[allow(clippy::missing_fields_in_debug)]
impl fmt::Debug for MappedSamples {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("MappedSamples")
            .field("frames", &self.frames)
            .finish()
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

    #[test]
    fn resident_samples_convert_to_unit_range() {
        let source = ResidentSamples::new(vec![0, 16384, -16384, 32767, -32768]);
        assert_eq!(source.len(), 5);
        assert!((source.sample(0) - 0.0).abs() < 1e-9);
        assert!((source.sample(1) - 0.5).abs() < 1e-6);
        assert!((source.sample(2) + 0.5).abs() < 1e-6);
        assert!(source.sample(3) < 1.0);
        assert!((source.sample(4) + 1.0).abs() < 1e-6);
    }

    #[test]
    fn reading_past_the_end_is_silence_not_a_panic() {
        let source = ResidentSamples::new(vec![32767, 32767]);
        assert_eq!(source.sample(2), 0.0);
        assert_eq!(source.sample(usize::MAX), 0.0);

        let mut out = [1.0f32; 4];
        source.read(1, &mut out);
        assert!(out[0] > 0.9);
        assert_eq!(out[1], 0.0);
        assert_eq!(out[2], 0.0);
    }

    #[test]
    fn bytes_are_read_little_endian() {
        // 0x0100 little-endian is 1; 0x00FF is −256.
        let source = ResidentSamples::from_bytes(&[0x01, 0x00, 0x00, 0xFF]);
        assert_eq!(source.len(), 2);
        assert!((source.sample(0) - 1.0 / 32768.0).abs() < 1e-9);
        assert!(source.sample(1) < 0.0);
    }

    #[test]
    fn an_odd_trailing_byte_is_dropped_rather_than_read_half() {
        let source = ResidentSamples::from_bytes(&[0x01, 0x00, 0x02]);
        assert_eq!(source.len(), 1);
    }

    #[test]
    fn an_empty_source_is_empty() {
        let source = ResidentSamples::new(Vec::new());
        assert!(source.is_empty());
        assert_eq!(source.sample(0), 0.0);
    }
}
