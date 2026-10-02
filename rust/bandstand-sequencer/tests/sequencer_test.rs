//! Reading a sequence against the transport.
//!
//! The two crates only meet here, and what they have to agree about — where an
//! event lands in a block, and what happens at a loop — is exactly what a
//! backing track gets wrong when it is wrong.

// These tests assert the exact values the code produces, and their arithmetic
// converts between sizes deliberately.
#![allow(
    clippy::float_cmp,
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    clippy::cast_precision_loss
)]

use std::sync::Arc;

use bandstand_sequencer::{EventKind, Sequence, Sequencer, TimedEvent};
use bandstand_transport::{LoopRegion, TempoMap, Transport};

const SR: f64 = 48_000.0;
const PPQ: u32 = 960;

/// What the sink saw: the frame, and the event.
type Seen = Vec<(usize, TimedEvent)>;

fn sequencer(events: Vec<TimedEvent>, length: u64) -> Sequencer {
    Sequencer::new(Arc::new(Sequence::new(events, PPQ, length)))
}

fn collect(
    sequencer: &mut Sequencer,
    transport: &mut Transport,
    map: &TempoMap,
    frames: usize,
) -> Seen {
    let segments = transport.advance(frames, 0);
    let mut seen: Seen = Vec::new();
    let mut sink = |frame: usize, event: &TimedEvent| seen.push((frame, *event));
    sequencer.process(&segments, map, SR, &mut sink);
    seen
}

fn keys(seen: &Seen) -> Vec<u8> {
    seen.iter()
        .filter_map(|(_, event)| match event.kind {
            EventKind::NoteOn { key, .. } => Some(key),
            _ => None,
        })
        .collect()
}

#[test]
fn events_land_on_the_frame_their_tick_falls_on() {
    let map = TempoMap::constant(PPQ, 120.0).unwrap();
    // At 120 bpm a quarter note is half a second: 24 000 frames at 48 kHz.
    let mut sequencer = sequencer(
        vec![
            TimedEvent::note_on(0, 0, 60, 100),
            TimedEvent::note_on(960, 0, 62, 100),
            TimedEvent::note_on(1920, 0, 64, 100),
        ],
        2880,
    );
    let (mut transport, handle) = Transport::new(map.clone());
    transport.set_sample_rate(SR);
    handle.play();

    let seen = collect(&mut sequencer, &mut transport, &map, 72_000);
    assert_eq!(keys(&seen), vec![60, 62, 64]);
    assert_eq!(seen[0].0, 0);
    assert_eq!(seen[1].0, 24_000);
    assert_eq!(seen[2].0, 48_000);
}

#[test]
fn an_event_never_lands_past_the_end_of_its_block() {
    let map = TempoMap::constant(PPQ, 120.0).unwrap();
    let mut sequencer = sequencer(
        (0..64)
            .map(|i| TimedEvent::note_on(i * 30, 0, 60, 100))
            .collect(),
        2880,
    );
    let (mut transport, handle) = Transport::new(map.clone());
    transport.set_sample_rate(SR);
    handle.play();

    for _ in 0..40 {
        for (frame, _) in collect(&mut sequencer, &mut transport, &map, 256) {
            assert!(frame < 256, "frame {frame} is outside a 256-frame block");
        }
    }
}

#[test]
fn a_stopped_transport_emits_nothing() {
    let map = TempoMap::constant(PPQ, 120.0).unwrap();
    let mut sequencer = sequencer(vec![TimedEvent::note_on(0, 0, 60, 100)], 960);
    let (mut transport, _handle) = Transport::new(map.clone());
    transport.set_sample_rate(SR);

    let seen = collect(&mut sequencer, &mut transport, &map, 4096);
    assert!(seen.is_empty());
}

#[test]
fn a_tempo_change_moves_where_later_events_land() {
    let fast = TempoMap::constant(PPQ, 240.0).unwrap();
    let mut sequencer = sequencer(vec![TimedEvent::note_on(960, 0, 60, 100)], 1920);
    let (mut transport, handle) = Transport::new(fast.clone());
    transport.set_sample_rate(SR);
    handle.play();

    // At 240 bpm a quarter note is a quarter of a second: 12 000 frames.
    let seen = collect(&mut sequencer, &mut transport, &fast, 48_000);
    assert_eq!(seen[0].0, 12_000);
}

