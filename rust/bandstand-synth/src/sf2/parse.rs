//! Reading a SoundFont file into a [`SoundBank`].
//!
//! Rules: `docs/rules/sf2-sampler.md` §1 and §2.

use std::fs::File;
use std::path::Path;
use std::sync::Arc;

use super::bank::{ByteRange, GeneratorSet, Instrument, Preset, SampleHeader, SoundBank, Zone};
use super::generators::Generator;
use super::riff::{read_i16, read_name, read_u16, read_u32, Chunk, RiffReader, SoundFontError};
use super::samples::{MappedSamples, ResidentSamples, SampleSource};

const PHDR_SIZE: usize = 38;
const BAG_SIZE: usize = 4;
const MOD_SIZE: usize = 10;
const GEN_SIZE: usize = 4;
const INST_SIZE: usize = 22;
const SHDR_SIZE: usize = 46;

/// Load a SoundFont from a file, memory-mapping its sample data (ADR 0007).
///
/// The mapping is read-only and faults pages in on demand;
/// [`SoundBank::warm_preset`] brings a preset's samples in on the control
/// thread so the audio thread does not pay for the first pass.
///
/// The file must not be truncated, replaced or deleted while the bank is
/// loaded. A read from a mapping whose file has shrunk underneath it is a
/// `SIGBUS`, which kills the process uncatchably; nothing in this crate can
/// defend against that at read time. Bandstand loads soundfonts only from
/// `~/Music/Bandstand/soundbanks/`, which the app never writes — the
/// constraint and its reason are recorded in
/// `docs/decisions/0007-sample-access.md`.
///
/// # Errors
/// Returns [`SoundFontError::Io`] if the file cannot be opened or mapped,
/// or another [`SoundFontError`] variant if the bytes are not a SoundFont
/// this build understands.
pub fn load_soundfont(path: &Path) -> Result<SoundBank, SoundFontError> {
    let file = File::open(path).map_err(|error| SoundFontError::Io {
        what: "open the soundfont",
        error,
    })?;
    // SAFETY: the mapping is read-only. The file must not change on disk
    // while it is mapped — a truncated or replaced file turns a read into
    // SIGBUS — which is documented above and recorded in ADR 0007.
    let mapping = unsafe { memmap2::Mmap::map(&file) }.map_err(|error| SoundFontError::Io {
        what: "map the soundfont",
        error,
    })?;
    let mapping = Arc::new(mapping);
    parse(&mapping.clone(), Some(&mapping))
}

/// Parse a SoundFont already in memory.
///
/// Used by tests and by banks that arrive as bytes rather than as a file.
///
/// # Errors
/// Returns [`SoundFontError`] if the bytes are not a SoundFont this build
/// understands.
pub fn parse_soundfont(bytes: &[u8]) -> Result<SoundBank, SoundFontError> {
    parse(bytes, None)
}

/// Where the chunks that matter are.
struct Layout {
    smpl: Option<Chunk>,
    phdr: Option<Chunk>,
    pbag: Option<Chunk>,
    pgen: Option<Chunk>,
    inst: Option<Chunk>,
    ibag: Option<Chunk>,
    igen: Option<Chunk>,
    shdr: Option<Chunk>,
    name: String,
}

fn parse(bytes: &[u8], mapping: Option<&Arc<memmap2::Mmap>>) -> Result<SoundBank, SoundFontError> {
    let layout = find_chunks(bytes)?;

    let phdr = require(layout.phdr, "phdr")?;
    let pbag = require(layout.pbag, "pbag")?;
    let pgen = require(layout.pgen, "pgen")?;
    let inst = require(layout.inst, "inst")?;
    let ibag = require(layout.ibag, "ibag")?;
    let igen = require(layout.igen, "igen")?;
    let shdr = require(layout.shdr, "shdr")?;

    let bags = read_bags(bytes, pbag, "pbag")?;
    let gens = read_generators(bytes, pgen, "pgen")?;
    let instrument_bags = read_bags(bytes, ibag, "ibag")?;
    let instrument_gens = read_generators(bytes, igen, "igen")?;
    let samples = read_samples(bytes, shdr)?;

    let instruments = read_instruments(
        bytes,
        inst,
        &instrument_bags,
        &instrument_gens,
        samples.len(),
    )?;
    let presets = read_presets(bytes, phdr, &bags, &gens, instruments.len())?;

    let data: Arc<dyn SampleSource> = match (layout.smpl, mapping) {
        (Some(chunk), Some(mapping)) => {
            let frames = chunk.length / 2;
            Arc::new(
                MappedSamples::new(Arc::clone(mapping), chunk.start, frames).map_err(
                    |(start, end)| SoundFontError::Truncated {
                        what: "the sample data",
                        needed: end - start,
                        available: 0,
                    },
                )?,
            )
        }
        (Some(chunk), None) => Arc::new(ResidentSamples::from_bytes(
            &bytes[chunk.start..chunk.end()],
        )),
        (None, _) => Arc::new(ResidentSamples::new(Vec::new())),
    };

    Ok(SoundBank {
        name: layout.name,
        presets,
        instruments,
        samples,
        data,
    })
}

