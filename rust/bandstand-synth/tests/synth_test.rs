//! Playing notes on a real bank.
//!
//! These make actual sound and measure it. A synth whose parser is tested and
//! whose DSP is not is a synth that loads a file and plays silence.

// These tests assert the exact values the code produces, and their arithmetic
// converts between sizes deliberately.
#![allow(
    clippy::float_cmp,
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    clippy::cast_precision_loss
)]

use std::path::{Path, PathBuf};
use std::sync::Arc;

use bandstand_synth::sf2::{load_soundfont, Generator};
use bandstand_synth::{Synth, DRUM_BANK, DRUM_CHANNEL};

const CANDIDATES: &[&str] = &[
    "/usr/share/sounds/sf2/TimGM6mb.sf2",
    "/usr/share/sounds/sf2/default-GM.sf2",
    "/usr/share/soundfonts/default.sf2",
    "/usr/share/sounds/sf2/FluidR3_GM.sf2",
];

const SR: f32 = 48_000.0;
const BLOCK: usize = 256;

fn find_bank() -> Option<PathBuf> {
    CANDIDATES
        .iter()
        .map(Path::new)
        .find(|path| path.exists())
        .map(Path::to_path_buf)
}

fn synth() -> Option<Synth> {
    let path = find_bank()?;
    let bank = Arc::new(load_soundfont(&path).expect("the bank reads"));
    let mut synth = Synth::new(SR, BLOCK, 200);
    synth.set_bank(Some(bank));
    Some(synth)
}

/// Render `blocks` blocks and return the interleaved stereo output.
fn render(synth: &mut Synth, blocks: usize) -> Vec<f32> {
    let mut out = Vec::with_capacity(blocks * BLOCK * 2);
    for _ in 0..blocks {
        let mut buffer = vec![0.0f32; BLOCK * 2];
        synth.render(&mut buffer, 2);
        out.extend_from_slice(&buffer);
    }
    out
}

fn peak(buffer: &[f32]) -> f32 {
    buffer.iter().fold(0.0f32, |acc, s| acc.max(s.abs()))
}

fn rms(buffer: &[f32]) -> f32 {
    if buffer.is_empty() {
        return 0.0;
    }
    (buffer.iter().map(|s| s * s).sum::<f32>() / buffer.len() as f32).sqrt()
}

#[test]
fn a_synth_with_no_bank_is_silent_rather_than_broken() {
    let mut synth = Synth::new(SR, BLOCK, 32);
    synth.note_on(0, 60, 100);
    assert_eq!(synth.active_voices(), 0);
    assert_eq!(peak(&render(&mut synth, 4)), 0.0);
}

#[test]
fn a_note_makes_sound_and_stops_when_it_is_let_go() {
    let Some(mut synth) = synth() else {
        eprintln!("no soundfont; skipping");
        return;
    };
    synth.set_program(0, 0, 0);
    synth.note_on(0, 60, 100);
    assert!(synth.active_voices() > 0, "no voice started");

    let sound = render(&mut synth, 20);
    assert!(peak(&sound) > 0.001, "peak {}", peak(&sound));
    assert!(peak(&sound) <= 1.5, "clipping: {}", peak(&sound));

    synth.note_off(0, 60);
    // A grand piano's release is short; five seconds is plenty.
    render(&mut synth, (SR as usize / BLOCK) * 5);
    assert_eq!(synth.active_voices(), 0, "the note never stopped");
}

#[test]
fn every_general_midi_program_makes_a_sound() {
    let Some(mut synth) = synth() else {
        return;
    };
    let mut silent = Vec::new();
    for program in 0..128u16 {
        synth.panic();
        synth.set_program(0, 0, program);
        synth.note_on(0, 60, 110);
        let sound = render(&mut synth, 40);
        if peak(&sound) < 1e-4 {
            silent.push(program);
        }
        synth.note_off(0, 60);
    }
    assert!(silent.is_empty(), "silent programs: {silent:?}");
}