#[test]
fn a_loop_lets_go_of_every_note_that_was_sounding() {
    let map = TempoMap::constant(PPQ, 120.0).unwrap();
    // A note that starts inside the loop and is released after it: without the
    // wrap handling it would sound forever.
    let mut sequencer = sequencer(
        vec![
            TimedEvent::note_on(0, 0, 60, 100),
            TimedEvent::note_off(3840, 0, 60),
        ],
        3840,
    );
    let (mut transport, handle) = Transport::new(map.clone());
    transport.set_sample_rate(SR);
    handle.set_loop(LoopRegion {
        start_tick: 0,
        end_tick: 960,
        enabled: true,
    });
    handle.play();

    // Half a second is exactly the loop, so this block wraps once.
    let seen = collect(&mut sequencer, &mut transport, &map, 24_000);
    assert_eq!(keys(&seen), vec![60], "the note should start once");
    assert!(
        seen.iter()
            .any(|(_, event)| matches!(event.kind, EventKind::NoteOff { key: 60 })),
        "the wrap did not let the note go: {seen:?}"
    );
    assert_eq!(sequencer.sounding_notes(), 0);
}

#[test]
fn a_loop_plays_its_notes_again_on_every_pass() {
    let map = TempoMap::constant(PPQ, 120.0).unwrap();
    let mut sequencer = sequencer(
        vec![
            TimedEvent::note_on(0, 0, 60, 100),
            TimedEvent::note_off(480, 0, 60),
        ],
        960,
    );
    let (mut transport, handle) = Transport::new(map.clone());
    transport.set_sample_rate(SR);
    handle.set_loop(LoopRegion {
        start_tick: 0,
        end_tick: 960,
        enabled: true,
    });
    handle.play();

    // Three times round the loop.
    let seen = collect(&mut sequencer, &mut transport, &map, 72_000);
    assert_eq!(keys(&seen), vec![60, 60, 60], "{seen:?}");
}

#[test]
fn seeking_lets_go_of_what_was_sounding() {
    let map = TempoMap::constant(PPQ, 120.0).unwrap();
    let mut sequencer = sequencer(
        vec![
            TimedEvent::note_on(0, 0, 60, 100),
            TimedEvent::note_off(9600, 0, 60),
        ],
        9600,
    );
    let (mut transport, handle) = Transport::new(map.clone());
    transport.set_sample_rate(SR);
    handle.play();

    collect(&mut sequencer, &mut transport, &map, 4800);
    assert_eq!(sequencer.sounding_notes(), 1);

    handle.seek(5000.0);
    let seen = collect(&mut sequencer, &mut transport, &map, 4800);
    assert!(
        seen.iter()
            .any(|(_, event)| matches!(event.kind, EventKind::NoteOff { key: 60 })),
        "the seek left the note hanging"
    );
    assert_eq!(sequencer.sounding_notes(), 0);
}

#[test]
fn seeking_re_sends_the_programs_that_apply_there() {
    let map = TempoMap::constant(PPQ, 120.0).unwrap();
    let mut sequencer = sequencer(
        vec![
            TimedEvent::new(
                0,
                0,
                EventKind::Program {
                    bank: 0,
                    program: 4,
                },
            ),
            TimedEvent::new(
                960,
                0,
                EventKind::Program {
                    bank: 0,
                    program: 40,
                },
            ),
            TimedEvent::note_on(1920, 0, 60, 100),
        ],
        2880,
    );
    let (mut transport, handle) = Transport::new(map.clone());
    transport.set_sample_rate(SR);
    handle.seek(1900.0);
    handle.play();

    let seen = collect(&mut sequencer, &mut transport, &map, 4800);
    assert!(
        seen.iter()
            .any(|(_, event)| matches!(event.kind, EventKind::Program { program: 40, .. })),
        "seeking past a program change did not restore the sound: {seen:?}"
    );
}

#[test]
fn replacing_the_sequence_lets_go_of_what_was_sounding() {
    let map = TempoMap::constant(PPQ, 120.0).unwrap();
    let mut sequencer = sequencer(
        vec![
            TimedEvent::note_on(0, 0, 60, 100),
            TimedEvent::note_off(9600, 0, 60),
        ],
        9600,
    );
    let (mut transport, handle) = Transport::new(map.clone());
    transport.set_sample_rate(SR);
    handle.play();
    collect(&mut sequencer, &mut transport, &map, 4800);
    assert_eq!(sequencer.sounding_notes(), 1);

    let mut released = Vec::new();
    {
        let mut sink = |_frame: usize, event: &TimedEvent| released.push(*event);
        sequencer.set_sequence(Arc::new(Sequence::empty()), &mut sink);
    }
    assert_eq!(released.len(), 1);
    assert!(matches!(released[0].kind, EventKind::NoteOff { key: 60 }));
    assert_eq!(sequencer.sounding_notes(), 0);
}

