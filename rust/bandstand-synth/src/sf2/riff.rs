//! The RIFF container a SoundFont is wrapped in.
//!
//! Rules: `docs/rules/sf2-sampler.md` §1.

use std::fmt;

/// Why a file is not a SoundFont this build can read.
#[derive(Debug)]
pub enum SoundFontError {
    /// The file could not be opened or mapped.
    Io {
        /// What was being done when it failed.
        what: &'static str,
        /// The error the operating system gave.
        error: std::io::Error,
    },
    /// The file is shorter than the structure it claims.
    Truncated {
        /// What was being read.
        what: &'static str,
        /// How many bytes were needed.
        needed: usize,
        /// How many were left.
        available: usize,
    },
    /// The file is not RIFF, or not a SoundFont.
    NotASoundFont {
        /// What the header said instead.
        found: String,
    },
    /// A chunk the format requires is absent.
    MissingChunk {
        /// Its four-character id.
        id: &'static str,
    },
    /// A record array's length is not a multiple of its record size.
    BadChunkLength {
        /// Its four-character id.
        id: &'static str,
        /// The length found.
        length: usize,
        /// The record size expected.
        record: usize,
    },
    /// A record array has no terminal record, so its index ranges are unbounded.
    NoTerminalRecord {
        /// Its four-character id.
        id: &'static str,
    },
    /// An index in the file points outside the array it indexes.
    IndexOutOfRange {
        /// Where the index was.
        what: &'static str,
        /// The index.
        index: usize,
        /// How many entries there are.
        length: usize,
    },
}

impl fmt::Display for SoundFontError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io { what, error } => write!(f, "could not {what}: {error}"),
            Self::Truncated {
                what,
                needed,
                available,
            } => write!(
                f,
                "the file ends in the middle of {what}: {needed} bytes needed, \
                 {available} left"
            ),
            Self::NotASoundFont { found } => {
                write!(f, "not a SoundFont: the header says {found:?}")
            }
            Self::MissingChunk { id } => write!(f, "no {id} chunk"),
            Self::BadChunkLength { id, length, record } => write!(
                f,
                "the {id} chunk is {length} bytes, which is not a whole number \
                 of {record}-byte records"
            ),
            Self::NoTerminalRecord { id } => {
                write!(f, "the {id} chunk has no terminal record")
            }
            Self::IndexOutOfRange {
                what,
                index,
                length,
            } => write!(f, "{what} points at {index} of {length}"),
        }
    }
}

impl std::error::Error for SoundFontError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io { error, .. } => Some(error),
            _ => None,
        }
    }
}

/// A chunk found in the file: its id and where its body is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Chunk {
    /// The four-character id.
    pub id: [u8; 4],
    /// Offset of the body from the start of the file.
    pub start: usize,
    /// Length of the body.
    pub length: usize,
}

impl Chunk {
    /// The id as text, for messages.
    #[must_use]
    pub fn id_string(&self) -> String {
        String::from_utf8_lossy(&self.id).into_owned()
    }

    /// One past the last byte of the body.
    #[must_use]
    pub const fn end(&self) -> usize {
        self.start + self.length
    }
}

/// Reads RIFF chunks out of a byte slice.
pub struct RiffReader<'a> {
    bytes: &'a [u8],
    cursor: usize,
    end: usize,
}