#[test]
fn the_drum_channel_plays_percussion() {
    let Some(mut synth) = synth() else {
        return;
    };
    synth.set_program(DRUM_CHANNEL, DRUM_BANK, 0);
    for key in [35u8, 38, 42, 46, 51] {
        synth.panic();
        synth.note_on(DRUM_CHANNEL, key, 110);
        let sound = render(&mut synth, 20);
        assert!(peak(&sound) > 1e-4, "key {key} is silent");
    }
}

#[test]
fn velocity_changes_how_loud_a_note_is() {
    let Some(mut synth) = synth() else {
        return;
    };
    synth.set_program(0, 0, 0);

    synth.note_on(0, 60, 30);
    let quiet = rms(&render(&mut synth, 20));
    synth.panic();

    synth.note_on(0, 60, 127);
    let loud = rms(&render(&mut synth, 20));

    assert!(loud > quiet * 1.5, "quiet {quiet}, loud {loud}");
}

#[test]
fn a_muted_channel_is_silent() {
    let Some(mut synth) = synth() else {
        return;
    };
    synth.set_program(0, 0, 0);
    synth.set_channel_muted(0, true);
    synth.note_on(0, 60, 110);
    // The voice still exists — muting is a mixer setting, not a note off —
    // but nothing comes out.
    let sound = render(&mut synth, 20);
    assert!(peak(&sound) < 1e-6, "peak {}", peak(&sound));
}

#[test]
fn the_master_gain_scales_the_output() {
    let Some(mut synth) = synth() else {
        return;
    };
    synth.set_program(0, 0, 0);
    synth.set_master_gain(1.0);
    synth.note_on(0, 60, 110);
    let loud = rms(&render(&mut synth, 20));

    synth.panic();
    synth.set_master_gain(0.25);
    synth.note_on(0, 60, 110);
    let quiet = rms(&render(&mut synth, 20));

    assert!(quiet < loud * 0.5, "loud {loud}, quiet {quiet}");
    assert!(quiet > 0.0);
}

#[test]
fn the_sustain_pedal_holds_notes_until_it_is_lifted() {
    let Some(mut synth) = synth() else {
        return;
    };
    synth.set_program(0, 0, 0);
    synth.set_sustain(0, true);
    synth.note_on(0, 60, 110);
    render(&mut synth, 10);
    synth.note_off(0, 60);
    render(&mut synth, 10);
    assert!(synth.active_voices() > 0, "the pedal did not hold the note");

    synth.set_sustain(0, false);
    render(&mut synth, (SR as usize / BLOCK) * 5);
    assert_eq!(synth.active_voices(), 0);
}

#[test]
fn a_velocity_of_zero_is_a_note_off() {
    let Some(mut synth) = synth() else {
        return;
    };
    synth.set_program(0, 0, 0);
    synth.note_on(0, 60, 100);
    let started = synth.active_voices();
    assert!(started > 0);
    synth.note_on(0, 60, 0);
    render(&mut synth, (SR as usize / BLOCK) * 5);
    assert_eq!(synth.active_voices(), 0);
}

#[test]
fn the_voice_pool_is_capped_and_steals_rather_than_growing() {
    let Some(path) = find_bank() else {
        return;
    };
    let bank = Arc::new(load_soundfont(&path).unwrap());
    let mut synth = Synth::new(SR, BLOCK, 8);
    synth.set_bank(Some(bank));
    synth.set_program(0, 0, 48); // strings: long, sustaining, layered

    for key in 20..100u8 {
        synth.note_on(0, key, 100);
        assert!(
            synth.active_voices() <= 8,
            "{} voices with a cap of 8",
            synth.active_voices()
        );
    }
    let sound = render(&mut synth, 20);
    assert!(peak(&sound) > 0.0, "stealing left it silent");
    assert!(peak(&sound).is_finite());
}

#[test]
fn a_hundred_notes_at_once_stay_inside_the_output_range() {
    let Some(mut synth) = synth() else {
        return;
    };
    synth.set_program(0, 0, 0);
    for key in 21..109u8 {
        synth.note_on(0, key, 127);
    }
    let sound = render(&mut synth, 40);
    for value in &sound {
        assert!(value.is_finite(), "{value}");
    }
    // The master gain is there to stop a full keyboard clipping.
    assert!(peak(&sound) < 4.0, "peak {}", peak(&sound));
}