fn require(chunk: Option<Chunk>, id: &'static str) -> Result<Chunk, SoundFontError> {
    chunk.ok_or(SoundFontError::MissingChunk { id })
}

fn find_chunks(bytes: &[u8]) -> Result<Layout, SoundFontError> {
    let mut layout = Layout {
        smpl: None,
        phdr: None,
        pbag: None,
        pgen: None,
        inst: None,
        ibag: None,
        igen: None,
        shdr: None,
        name: String::new(),
    };

    let mut top = RiffReader::open(bytes)?;
    while let Some(chunk) = top.next_chunk()? {
        if &chunk.id != b"LIST" {
            continue;
        }
        let Some(kind) = RiffReader::list_type(bytes, chunk) else {
            continue;
        };
        let mut body = RiffReader::list_body(bytes, chunk)?;
        while let Some(inner) = body.next_chunk()? {
            match (&kind, &inner.id) {
                (b"INFO", b"INAM") => {
                    layout.name = read_name(&bytes[inner.start..inner.end()]);
                }
                (b"sdta", b"smpl") => layout.smpl = Some(inner),
                (b"pdta", b"phdr") => layout.phdr = Some(inner),
                (b"pdta", b"pbag") => layout.pbag = Some(inner),
                (b"pdta", b"pgen") => layout.pgen = Some(inner),
                (b"pdta", b"inst") => layout.inst = Some(inner),
                (b"pdta", b"ibag") => layout.ibag = Some(inner),
                (b"pdta", b"igen") => layout.igen = Some(inner),
                (b"pdta", b"shdr") => layout.shdr = Some(inner),
                _ => {}
            }
        }
    }
    Ok(layout)
}

/// One `pbag` or `ibag` record: where a zone's generators start.
#[derive(Debug, Clone, Copy)]
struct Bag {
    generator_index: usize,
}

#[allow(clippy::needless_pass_by_value)]
fn read_bags(bytes: &[u8], chunk: Chunk, id: &'static str) -> Result<Vec<Bag>, SoundFontError> {
    check_record_length(chunk, BAG_SIZE, id)?;
    let count = chunk.length / BAG_SIZE;
    if count < 1 {
        return Err(SoundFontError::NoTerminalRecord { id });
    }
    Ok((0..count)
        .map(|i| Bag {
            generator_index: read_u16(bytes, chunk.start + i * BAG_SIZE) as usize,
        })
        .collect())
}

/// One `pgen` or `igen` record.
#[derive(Debug, Clone, Copy)]
struct GeneratorRecord {
    operator: u16,
    amount: i16,
}

fn read_generators(
    bytes: &[u8],
    chunk: Chunk,
    id: &'static str,
) -> Result<Vec<GeneratorRecord>, SoundFontError> {
    check_record_length(chunk, GEN_SIZE, id)?;
    let count = chunk.length / GEN_SIZE;
    Ok((0..count)
        .map(|i| {
            let at = chunk.start + i * GEN_SIZE;
            GeneratorRecord {
                operator: read_u16(bytes, at),
                amount: read_i16(bytes, at + 2),
            }
        })
        .collect())
}

fn read_samples(bytes: &[u8], chunk: Chunk) -> Result<Vec<SampleHeader>, SoundFontError> {
    check_record_length(chunk, SHDR_SIZE, "shdr")?;
    let count = chunk.length / SHDR_SIZE;
    if count < 1 {
        return Err(SoundFontError::NoTerminalRecord { id: "shdr" });
    }
    // The last record is the terminal `EOS` marker.
    Ok((0..count - 1)
        .map(|i| {
            let at = chunk.start + i * SHDR_SIZE;
            SampleHeader {
                name: read_name(&bytes[at..at + 20]),
                start: read_u32(bytes, at + 20),
                end: read_u32(bytes, at + 24),
                loop_start: read_u32(bytes, at + 28),
                loop_end: read_u32(bytes, at + 32),
                sample_rate: read_u32(bytes, at + 36),
                original_pitch: bytes[at + 40],
                pitch_correction: bytes[at + 41] as i8,
                link: read_u16(bytes, at + 42),
                sample_type: read_u16(bytes, at + 44),
            }
        })
        .collect())
}

