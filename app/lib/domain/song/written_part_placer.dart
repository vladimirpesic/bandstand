import '../phrase/note_event.dart';
import '../phrase/phrase.dart';
import '../song/rhythm.dart';
import '../song/song_chord_sequence.dart';
import '../song/written_part.dart';

/// Places a written part onto the playback timeline (§9).
///
/// The part is written on the page — bar 12, beat 3 — and playback is a
/// flattened sequence in which bar 12 may be played three times. Placing it is
/// therefore not a shift but a *fan-out*: walk the flattened bars, and wherever
/// one comes from a written bar the part has notes in, emit them there.
///
/// That is what makes a repeat play the melody again, and it costs nothing
/// extra: §4.5 already insists every flattened bar knows its `sourceBar`, for
/// the cursor.
///
/// Rules: `docs/rules/written-parts.md` §2.
abstract final class WrittenPartPlacer {
  /// The voice a written part plays as.
  ///
  /// One voice per part, identified by the part, so the mixer remembers a level
  /// for "Melody" separately from one for "Tenor 1", and so does the MIDI
  /// export's track name.
  static RhythmVoice voiceFor(WrittenPart part) => RhythmVoice(
    id: 'written:${part.id}',
    displayName: part.displayName,
    isDrums: false,
  );

  /// [part] laid out across [sequence], in **quarter notes** from the start of
  /// playback.
  ///
  /// Quarters, because this phrase joins the same accumulated song timeline
  /// that [SongGenerator] converts every generated part onto, and that timeline
  /// counts in quarters. A written part is written on the page in the bar's own
  /// beats, so the conversion happens here.
  ///
  /// Returns an empty phrase when the part has no notes in any bar the sequence
  /// plays — a part written for a section the arrangement leaves out.
  static Phrase place(WrittenPart part, SongChordSequence sequence) {
    final byBar = part.notesByBar;
    if (byBar.isEmpty) {
      return Phrase.empty(channel: 0);
    }

    final notes = <NoteEvent>[];
    for (final bar in sequence.bars) {
      final written = byBar[bar.sourceBar];
      if (written == null) {
        continue;
      }
      // A written note's beat and duration are in the bar's own beats — an
      // eighth in 6/8 — and the timeline is in quarters, so both convert with
      // the bar's own beat length. Each bar converts with its own: a written
      // part fans out across the whole arrangement and the bars it lands in
      // need not share a meter.
      final beatLength = bar.timeSignature.beatDurationInQuarters;
      for (final note in written) {
        notes.add(
          NoteEvent(
            pitch: note.key,
            positionInBeats: bar.startQuarters + note.beat * beatLength,
            beatDuration: note.durationBeats * beatLength,
            velocity: note.velocity,
          ),
        );
      }
    }
    // Channel 0 is a placeholder: `SongGenerator` assigns the real one from
    // the same allocator every other voice goes through, so a written part
    // cannot collide with the bass.
    return Phrase(channel: 0, notes: notes);
  }
}
