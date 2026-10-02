# Remediation Plan — Bandstand QA Audit

Compiled from the full-coverage line-by-line audit of the hand-written Dart and Rust
corpus (~216 source/test files, ~48k lines). Every finding below cites its location
and gives concrete fix instructions. Findings are grouped by priority, not by
discovery order; each item is independently actionable.

**Priorities:**

- **P0** — wrong/corrupt user-facing behavior, silent data loss, or a permanently
  broken playback state. Fix first; each needs a regression test.
- **P1** — real bugs in reachable paths, or contract violations that mislead
  callers/debuggers.
- **P2** — edge cases, latent bugs, doc/code contradictions, resource hygiene.
- **P3** — test quality: assertions that can never fail, vacuous guards, flaky
  timing checks.

**Verification baseline (all currently green — keep them green):**

```sh
cd app && flutter analyze && flutter test          # no issues; 844 tests
cd rust && cargo clippy --workspace --all-targets  # clean
cd rust && cargo test --workspace                  # 72 tests
```

Each fix should add or update a test that fails before the fix and passes after,
unless the item explicitly says otherwise.

---

## P0 — High

### P0.1 `ChordModifier.applyTo` silently drops `b9`/`#9`

`app/lib/domain/harmony/chord_type_database.dart:64-69`

**Problem:** degrees are removed by letter index, so applying `#9` after `b9` (or
vice versa) deletes the other. `C7b9#9` parses to `1 3 5 b7 #9`. Confirmed against
the shipped `chord_types.json`. Order-dependent, and the resulting `ChordType.name`
claims a degree that is not in the set.

**Fix:**

1. In the `removeWhere` predicate, only match an existing degree by letter index
   when the existing degree is *unmodified* (e.g. replacing plain `9` when adding
   `b9`), and always match by semitone count so true duplicates still collapse.
   Two degrees with the same letter index but different alterations (`b9`, `#9`)
   must coexist.
2. Add regression tests: `ChordSymbol.parse('C7b9#9')` and `parse('C7(#9b9)')` must
   both contain exactly `{1, 3, 5, b7, b9, #9}`, and `format()` must round-trip
   both regardless of written order.

### P0.2 Text importer truncates sharp chords at `#`

`app/lib/io/importers/text_import.dart:53`

**Problem:** `lines[index].split('#').first` turns `| F#7 | B7 |` into `| F`,
which parses *validly* — the sharp, the alteration, and the rest of the line are
silently discarded with no problem entry.

**Fix:**

1. Strip comments only when `#` starts a comment: split on `RegExp(r'(^|\s)#')`
   (or require `#` at start-of-line/after whitespace), never inside a token.
2. Add a problem entry if truncation leaves a dangling partial token.
3. Regression test: `| F#7 | B7 |` imports two bars with F♯7 and B7 and zero problems.

### P0.3 corpus_import tool has the same `#` truncation bug

`tools/corpus_import/lib/annotation.dart:73`

**Problem:** identical defect to P0.2 — `F#7 Bb7` harvests as `F`, silently
producing wrong harmony for sharp-side keys.

**Fix:** same regex-based comment stripping as P0.2. Add a test parsing an
annotation containing `F#7 C#m7` chords; extend `import_test.dart` (currently only
tests `#`-as-comment).

### P0.4 MusicXML importer: invalid meter escapes the intended catch

`app/lib/io/importers/musicxml_import.dart:328-332`

**Problem:** the code catches `ArgumentError` around `TimeSignature(upper, lower)`,
but that constructor only `assert`s and throws `AssertionError`. A file with
`4/5` crashes in debug; in release it installs an invalid meter that flows into
every beat conversion.

**Fix:** use `TimeSignature.tryParse('$upper/$lower')`; on null, record a problem
(mirroring `text_import.dart:257-260` and `ireal_import.dart:586`). Regression
test: import a file with `<beats>4</beats><beat-type>5</beat-type>` and assert a
problem is recorded and no invalid meter is installed.

### P0.5 MusicXML rehearsal-mark sections default to 4/4

`app/lib/io/importers/musicxml_import.dart:499`

**Problem:** sections created from `<rehearsal>` marks omit the time signature, so
`Section.timeSignature` defaults to 4/4 even when the file is in 6/8. From that
bar onward `timeSignatureAt` returns the wrong meter.

**Fix:** pass `timeSignature: timeSignature` (the running meter) at the `CliSection`
construction site. Regression test: 6/8 file with two rehearsal-marked sections;
assert `sheet.timeSignatureAt(bar_in_section_2)` is 6/8.

### P0.6 Playlist edits reset `modifiedAt` to the creation time

`app/lib/domain/song/playlist.dart:299-322`

**Problem:** `_with`, `renamed`, and `withNote` omit `modifiedAt`, so the factory
falls back to `createdAt`. Every edit moves the timestamp *backwards*, and since
`Playlist.==`/`hashCode` include `modifiedAt`, a playlist compares equal to its
pre-edit self.

**Fix:** pass `modifiedAt: DateTime.now().toUtc()` in all three rebuild methods
(mirroring `Song.copyWith`, `song.dart:169`). Tests: rename/add/move an entry and
assert `modifiedAt` is after `createdAt` and the edited playlist is not equal to
the original.

### P0.7 `Song.==`/`hashCode` omit `writtenParts`

`app/lib/domain/song/song.dart:192-206, 221-236`

**Problem:** songs differing only in written parts compare equal. Because
`UndoStack.run` (`app/lib/domain/command/undo_stack.dart:81-83`) discards commands
whose before/after compare equal, any edit touching only written parts is silently
non-undoable.

**Fix:** include `writtenParts` in `==` (list-length + pairwise comparison;
`WrittenPart` has value equality) and in `hashCode` (`Object.hashAll(writtenParts)`).
Tests: songs differing only in a written part must be unequal with different hash
codes; an undo of a written-part edit must restore the previous state.

### P0.8 Transport abandons the loop permanently

`rust/bandstand-transport/src/transport.rs:403-434`

**Problem:** when one block needs ≥ `MAX_BLOCK_SEGMENTS` wraps, or the playhead is
exactly at/past `end_tick`, the code falls through to plain advance. Because the
wrap guard is `tick < loop_end`, the transport never wraps again for the rest of
playback. Reproduced: 0..1-tick loop at 4096-frame block → playhead stuck at
tick 539.6, outside the loop. The existing boundedness test passes during the
defect.

**Fix:**

