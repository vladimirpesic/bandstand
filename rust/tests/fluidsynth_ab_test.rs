//! A/B against FluidSynth — the §10 M4 acceptance.
//!
//! > *"Play a General MIDI file and A/B it against FluidSynth — no audible
//! > defects."*
//!
//! "No audible defects" is finally a listening judgement, and this harness
//! writes both files so a person can make it. What it *asserts* is the set of
//! defects that can be measured: notes missing or arriving late, a level that
//! is wildly off, clipping, silence where there should be sound, or a spectrum
//! missing a whole region.
//!
//! §11.2 calls this an audio null test. It is not a null test in the strict
//! sense — two different samplers reading the same bank will never cancel —
//! so what is compared is the envelope and the spectrum rather than the
//! samples.
//!
//! Skips when `fluidsynth` is not installed, so the suite stays green on a
//! machine without it (§12.1 lists it as a dev-box requirement).

#![allow(
    clippy::cast_precision_loss,
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss
)]

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;

use bandstand_sequencer::{EventKind, Sequence, TimedEvent};
use bandstand_synth::sf2::load_soundfont;
use bandstand_synth::CHANNEL_COUNT;
use bandstand_transport::TempoMap;
use rust_lib_bandstand::render_to_wav;

const PPQ: u32 = 960;
const RATE: u32 = 48_000;

/// The mix the A/B has always rendered with: the synth's own default channel
/// state (volume 100/127, centred, unmuted), so per-channel mixer settings do
/// not enter a comparison that is about the sampler.
const FLAT_MIX: [(f32, f32, bool); CHANNEL_COUNT] = [(100.0 / 127.0, 0.0, false); CHANNEL_COUNT];

/// The gains at which the two are actually comparable.
///
/// The two programs' gain parameters are not the same scale: rendering this
/// material through FluidSynth at -g 0.25, 0.5 and 1.0 gives exactly 2x the
/// level at each step, and Bandstand's `master_gain` of 0.5 lands at
/// FluidSynth's -g 0.219. Comparing the same *number* through both therefore
/// reports a 7 dB gap that is nothing but calibration.
///
/// At the pair below the two agree to within about 1 dB, so this is the
/// setting at which a level difference means something.
const OUR_GAIN: f32 = 0.5;
const THEIR_GAIN: &str = "0.2"; // FluidSynth's own default

const BANK_CANDIDATES: &[&str] = &[
    "/usr/share/sounds/sf2/TimGM6mb.sf2",
    "/usr/share/sounds/sf2/default-GM.sf2",
    "/usr/share/soundfonts/default.sf2",
    "/usr/share/sounds/sf2/FluidR3_GM.sf2",
];

fn find_bank() -> Option<PathBuf> {
    BANK_CANDIDATES
        .iter()
        .map(Path::new)
        .find(|path| path.exists())
        .and_then(|path| std::fs::canonicalize(path).ok())
}

fn has_fluidsynth() -> bool {
    Command::new("fluidsynth")
        .arg("--version")
        .output()
        .map(|out| out.status.success())
        .unwrap_or(false)
}

/// A file that removes itself.
struct Temp(PathBuf);

