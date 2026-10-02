//! What the synth costs per block, measured against real time.
//!
//! §3 budgets dropouts at zero for a 90-minute set, and §7.2 caps polyphony at
//! [`DEFAULT_MAX_VOICES`]. Neither is meaningful without knowing how much of a
//! block's wall-clock the renderer actually uses: a synth that takes longer to
//! produce 256 frames than those frames take to play will underrun no matter
//! how careful the ring buffer is.
//!
//! The number this reports is the *real-time factor* — how many times faster
//! than real time one core renders. Anything above 1.0 keeps up; the headroom
//! above that is what absorbs a scheduler hiccup, a page fault, or the rest of
//! the application. Results are recorded in `docs/benchmarks.md`.
//!
//! These are timings, so they are best-of-N: the suite runs tests in parallel
//! and one descheduled run would otherwise read as a regression.

#![allow(clippy::cast_precision_loss, clippy::cast_possible_truncation)]

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Instant;

use bandstand_synth::{load_soundfont, Synth, DEFAULT_MAX_VOICES};

const CANDIDATES: &[&str] = &[
    "/usr/share/sounds/sf2/TimGM6mb.sf2",
    "/usr/share/sounds/sf2/default-GM.sf2",
    "/usr/share/soundfonts/default.sf2",
    "/usr/share/sounds/sf2/FluidR3_GM.sf2",
];

/// Whether the timing budgets apply to this build.
///
/// §3's budgets describe the binary that goes on stage. A debug build runs this
/// DSP about seven times slower — 68 voices at 1.2x real time rather than 8.5x
/// — which measures the optimiser and not the synth, so asserting a §3 number
/// against it would only teach people to ignore a red test. `just bench` and
/// `benchmarks/run.sh` both build with `--release`.
///
/// The tests still run in debug, and still check that the load being measured
/// is the load that was asked for. That is the part that would rot if these
/// were `#[ignore]`d and only ever run by hand.
const TIMED: bool = !cfg!(debug_assertions);

/// What to call the build in output, so a debug number is never mistaken for a
/// benchmark.
const PROFILE: &str = if cfg!(debug_assertions) {
    "debug, untimed"
} else {
    "release"
};

const SAMPLE_RATE: f32 = 48_000.0;
const BLOCK_FRAMES: usize = 256;
const CHANNELS: usize = 2;

fn find_bank() -> Option<PathBuf> {
    CANDIDATES
        .iter()
        .map(Path::new)
        .find(|path| path.exists())
        .map(Path::to_path_buf)
}