#[test]
fn a_note_on_with_zero_velocity_clears_the_note_as_a_note_off_does() {
    let map = TempoMap::constant(PPQ, 120.0).unwrap();
    let mut sequencer = sequencer(
        vec![
            TimedEvent::note_on(0, 0, 60, 100),
            TimedEvent::note_on(480, 0, 60, 0),
        ],
        960,
    );
    let (mut transport, handle) = Transport::new(map.clone());
    transport.set_sample_rate(SR);
    handle.play();

    collect(&mut sequencer, &mut transport, &map, 24_000);
    assert_eq!(sequencer.sounding_notes(), 0);
}

#[test]
fn all_notes_off_clears_the_channel_it_names_and_no_other() {
    let map = TempoMap::constant(PPQ, 120.0).unwrap();
    let mut sequencer = sequencer(
        vec![
            TimedEvent::note_on(0, 0, 60, 100),
            TimedEvent::note_on(0, 1, 62, 100),
            TimedEvent::new(480, 0, EventKind::AllNotesOff),
        ],
        960,
    );
    let (mut transport, handle) = Transport::new(map.clone());
    transport.set_sample_rate(SR);
    handle.play();

    collect(&mut sequencer, &mut transport, &map, 24_000);
    assert_eq!(sequencer.sounding_notes(), 1);
}

#[test]
fn events_arrive_in_order_across_many_small_blocks() {
    let map = TempoMap::constant(PPQ, 132.0).unwrap();
    let events: Vec<TimedEvent> = (0..200)
        .map(|i| {
            #[allow(clippy::cast_possible_truncation)]
            TimedEvent::note_on(i * 240, 0, 60 + (i % 12) as u8, 100)
        })
        .collect();
    let mut sequencer = sequencer(events.clone(), 200 * 240);
    let (mut transport, handle) = Transport::new(map.clone());
    transport.set_sample_rate(SR);
    handle.play();

    // 200 events a quarter apart at 132 bpm is about 23 seconds; at 64 frames
    // a block that is a bit over 17 000 blocks.
    let mut all = Vec::new();
    for _ in 0..20_000 {
        all.extend(keys(&collect(&mut sequencer, &mut transport, &map, 64)));
    }
    let expected: Vec<u8> = events
        .iter()
        .filter_map(|event| match event.kind {
            EventKind::NoteOn { key, .. } => Some(key),
            _ => None,
        })
        .collect();
    assert_eq!(all, expected);
}

#[test]
fn a_loop_many_times_shorter_than_a_block_keeps_repeating() {
    let map = TempoMap::constant(PPQ, 400.0).unwrap();
    // P0.8's repro: a one-tick loop wraps far more often per 4096-frame block
    // than the transport's wrap budget can express. Every block must still
    // repeat the loop; the playhead must never be stranded outside it.
    let mut sequencer = sequencer(vec![TimedEvent::note_on(0, 0, 60, 100)], 1);
    let (mut transport, handle) = Transport::new(map.clone());
    transport.set_sample_rate(SR);
    handle.set_loop(LoopRegion {
        start_tick: 0,
        end_tick: 1,
        enabled: true,
    });
    handle.play();

    for block in 0..3 {
        let seen = collect(&mut sequencer, &mut transport, &map, 4096);
        assert!(
            !keys(&seen).is_empty(),
            "block {block} played nothing: the loop was abandoned"
        );
        assert!(
            transport.tick() < 1.0,
            "block {block} left the playhead at {} outside the loop",
            transport.tick()
        );
    }
}