fn read_instruments(
    bytes: &[u8],
    chunk: Chunk,
    bags: &[Bag],
    generators: &[GeneratorRecord],
    sample_count: usize,
) -> Result<Vec<Instrument>, SoundFontError> {
    check_record_length(chunk, INST_SIZE, "inst")?;
    let count = chunk.length / INST_SIZE;
    if count < 2 {
        return Err(SoundFontError::NoTerminalRecord { id: "inst" });
    }

    let mut instruments = Vec::with_capacity(count - 1);
    for i in 0..count - 1 {
        let at = chunk.start + i * INST_SIZE;
        let name = read_name(&bytes[at..at + 20]);
        let first_bag = read_u16(bytes, at + 20) as usize;
        let next_bag = read_u16(bytes, at + INST_SIZE + 20) as usize;
        instruments.push(Instrument {
            name,
            zones: read_zones(
                bags,
                generators,
                first_bag,
                next_bag,
                Generator::SampleId,
                sample_count,
                "ibag",
            )?,
        });
    }
    Ok(instruments)
}

fn read_presets(
    bytes: &[u8],
    chunk: Chunk,
    bags: &[Bag],
    generators: &[GeneratorRecord],
    instrument_count: usize,
) -> Result<Vec<Preset>, SoundFontError> {
    check_record_length(chunk, PHDR_SIZE, "phdr")?;
    let count = chunk.length / PHDR_SIZE;
    if count < 2 {
        return Err(SoundFontError::NoTerminalRecord { id: "phdr" });
    }

    let mut presets = Vec::with_capacity(count - 1);
    for i in 0..count - 1 {
        let at = chunk.start + i * PHDR_SIZE;
        let first_bag = read_u16(bytes, at + 24) as usize;
        let next_bag = read_u16(bytes, at + PHDR_SIZE + 24) as usize;
        presets.push(Preset {
            name: read_name(&bytes[at..at + 20]),
            program: read_u16(bytes, at + 20),
            bank: read_u16(bytes, at + 22),
            zones: read_zones(
                bags,
                generators,
                first_bag,
                next_bag,
                Generator::Instrument,
                instrument_count,
                "pbag",
            )?,
        });
    }
    Ok(presets)
}

/// Build the zones between two bag indices.
///
/// The first zone is a *global zone* if it has no target generator; its
/// generators become the defaults for the rest (`docs/rules/sf2-sampler.md`
/// §2).
fn read_zones(
    bags: &[Bag],
    generators: &[GeneratorRecord],
    first_bag: usize,
    next_bag: usize,
    target_generator: Generator,
    target_count: usize,
    bag_id: &'static str,
) -> Result<Vec<Zone>, SoundFontError> {
    if first_bag > bags.len() || next_bag > bags.len() {
        return Err(SoundFontError::IndexOutOfRange {
            what: bag_id,
            index: first_bag.max(next_bag),
            length: bags.len(),
        });
    }
    let mut zones = Vec::new();
    let mut global = GeneratorSet::defaults();
    let mut seen_global = false;

    for bag in first_bag..next_bag {
        let start = bags[bag].generator_index;
        let end = bags
            .get(bag + 1)
            .map_or(generators.len(), |next| next.generator_index);
        if start > generators.len() || end > generators.len() || start > end {
            continue;
        }

        let mut stated = GeneratorSet::zeroed();
        let mut target: Option<usize> = None;
        for record in &generators[start..end] {
            let Some(generator) = Generator::from_operator(record.operator) else {
                continue;
            };
            if generator == target_generator {
                target = Some(record.amount as u16 as usize);
            }
            stated.set(generator, record.amount);
        }

        match target {
            None if !seen_global && zones.is_empty() => {
                // A leading zone with no target is the global zone.
                seen_global = true;
                global = GeneratorSet::defaults();
                global.overlay(&stated);
            }
            Some(index) if index < target_count => {
                let mut resolved = global.clone();
                resolved.overlay(&stated);
                zones.push(Zone {
                    key_range: ByteRange::from_generator(resolved.get(Generator::KeyRange)),
                    velocity_range: ByteRange::from_generator(resolved.get(Generator::VelRange)),
                    generators: resolved,
                    target: index,
                });
            }
            // A zone with no target that is not the first is malformed, and
            // one pointing at an instrument or sample the file does not have is
            // broken. The specification says to ignore both, and so does every
            // other synth.
            None | Some(_) => {}
        }
    }
    Ok(zones)
}

fn check_record_length(
    chunk: Chunk,
    record: usize,
    id: &'static str,
) -> Result<(), SoundFontError> {
    if chunk.length % record != 0 {
        return Err(SoundFontError::BadChunkLength {
            id,
            length: chunk.length,
            record,
        });
    }
    Ok(())
}

/// The size of a modulator record, for callers that skip them.
///
/// Bandstand does not implement modulators: the default modulator set is what
/// every General MIDI bank relies on, and it is implemented directly in the
/// voice (velocity to attenuation, key to filter). File-defined modulators are
/// read past.
pub const MODULATOR_RECORD_SIZE: usize = MOD_SIZE;