impl Drop for Temp {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

fn temp(name: &str) -> Temp {
    Temp(std::env::temp_dir().join(name))
}

// --- the test material -------------------------------------------------------

/// Four bars: a chord a bar, four notes each, at 120 bpm on the piano.
fn material() -> Vec<TimedEvent> {
    let chords: [[u8; 4]; 4] = [
        [50, 57, 60, 65], // Dm7
        [43, 47, 53, 57], // G7
        [48, 52, 55, 59], // Cmaj7
        [45, 52, 55, 60], // Am7
    ];
    let mut events = vec![TimedEvent::new(
        0,
        0,
        EventKind::Program {
            bank: 0,
            program: 0,
        },
    )];
    for (bar, keys) in chords.iter().enumerate() {
        let tick = bar as u64 * u64::from(PPQ) * 4;
        for key in keys {
            events.push(TimedEvent::note_on(tick, 0, *key, 100));
            events.push(TimedEvent::note_off(tick + u64::from(PPQ) * 3, 0, *key));
        }
    }
    events
}

fn sequence() -> Sequence {
    Sequence::new(material(), PPQ, u64::from(PPQ) * 16)
}

/// The same material as a Standard MIDI File, for FluidSynth to read.
fn write_midi(path: &Path) {
    let mut track: Vec<u8> = Vec::new();

    fn variable(value: u32, out: &mut Vec<u8>) {
        let mut buffer = vec![(value & 0x7F) as u8];
        let mut rest = value >> 7;
        while rest > 0 {
            buffer.insert(0, ((rest & 0x7F) | 0x80) as u8);
            rest >>= 7;
        }
        out.extend_from_slice(&buffer);
    }

    // Tempo, then the notes, as absolute ticks turned into deltas.
    let mut events: Vec<(u64, Vec<u8>, u8)> = vec![(
        0,
        vec![0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20], // 500 000 us = 120 bpm
        0,
    )];
    for event in material() {
        let bytes = match event.kind {
            EventKind::Program { program, .. } => {
                vec![0xC0, program as u8]
            }
            EventKind::NoteOn { key, velocity } => vec![0x90, key, velocity],
            EventKind::NoteOff { key } => vec![0x80, key, 0],
            _ => continue,
        };
        let order = match event.kind {
            EventKind::NoteOff { .. } => 0,
            EventKind::NoteOn { .. } => 2,
            _ => 1,
        };
        events.push((event.tick, bytes, order));
    }
    events.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| a.2.cmp(&b.2)));

    let mut previous = 0u64;
    for (tick, bytes, _) in events {
        variable((tick - previous) as u32, &mut track);
        track.extend_from_slice(&bytes);
        previous = tick;
    }
    variable(0, &mut track);
    track.extend_from_slice(&[0xFF, 0x2F, 0x00]);

    let mut file: Vec<u8> = Vec::new();
    file.extend_from_slice(b"MThd");
    file.extend_from_slice(&6u32.to_be_bytes());
    file.extend_from_slice(&0u16.to_be_bytes()); // format 0
    file.extend_from_slice(&1u16.to_be_bytes());
    file.extend_from_slice(&(PPQ as u16).to_be_bytes());
    file.extend_from_slice(b"MTrk");
    file.extend_from_slice(&(track.len() as u32).to_be_bytes());
    file.extend_from_slice(&track);

    std::fs::write(path, file).expect("write the MIDI file");
}

// --- reading a WAV back ------------------------------------------------------

struct Audio {
    rate: u32,
    channels: u16,
    /// Mono, for comparison: the two synths pan the same bank the same way, so
    /// summing loses nothing that matters here.
    samples: Vec<f32>,
}