#[test]
fn an_exclusive_class_cuts_its_own_kind_off() {
    let Some(path) = find_bank() else {
        return;
    };
    let bank = Arc::new(load_soundfont(&path).expect("the bank reads"));
    let Some(kit) = bank.find_preset(DRUM_BANK, 0) else {
        return;
    };

    // What each hat starts, and whether the bank wires them to one class.
    let mut starts = Vec::new();
    bank.voices_for(kit, 46, 110, &mut starts);
    let open_class = starts
        .first()
        .map(|voice| voice.generators.get(Generator::ExclusiveClass));
    starts.clear();
    bank.voices_for(kit, 42, 110, &mut starts);
    let closed_class = starts
        .first()
        .map(|voice| voice.generators.get(Generator::ExclusiveClass));
    let closed_starts = starts.len();

    let mut synth = Synth::new(SR, BLOCK, 200);
    synth.set_bank(Some(Arc::clone(&bank)));
    synth.set_program(DRUM_CHANNEL, DRUM_BANK, 0);
    // Open hi-hat, then closed: the closed one must cut the open one.
    synth.note_on(DRUM_CHANNEL, 46, 110);
    render(&mut synth, 4);
    assert!(synth.active_voices() > 0, "the open hi-hat made no voice");
    synth.note_on(DRUM_CHANNEL, 42, 110);
    // Two blocks is ~11 ms — well past the 6 ms fast release a cut uses. The
    // assertion must fail if the cut never happened; rendering for seconds
    // until the drum ends naturally would pass either way.
    render(&mut synth, 2);

    if open_class.is_some() && open_class == closed_class {
        assert!(
            synth.active_voices() <= closed_starts,
            "{} voices a couple of blocks after the closed hat cut the open one",
            synth.active_voices()
        );
    } else {
        // The bank does not use exclusive classes; the closed hat at most
        // adds its own voices.
        assert!(
            synth.active_voices() <= closed_starts * 2,
            "{} voices after the closed hat",
            synth.active_voices()
        );
    }
}

#[test]
fn changing_the_bank_stops_what_was_playing() {
    let Some(path) = find_bank() else {
        return;
    };
    let bank = Arc::new(load_soundfont(&path).unwrap());
    let mut synth = Synth::new(SR, BLOCK, 64);
    synth.set_bank(Some(Arc::clone(&bank)));
    synth.set_program(0, 0, 0);
    synth.note_on(0, 60, 110);
    assert!(synth.active_voices() > 0);

    synth.set_bank(Some(bank));
    assert_eq!(synth.active_voices(), 0);
    assert_eq!(peak(&render(&mut synth, 4)), 0.0);
}

#[test]
fn a_program_that_is_not_in_the_bank_still_makes_a_sound() {
    let Some(mut synth) = synth() else {
        return;
    };
    // Bank 42 does not exist in a General MIDI file.
    synth.set_program(0, 42, 7);
    synth.note_on(0, 60, 110);
    assert!(
        synth.active_voices() > 0,
        "fell silent instead of falling back"
    );
    assert!(peak(&render(&mut synth, 20)) > 1e-4);
}

#[test]
fn mono_and_multichannel_output_both_work() {
    let Some(mut synth) = synth() else {
        return;
    };
    synth.set_program(0, 0, 0);
    synth.note_on(0, 60, 110);

    let mut mono = vec![0.0f32; BLOCK];
    synth.render(&mut mono, 1);
    assert!(peak(&mono) > 0.0);

    let mut surround = vec![0.0f32; BLOCK * 4];
    synth.render(&mut surround, 4);
    assert!(peak(&surround) > 0.0);
    for value in &surround {
        assert!(value.is_finite());
    }
}