impl<'a> RiffReader<'a> {
    /// Read the whole file, checking it is a SoundFont.
    ///
    /// Returns a reader positioned at the first chunk inside the `sfbk` form.
    ///
    /// # Errors
    /// Returns [`SoundFontError`] if the file is truncated or is not a
    /// SoundFont.
    pub fn open(bytes: &'a [u8]) -> Result<Self, SoundFontError> {
        if bytes.len() < 12 {
            return Err(SoundFontError::Truncated {
                what: "the RIFF header",
                needed: 12,
                available: bytes.len(),
            });
        }
        if &bytes[0..4] != b"RIFF" {
            return Err(SoundFontError::NotASoundFont {
                found: String::from_utf8_lossy(&bytes[0..4]).into_owned(),
            });
        }
        let declared = u32::from_le_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]);
        // The declared size covers everything after it; a file may be padded.
        // The sum is done in u64: on a 32-bit target a crafted size near
        // `u32::MAX` would overflow `usize` (L-RS3).
        let end = (u64::from(declared) + 8).min(bytes.len() as u64) as usize;
        if &bytes[8..12] != b"sfbk" {
            return Err(SoundFontError::NotASoundFont {
                found: String::from_utf8_lossy(&bytes[8..12]).into_owned(),
            });
        }
        Ok(Self {
            bytes,
            cursor: 12,
            end,
        })
    }

    /// A reader over the body of a LIST chunk, skipping its form type.
    ///
    /// # Errors
    /// Returns [`SoundFontError`] if the chunk is too short to hold a form type.
    #[allow(clippy::trivially_copy_pass_by_ref)]
    pub fn list_body(bytes: &'a [u8], chunk: Chunk) -> Result<Self, SoundFontError> {
        if chunk.length < 4 {
            return Err(SoundFontError::Truncated {
                what: "a LIST chunk's form type",
                needed: 4,
                available: chunk.length,
            });
        }
        Ok(Self {
            bytes,
            cursor: chunk.start + 4,
            end: chunk.end(),
        })
    }

    /// The next chunk, or `None` at the end.
    ///
    /// # Errors
    /// Returns [`SoundFontError`] if a chunk header runs off the end.
    pub fn next_chunk(&mut self) -> Result<Option<Chunk>, SoundFontError> {
        if self.cursor + 8 > self.end {
            return Ok(None);
        }
        let id = [
            self.bytes[self.cursor],
            self.bytes[self.cursor + 1],
            self.bytes[self.cursor + 2],
            self.bytes[self.cursor + 3],
        ];
        let length = u32::from_le_bytes([
            self.bytes[self.cursor + 4],
            self.bytes[self.cursor + 5],
            self.bytes[self.cursor + 6],
            self.bytes[self.cursor + 7],
        ]);
        let start = self.cursor + 8;
        // Compared in u64: `start + length` can overflow `usize` on a 32-bit
        // target for a crafted chunk size (L-RS3). Passing pins `start +
        // length` to at most the file's length, so the cursor arithmetic
        // below cannot overflow either.
        if u64::from(length) + start as u64 > self.bytes.len() as u64 {
            return Err(SoundFontError::Truncated {
                what: "a chunk body",
                needed: length as usize,
                available: self.bytes.len().saturating_sub(start),
            });
        }
        // Chunks are padded to an even length.
        self.cursor = start + length as usize + (length & 1) as usize;
        Ok(Some(Chunk {
            id,
            start,
            length: length as usize,
        }))
    }

    /// The form type of a LIST chunk, e.g. `INFO`.
    #[must_use]
    pub fn list_type(bytes: &'a [u8], chunk: Chunk) -> Option<[u8; 4]> {
        if chunk.length < 4 {
            return None;
        }
        Some([
            bytes[chunk.start],
            bytes[chunk.start + 1],
            bytes[chunk.start + 2],
            bytes[chunk.start + 3],
        ])
    }
}

/// Read a fixed-width, NUL-padded name out of a record.
#[must_use]
pub fn read_name(bytes: &[u8]) -> String {
    let end = bytes.iter().position(|&b| b == 0).unwrap_or(bytes.len());
    String::from_utf8_lossy(&bytes[..end]).trim_end().to_owned()
}

/// Read a little-endian `u16`.
#[must_use]
pub fn read_u16(bytes: &[u8], at: usize) -> u16 {
    u16::from_le_bytes([bytes[at], bytes[at + 1]])
}

/// Read a little-endian `i16`.
#[must_use]
pub fn read_i16(bytes: &[u8], at: usize) -> i16 {
    i16::from_le_bytes([bytes[at], bytes[at + 1]])
}

/// Read a little-endian `u32`.
#[must_use]
pub fn read_u32(bytes: &[u8], at: usize) -> u32 {
    u32::from_le_bytes([bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]])
}

#[cfg(test)]
// The helpers below take four-byte chunk ids by reference because that is how
// a byte-string literal arrives.
#[allow(clippy::trivially_copy_pass_by_ref)]
mod tests {
    use super::*;

    fn riff(form: &[u8; 4], body: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(b"RIFF");
        out.extend_from_slice(&((body.len() + 4) as u32).to_le_bytes());
        out.extend_from_slice(form);
        out.extend_from_slice(body);
        out
    }

    fn chunk(id: &[u8; 4], body: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(id);
        out.extend_from_slice(&(body.len() as u32).to_le_bytes());
        out.extend_from_slice(body);
        if body.len() % 2 == 1 {
            out.push(0);
        }
        out
    }

    #[test]
    fn reads_chunks_in_order() {
        let mut body = Vec::new();
        body.extend_from_slice(&chunk(b"one ", &[1, 2, 3, 4]));
        body.extend_from_slice(&chunk(b"two ", &[5, 6]));
        let file = riff(b"sfbk", &body);

        let mut reader = RiffReader::open(&file).unwrap();
        let first = reader.next_chunk().unwrap().unwrap();
        assert_eq!(&first.id, b"one ");
        assert_eq!(first.length, 4);
        let second = reader.next_chunk().unwrap().unwrap();
        assert_eq!(&second.id, b"two ");
        assert!(reader.next_chunk().unwrap().is_none());
    }