1. In `advance`, when the loop region is active and `tick >= loop_end` at block
   start, wrap to `start_tick` and bump `loop_generation` before splitting
   segments (don't require `tick < loop_end` as a precondition for wrapping).
2. Strengthen `a_loop_shorter_than_a_block_is_bounded` (transport.rs:622-642) to
   advance a *second* block and assert the playhead is back inside the loop; add a
   test for a seek landing exactly on `end_tick` and for a loop enabled while the
   playhead is past its end.

---

## P1 — Medium

### Audio engine / state layer

**P1.1 — Focus return auto-starts playback the user explicitly paused**
`app/lib/state/platform_audio.dart:225-241`
On `lostTransient`, `pausedForFocus: true` is set unconditionally. On `gained`,
playback restarts even if the user had paused before the interruption — the exact
case the file's own policy comment (lines 118-124) forbids.
*Fix:* snapshot whether the transport was playing before setting the flag; on
`gained`, only auto-play if it was. Test: pause → simulate transient loss/gain →
transport must still be paused.

**P1.2 — Duck gain stuck at 0.25 after permanent focus loss**
`app/lib/state/platform_audio.dart:218-223`
The `lost` branch stops transport and clears flags but never restores
`normalGain` if a duck was in effect; no `gained` follows a permanent loss, and
`play()` never touches gain.
*Fix:* call `setMasterGain(gain: normalGain)` in the `lost` branch before clearing
flags. Test: duck → permanent loss → play → gain is normal.

**P1.3 — `stop()` and settings changes silently dropped during an in-flight `start()`**
`app/lib/audio/audio_engine.dart:135-170`
All of `stop()`/`selectDevice`/`selectSampleRate`/`selectBufferFrames` return
immediately when `state.busy`, which `start()` holds across an unbounded FFI
round-trip. A user pressing Stop during that window gets nothing.
*Fix:* queue the requested action (a pending-action field applied when the
in-flight operation completes) instead of dropping it. Test: call `stop()`
concurrent with a stubbed slow `start()`; assert the engine ends up stopped.

**P1.4 — Tone-push failure after successful start leaks a running stream reported as off**
`app/lib/audio/audio_engine.dart:112-131`
If `_pushTone()` throws after `audioStart` succeeded, the catch clears status and
sets `errorMessage` while the stream keeps rendering; polling never starts and the
stream is never closed.
*Fix:* handle tone-push failure separately: keep the started status, report the
tone error, start polling, and expose a way to retry the tone. Test: make
`_pushTone` throw; assert status reflects a running engine with an error message.

**P1.5 — `generateAndLoad` is not serialized; concurrent calls interleave**
`app/lib/state/generation_state.dart:89-121`
Multiple `await`s between `busy: true` and `loadSequence`, with no re-check — two
overlapping calls can leave the engine playing song A while state says song B.
Related: `practice_state.dart:96-109` `advance()`/`goTo()` have no guard at all.
*Fix:* serialize through a single in-flight future (chain: `._inFlight =
(_inFlight ?? Future.value()).then(_generateAndLoad)`), or add a generation
counter checked after each await, aborting stale runs. Test: two rapid
`generateAndLoad` calls with different songs; final engine sequence and state must
describe the same (last-requested) song.

**P1.6 — Failed regeneration exports/plays the stale previous sequence, reported as success**
`app/lib/state/export_state.dart:90-101` and
`app/lib/ui/widgets/song_transport_bar.dart:65-77`
`generateAndLoad` catches its own errors and never rethrows; neither caller checks
the outcome, so a failed regeneration exports or plays whatever sequence the
engine still holds — possibly a different song — as the new take.
*Fix:* after `generateAndLoad`, verify the playback state (`songId == song.id`,
`errorMessage == null`) and bail out before `renderOffline`/`transportSeek`/
`transportPlay`. Test: make generation fail; assert no seek/play/render happens
and the error is surfaced.

**P1.7 — Walking-bass generator ignores `randomSeed`; reroll is a no-op**
`app/lib/domain/generation/bass/walking_bass_generator.dart:70-143`
The doc promises seeded reroll; nothing consumes `GenerationContext.randomSeed`,
and the pipeline is fully deterministic — two seeds return byte-identical lines.
*Fix:* consume the seed (e.g. seeded tie-breaking/jitter in `_rank`). If reroll
variation is intentionally out of scope for this generator, correct the doc and
the generator's contract comment. Test: two different seeds produce different
lines; the same seed reproduces.

### Importers / exporters

**P1.8 — Voicing-engine seeds bypass constraint checks but report `isClean`**
`app/lib/domain/generation/voicing/voicing_engine.dart:170-181`
Seeds from `VoicingBuilder.candidates` are deliberately unfiltered, yet
`_chainFrom` forces the seed with `relaxation: none` and the chain score never
penalizes it — a first `VoicingChoice` can be clean-flagged while violating rules
`choose()` enforces (e.g. quartal voicing over a minor chord omits the third).
*Fix:* run seeds through `VoicingConstraints.check`; record the real rejection in
`relaxation`/`isClean`, and include the seed in the chain score's
relaxation/family terms. Test: a seed that violates a constraint must not be
reported `isClean`.

**P1.9 — Parts spanning a meter change get wrong beat math**
`app/lib/domain/generation/generation_context.dart:160-185` (compounded by
`song_generator.dart:133-135`, `drum_generator.dart:114`,
`comping_generator.dart:100`)
`forPart` converts every chord's quarter position with the *first* bar's
`beatDurationInQuarters`, but bars may carry different meters (`timeSignatureAt`).
Every chord after a mid-part meter change lands at a wrong beat.
*Fix:* either reject/split parts spanning a meter change, or convert per bar using
each bar's own `beatDurationInQuarters`. Test: a part crossing a 4/4→6/8 change
must place chords at the documented beats either way (rejection must produce a
problem entry).

**P1.10 — MusicXML export: chord offsets wrong in non-quarter meters**
`app/lib/io/exporters/musicxml_export.dart:118,156`
Offset = `beat * divisions` with `divisions` per quarter, but `Position.beat` is in
written beats (`beatDurationInQuarters = 4/lower`). In 6/8, chords after beat 0
are placed late by factor `4/lower`.
*Fix:* `(beat * beatDurationInQuarters * divisions).round()` — pass the bar's time
signature (or offset in quarters) into `_harmony`. Test: 6/8 song with a chord at
beat 2 exports at division 4, not 8.

**P1.11 — MusicXML export: per-section meters ignored; endings/navigation dropped**
`app/lib/io/exporters/musicxml_export.dart:68,75-93,123-128` and module doc 9-12
Every bar is exported in the global meter; bars in a 3/4 section get a 4-quarter
rest and no `<attributes><time>`. `CliEnding`, `CliNavigation`, and `CliAnnotation`
items are never written despite the doc claiming "the written page, repeats and
all".
*Fix:* use `sheet.sectionAt(bar).timeSignature` for bar lengths; emit
`<attributes><time>` on the first bar of each meter change; export `<ending>` for
`CliEnding` and `<direction><words>` for navigation/annotation — or narrow the doc
claim. Tests: meter-change song round-trips; a chart with 1st/2nd endings exports
them.

**P1.12 — Malformed written-note data throws raw `ArgumentError`, not `SongFormatException`**
`app/lib/io/song_json.dart:255-289`
`WrittenNote(…)` constructions sit outside the `try`/`on ArgumentError` block, so a
note with e.g. `key: 200` escapes as `ArgumentError` past the recovery handling.
*Fix:* move the note-parsing loop inside the try (or wrap it separately). Test:
song JSON with an out-of-range written-note key throws `SongFormatException`.

**P1.13 — PDF heading overlaps the chart**
`app/lib/io/exporters/pdf_export.dart:39,104-155`
The 150 px reservation is ~29 px short of the real two-line heading (probe-
verified: heading bottom at y=179 at scale 300/72). Every chart with a composer
line overlaps.
*Fix:* lay the heading out first, measure its height, and use that for the
translate and raster height instead of the constant. Test: title + composer export
— assert the heading region and chart region do not overlap (compare against a
golden or the measured layout box).

**P1.14 — MusicXML endings left open at EOF are silently discarded**
`app/lib/io/importers/musicxml_import.dart:561-583`
Only `type="stop"`/`"discontinue"` finalize an ending; a trailing open ending (or
one overwritten by a second `type="start"`) vanishes with no problem, while an
unmatched backward ending *is* reported — asymmetric.
*Fix:* close any open ending at EOF (as `text_import.dart:96-98` does) and report
an overwritten open ending. Test: file ending mid-ending imports with the ending
captured plus zero problems.

**P1.15 — MusicXML `<degree>` modifiers blindly appended to the kind**
`app/lib/io/importers/musicxml_import.dart:427-454`
`major` + `add 9` becomes `C9` (a dominant ninth — adds a minor 7th the file never
had); `major-seventh` + add-13 produces `Cmaj713` (unparseable).
*Fix:* map `add` degrees to faithful Bandstand spellings where they exist (e.g.
`6`, `maj9`); report a problem when no faithful spelling exists instead of
emitting a different chord. Test: `major`+add9 imports as a major-ninth chord, not
`C9`.

**P1.16 — iReal URL decode error escapes uncaught**
`app/lib/io/importers/ireal_import.dart:177-179`
`Uri.decodeComponent` on a malformed `%`-escape throws `FormatException`, which is
not one of the documented exceptions and is not caught at playlist level.
*Fix:* catch `FormatException` and rethrow as `NotAnIRealUrl` (or record a
playlist-level problem). Test: URL containing `%ZZ` is refused cleanly.

**P1.17 — Melody tie tracking keyed by clamped MIDI key**
`app/lib/io/importers/musicxml_melody.dart:212-238`
The `tied` map is keyed by the shifted-and-clamped key, so distinct written
pitches that clamp to the same value collide; the overwritten open tie is never
reported.
*Fix:* key `tied` by written pitch (from `_pitchOf`) plus voice. Test: two
written pitches that would clamp together each tie independently.

**P1.18 — Text importer drops a section declared at bar 0**
`app/lib/io/importers/text_import.dart:114-118`
The `entry.key > 0` guard discards `sections[0]` — including the doc's own
canonical example ("A:" as the first chart line) — and two pre-bar section lines
overwrite each other.
*Fix:* at bar 0, replace/rename the default 'A' section instead of dropping, or
record a problem; reject duplicate pre-bar section lines with a problem. Test:
the doc's example imports with section A named and present.

### Rust — synth

**P1.19 — Sustain-pedal release cuts still-held notes**
`rust/bandstand-synth/src/synth.rs:293-320`
While the pedal is down, `note_off` is swallowed with no record of which keys went
up; on pedal-up *all* held voices are released, including keys still physically
down. Every GM synth releases only the keys that received note-off during sustain.
*Fix:* track per-channel "released while sustained" key marks; on pedal-up release
only those. Test: hold a chord, tap pedal, release pedal while holding — the chord
must still sound; then key-up ends it.

**P1.20 — Tremolo runs at double rate (`abs()` of bipolar product)**
`rust/bandstand-synth/src/voice.rs:405-409`
`mod_lfo` is bipolar and the generator is in centibels; `centibels_to_gain` clamps
negatives to unity, so the signed product already oscillates correctly. The
`.abs()` applies attenuation on both halves → double-frequency tremolo, and the
generator's sign is discarded. The adjacent pitch/filter paths use the signed
product correctly.
*Fix:* `centibels_to_gain(settings.mod_lfo_to_volume * mod_lfo)` with no `abs()`.
Test: render a bank with `modLfoToVolume` set; the gain-modulation envelope must
have the LFO's fundamental period.

**P1.21 — Loop wrap fails when `increment > loop length`**
`rust/bandstand-synth/src/voice.rs:421-426`
Only one subtraction per sample; when `increment > length`, position grows without
bound and extreme-high looped notes go silent while burning CPU.
*Fix:* wrap with
`self.position = loop_start + (self.position - loop_start).rem_euclid(length)`.
Test: force a high key on a short-looped sample; assert playback stays in-loop and
audible across blocks.

**P1.22 — SF2 `originalPitch == 255` ("undefined") renders ~16 octaves off**
`rust/bandstand-synth/src/voice.rs:170-178`, `rust/bandstand-synth/src/sf2/parse.rs:230`
*Fix:* treat 255 as "play at the played key" (root = key, cents from tuning
generators only) or substitute a documented default. Test: sample with
`originalPitch = 255` plays at the keyed pitch.

**P1.23 — `note_on` heap-allocates on the audio thread**
`rust/bandstand-synth/src/lib.rs:7` vs `rust/bandstand-synth/src/sf2/bank.rs:353-380`
The crate claims "nothing allocates, locks or blocks on the audio thread", but
`voices_for` builds a fresh `Vec<VoiceRecipe>` (plus a `GeneratorSet::clone()` per
zone) on every note-on, and `Synth` is owned by the audio thread.
*Fix:* resolve recipes into a caller-owned reusable buffer (`&mut Vec<VoiceRecipe>`
cleared per call) held by `Synth`; avoid the per-zone clone where possible. Note:
fixing this removes the doc contradiction in P2.57 too.

**P1.24 — Memory-mapped soundfont can SIGBUS if the file changes on disk**
`rust/bandstand-synth/src/sf2/parse.rs:33-39`, `rust/bandstand-synth/src/sf2/samples.rs:143`
The SAFETY comment covers the app itself, not external modification; a truncated/
replaced file mid-playback turns the next mapped read into SIGBUS, killing the
process uncatchably.
*Fix:* document the constraint in user-facing docs at minimum; stronger options:
`mlock` the mapping or fall back to resident samples on platforms where files can
change. At least map read errors defensively where feasible.

### Rust — transport / sequencer / FFI

**P1.25 — Program changes re-sent after a mid-block wrap land at frame 0**
`rust/bandstand-sequencer/src/sequencer.rs:147-156`
After a wrap segment, the next segment is treated as a jump and `seek_to`
re-sends program changes at frame 0 of the block — inside the previous pass's time
region. Every non-block-aligned wrap plays wrong sounds.
*Fix:* pass `segment.frame_offset` into `seek_to` and dispatch at that frame.
Test: wrap at a non-zero frame offset with a program change after the wrap point;
assert the program event lands at the wrap frame.

**P1.26 — Seek can be applied twice (load-order race)**
`rust/bandstand-transport/src/transport.rs:370-377`
`seek_seq` is loaded (Acquire) before `seek_tick_bits` (Relaxed); a concurrent
`seek()` between the loads makes the audio thread consume the new sequence number
with the old tick and re-apply the same tick next block, snapping the playhead
back.
*Fix:* classic seqlock read: load `seek_tick_bits` first, then `seek_seq` with
Acquire, retry if `seq` changed between the loads (or pack both into one atomic).
Test: hammer seeks from one thread while advancing from another; assert the
applied tick always matches a published seek.

**P1.27 — FFI boundary validates nothing**
`rust/src/api/audio.rs:351-377`
`data1 = 300` silently becomes key 44; channel 16–255 wraps via `% CHANNEL_COUNT`;
`PitchBend` with `data2 > 16383` exceeds the documented range; values truncate
instead of erroring.
*Fix:* in `to_timed`/`load_sequence`, validate `channel < 16`, `data1 <= 127`, and
per-kind `data2` ranges; return `Err` with a clear message on violation. Test: each
out-of-range input returns an error, not a wrapped event.

**P1.28 — `load_sequence` ignores `ppq` when tempo markers are empty**
`rust/src/api/audio.rs:393-397`
With empty markers the installed tempo map's `ppq` is kept; events generated
against the passed `ppq` play at the wrong speed with no error.
*Fix:* when markers are empty, rebuild the map as `TempoMap::constant(ppq,
current_bpm)` (or reject the call). Test: load a sequence with a ppq different
from the installed map and empty markers; playback timing must match the sequence
grid.

**P1.29 — Offline render clamps the DSP rate but writes the raw rate into the WAV header**
`rust/src/offline.rs:94 vs 112,172,176`
For `sample_rate < 8000` (reachable from the UI), audio renders at 8000 Hz while
the header claims the raw rate — the file plays at the wrong speed/pitch.
*Fix:* reject `sample_rate < 8000` at the API (return an error), or use the
clamped rate consistently in header and summary. Test: rate 4000 either errors or
produces a header that matches the rendered rate.

**P1.30 — Offline bounce ignores the live mix**
`rust/src/api/audio.rs:463-477`, `rust/src/offline.rs:97-98`
The bounce hardcodes master gain 0.5 and never applies per-channel volume/pan/mute,
so a muted channel sounds in the bounce and a lowered master gain is ignored —
the file does not reflect what the user hears.
*Fix:* pass `EngineState.channels`/`master_gain` into `render_to_wav` and apply
them, or document the bounce as raw in the API doc. Test: mute a channel, bounce,
assert it is silent (or assert documented raw behavior).

---

## P2 — Low (edge cases, hygiene, doc/code drift)

### Error-contract leaks (throw the documented exception type)

- **P2.1** `app/lib/domain/generation/bass/bass_corpus_codec.dart:151-162` —
  short-form pitch out of range escapes `decode()` as `ArgumentError`. Wrap the
  note construction in `_readShortNotes` in the same `on ArgumentError →
  FormatException` used by `_readLongNote`.
- **P2.2** `app/lib/domain/harmony/diagrams/chord_diagram_library.dart:100,139` —
  wrong-typed `displayName`/`baseFret` throw uncaught `TypeError`, violating the
  `FormatException` contract. Catch `TypeError` too (or validate types), and
  include instrument/shape context in the `PitchSpelling.parse` failure message.
- **P2.3** `app/lib/domain/generation/drum_patterns.dart:160-166,196` — raw
  `TypeError` on non-numeric `intensity` elements; `chance` accepts any number.
  Validate element types and range-check `chance` to 0..1 with a `FormatException`
  naming the pattern id.
- **P2.4** `app/lib/domain/generation/comping/comping_cells.dart:108` — a bad
  meter string propagates a cell-id-less `FormatException`. Catch `FormatException`
  in `_readCell` and rethrow with the `cell "$id"` prefix the doc promises.

### Music-domain math & model inconsistencies

- **P2.5** `app/lib/domain/harmony/chord_type.dart:67-77` — duplicate-degree check
  carves out `asExtension`, accepting `[2°, 9°]` which then emits duplicate pitch
  classes, while `ChordType.==` treats them as different. Decide one rule: either
  reject `==`-equal pairs in the constructor (and fix the doc) or keep the
  carve-out and dedupe in `pitchClassesFrom`/`spellingsFrom`.
- **P2.6** `app/lib/domain/harmony/chord_type.dart:112-115` and
  `app/lib/domain/harmony/scale.dart:45-48` — "ascending" doc claims are false for
  9/11/13 degrees (`C13` → `[0,4,7,10,2,9]`). Sort output ascending or correct the
  docs; audit consumers if sorting.
- **P2.7** `app/lib/domain/harmony/diagrams/chord_diagram.dart:59-66` — constructor
  validates `baseFret ≤ 20` and fret ≤ 24 independently but not the combined
  `baseFret + fret - 1 ≤ 24` that `transposed()` enforces. Apply the same combined
  bound at construction.
- **P2.8** `app/lib/domain/harmony/ext_chord_symbol.dart:64-67` — the `N.C.` branch
  silently drops caller-supplied `rendering`/`scale`. Apply the parameters or
  document the drop.
- **P2.9** `app/lib/domain/harmony/nashville.dart:53-55` — major/minor pitch-class
  tables duplicated from `KeyMode.semitones`. Use `key.mode.semitones` so the two
  cannot diverge.
- **P2.10** `app/lib/domain/generation/bass/wbp_tiling.dart:310-313` — freshness
  window is off-by-one vs `docs/rules/corpus-tiling.md` §6.2 (`>` should be `>=`,
  or fix the doc). Pick one and make the test assert the same rule.
- **P2.11** `app/lib/domain/generation/bass/wbp_tiling.dart:432-435` — fallback-bar
  fifth applies only one `-12` correction; a custom range < 12 semitones can emit
  out-of-range MIDI. Wrap by ±12 in a loop until inside the range (or clamp and
  record a problem).
- **P2.12** `app/lib/domain/generation/bass/wbp_source.dart:269` — strong-beat
  detection (`beat % 2 == 0`) is hardcoded to a 4/4 grid though the corpus format
  allows any `beatsPerBar`. Derive beats-per-bar from the harmony span and compute
  strong beats per meter.
- **P2.13** `app/lib/domain/generation/generation_context.dart:96-106` — `chordAt`
  ignores `endBeat` and returns a chord after it stopped sounding. Require
  `beat < chord.endBeat` (or document the hold-over behavior explicitly).
- **P2.14** `app/lib/domain/generation/chord_tones.dart:80-84` — `_defaultScale`
  for `ChordFamily.other` asserts 2 and 9 as scale tones, contradicting its own
  comment ("everything else is chromatic"). Reconcile the table with the comment.
- **P2.15** `app/lib/domain/generation/song_generator.dart:173-207` — channel
  allocator can double-assign: `nextChannel = channel + 1` moves backwards when a
  low `preferredChannel` is processed late, and >15 voices all get channel 15.
  Track an assigned-channel `Set` and have `_nextFreeChannel` skip it; surface a
  problem when channels run out.
- **P2.16** `app/lib/domain/generation/post_processing.dart:111-115` — `fixOverlaps`
  comment promises dropping the second same-onset note; the code keeps both at
  full length, defeating the function's purpose on a monophonic voice. Skip the
  lower-priority note when `longest <= 0`.
- **P2.17** `app/lib/domain/generation/voicing/voicing_constraints.dart:121-127` —
  the `lowMinorSecond` rejection is unreachable (the interval-limit loop at
  89-95 fires first for the same condition). Reorder so §6.5 is evaluated first,
  or drop the redundant check.
- **P2.18** `app/lib/domain/generation/voicing/voicing_engine.dart:268-272` —
  `_onlyFailsRootRules` inspects only the *first* failure, so a candidate failing a
  root rule *and* a minor-ninth clash passes at `VoicingRelaxation.root` with the
  clash intact. Make `check` return all failures, or re-run clash checks inside the
  guard.
- **P2.19** `app/lib/domain/generation/comping/comping_generator.dart:178-194` —
  the "leave space at the end" filter misses multi-bar cells that *cover* the last
  bar (`bar + 1 >= barCount` is false for a cell starting at `barCount - 2`). Base
  the filter on coverage: `bar + cell.bars >= barCount`.
- **P2.20** `app/lib/domain/generation/drum_generator.dart:158-160` — when a meter
  has patterns but no groove, the loop `break`s and the rest of the part is silent
  with no `problems` entry. Add a problem when the loop exits with bars unplayed.
- **P2.21** `app/lib/domain/generation/bass/bass_corpus_codec.dart:260-275` —
  encoder drops velocities when re-encoding: the `isWalking` predicate checks beats
  and durations but not velocities, so a legally-accented long-form phrase re-
  encodes as a bare pitch array and loses accents. Include the velocity check in
  `isWalking` (or emit long form when any velocity deviates).
- **P2.22** `app/lib/domain/song/playlist.dart` / `app/lib/io/playlist_json.dart:120-146`
  vs `app/lib/io/song_json.dart:190-227` — duplicated migration-chain logic has
  diverged: playlist lacks the `current < 1` guard. Reuse `applyMigrationChain` or
  add the guard.
- **P2.23** `app/lib/domain/phrase/phrase.dart:264-273` +
  `app/lib/domain/phrase/note_event.dart:62-64` — negative `shifted` clamps
  distinct notes onto beat 0 instead of dropping them. Reject negative shifts for
  `SizedPhrase` or drop notes landing below the range start.
- **P2.24** `app/lib/domain/song/written_part.dart:188` — `barCount` ignores notes
  sustaining past their start bar. Compute the end bar from duration and meter, or
  document that `barCount` means "last start bar + 1".

### Importer / IO robustness

- **P2.25** `app/lib/io/importers/ireal_import.dart:233-238` — trailing-metadata
  fields parsed by pure index (`fields[7]`/`fields[8]`), so exports with partial
  trailing metadata misalign tempo/repeats. Parse from the end or validate the
  style field before trusting alignment; report unparseable tempo.
- **P2.26** `app/lib/io/importers/ireal_import.dart:640-690` — a chart with no
  sections produces a structure pointing at a nonexistent section → zero bars
  play. Guarantee at least one section (as `ChordLeadSheet.empty` does).
- **P2.27** `app/lib/io/importers/musicxml_import.dart:515-518` — out-of-range
  tempo silently becomes 120 with no problem (the text importer reports it).
  Record a problem.
- **P2.28** `app/lib/io/importers/musicxml_import.dart:450,473-476` — degree
  accidentals collapse to a single `#`/`b` regardless of `|alter|` while `_spell`
  repeats correctly. Repeat the accidental `alter.abs()` times.
- **P2.29** `app/lib/io/importers/musicxml_import.dart:479-489` — `<offset>` beat
  is not clamped above; a chord past the bar end lands in later bars via
  `toQuarters`. Clamp to the meter's beat count or report a problem.
- **P2.30** `app/lib/io/importers/musicxml_melody.dart:186-254` — multi-voice
  parts are flattened into overlapping notes. Keep voice 1 and report the drop, or
  report multi-voice parts as a problem.
- **P2.31** `app/lib/io/importers/ireal_import.dart:648,656,663` — `pendingSection`
  assigned but never read (dead store). Remove it.
- **P2.32** `app/lib/io/importers/musicxml_melody.dart:268-271` — tautological
  `duration > 0 ? duration : 0` (dead conditional). Simplify.
- **P2.33** `app/lib/io/exporters/export_service.dart:88-113` — same-title songs
  overwrite each other's exports; `safeFileName` truncates by code units, not
  bytes. Include the song id (or a collision suffix) in the filename; truncate by
  UTF-8 byte length.
- **P2.34** `app/lib/io/midi/midi_writer.dart:85-93` — non-ASCII text (e.g.
  "B♭") is stripped from exported track names/markers. Encode as latin-1 when it
  fits, or document the loss.
- **P2.35** `app/lib/io/midi/midi_file.dart:236-284` — running status is not
  cleared on meta/sysex events (SMF requires it), and system-common statuses
  0xF1–0xF6 are misparsed as channel events. Clear running status on meta/sysex;
  handle 0xF1–0xF6 data lengths.
- **P2.36** `app/lib/io/midi/midi_file.dart:66` — time-signature denominator
  exponent unvalidated (`1 << bytes[1]` up to 2^127). Reject `bytes[1] > 15`.
- **P2.37** `app/lib/state/playback_state.dart:142` — `BigInt.toInt()` silently
  wraps for lengths ≥ 2^63. Clamp or throw when `isValidInt == false`.

### Audio / state / UI hygiene

- **P2.38** `app/lib/state/generation_state.dart:127-138` — `applyMixer` re-derives
  channels by list index, diverging from the generator's channel assignment
  (preferredChannel, drums-skip). Dead code today (no callers), but public: pass a
  voiceId→channel map from the generated sequence instead of reconstructing.
- **P2.39** `app/lib/state/practice_state.dart:121-132` — `planFor` is called
  outside the try; a zero-bar song with a configured loop throws uncaught and
  leaves state claiming a running session. Move `planFor` inside the try and guard
  `LoopRange.clampedTo` against `bars <= 0`.
- **P2.40** `app/lib/audio/audio_engine.dart:207-216` — poll-timer callback has no
  try/catch (a throwing `audioStatus()` repeats as an unhandled error every
  second) and can write state after dispose. Wrap the body in try/catch (cancel
  polling on error) and guard the state write with a disposed check.
- **P2.41** `app/lib/audio/soundbank_library.dart:59-81` — one broken symlink or
  unreadable file aborts the entire soundbank scan. Wrap the per-file body in
  try/catch and skip unstatable entries.
- **P2.42** `app/lib/audio/soundbank_library.dart:65-77` — filter is
  case-insensitive (`.SF2` passes) but name stripping is case-sensitive (`.SF2`
  kept in the display name). Strip case-insensitively.
- **P2.43** `app/lib/state/library_state.dart:409-426` — undo/redo mark the editor
  dirty even when returning to the saved state. Track the save point in the undo
  stack, or compare against the last-saved snapshot.
- **P2.44** `app/lib/state/library_state.dart:210-228` — partial iReal import:
  songs saved before a failure remain, but the scan provider is never invalidated.
  Invalidate in a `finally`, or report a partial result instead of throwing.
- **P2.45** `app/lib/audio/playhead.dart:49-57` — FP fuzz at barlines
  (`3.9999999` → "bar 1 beat 4.9999"). Round `totalBeats` to ~1e-6 before
  splitting into bar/beat.
- **P2.46** `app/lib/audio/sequence_builder.dart:161-173` — program change for
  muted voices is still emitted (comment claims they are left out entirely). Move
  the audibility check before the program event, or correct the comment.
- **P2.47** `app/lib/render/chart_layout.dart:197-204` — `barAt` falls back to the
  *last* bar for any unmatched x, including taps left of the first bar (left
  gutter). Only fall back when `x > lastBar.rect.right`; return null otherwise.
- **P2.48** `app/lib/render/chart_layout.dart:222-224` — `beatAt` can return
  `upper` (one past the bar). Clamp the result to `upper - 0.5` inside the method.
- **P2.49** `app/lib/render/chord_diagram_painter.dart:203-238` — `TextPainter`s
  are never disposed (sibling `chart_painter.dart` disposes all of its). Add
  `..dispose()` after each paint.
- **P2.50** `app/lib/render/chord_diagram_painter.dart:57-58,213-222` — base-fret
  labels for frets 10+ paint at negative x and are clipped. Widen the left margin
  based on the label width when `baseFret > 9`.
- **P2.51** `app/lib/render/chord_diagram_painter.dart:152,164` — dots/barres with
  relative fret > 5 silently vanish (the domain model allows up to 24). Constrain
  span ≤ `fretCount` in `ChordShape` validation or draw an overflow indicator.
- **P2.52** `app/lib/render/playback_cursor.dart:17,71` — `quartersPerBeat` is
  computed from the bar-0 meter only and has no callers. Derive per bar or remove
  the getter.
- **P2.53** `app/lib/render/chord_measurer.dart:24,55` — `clear()` is never
  called; the measurement cache grows unbounded. Wire it to a font-change
  listener or delete it and document why.
- **P2.54** `app/lib/ui/widgets/playback_panel.dart:73-80` and
  `app/lib/ui/widgets/playhead_readout.dart:154-159` — duration formatting can
  print "1:60" / "1:60.00". Round total seconds first, then split minutes/seconds
  with carry.
- **P2.55** `app/lib/ui/screens/playlists_screen.dart:147-151` — deleting a set is
  a single tap with no confirmation (song deletion confirms). Add the same
  confirmation dialog.
- **P2.56** `app/lib/ui/screens/playlists_screen.dart:182` — reorder keys include
  the index, so keys are unstable across reorder and all affected rows rebuild.
  Key by a stable per-entry identifier (or add an `id` to `PlaylistEntry`).
- **P2.57** `app/lib/ui/screens/library_screen.dart:155-214` — the search field
  doesn't reflect external filter resets ("Show all" clears the filter but not the
  text). Add `didUpdateWidget` syncing the `TextEditingController` (see
  `song_details_screen.dart`'s `_TextRow`).
- **P2.58** `app/lib/ui/screens/chart_editor_screen.dart:74-110` — `_moveTo` and
  `_step` clamp/decompose beats against the *old* caret bar's meter, so moving
  across a meter change can land the caret on a nonexistent beat. Compute
  beats-per-bar for the target bar; make `_step` resolve meters per bar crossed.
- **P2.59** `app/lib/ui/screens/practice_screen.dart:35-36` — loop defaults
  (bars 1–8) are not clamped to the actual form length; short forms display and
  hand the session an out-of-range loop. Clamp in `initState`/on song change, or
  have `_Loop` display `min(value, formBars)`.
- **P2.60** `app/lib/ui/screens/reading_mode_screen.dart:130-137` — paging down is
  unbounded; the user can scroll past the chart end forever. Cap `_scrollOffset`
  at `max(0, chartHeight - viewportHeight)` (expose content height from
  `ChartView`).

### Rust — synth / engine / host hygiene

- **P2.61** `rust/bandstand-synth/src/envelope.rs:173-180` — the `Delay` arm calls
  `enter_attack()` and then unconditionally clobbers `level` with 0.0, delaying an
  instant attack by one sample and returning a wrong level for that sample. Set
  level 0.0 *before* `enter_attack()`, or return early after it.
- **P2.62** `rust/bandstand-synth/src/filter.rs:75-77` — re-engaging after a
  bypass period uses stale filter state (click). Call `reset()` on the
  bypassed→active transition.
- **P2.63** `rust/bandstand-synth/src/effects/chorus.rs:83-99`,
  `rust/bandstand-synth/src/effects/reverb.rs:208-226` — `process` indexes
  `left[i]`/`right[i]`/`send[i]` without a length precondition (panics on
  mismatched slices from another crate). Document the equal-length precondition as
  `Voice::render` does, or assert up front.
- **P2.64** `rust/bandstand-synth/src/sf2/parse.rs:28-39` — file-open/map
  failures are misreported as `Truncated` with a confusing message, discarding the
  `io::Error`. Add an `Io` error variant wrapping `std::io::Error`.
- **P2.65** `rust/bandstand-sequencer/src/sequencer.rs:159-175` — the
  sounding-note table is one boolean per (channel, key); overlapping same-key
  notes miscount, so a wrap's `release_all` can skip a hanging note. Count notes
  per slot, or document same-key overlap as unsupported.
- **P2.66** `rust/bandstand-sequencer/src/event.rs:14,83-89` — zero-velocity
  NoteOn is documented as a note-off but ordered as a note-on. Return order 0 for
  `NoteOn { velocity: 0 }`.
- **P2.67** `rust/bandstand-sequencer/src/metronome.rs:67,70` — `click_track` can
  overflow `u32` on huge `bars * beats_per_bar` (panic in debug, wrap in release).
  Compute in `u64` or validate/saturate inputs.
- **P2.68** `rust/bandstand-transport/src/transport.rs:247-250` —
  `create_audio_side` reads the position snapshot three times and can mix fields
  from different publishes. Read `self.position()` once and use its fields.
- **P2.69** `rust/src/engine.rs:402-405` — during `open()`, the new task sender is
  stored only after the reply, while concurrent `post()` calls hit the
  disconnected old sender and are silently dropped. Clear `self.tasks` before
  sending `Command::Open` (or synchronize the swap).
- **P2.70** `rust/src/android.rs:83-89` — `is_initialised` is dead code whose doc
  claims it guards the FFI panic that still happens. Wire it into `audio_start`/
  `audio_devices` (return an error when false) or delete it and fix the comment.
- **P2.71** `rust/src/api/audio.rs:368` — pan maps value 0 to −64/63 ≈ −1.0159,
  below the clamped −1.0 range; the left half of the pot is coarser by one step.
  Use `/64.0` (or clamp) keeping 127 reachable.
- **P2.72** `rust/src/offline.rs:209,219` — WAV header fields silently overflow
  `u32` for renders > ~4 GiB or huge rates. Reject totals above `u32::MAX` (or
  write W64).
- **P2.73** `rust/src/engine.rs:361` — `.expect("the audio engine thread must
  start")` panics across the FFI on spawn failure. Return a `Result` (poisoned-
  engine error) instead.

### Tools

- **P2.74** `tools/corpus_import/lib/slicer.dart:166-172` — duplicate fingerprint
  keys on beat + relative pitch only (durations/dynamics collapse distinct
  phrases) and is recorded *before* constraint checks, misreporting later rejects
  as `duplicate`. Include duration (and optionally velocity); add to `seen` only
  after a phrase passes constraints.
- **P2.75** `tools/corpus_import/lib/slicer.dart:100,124-131` — dead `keptSoFar`
  parameter. Remove it and the call-site argument.
- **P2.76** `tools/corpus_import/lib/annotation.dart:86-95` — `tempoRange` header
  doesn't validate ordering (`200 100` accepted). Add the same `low >= high`
  rejection the `range:` header has.
- **P2.77** `tools/corpus_import/bin/corpus_import.dart:68-73` — `--merge` file
  read/codec errors escape uncaught after all slicing work. Wrap in the same
  try/catch pattern and exit 1 with a message.
- **P2.78** `tools/corpus_import/bin/corpus_import.dart:94-103` — `_merge`
  overwrites each harvested phrase's `range` with the existing corpus's range,
  mislabeling per-phrase metadata when takes used different ranges. Use
  `phrase.range`, or document the normalization.
- **P2.79** `tools/tiling_probe/bin/tiling_probe.dart:186-204` — `double.parse`/
  `arguments[++i]` crash with raw exceptions on bad CLI input. Use `tryParse` with
  a usage message; bounds-check `i + 1 < arguments.length`.
- **P2.80** `tools/tiling_probe/bin/tiling_probe.dart:140-144` — `_minutes` prints
  ":60". Round total seconds first, carry into minutes.
- **P2.81** `tools/tiling_probe/lib/render.dart:60` — `renderTiling` loops forever
  if `formBars <= 0`. Assert/guard `formBars > 0`.
- **P2.82** `tools/tiling_probe/lib/phrase.dart:97-98` — `lengthBars` divides by
  literal 4 despite a `beatsPerBar` parameter. Derive the divisor from the
  phrase's spans or store `beatsPerBar`.

---

## P3 — Test quality

**Assertions that can never fail:**

- **P3.1** `app/test/io/exporters/export_test.dart:281-289` — the "title and
  composer" test only asserts `contains('PDF')`. Assert the title/composer via the
  document metadata (`/Title` in the Info dictionary) or rename the test.
- **P3.2** `app/test/ui/library_screen_test.dart:109-132` — the sort test asserts
  identical order before/after switching to Tempo ('Ballad' sorts first both
  ways); Composer only asserts length. Use fixtures whose orders differ and assert
  the reordered list.
- **P3.3** `app/test/domain/generation/drum_generator_test.dart:95` —
  `throwsA(isA<Object>())` matches any throw. Use `throwsFormatException`.
- **P3.4** `rust/bandstand-audio-host/src/host.rs:554-558` — asserts the constants
  equal their own literals. Delete or test `choose_config` against a mock.

**Vacuous guards / skipped coverage:**

- **P3.5** `app/integration_test/memory_test.dart:72,162` — growth assertions are
  gated behind a 20 MB bank the suite rarely finds; on typical boxes the suite
  passes having measured nothing. Fail/skip loudly when the largest bank can't
  distinguish mapping from reading.
- **P3.6** `app/test/domain/generation/drum_generator_test.dart:201-221` — the
  downbeat-accent test passes if either filter selects nothing; the "waltz"
  test only asserts the input length echoed back. Assert non-emptiness and a
  meter-specific property.
- **P3.7** `app/test/domain/generation/bass/walking_bass_generator_test.dart:146-163`
  — `if (phrase.isEmpty) continue` skips the assertion. Assert `isNotEmpty` first.
- **P3.8** `app/test/domain/harmony/diagrams/chord_diagram_test.dart:205-217` —
  the m9 movable-shape test passes vacuously if the library loses all m9 shapes.
  Assert `shape, isNotNull` before the range check.
- **P3.9** `app/test/io/song_library_test.dart:251-262` — the stale-journal test
  never exercises the stale-drop branch (`saveSong` clears the journal outright).
  Arrange a journal that survives with an older `modifiedAt` and assert it is
  dropped.
- **P3.10** `app/test/io/song_library_test.dart:179-190` — "newest is always kept"
  has no assertion. Decode the newest backup and assert it is the latest take.
- **P3.11** `app/test/io/exporters/export_test.dart:134-151` — note-off tracking
  keys by pitch only across merged tracks. Key by `(channel, pitch)`.
- **P3.12** `app/test/io/exporters/export_test.dart:123-132` — "drums on the
  percussion channel" asserts *all* notes are on it (true only because the fixture
  is drums-only). Filter to the drum track or rename.