fn read_wav(path: &Path) -> Audio {
    let bytes = std::fs::read(path).expect("read the wav");
    assert_eq!(&bytes[0..4], b"RIFF", "{} is not RIFF", path.display());
    assert_eq!(&bytes[8..12], b"WAVE");

    let mut cursor = 12usize;
    let mut rate = 0u32;
    let mut channels = 0u16;
    let mut bits = 0u16;
    let mut data: Option<(usize, usize)> = None;

    while cursor + 8 <= bytes.len() {
        let id = &bytes[cursor..cursor + 4];
        let length = u32::from_le_bytes([
            bytes[cursor + 4],
            bytes[cursor + 5],
            bytes[cursor + 6],
            bytes[cursor + 7],
        ]) as usize;
        let body = cursor + 8;
        if id == b"fmt " {
            channels = u16::from_le_bytes([bytes[body + 2], bytes[body + 3]]);
            rate = u32::from_le_bytes([
                bytes[body + 4],
                bytes[body + 5],
                bytes[body + 6],
                bytes[body + 7],
            ]);
            bits = u16::from_le_bytes([bytes[body + 14], bytes[body + 15]]);
        } else if id == b"data" {
            data = Some((body, length.min(bytes.len() - body)));
        }
        cursor = body + length + (length & 1);
    }

    let (start, length) = data.expect("the wav has no data chunk");
    let frames_bytes = &bytes[start..start + length];
    let mut samples = Vec::new();

    match bits {
        16 => {
            for frame in frames_bytes.chunks_exact(2 * channels as usize) {
                let mut sum = 0.0f32;
                for pair in frame.chunks_exact(2) {
                    sum += f32::from(i16::from_le_bytes([pair[0], pair[1]])) / 32768.0;
                }
                samples.push(sum / f32::from(channels));
            }
        }
        32 => {
            for frame in frames_bytes.chunks_exact(4 * channels as usize) {
                let mut sum = 0.0f32;
                for quad in frame.chunks_exact(4) {
                    sum += f32::from_le_bytes([quad[0], quad[1], quad[2], quad[3]]);
                }
                samples.push(sum / f32::from(channels));
            }
        }
        other => panic!("unexpected bit depth {other} in {}", path.display()),
    }

    Audio {
        rate,
        channels,
        samples,
    }
}

fn peak(samples: &[f32]) -> f32 {
    samples.iter().fold(0.0f32, |acc, s| acc.max(s.abs()))
}

fn rms(samples: &[f32]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    (samples.iter().map(|s| s * s).sum::<f32>() / samples.len() as f32).sqrt()
}

/// The loudness of each 10 ms window, in dBFS, normalised to the file's peak.
///
/// Comparing envelopes rather than samples is the only fair comparison between
/// two different samplers reading the same bank.
fn envelope(audio: &Audio) -> Vec<f32> {
    let window = (audio.rate / 100) as usize;
    let normalise = peak(&audio.samples).max(1e-9);
    audio
        .samples
        .chunks(window)
        .map(|chunk| {
            let level = rms(chunk) / normalise;
            20.0 * (level.max(1e-6)).log10()
        })
        .collect()
}

/// Where the level rises sharply — a note starting.
fn onsets(envelope: &[f32]) -> Vec<usize> {
    let mut found = Vec::new();
    for i in 0..envelope.len() {
        // The first window has nothing before it to rise from, and the first
        // chord starts there. Treat the run-up as silence so it is counted.
        let previous = if i == 0 { -120.0 } else { envelope[i - 1] };
        if envelope[i] - previous > 8.0
            && envelope[i] > -45.0
            && found.last().is_none_or(|last| i - last > 10)
        {
            found.push(i);
        }
    }
    found
}

/// Energy above and below 2 kHz, as a rough spectral balance.
///
/// A one-pole split rather than an FFT: what this has to catch is a sampler
/// that has lost its top end or is playing everything an octave out, and a
/// crossover finds that.
fn spectral_balance(audio: &Audio) -> f32 {
    let cutoff = 2000.0;
    let dt = 1.0 / audio.rate as f32;
    let rc = 1.0 / (2.0 * std::f32::consts::PI * cutoff);
    let alpha = dt / (rc + dt);
    let mut low = 0.0f32;
    let mut low_energy = 0.0f64;
    let mut high_energy = 0.0f64;
    for sample in &audio.samples {
        low += alpha * (sample - low);
        let high = sample - low;
        low_energy += f64::from(low) * f64::from(low);
        high_energy += f64::from(high) * f64::from(high);
    }
    if low_energy <= 0.0 {
        return 0.0;
    }
    (high_energy / low_energy) as f32
}

/// Render both, and hand back the two files plus their measurements.
struct Comparison {
    ours: Audio,
    theirs: Audio,
    _bandstand_file: Temp,
    _fluidsynth_file: Temp,
    _midi_file: Temp,
}