#[test]
fn programs_re_sent_after_a_mid_block_wrap_land_at_the_wrap_frame() {
    let map = TempoMap::constant(PPQ, 120.0).unwrap();
    // Loop one quarter long, from tick 960 to 1920, and start half a quarter
    // in: the wrap back to tick 960 lands at frame 12 000 of a 24 000-frame
    // block, not on a block boundary. The wrap re-sends the program changes
    // that apply strictly before the loop start — the one sitting exactly on
    // the loop start is dispatched once, by the walk (L-RT2) — and everything
    // it re-sends must land at the wrap frame, inside the second pass's time
    // region — not at frame 0 of the block.
    let mut sequencer = sequencer(
        vec![
            TimedEvent::new(
                0,
                0,
                EventKind::Program {
                    bank: 0,
                    program: 4,
                },
            ),
            TimedEvent::new(
                960,
                0,
                EventKind::Program {
                    bank: 0,
                    program: 40,
                },
            ),
            TimedEvent::note_on(960, 0, 60, 100),
            TimedEvent::note_off(1200, 0, 60),
        ],
        1920,
    );
    let (mut transport, handle) = Transport::new(map.clone());
    transport.set_sample_rate(SR);
    handle.set_loop(LoopRegion {
        start_tick: 960,
        end_tick: 1920,
        enabled: true,
    });
    handle.play();
    handle.seek(1440.0);

    let seen = collect(&mut sequencer, &mut transport, &map, 24_000);
    let programs: Vec<(usize, u16)> = seen
        .iter()
        .filter_map(|(frame, event)| match event.kind {
            EventKind::Program { program, .. } => Some((*frame, program)),
            _ => None,
        })
        .collect();
    // The initial seek to 1440 re-sends program 40 (its change at tick 960,
    // before the target) at frame 0. At the wrap the restore re-sends the
    // channel's applicable program strictly before the loop start — that is
    // program 4, at tick 0 — and the walk then dispatches the loop's own
    // change, program 40 at the loop start, exactly once per pass (L-RT2:
    // the change sitting on the loop start itself is never doubled). The
    // restore of program 4 lands at the same frame and is superseded before
    // any note sounds, so nothing after the first dispatch lands inside the
    // first pass's time region.
    assert_eq!(programs, vec![(0, 40), (12_000, 4), (12_000, 40)]);
    // The note at the loop start plays on the second pass, at the wrap frame.
    assert!(
        seen.iter().any(|(frame, event)| *frame == 12_000
            && matches!(event.kind, EventKind::NoteOn { key: 60, .. })),
        "the second pass did not play the loop's note: {seen:?}"
    );
}

#[test]
fn overlapping_notes_on_one_key_keep_an_accurate_count() {
    let map = TempoMap::constant(PPQ, 120.0).unwrap();
    // Two notes on the same key overlap; one note-off is not enough to stop
    // both (P2.65: the sounding table counts per slot, not per key).
    let mut sequencer = sequencer(
        vec![
            TimedEvent::note_on(0, 0, 60, 100),
            TimedEvent::note_on(240, 0, 60, 100),
            TimedEvent::note_off(480, 0, 60),
        ],
        960,
    );
    let (mut transport, handle) = Transport::new(map.clone());
    transport.set_sample_rate(SR);
    handle.play();

    collect(&mut sequencer, &mut transport, &map, 24_000);
    assert_eq!(
        sequencer.sounding_notes(),
        1,
        "one overlapping note was lost"
    );
}

#[test]
fn a_loop_lets_go_of_an_overlapping_note_still_sounding() {
    let map = TempoMap::constant(PPQ, 120.0).unwrap();
    // Two overlapping notes on one key, one note-off inside the loop. The
    // wrap must still release the survivor; a boolean table had already
    // forgotten it.
    let mut sequencer = sequencer(
        vec![
            TimedEvent::note_on(0, 0, 60, 100),
            TimedEvent::note_on(240, 0, 60, 100),
            TimedEvent::note_off(480, 0, 60),
        ],
        960,
    );
    let (mut transport, handle) = Transport::new(map.clone());
    transport.set_sample_rate(SR);
    handle.set_loop(LoopRegion {
        start_tick: 0,
        end_tick: 960,
        enabled: true,
    });
    handle.play();

    let seen = collect(&mut sequencer, &mut transport, &map, 24_000);
    // The note-off inside the loop (tick 480) is not enough: the overlapping
    // note it leaves sounding must be let go by the wrap itself, at the wrap
    // frame — a per-key table had already forgotten it.
    let offs: Vec<usize> = seen
        .iter()
        .filter(|(_, event)| matches!(event.kind, EventKind::NoteOff { key: 60 }))
        .map(|(frame, _)| *frame)
        .collect();
    assert_eq!(offs, vec![12_000, 23_999]);
    assert_eq!(sequencer.sounding_notes(), 0);
}
