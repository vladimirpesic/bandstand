//! Reading a real SoundFont.
//!
//! A parser tested only against files it wrote itself is a parser tested
//! against its own assumptions. These read whatever General MIDI bank the
//! machine has, and skip if it has none — a developer without one still gets a
//! green suite, and CI, if this project ever has any, gets the truth.

// These tests assert the exact values the code produces, and their arithmetic
// converts between sizes deliberately.
#![allow(
    clippy::doc_markdown,
    clippy::float_cmp,
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    clippy::cast_precision_loss
)]

use std::path::{Path, PathBuf};

use bandstand_synth::sf2::{load_soundfont, Generator, LoopMode, SoundBank, SoundFontError};

/// The places a General MIDI bank tends to live on a Linux box.
const CANDIDATES: &[&str] = &[
    "/usr/share/sounds/sf2/TimGM6mb.sf2",
    "/usr/share/sounds/sf2/default-GM.sf2",
    "/usr/share/soundfonts/default.sf2",
    "/usr/share/sounds/sf2/FluidR3_GM.sf2",
];

fn find_bank() -> Option<PathBuf> {
    CANDIDATES
        .iter()
        .map(Path::new)
        .find(|path| path.exists())
        .map(Path::to_path_buf)
}

fn load() -> Option<SoundBank> {
    let path = find_bank()?;
    Some(
        load_soundfont(&path)
            .unwrap_or_else(|error| panic!("could not read {}: {error}", path.display())),
    )
}

#[test]
fn reads_a_general_midi_bank() {
    let Some(bank) = load() else {
        eprintln!("no General MIDI soundfont on this machine; skipping");
        return;
    };

    // A GM bank has 128 melodic programs plus at least one drum kit.
    assert!(
        bank.presets.len() >= 128,
        "{} presets is not a General MIDI bank",
        bank.presets.len()
    );
    assert!(!bank.instruments.is_empty());
    assert!(!bank.samples.is_empty());
    assert!(!bank.data.is_empty());
}

#[test]
fn every_preset_has_a_name_and_a_valid_program() {
    let Some(bank) = load() else {
        return;
    };
    for preset in &bank.presets {
        assert!(preset.program <= 127, "{} is not a program", preset.program);
        assert!(!preset.name.is_empty(), "a preset has no name");
    }
}

#[test]
fn the_general_midi_programs_are_all_there() {
    let Some(bank) = load() else {
        return;
    };
    for program in 0..128u16 {
        assert!(
            bank.find_preset(0, program).is_some(),
            "bank 0 has no program {program}"
        );
    }
    // Bank 128 is the percussion bank in every GM soundfont.
    assert!(bank.find_preset(128, 0).is_some(), "no drum kit");
}

#[test]
fn every_zone_points_somewhere_real() {
    let Some(bank) = load() else {
        return;
    };
    for preset in &bank.presets {
        for zone in &preset.zones {
            assert!(
                zone.target < bank.instruments.len(),
                "{} points at instrument {}",
                preset.name,
                zone.target
            );
        }
    }
    for instrument in &bank.instruments {
        for zone in &instrument.zones {
            assert!(
                zone.target < bank.samples.len(),
                "{} points at sample {}",
                instrument.name,
                zone.target
            );
        }
    }
}

#[test]
fn every_sample_is_inside_the_data() {
    let Some(bank) = load() else {
        return;
    };
    let frames = bank.data.len() as u32;
    for sample in &bank.samples {
        assert!(
            sample.end <= frames,
            "{} ends at {} of {frames}",
            sample.name,
            sample.end
        );
        assert!(sample.start <= sample.end, "{} is inside out", sample.name);
        assert!(
            sample.sample_rate >= 400 && sample.sample_rate <= 200_000,
            "{} claims {} Hz",
            sample.name,
            sample.sample_rate
        );
        assert!(sample.original_pitch <= 127 || sample.original_pitch == 255);
    }
}

#[test]
fn every_program_answers_a_middle_c() {
    let Some(bank) = load() else {
        return;
    };
    for program in 0..128u16 {
        let preset = bank.find_preset(0, program).expect("a GM program");
        let mut voices = Vec::new();
        bank.voices_for(preset, 60, 100, &mut voices);
        assert!(
            !voices.is_empty(),
            "program {program} ({}) plays nothing at middle C",
            bank.presets[preset].name
        );
        for voice in &voices {
            assert!(voice.sample < bank.samples.len());
        }
    }
}

#[test]
fn a_drum_kit_answers_the_general_midi_percussion_keys() {
    let Some(bank) = load() else {
        return;
    };
    let Some(kit) = bank.find_preset(128, 0) else {
        return;
    };
    // Bass drum, snare, closed hi-hat, ride — the keys any kit has.
    for key in [35u8, 38, 42, 51] {
        let mut voices = Vec::new();
        bank.voices_for(kit, key, 100, &mut voices);
        assert!(!voices.is_empty(), "the kit is silent on key {key}");
    }
}

#[test]
fn resolved_generators_are_inside_their_ranges() {
    let Some(bank) = load() else {
        return;
    };
    for program in 0..128u16 {
        let preset = bank.find_preset(0, program).unwrap();
        for velocity in [1u8, 64, 127] {
            for key in [24u8, 60, 96] {
                let mut voices = Vec::new();
                bank.voices_for(preset, key, velocity, &mut voices);
                for voice in &voices {
                    let gens = &voice.generators;
                    let attenuation = gens.get_f32(Generator::InitialAttenuation);
                    assert!(
                        (-1000.0..=2000.0).contains(&attenuation),
                        "program {program}: attenuation {attenuation}"
                    );
                    let pan = gens.get(Generator::Pan);
                    assert!(
                        (-1000..=1000).contains(&pan),
                        "program {program}: pan {pan}"
                    );
                    let scale = gens.get(Generator::ScaleTuning);
                    assert!(
                        (0..=1200).contains(&scale),
                        "program {program}: scaleTuning {scale}"
                    );
                }
            }
        }
    }
}

#[test]
fn a_looping_sample_has_loop_points_that_can_be_used() {
    let Some(bank) = load() else {
        return;
    };
    let mut looping = 0usize;
    for program in 0..128u16 {
        let preset = bank.find_preset(0, program).unwrap();
        let mut voices = Vec::new();
        bank.voices_for(preset, 60, 100, &mut voices);
        for voice in &voices {
            let mode = LoopMode::from_value(voice.generators.get(Generator::SampleModes));
            if mode.loops() {
                looping += 1;
                let sample = &bank.samples[voice.sample];
                assert!(
                    sample.has_usable_loop(),
                    "{} loops but its points are {}..{} inside {}..{}",
                    sample.name,
                    sample.loop_start,
                    sample.loop_end,
                    sample.start,
                    sample.end
                );
            }
        }
    }
    // A General MIDI bank without a single looping sample is not one.
    assert!(looping > 0, "no program loops");
}

#[test]
fn reading_a_file_that_is_not_a_soundfont_fails_rather_than_guessing() {
    let path = std::env::temp_dir().join("bandstand-not-a-soundfont.sf2");
    std::fs::write(&path, b"this is not a soundfont at all, not even close")
        .expect("write the temporary file");
    let result = load_soundfont(&path);
    let _ = std::fs::remove_file(&path);
    assert!(result.is_err());
}

#[test]
fn reading_a_file_that_is_not_there_fails() {
    let result = load_soundfont(Path::new("/no/such/soundfont.sf2"));
    assert!(
        matches!(result, Err(SoundFontError::Io { .. })),
        "a missing file must surface its I/O error, not masquerade as truncation: {result:?}"
    );
}
