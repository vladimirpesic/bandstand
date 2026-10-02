//! Rendering a sequence through a real soundfont to a real file.
//!
//! This is the whole audio core end to end with no device involved: parser,
//! sampler, sequencer, transport and file writer. It is also how the §10 M4
//! acceptance test is run — comparing Bandstand against FluidSynth needs a
//! file, not a speaker.

#![allow(clippy::cast_precision_loss, clippy::cast_possible_truncation)]

use std::path::{Path, PathBuf};
use std::sync::Arc;

use bandstand_sequencer::{click_track, EventKind, MetronomeSpec, Sequence, TimedEvent};
use bandstand_synth::sf2::load_soundfont;
use bandstand_synth::CHANNEL_COUNT;
use bandstand_transport::TempoMap;
use rust_lib_bandstand::render_to_wav;

/// The synth's own default channel state (volume 100/127, centred, unmuted),
/// passed explicitly wherever a test is about the render itself rather than
/// the mixer.
const FLAT_MIX: [(f32, f32, bool); CHANNEL_COUNT] = [(100.0 / 127.0, 0.0, false); CHANNEL_COUNT];

const CANDIDATES: &[&str] = &[
    "/usr/share/sounds/sf2/TimGM6mb.sf2",
    "/usr/share/sounds/sf2/default-GM.sf2",
    "/usr/share/soundfonts/default.sf2",
    "/usr/share/sounds/sf2/FluidR3_GM.sf2",
];

const PPQ: u32 = 960;

fn find_bank() -> Option<PathBuf> {
    CANDIDATES
        .iter()
        .map(Path::new)
        .find(|path| path.exists())
        .map(Path::to_path_buf)
}

/// A ii–V–I in C: three chords, four beats each.
fn progression() -> Sequence {
    let chords: [(u64, [u8; 4]); 3] = [
        (0, [50, 57, 60, 65]),    // Dm7
        (3840, [43, 47, 53, 57]), // G7
        (7680, [48, 52, 55, 59]), // Cmaj7
    ];
    let mut events = vec![TimedEvent::new(
        0,
        0,
        EventKind::Program {
            bank: 0,
            program: 0,
        },
    )];
    for (tick, keys) in chords {
        for key in keys {
            events.push(TimedEvent::note_on(tick, 0, key, 96));
            events.push(TimedEvent::note_off(tick + 3600, 0, key));
        }
    }
    Sequence::new(events, PPQ, 11_520)
}

fn read_wav(path: &Path) -> (u32, u16, Vec<i16>) {
    let bytes = std::fs::read(path).expect("the file reads back");
    assert_eq!(&bytes[0..4], b"RIFF");
    assert_eq!(&bytes[8..12], b"WAVE");
    assert_eq!(&bytes[12..16], b"fmt ");
    let channels = u16::from_le_bytes([bytes[22], bytes[23]]);
    let rate = u32::from_le_bytes([bytes[24], bytes[25], bytes[26], bytes[27]]);
    assert_eq!(&bytes[36..40], b"data");
    let length = u32::from_le_bytes([bytes[40], bytes[41], bytes[42], bytes[43]]) as usize;
    assert_eq!(bytes.len(), 44 + length, "the header's length is wrong");
    let samples = bytes[44..]
        .chunks_exact(2)
        .map(|pair| i16::from_le_bytes([pair[0], pair[1]]))
        .collect();
    (rate, channels, samples)
}

fn peak(samples: &[i16]) -> i16 {
    samples
        .iter()
        .fold(0i16, |acc, s| acc.max(s.saturating_abs()))
}

struct Bounce {
    path: PathBuf,
}

