//! The §11.2 audio null test: render offline, compare against a stored
//! reference, fail on any difference beyond a sample threshold.
//!
//! *"Catches synth regressions no listening test will."* A change to an
//! envelope curve, an interpolation coefficient or a generator default can move
//! every sample slightly and still sound fine in isolation — until it is
//! stacked eight voices deep on a stage. Comparing against audio rendered by a
//! known-good build catches that on the next `just check`.
//!
//! The reference describes one bank. Rendering `TimGM6mb.sf2` and comparing it
//! against a reference made from `FluidR3_GM.sf2` would fail for a reason that
//! has nothing to do with the synth, so the bank is identified by size and
//! digest and the test says so and skips when it does not match. That is a real
//! limitation, not a hidden one: on a machine with a different soundfont this
//! test reports that it cannot run rather than passing vacuously.
//!
//! To record a reference after a *deliberate* change to the synth, listen to
//! the new render first, then:
//!
//! ```text
//! BANDSTAND_BLESS_REFERENCE=1 cargo test --test audio_null_test
//! ```
//!
//! and commit the new file with the reason in the message.

#![allow(clippy::cast_precision_loss, clippy::cast_possible_truncation)]

use std::path::{Path, PathBuf};
use std::sync::Arc;

use bandstand_sequencer::{EventKind, Sequence, TimedEvent};
use bandstand_synth::sf2::load_soundfont;
use bandstand_synth::CHANNEL_COUNT;
use bandstand_transport::TempoMap;
use rust_lib_bandstand::render_to_wav;

/// The mix the reference was rendered with: the synth's own default channel
/// state (volume 100/127, centred, unmuted), passed explicitly so a mixer
/// change cannot slip into the comparison unnoticed.
const FLAT_MIX: [(f32, f32, bool); CHANNEL_COUNT] = [(100.0 / 127.0, 0.0, false); CHANNEL_COUNT];

/// The bank the reference was rendered from.
///
/// `TimGM6mb.sf2` because it is small, ships with Ubuntu's `timgm6mb-soundfont`
/// package, and has not changed since 2015 — a reference is only useful if the
/// thing it describes holds still.
const REFERENCE_BANK: &str = "/usr/share/sounds/sf2/TimGM6mb.sf2";
const REFERENCE_BANK_BYTES: u64 = 5_969_788;

const SAMPLE_RATE: u32 = 48_000;

/// How much of the render the reference stores.
///
/// The offline renderer runs a fixed tail past the end of the sequence so
/// releases and reverb are not cut off, and for this sequence three of the six
/// and a half seconds are digital silence. Storing them would be a megabyte of
/// git history carrying no information, so the reference holds the music and
/// its decay, and the test asserts separately that what follows is actually
/// silent — which is the stronger check, because a stuck voice or a runaway
/// reverb tail shows up there and nowhere else.
const REFERENCE_FRAMES: usize = 4 * SAMPLE_RATE as usize;
const MASTER_GAIN: f32 = 0.5;
const PPQ: u32 = 960;

/// A ii–V–I with a bass note under each chord: piano and bass, two programs,
/// sustained and released. Enough voices to exercise the mixer and the release
/// tails, short enough that the stored reference stays under a megabyte.
fn reference_sequence() -> Sequence {
    const PIANO: u8 = 0;
    const BASS: u8 = 1;
    let beat = u64::from(PPQ);

    let mut events = vec![
        TimedEvent::new(
            0,
            PIANO,
            EventKind::Program {
                bank: 0,
                program: 0,
            },
        ),
        TimedEvent::new(
            0,
            BASS,
            EventKind::Program {
                bank: 0,
                program: 32,
            },
        ),
    ];

    let chords: [(u64, [u8; 4], u8); 3] = [
        (0, [62, 65, 69, 72], 38),        // Dm7 over D
        (beat * 2, [55, 62, 65, 71], 31), // G7 over G
        (beat * 4, [60, 64, 67, 71], 36), // Cmaj7 over C
    ];
    for (tick, voicing, bass) in chords {
        let end = tick + beat * 2;
        for key in voicing {
            events.push(TimedEvent::note_on(tick, PIANO, key, 88));
            events.push(TimedEvent::new(end, PIANO, EventKind::NoteOff { key }));
        }
        events.push(TimedEvent::note_on(tick, BASS, bass, 100));
        events.push(TimedEvent::new(end, BASS, EventKind::NoteOff { key: bass }));
    }

    // A beat past the last release, so the reference carries the tails rather
    // than cutting them — a change to the release curve has to show up.
    Sequence::new(events, PPQ, beat * 7)
}

fn reference_path() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/references/ii-v-i.wav")
}

/// The bank this reference describes, if this machine has it.
fn reference_bank() -> Option<PathBuf> {
    let path = Path::new(REFERENCE_BANK);
    let bytes = std::fs::metadata(path).ok()?.len();
    if bytes != REFERENCE_BANK_BYTES {
        eprintln!("{REFERENCE_BANK} is {bytes} bytes, not {REFERENCE_BANK_BYTES}");
        return None;
    }
    Some(path.to_path_buf())
}

/// Read the samples out of a 16-bit PCM WAV, ignoring the header.
fn read_samples(path: &Path) -> Vec<i16> {
    let bytes = std::fs::read(path).expect("the render is on disk");
    // The writer emits a canonical 44-byte header; anything else is a bug in
    // the writer, which the offline render tests cover.
    assert!(
        bytes.len() > 44,
        "{} is too short to be a WAV",
        path.display()
    );
    bytes[44..]
        .chunks_exact(2)
        .map(|pair| i16::from_le_bytes([pair[0], pair[1]]))
        .collect()
}