- **P3.13** `app/integration_test/synth_test.dart:71` — `throwsA(isNotNull)`
  passes for infrastructure errors too. Assert the specific error type/message.
- **P3.14** `app/integration_test/synth_test.dart:196-198` — drift comment
  promises "far tighter" than 20 ms but asserts the full 20 ms budget. Tighten
  (≈2 ms for a 10 s window) or reword the comment.
- **P3.15** `app/integration_test/synth_test.dart:75-76` — the MIDI writer output
  is only asserted non-empty. Parse it back through the real reader and assert the
  recovered events.
- **P3.16** `rust/bandstand-synth/tests/synth_test.rs:253-272` — the
  exclusive-class test renders ~5.4 s so drum voices end naturally; the assertion
  passes even without the cut. Render 1–2 blocks and assert the open-hat voice is
  gone/in fast release.
- **P3.17** `rust/tests/fluidsynth_ab_test.rs:519-526` — the onset comparison
  zips to the shorter list, dropping extra onsets. Iterate to the max length and
  assert missing counterparts explicitly.
- **P3.18** `app/test/io/importers/musicxml_import_test.dart:419-432` — the
  Latin-1 test asserts `contains('Sa')`, which passes even if `ë` was lossy-
  decoded to U+FFFD. Assert `contains('Saëns')`.