#[test]
fn rendering_adds_into_the_buffer_rather_than_replacing_it() {
    let Some(mut synth) = synth() else {
        return;
    };
    synth.set_program(0, 0, 0);
    synth.note_on(0, 60, 110);
    let mut buffer = vec![0.25f32; BLOCK * 2];
    synth.render(&mut buffer, 2);
    // Everything that was there is still there, plus the synth.
    assert!(buffer.iter().all(|value| *value != 0.0));
}

#[test]
fn a_reset_stops_everything_including_the_tails() {
    let Some(mut synth) = synth() else {
        return;
    };
    synth.set_program(0, 0, 0);
    synth.note_on(0, 60, 110);
    render(&mut synth, 20);
    synth.panic();
    assert_eq!(synth.active_voices(), 0);
    assert_eq!(peak(&render(&mut synth, 8)), 0.0);
}

#[test]
fn channel_volume_and_expression_scale_the_output() {
    let Some(mut synth) = synth() else {
        return;
    };
    synth.set_program(0, 0, 0);
    synth.set_channel_volume(0, 1.0);
    synth.note_on(0, 60, 110);
    let full = rms(&render(&mut synth, 20));

    synth.panic();
    synth.set_channel_volume(0, 0.25);
    synth.note_on(0, 60, 110);
    let quiet = rms(&render(&mut synth, 20));
    assert!(quiet < full * 0.5, "full {full}, quiet {quiet}");

    synth.panic();
    synth.set_channel_volume(0, 1.0);
    synth.set_channel_expression(0, 0.25);
    synth.note_on(0, 60, 110);
    assert!(rms(&render(&mut synth, 20)) < full * 0.5);
}

#[test]
fn channel_pan_moves_the_sound_between_the_speakers() {
    let Some(mut synth) = synth() else {
        return;
    };
    synth.set_program(0, 0, 0);
    synth.set_channel_pan(0, -1.0);
    synth.note_on(0, 60, 110);
    let hard_left = render(&mut synth, 20);
    let left: Vec<f32> = hard_left.iter().step_by(2).copied().collect();
    let right: Vec<f32> = hard_left.iter().skip(1).step_by(2).copied().collect();
    assert!(rms(&left) > rms(&right) * 2.0, "not panned left");

    synth.panic();
    synth.set_channel_pan(0, 1.0);
    synth.note_on(0, 60, 110);
    let hard_right = render(&mut synth, 20);
    let left: Vec<f32> = hard_right.iter().step_by(2).copied().collect();
    let right: Vec<f32> = hard_right.iter().skip(1).step_by(2).copied().collect();
    assert!(rms(&right) > rms(&left) * 2.0, "not panned right");
}

#[test]
fn pitch_bend_changes_what_is_played() {
    let Some(mut synth) = synth() else {
        return;
    };
    // Counting zero crossings would measure the harmonics of whatever patch
    // this bank happens to have, not the bend. What can be asserted here is
    // that the bend reaches the audio at all; that it is the *right* amount is
    // arithmetic, and is tested where the arithmetic is.
    synth.set_program(0, 0, 48);
    synth.set_bend_range(0, 2.0);

    synth.note_on(0, 60, 110);
    render(&mut synth, 10);
    let plain = render(&mut synth, 30);

    synth.panic();
    synth.set_pitch_bend(0, 1.0);
    synth.note_on(0, 60, 110);
    render(&mut synth, 10);
    let bent = render(&mut synth, 30);

    assert!(peak(&bent) > 1e-4, "the bent note is silent");
    let difference: f32 = plain
        .iter()
        .zip(bent.iter())
        .map(|(a, b)| (a - b).abs())
        .sum();
    assert!(difference > 0.0, "the bend changed nothing");
}

#[test]
fn a_note_that_is_never_released_ends_on_its_own_if_the_sample_does() {
    let Some(mut synth) = synth() else {
        return;
    };
    // A drum hit does not loop, so it must free its voice by itself.
    synth.set_program(DRUM_CHANNEL, DRUM_BANK, 0);
    synth.note_on(DRUM_CHANNEL, 35, 110);
    render(&mut synth, (SR as usize / BLOCK) * 10);
    assert_eq!(synth.active_voices(), 0, "the drum hit never ended");
}