/// Render the material through both synths.
///
/// `tag` names this comparison's temporary files. Tests run in parallel, and
/// sharing one set of names means each render clobbers the others — which is
/// exactly what happened the first time this was written.
fn render_both(tag: &str) -> Option<Comparison> {
    let bank_path = find_bank()?;
    if !has_fluidsynth() {
        return None;
    }

    let midi = temp(&format!("bandstand-ab-{tag}.mid"));
    write_midi(&midi.0);

    let ours_path = temp(&format!("bandstand-ab-{tag}-bandstand.wav"));
    let bank = Arc::new(load_soundfont(&bank_path).expect("the bank reads"));
    let map = TempoMap::constant(PPQ, 120.0).unwrap();
    render_to_wav(
        &ours_path.0,
        bank,
        &sequence(),
        &map,
        RATE,
        OUR_GAIN,
        FLAT_MIX,
    )
    .expect("bandstand renders");

    let theirs_path = temp(&format!("bandstand-ab-{tag}-fluidsynth.wav"));
    let output = Command::new("fluidsynth")
        .args([
            "-ni",
            "-F",
            theirs_path.0.to_str().unwrap(),
            "-r",
            &RATE.to_string(),
            "-g",
            THEIR_GAIN,
            "-T",
            "wav",
            bank_path.to_str().unwrap(),
            midi.0.to_str().unwrap(),
        ])
        .output()
        .expect("fluidsynth runs");
    assert!(
        output.status.success(),
        "fluidsynth failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(theirs_path.0.exists(), "fluidsynth wrote no file");

    Some(Comparison {
        ours: read_wav(&ours_path.0),
        theirs: read_wav(&theirs_path.0),
        _bandstand_file: ours_path,
        _fluidsynth_file: theirs_path,
        _midi_file: midi,
    })
}

fn skip(reason: &str) {
    eprintln!("skipping the FluidSynth A/B: {reason}");
}

// --- the comparison ----------------------------------------------------------

#[test]
fn both_synths_render_the_same_material() {
    let Some(comparison) = render_both("bsrtsm") else {
        skip("fluidsynth or a General MIDI bank is missing");
        return;
    };

    assert_eq!(comparison.ours.rate, RATE);
    assert_eq!(comparison.ours.channels, 2);
    assert!(!comparison.ours.samples.is_empty());
    assert!(!comparison.theirs.samples.is_empty());

    // Both must last about as long as the music: four bars at 120 bpm is eight
    // seconds, plus whatever tail each chooses.
    let ours_seconds = comparison.ours.samples.len() as f32 / RATE as f32;
    let theirs_seconds = comparison.theirs.samples.len() as f32 / RATE as f32;
    assert!(ours_seconds > 8.0, "ours is only {ours_seconds}s");
    assert!(theirs_seconds > 8.0, "theirs is only {theirs_seconds}s");
}

#[test]
fn neither_is_silent_and_ours_does_not_clip() {
    let Some(comparison) = render_both("nisaodnc") else {
        skip("fluidsynth or a General MIDI bank is missing");
        return;
    };

    let ours = peak(&comparison.ours.samples);
    let theirs = peak(&comparison.theirs.samples);
    eprintln!("MEASURED peak: Bandstand {ours:.4}, FluidSynth {theirs:.4}");
    assert!(ours > 0.05, "Bandstand's render peaks at {ours}");
    assert!(theirs > 0.05, "FluidSynth's render peaks at {theirs}");
    // §7.2: the output must not clip. FluidSynth's own gain staging is its
    // business; ours is asserted.
    assert!(ours <= 1.0, "Bandstand clipped at {ours}");
}

#[test]
fn the_levels_match_at_the_calibrated_gains() {
    let Some(comparison) = render_both("tlmatcg") else {
        skip("fluidsynth or a General MIDI bank is missing");
        return;
    };

    // Over the music only, so a different tail length does not skew it.
    let window = (RATE as usize * 8)
        .min(comparison.ours.samples.len())
        .min(comparison.theirs.samples.len());
    let ours = rms(&comparison.ours.samples[..window]);
    let theirs = rms(&comparison.theirs.samples[..window]);

    let difference_db = 20.0 * (ours.max(1e-9) / theirs.max(1e-9)).log10();
    eprintln!(
        "MEASURED level: Bandstand {ours:.5} rms, FluidSynth {theirs:.5} rms, \
         {difference_db:+.1} dB"
    );
    // At OUR_GAIN against THEIR_GAIN the two are calibrated, so this is tight
    // enough to catch a real gain fault — an attenuation generator ignored, or
    // velocity applied twice — rather than a difference of convention.
    assert!(
        difference_db.abs() < 3.0,
        "Bandstand is {difference_db:.1} dB from FluidSynth \
         (ours {ours:.5}, theirs {theirs:.5})"
    );
}

#[test]
fn the_dynamics_match() {
    let Some(comparison) = render_both("tdm") else {
        skip("fluidsynth or a General MIDI bank is missing");
        return;
    };

    // Crest factor — peak over RMS — says how much louder the loudest moment is
    // than the average one. It is a ratio, so it does not care about gain
    // staging at all, and it is what changes when an envelope stage is skipped,
    // a release is cut short, or a limiter is squashing the peaks.
    let crest = |samples: &[f32]| {
        let r = rms(samples);
        if r <= 0.0 {
            0.0
        } else {
            20.0 * (peak(samples) / r).log10()
        }
    };
    let window = (RATE as usize * 8)
        .min(comparison.ours.samples.len())
        .min(comparison.theirs.samples.len());
    let ours = crest(&comparison.ours.samples[..window]);
    let theirs = crest(&comparison.theirs.samples[..window]);

    eprintln!("MEASURED crest factor: Bandstand {ours:.1} dB, FluidSynth {theirs:.1} dB");
    assert!(
        (ours - theirs).abs() < 2.0,
        "crest factors differ by {:.1} dB (ours {ours:.1}, theirs {theirs:.1})",
        ours - theirs
    );
}

#[test]
fn the_notes_arrive_at_the_same_times() {
    let Some(comparison) = render_both("tnaatst") else {
        skip("fluidsynth or a General MIDI bank is missing");
        return;
    };

    let ours = onsets(&envelope(&comparison.ours));
    let theirs = onsets(&envelope(&comparison.theirs));

    assert!(!ours.is_empty(), "Bandstand produced no note onsets");
    assert!(!theirs.is_empty(), "FluidSynth produced no note onsets");

    // Four chords, so four onsets each, give or take one from the decay of the
    // chord before.
    eprintln!("MEASURED onsets: Bandstand {ours:?}, FluidSynth {theirs:?} (10 ms windows)");
    assert!(
        (ours.len() as i32 - theirs.len() as i32).abs() <= 1,
        "onset counts differ: ours {:?}, theirs {:?}",
        ours,
        theirs
    );

    // Each onset within 30 ms — three windows — of its counterpart. A timing
    // error big enough to hear would be far larger. Pair every onset with the
    // nearest one on the other side, on both sides: an onset with no partner
    // in the window is a real defect, and one the old zip-to-the-shorter-list
    // loop would have dropped without a word.
    let nearest = |a: usize, list: &[usize]| {
        list.iter()
            .map(|&b| (a as i32 - b as i32).abs())
            .min()
            .unwrap_or(i32::MAX)
    };
    for (index, &a) in ours.iter().enumerate() {
        let apart = nearest(a, &theirs);
        assert!(
            apart <= 3,
            "onset {index} is {}0 ms from its nearest counterpart: ours at {a}, \
             FluidSynth onsets {theirs:?}",
            apart
        );
    }
    for (index, &b) in theirs.iter().enumerate() {
        let apart = nearest(b, &ours);
        assert!(
            apart <= 3,
            "FluidSynth onset {index} is {}0 ms from its nearest counterpart: \
             theirs at {b}, Bandstand onsets {ours:?}",
            apart
        );
    }
}

#[test]
fn the_envelope_follows_the_same_shape() {
    let Some(comparison) = render_both("teftss") else {
        skip("fluidsynth or a General MIDI bank is missing");
        return;
    };

    let ours = envelope(&comparison.ours);
    let theirs = envelope(&comparison.theirs);
    let length = ours.len().min(theirs.len()).min(800); // eight seconds

    // Correlate the two loudness curves. Two samplers reading the same bank
    // with the same envelopes should track each other closely; a filter stuck
    // open, an envelope stage skipped, or a sample looping when it should not
    // would all show up as a curve that stops following.
    let mean = |values: &[f32]| values.iter().sum::<f32>() / values.len() as f32;
    let ours_mean = mean(&ours[..length]);
    let theirs_mean = mean(&theirs[..length]);

    let mut covariance = 0.0f64;
    let mut ours_variance = 0.0f64;
    let mut theirs_variance = 0.0f64;
    for i in 0..length {
        let a = f64::from(ours[i] - ours_mean);
        let b = f64::from(theirs[i] - theirs_mean);
        covariance += a * b;
        ours_variance += a * a;
        theirs_variance += b * b;
    }
    let correlation = covariance / (ours_variance.sqrt() * theirs_variance.sqrt()).max(1e-9);

    eprintln!("MEASURED envelope correlation: {correlation:.3}");
    assert!(
        correlation > 0.75,
        "the loudness curves only correlate at {correlation:.3}"
    );
}

#[test]
fn the_spectral_balance_is_comparable() {
    let Some(comparison) = render_both("tsbic") else {
        skip("fluidsynth or a General MIDI bank is missing");
        return;
    };

    let ours = spectral_balance(&comparison.ours);
    let theirs = spectral_balance(&comparison.theirs);

    // A sampler that has lost its top end, or is interpolating badly enough to
    // alias, or is playing everything an octave out, shows up here. The bar is
    // deliberately loose: the two use different interpolation and different
    // filter implementations, and a factor of four either way is still the same
    // instrument.
    let ratio = (ours.max(1e-6) / theirs.max(1e-6)) as f64;
    eprintln!(
        "MEASURED spectral balance: Bandstand {ours:.4}, FluidSynth {theirs:.4}, ratio {ratio:.2}x"
    );
    assert!(
        (0.25..=4.0).contains(&ratio),
        "high-to-low energy differs by {ratio:.2}× (ours {ours:.4}, theirs {theirs:.4})"
    );
}

/// Write the two renders somewhere a person can listen to them.
///
/// Not an assertion — the last word on "no audible defects" is a pair of ears,
/// and this is what they need. Run with `--ignored` to keep the files.
#[test]
#[ignore = "writes files for a listening test rather than asserting"]
fn write_the_pair_for_a_listening_test() {
    let Some(bank_path) = find_bank() else {
        skip("no General MIDI bank");
        return;
    };
    assert!(has_fluidsynth(), "fluidsynth is needed for the A/B");

    let directory = std::env::var("BANDSTAND_AB_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| std::env::temp_dir());
    std::fs::create_dir_all(&directory).expect("the output directory");

    let midi = directory.join("ab-material.mid");
    write_midi(&midi);

    let ours = directory.join("ab-bandstand.wav");
    let bank = Arc::new(load_soundfont(&bank_path).expect("the bank reads"));
    let map = TempoMap::constant(PPQ, 120.0).unwrap();
    render_to_wav(&ours, bank, &sequence(), &map, RATE, OUR_GAIN, FLAT_MIX).expect("renders");

    let theirs = directory.join("ab-fluidsynth.wav");
    let status = Command::new("fluidsynth")
        .args([
            "-ni",
            "-F",
            theirs.to_str().unwrap(),
            "-r",
            &RATE.to_string(),
            "-g",
            THEIR_GAIN,
            "-T",
            "wav",
            bank_path.to_str().unwrap(),
            midi.to_str().unwrap(),
        ])
        .status()
        .expect("fluidsynth runs");
    assert!(status.success());

    eprintln!("Bandstand: {}", ours.display());
    eprintln!("FluidSynth: {}", theirs.display());
}