- **P3.19** `app/test/domain/generation/voicing/voicing_engine_test.dart:86-95` —
  only an exact 13-semitone gap is rejected; compound minor ninths (25 st) escape.
  Check `interval % 12 == 1 && interval > 12`.
- **P3.20** `app/test/domain/generation/post_processing_test.dart:36-42` — dead
  `onsets` map (keyed by identical durations anyway). Remove it.

**Misleading names/comments, weak fingerprints:**

- **P3.21** `app/test/domain/generation/bass/wbp_tiling_test.dart:163-167` — the
  comment claims a fresh-alternative check the code doesn't perform. Implement the
  check or correct the comment; align the enforced rule with P2.10.
- **P3.22** `app/test/domain/generation/bass/wbp_tiling_test.dart:392-402` — the
  "tempo changes the line" test only asserts determinism. Rename, or assert a real
  tempo-dependent difference.
- **P3.23** `app/test/domain/song/playlist_test.dart:236-242` — the "never
  touched" snapshot omits `barCount`/`pickupBeats`. Include all scalars or
  serialize via the real codec.
- **P3.24** `app/integration_test/generation_test.dart:247-249` — the determinism
  fingerprint ignores duration/velocity (a reroll that only alters velocities
  passes). Include both fields.
- **P3.25** `app/test/domain/domain_purity_test.dart:29-46` — the purity lint
  misses `export` statements. Add `export` variants of both regexes.