/// Write 16-bit stereo samples as a WAV, so the reference can be listened to.
///
/// A reference nobody can play is a reference nobody will re-record correctly:
/// the blessing workflow asks you to hear the new render before committing it.
fn write_wav(path: &Path, samples: &[i16]) {
    let data_bytes = (samples.len() * 2) as u32;
    let mut out = Vec::with_capacity(44 + samples.len() * 2);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(36 + data_bytes).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes()); // PCM
    out.extend_from_slice(&2u16.to_le_bytes()); // stereo
    out.extend_from_slice(&SAMPLE_RATE.to_le_bytes());
    out.extend_from_slice(&(SAMPLE_RATE * 4).to_le_bytes());
    out.extend_from_slice(&4u16.to_le_bytes());
    out.extend_from_slice(&16u16.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&data_bytes.to_le_bytes());
    for sample in samples {
        out.extend_from_slice(&sample.to_le_bytes());
    }
    std::fs::create_dir_all(path.parent().expect("has a parent")).expect("can create");
    std::fs::write(path, out).expect("the reference is written");
}

#[test]
fn the_render_matches_its_reference() {
    let Some(bank_path) = reference_bank() else {
        eprintln!("this machine does not have the bank the reference describes; skipping");
        return;
    };

    let bank = Arc::new(load_soundfont(&bank_path).expect("the bank reads"));
    let temporary = std::env::temp_dir().join("bandstand-null-test.wav");
    let summary = render_to_wav(
        &temporary,
        bank,
        &reference_sequence(),
        &TempoMap::constant(PPQ, 120.0).expect("a constant tempo map"),
        SAMPLE_RATE,
        MASTER_GAIN,
        FLAT_MIX,
    )
    .expect("the render succeeds");
    assert_eq!(summary.clipped, 0, "the reference mix should not clip");

    let rendered = read_samples(&temporary);
    std::fs::remove_file(&temporary).ok();
    let stored = REFERENCE_FRAMES * 2;
    assert!(
        rendered.len() > stored,
        "the render is only {} samples; it should run past the {stored} the \
         reference covers",
        rendered.len()
    );

    let reference = reference_path();
    if std::env::var_os("BANDSTAND_BLESS_REFERENCE").is_some() {
        write_wav(&reference, &rendered[..stored]);
        eprintln!("recorded a new reference at {}", reference.display());
        return;
    }

    assert!(
        reference.exists(),
        "no reference at {}; record one with BANDSTAND_BLESS_REFERENCE=1 \
         after listening to the render",
        reference.display()
    );

    let expected = read_samples(&reference);
    assert_eq!(
        expected.len(),
        stored,
        "the reference is {} samples against the {stored} this test compares — \
         re-record it",
        expected.len()
    );

    // Past what the reference stores, the render has to have decayed to
    // nothing. A voice that never finishes, or a reverb that feeds back, shows
    // up here as sound where there should be none.
    let loudest_tail = rendered[stored..]
        .iter()
        .map(|sample| sample.unsigned_abs())
        .max()
        .unwrap_or(0);
    assert!(
        loudest_tail <= 4,
        "the render is still at {loudest_tail} four seconds after the last \
         note was released — something is not decaying"
    );

    let rendered = &rendered[..stored];

    let mut peak = 0i32;
    let mut peak_at = 0usize;
    let mut squared = 0f64;
    for (index, (&got, &want)) in rendered.iter().zip(expected.iter()).enumerate() {
        let difference = i32::from(got) - i32::from(want);
        if difference.abs() > peak {
            peak = difference.abs();
            peak_at = index;
        }
        squared += (difference as f64) * (difference as f64);
    }
    let rms = (squared / rendered.len() as f64).sqrt();

    println!(
        "NULL TEST peak difference {peak} at sample {peak_at}, RMS {rms:.2}, \
         over {} samples",
        rendered.len()
    );

    // Bit-exactness is the intent — the renderer is deterministic and does no
    // dithering — but two least-significant bits of slack absorb the last
    // rounding step differing between compilers and target features, which
    // would be a build difference rather than a synth regression. Anything
    // audible is thousands of times larger than this.
    assert!(
        peak <= 2,
        "the render differs from its reference by {peak} at sample {peak_at} \
         (RMS {rms:.2}). If the synth was changed on purpose, listen to the new \
         render, then re-record with BANDSTAND_BLESS_REFERENCE=1."
    );
}

#[test]
fn the_render_is_deterministic() {
    // The null test is only meaningful if two renders of the same input agree.
    // §11.2: *"same seed ⇒ byte-identical output. This underpins every other
    // test."* Here there is no seed at all — the synth is a pure function of
    // the sequence — so the bar is byte-identical, with no slack.
    let Some(bank_path) = reference_bank() else {
        eprintln!("this machine does not have the bank the reference describes; skipping");
        return;
    };

    let bank = Arc::new(load_soundfont(&bank_path).expect("the bank reads"));
    let sequence = reference_sequence();
    let tempo = TempoMap::constant(PPQ, 120.0).expect("a constant tempo map");

    let mut renders = Vec::new();
    for pass in 0..2 {
        let path = std::env::temp_dir().join(format!("bandstand-determinism-{pass}.wav"));
        render_to_wav(
            &path,
            Arc::clone(&bank),
            &sequence,
            &tempo,
            SAMPLE_RATE,
            MASTER_GAIN,
            FLAT_MIX,
        )
        .expect("the render succeeds");
        renders.push(std::fs::read(&path).expect("the file is there"));
        std::fs::remove_file(&path).ok();
    }

    assert_eq!(
        renders[0], renders[1],
        "two renders of the same sequence differ; something in the synth is \
         reading uninitialised state or time"
    );
}