    #[test]
    fn skips_the_pad_byte_after_an_odd_chunk() {
        let mut body = Vec::new();
        body.extend_from_slice(&chunk(b"odd ", &[1, 2, 3]));
        body.extend_from_slice(&chunk(b"next", &[9]));
        let file = riff(b"sfbk", &body);

        let mut reader = RiffReader::open(&file).unwrap();
        reader.next_chunk().unwrap().unwrap();
        let next = reader.next_chunk().unwrap().unwrap();
        assert_eq!(&next.id, b"next");
    }

    #[test]
    fn refuses_what_is_not_a_soundfont() {
        assert!(matches!(
            RiffReader::open(b"not a file at all"),
            Err(SoundFontError::NotASoundFont { .. })
        ));
        assert!(matches!(
            RiffReader::open(&riff(b"WAVE", &[])),
            Err(SoundFontError::NotASoundFont { .. })
        ));
        assert!(matches!(
            RiffReader::open(b"RIFF"),
            Err(SoundFontError::Truncated { .. })
        ));
    }

    #[test]
    fn refuses_a_chunk_that_runs_off_the_end() {
        // A chunk header inside the form that claims more bytes than the file
        // has. The declared RIFF size covers the header, so the reader reaches
        // it and then finds the body is not there.
        let mut body = Vec::new();
        body.extend_from_slice(b"big ");
        body.extend_from_slice(&9999u32.to_le_bytes());
        let file = riff(b"sfbk", &body);

        let mut reader = RiffReader::open(&file).unwrap();
        assert!(matches!(
            reader.next_chunk(),
            Err(SoundFontError::Truncated { .. })
        ));
    }

    #[test]
    fn a_declared_size_near_u32_max_clamps_to_the_file() {
        // L-RS3: `declared + 8` must not overflow a `usize` on a 32-bit
        // target. Here it asserts the clamp still reads the whole file — the
        // crafted size claims everything, so nothing is cut off.
        let mut file = riff(b"sfbk", &chunk(b"one ", &[1, 2]));
        file[4..8].copy_from_slice(&u32::MAX.to_le_bytes());
        let mut reader = RiffReader::open(&file).unwrap();
        assert_eq!(&reader.next_chunk().unwrap().unwrap().id, b"one ");
        assert!(reader.next_chunk().unwrap().is_none());
    }

    #[test]
    fn a_chunk_length_near_u32_max_is_rejected_rather_than_overflowing() {
        // L-RS3: `start + length` in `usize` would overflow on a 32-bit
        // target for this crafted header; in u64 it is simply a body the
        // file does not have.
        let mut body = Vec::new();
        body.extend_from_slice(b"huge");
        body.extend_from_slice(&u32::MAX.to_le_bytes());
        let file = riff(b"sfbk", &body);

        let mut reader = RiffReader::open(&file).unwrap();
        assert!(matches!(
            reader.next_chunk(),
            Err(SoundFontError::Truncated { .. })
        ));
    }

    #[test]
    fn stops_at_the_declared_size_rather_than_reading_trailing_junk() {
        let mut file = riff(b"sfbk", &chunk(b"one ", &[1, 2]));
        file.extend_from_slice(b"junk after the declared size");
        let mut reader = RiffReader::open(&file).unwrap();
        assert_eq!(&reader.next_chunk().unwrap().unwrap().id, b"one ");
        assert!(reader.next_chunk().unwrap().is_none());
    }

    #[test]
    fn reads_a_list_body() {
        let mut inner = Vec::new();
        inner.extend_from_slice(b"INFO");
        inner.extend_from_slice(&chunk(b"ifil", &[1, 0, 4, 0]));
        let file = riff(b"sfbk", &chunk(b"LIST", &inner));

        let mut reader = RiffReader::open(&file).unwrap();
        let list = reader.next_chunk().unwrap().unwrap();
        assert_eq!(RiffReader::list_type(&file, list).unwrap(), *b"INFO");
        let mut body = RiffReader::list_body(&file, list).unwrap();
        let ifil = body.next_chunk().unwrap().unwrap();
        assert_eq!(&ifil.id, b"ifil");
        assert!(body.next_chunk().unwrap().is_none());
    }

    #[test]
    fn names_stop_at_the_first_nul() {
        assert_eq!(read_name(b"Piano\0\0\0\0"), "Piano");
        assert_eq!(read_name(b"NoTerminator"), "NoTerminator");
        assert_eq!(read_name(b"Trailing   \0"), "Trailing");
    }
}