**Flaky timing assertions:**

- **P3.26** `app/test/domain/generation/{walking_bass_generator,comping_generator,song_generator}_test.dart`
  — single-stopwatch mean `< 100 ms` over 20 runs can fail on one scheduler
  hiccup (the file's own post-mortem says so). Use the existing `fastestMillis`
  (best-of-N) helper everywhere, or move benchmarks out of the unit suite.
- **P3.27** `app/test/io/importers/musicxml_suite_test.dart:163` and
  `app/test/render/render_benchmark_test.dart:90,120,154,193` — wall-clock
  budgets asserted as hard failures, including the 4 ms *target* where the
  documented hard limit is 8 ms. Gate behind a `--benchmark` flag, or assert the
  8 ms hard limit and report the target as informational.
- **P3.28** `app/integration_test/generation_test.dart:232-235` — asserts the
  100 ms target where the spec's hard limit is 300 ms. Assert `< 300` and report
  100 ms informationally.

**Test hygiene:**

- **P3.29** `app/test/io/song_library_test.dart:409` — unawaited
  `..ensureLayout()` cascade. `final target = SongLibrary(other); await
  target.ensureLayout();`
- **P3.30** `app/test/io/importers/ireal_import_test.dart:13-15` — dead `problems`
  fixture and `setUp`. Delete.
- **P3.31** `app/integration_test/soak_test.dart:155` — unvalidated
  `BANDSTAND_SOAK_CYCLE_SECONDS` can divide by zero. Validate `> 0` at the top of
  `main()`.
- **P3.32** `app/integration_test/memory_test.dart:58` — `residentBytes()!` force-
  unwrap where line 49 uses a null-check-and-skip. Use the same skip pattern.
- **P3.33** `rust/bandstand-transport/src/transport.rs:622-642` and
  `rust/bandstand-sequencer/tests/sequencer_test.rs` — add the two missing
  regression tests called out in P0.8 and P1.25 (loop continuity across blocks;
  wrap-at-nonzero-frame with a program change).

---

## Final verification checklist

After each batch of fixes:

```sh
cd app && flutter analyze           # must stay clean
cd rust && cargo clippy --workspace --all-targets   # must stay clean
cd rust && cargo test --workspace   # 72+ tests, all green
cd app && flutter test              # 844+ tests, all green
```

Batch order recommended: **P0** (8 items) → **P1.6/P1.1–P1.5** (state layer) →
**P1.7–P1.18** (import/export) → **P1.19–P1.30** (Rust) → **P2** in listed order →
**P3** (can be interleaved — each fixed test should be run against the pre-fix
code once to confirm it actually fails).