/// Render `blocks` blocks and return the fastest pass's real-time factor.
///
/// Every pass renders the same voices from the same synth state, so the
/// comparison is between runs of identical work.
fn real_time_factor(voices: usize, passes: usize, blocks: usize) -> (f64, usize) {
    // An untimed build is only checking that the load is what it claims, so it
    // renders a tenth as much. The full measurement costs ten seconds in debug,
    // and `just check` runs on every commit.
    let (passes, blocks) = if TIMED {
        (passes, blocks)
    } else {
        (1, blocks / 10)
    };
    let bank = Arc::new(load_soundfont(&find_bank().expect("checked by the caller")).unwrap());
    let mut synth = Synth::new(SAMPLE_RATE, BLOCK_FRAMES, DEFAULT_MAX_VOICES);
    synth.set_bank(Some(bank));

    // Five different programs rather than one stacked on itself, so the mix of
    // sample rates, loop points and envelopes is representative.
    //
    // All five sustain. That is not what a rhythm section sounds like, but a
    // steady-state polyphony measurement needs polyphony that stays put:
    // plucked and struck programs decay, and a drum kit is one-shots, so a load
    // built from those drains away mid-measurement and reports the cost of
    // fewer voices than it claims.
    const PROGRAMS: [(u8, u16, u16); 5] = [
        (0, 0, 16), // drawbar organ
        (1, 0, 48), // string ensemble
        (2, 0, 52), // choir aahs
        (3, 0, 89), // warm pad
        (4, 0, 19), // church organ
    ];
    for (channel, bank_number, program) in PROGRAMS {
        synth.set_program(channel, bank_number, program);
    }

    // §3's budget counts voices, not notes, and the two are not the same: a
    // General MIDI preset commonly layers two or three samples per key, so
    // sixty-four note-ons can be a hundred and twelve voices. Play notes until
    // the synth is actually carrying the load being measured.
    //
    // Voices are held, never released, so polyphony stays there for the whole
    // measurement instead of decaying out from under it.
    let mut index = 0_usize;
    let play_up_to = |synth: &mut Synth, index: &mut usize| {
        while synth.active_voices() < voices && *index < DEFAULT_MAX_VOICES * 4 {
            let (channel, ..) = PROGRAMS[*index % PROGRAMS.len()];
            // A four-octave spread from C2, which is the range a band actually
            // covers, and avoids stacking unisons that the voice allocator
            // would steal.
            let key = 36 + (*index * 7 % 48) as u8;
            synth.note_on(channel, key, 100);
            *index += 1;
        }
    };
    play_up_to(&mut synth, &mut index);

    let mut output = vec![0.0_f32; BLOCK_FRAMES * CHANNELS];
    // A pass before the clock starts: the first block through a voice pages its
    // sample in and runs its attack, and that cost belongs to §7.2's warming,
    // not to steady state. Then top the load back up to the target, since
    // attacks that did not survive the warm-up would otherwise be missing from
    // the count.
    for _ in 0..blocks {
        synth.render(&mut output, CHANNELS);
    }
    play_up_to(&mut synth, &mut index);
    for _ in 0..8 {
        synth.render(&mut output, CHANNELS);
    }
    let sounding = synth.active_voices();

    let mut best = 0.0_f64;
    for _ in 0..passes {
        let start = Instant::now();
        for _ in 0..blocks {
            synth.render(&mut output, CHANNELS);
        }
        let elapsed = start.elapsed().as_secs_f64();
        let audio_seconds = (blocks * BLOCK_FRAMES) as f64 / f64::from(SAMPLE_RATE);
        let factor = audio_seconds / elapsed;
        if factor > best {
            best = factor;
        }
    }
    // What the load was when the last pass finished. Reporting the smaller of
    // the two keeps the figure honest if anything did decay under the clock.
    let remaining = synth.active_voices();
    (best, sounding.min(remaining))
}

#[test]
fn sixty_four_voices_render_faster_than_real_time() {
    let Some(_) = find_bank() else {
        eprintln!("no General MIDI soundfont on this machine; skipping");
        return;
    };

    let (factor, sounding) = real_time_factor(64, 5, 400);
    println!("BENCH synth, {sounding} voices: {factor:.1}x real time ({PROFILE})");
    assert!(
        (64..72).contains(&sounding),
        "{sounding} voices sounding; the load is not the 64 being measured"
    );
    // Five times real time leaves a block's work taking a fifth of a block's
    // duration. Below that the audio thread is sharing a core with the UI and
    // the generator, and §3's zero-dropout budget stops being credible.
    assert!(
        !TIMED || factor > 5.0,
        "64 voices render at only {factor:.1}x real time"
    );
}

#[test]
fn a_full_polyphony_load_still_keeps_up() {
    let Some(_) = find_bank() else {
        eprintln!("no General MIDI soundfont on this machine; skipping");
        return;
    };

    // §7.2's cap. Nothing Bandstand generates comes close, but a stuck sustain
    // pedal under a dense comp can, and the answer must still be audio rather
    // than a dropout.
    let (factor, sounding) = real_time_factor(DEFAULT_MAX_VOICES, 3, 200);
    println!("BENCH synth, {sounding} voices: {factor:.1}x real time ({PROFILE})");
    assert_eq!(
        sounding, DEFAULT_MAX_VOICES,
        "the allocator should have filled every voice; it held {sounding}"
    );
    assert!(
        !TIMED || factor > 1.0,
        "{sounding} voices render at {factor:.1}x real time — slower than the \
         audio they produce, which is a guaranteed underrun"
    );
}

#[test]
fn an_idle_synth_costs_almost_nothing() {
    let Some(_) = find_bank() else {
        eprintln!("no General MIDI soundfont on this machine; skipping");
        return;
    };

    // Silence still runs the reverb and chorus tails, so it is not free — but
    // it is what the engine burns between songs and while the user reads, and
    // on a laptop that is battery.
    let (factor, sounding) = real_time_factor(0, 5, 400);
    println!("BENCH synth, idle: {factor:.1}x real time ({PROFILE})");
    assert_eq!(sounding, 0, "nothing was asked to sound");
    assert!(
        !TIMED || factor > 100.0,
        "an idle synth costs {factor:.1}x real time"
    );
}