impl Drop for Bounce {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

fn bounce(name: &str) -> Bounce {
    Bounce {
        path: std::env::temp_dir().join(name),
    }
}

#[test]
fn a_progression_renders_to_a_playable_wav() {
    let Some(bank_path) = find_bank() else {
        eprintln!("no General MIDI soundfont on this machine; skipping");
        return;
    };
    let bank = Arc::new(load_soundfont(&bank_path).expect("the bank reads"));
    let map = TempoMap::constant(PPQ, 120.0).unwrap();
    let out = bounce("bandstand-progression.wav");

    let summary = render_to_wav(&out.path, bank, &progression(), &map, 48_000, 0.5, FLAT_MIX)
        .expect("the render succeeds");

    assert_eq!(summary.sample_rate, 48_000);
    assert_eq!(summary.channels, 2);
    // Three bars at 120 bpm is six seconds, plus the tail.
    assert!(
        summary.duration_seconds() > 8.0 && summary.duration_seconds() < 12.0,
        "{} seconds",
        summary.duration_seconds()
    );
    assert_eq!(summary.clipped, 0, "the mix clipped");

    let (rate, channels, samples) = read_wav(&out.path);
    assert_eq!(rate, 48_000);
    assert_eq!(channels, 2);
    assert_eq!(samples.len() as u64, summary.frames * 2);
    assert!(peak(&samples) > 1000, "peak {}", peak(&samples));
}

#[test]
fn the_chords_arrive_when_the_tempo_says_they_do() {
    let Some(bank_path) = find_bank() else {
        return;
    };
    let bank = Arc::new(load_soundfont(&bank_path).expect("the bank reads"));
    let map = TempoMap::constant(PPQ, 120.0).unwrap();
    let out = bounce("bandstand-timing.wav");

    render_to_wav(&out.path, bank, &progression(), &map, 48_000, 0.5, FLAT_MIX).unwrap();
    let (rate, _, samples) = read_wav(&out.path);

    // The level in the tenth of a second before each chord change, and just
    // after it: a new chord must be louder than the decay it interrupts.
    let level_at = |seconds: f64| -> f64 {
        let start = (seconds * f64::from(rate)) as usize * 2;
        let end = (start + (0.05 * f64::from(rate)) as usize * 2).min(samples.len());
        if start >= end {
            return 0.0;
        }
        let window = &samples[start..end];
        (window
            .iter()
            .map(|s| f64::from(*s) * f64::from(*s))
            .sum::<f64>()
            / window.len() as f64)
            .sqrt()
    };

    // Chords land at 0, 2 and 4 seconds at 120 bpm with four beats each.
    for chord_at in [0.0_f64, 2.0, 4.0] {
        let before = level_at((chord_at - 0.1).max(0.0));
        let after = level_at(chord_at + 0.02);
        if chord_at == 0.0 {
            assert!(after > 100.0, "nothing sounds at the start: {after}");
        } else {
            assert!(
                after > before,
                "the chord at {chord_at}s ({after}) is quieter than the decay \
                 before it ({before})"
            );
        }
    }
}

#[test]
fn a_click_track_renders_on_the_drum_channel() {
    let Some(bank_path) = find_bank() else {
        return;
    };
    let bank = Arc::new(load_soundfont(&bank_path).expect("the bank reads"));
    let map = TempoMap::constant(PPQ, 120.0).unwrap();
    let out = bounce("bandstand-click.wav");

    let mut events = vec![TimedEvent::new(
        0,
        9,
        EventKind::Program {
            bank: 128,
            program: 0,
        },
    )];
    events.extend(click_track(MetronomeSpec::four_four(), PPQ, 0, 2));
    let sequence = Sequence::new(events, PPQ, PPQ as u64 * 8);

    let summary = render_to_wav(&out.path, bank, &sequence, &map, 44_100, 0.5, FLAT_MIX)
        .expect("the render succeeds");
    assert_eq!(summary.sample_rate, 44_100);

    let (_, _, samples) = read_wav(&out.path);
    assert!(peak(&samples) > 1000, "the click is silent");
}

#[test]
fn a_render_with_nothing_in_the_sequence_is_refused() {
    let Some(bank_path) = find_bank() else {
        return;
    };
    let bank = Arc::new(load_soundfont(&bank_path).expect("the bank reads"));
    let out = bounce("bandstand-empty.wav");
    assert!(render_to_wav(
        &out.path,
        bank,
        &Sequence::empty(),
        &TempoMap::default(),
        48_000,
        0.5,
        FLAT_MIX,
    )
    .is_err());
    assert!(!out.path.exists());
}

#[test]
fn a_render_to_a_path_that_cannot_be_written_reports_rather_than_panicking() {
    let Some(bank_path) = find_bank() else {
        return;
    };
    let bank = Arc::new(load_soundfont(&bank_path).expect("the bank reads"));
    let result = render_to_wav(
        Path::new("/no/such/directory/anywhere/out.wav"),
        bank,
        &progression(),
        &TempoMap::default(),
        48_000,
        0.5,
        FLAT_MIX,
    );
    assert!(result.is_err());
}

#[test]
fn the_same_input_renders_to_the_same_bytes() {
    // §11.2 asks for determinism: the same seed gives byte-identical output.
    // There is no seed here, and there must be no other source of variation
    // either — a bounce that differs run to run cannot be null-tested.
    let Some(bank_path) = find_bank() else {
        return;
    };
    let bank = Arc::new(load_soundfont(&bank_path).expect("the bank reads"));
    let map = TempoMap::constant(PPQ, 132.0).unwrap();

    let first = bounce("bandstand-determinism-a.wav");
    let second = bounce("bandstand-determinism-b.wav");
    render_to_wav(
        &first.path,
        Arc::clone(&bank),
        &progression(),
        &map,
        48_000,
        0.5,
        FLAT_MIX,
    )
    .unwrap();
    render_to_wav(
        &second.path,
        bank,
        &progression(),
        &map,
        48_000,
        0.5,
        FLAT_MIX,
    )
    .unwrap();

    assert_eq!(
        std::fs::read(&first.path).unwrap(),
        std::fs::read(&second.path).unwrap(),
        "two renders of the same input differ"
    );
}

#[test]
fn a_quiet_master_gain_does_not_clip_a_loud_mix() {
    let Some(bank_path) = find_bank() else {
        return;
    };
    let bank = Arc::new(load_soundfont(&bank_path).expect("the bank reads"));
    let map = TempoMap::constant(PPQ, 120.0).unwrap();
    let out = bounce("bandstand-loud.wav");

    // Every key at once, at full velocity: about as loud as it gets.
    let mut events = Vec::new();
    for key in 24..96u8 {
        events.push(TimedEvent::note_on(0, 0, key, 127));
        events.push(TimedEvent::note_off(1920, 0, key));
    }
    let sequence = Sequence::new(events, PPQ, 1920);

    let summary = render_to_wav(&out.path, bank, &sequence, &map, 48_000, 0.15, FLAT_MIX)
        .expect("the render succeeds");
    assert_eq!(summary.clipped, 0, "{} samples clipped", summary.clipped);
}

#[test]
fn the_bounce_carries_the_live_mix() {
    let Some(bank_path) = find_bank() else {
        return;
    };
    let bank = Arc::new(load_soundfont(&bank_path).expect("the bank reads"));
    let map = TempoMap::constant(PPQ, 120.0).unwrap();
    let loud = bounce("bandstand-mix-loud.wav");
    let muted = bounce("bandstand-mix-muted.wav");
    let quiet = bounce("bandstand-mix-quiet.wav");

    render_to_wav(
        &loud.path,
        Arc::clone(&bank),
        &progression(),
        &map,
        48_000,
        0.5,
        FLAT_MIX,
    )
    .expect("the render succeeds");

    // The channel carrying the progression is muted: the file must reflect
    // what the user hears, not the raw sequence.
    let mut mix = FLAT_MIX;
    mix[0].2 = true;
    render_to_wav(
        &muted.path,
        Arc::clone(&bank),
        &progression(),
        &map,
        48_000,
        0.5,
        mix,
    )
    .expect("the render succeeds");

    // And a lowered master gain must come through, not the old hardcoded 0.5.
    render_to_wav(
        &quiet.path,
        bank,
        &progression(),
        &map,
        48_000,
        0.05,
        FLAT_MIX,
    )
    .expect("the render succeeds");

    let (_, _, muted_samples) = read_wav(&muted.path);
    assert!(
        muted_samples.iter().all(|&s| s == 0),
        "a muted channel must be silent in the bounce"
    );

    let (_, _, loud_samples) = read_wav(&loud.path);
    let (_, _, quiet_samples) = read_wav(&quiet.path);
    let ratio = f64::from(peak(&quiet_samples)) / f64::from(peak(&loud_samples));
    assert!(
        ratio < 0.2,
        "a 0.05 master gain should peak far below the 0.5 render, at {ratio:.3}"
    );
}
