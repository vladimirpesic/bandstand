import 'package:bandstand/domain/harmony/time_signature.dart';
import 'package:bandstand/domain/phrase/float_range.dart';
import 'package:bandstand/domain/phrase/note_event.dart';
import 'package:bandstand/domain/phrase/phrase.dart';
import 'package:flutter_test/flutter_test.dart';

NoteEvent note(double at, int pitch, {double length = 1, int velocity = 80}) =>
    NoteEvent(
      pitch: pitch,
      positionInBeats: at,
      beatDuration: length,
      velocity: velocity,
    );

void main() {
  group('FloatRange', () {
    test('rejects a range that is not one', () {
      expect(() => FloatRange(4, 0), throwsArgumentError);
      expect(() => FloatRange(double.nan, 1), throwsArgumentError);
      expect(() => FloatRange(0, double.infinity), throwsArgumentError);
    });

    test('is half open, so a bar boundary belongs to one bar only', () {
      final bar = FloatRange(0, 4);
      expect(bar.contains(0), isTrue);
      expect(bar.contains(3.999), isTrue);
      expect(bar.contains(4), isFalse);
      expect(bar.length, 4);
    });

    test('knows when two ranges touch', () {
      expect(FloatRange(0, 4).overlaps(FloatRange(3, 8)), isTrue);
      expect(FloatRange(0, 4).overlaps(FloatRange(4, 8)), isFalse);
      expect(FloatRange(0, 4).intersect(FloatRange(2, 8)), FloatRange(2, 4));
      expect(FloatRange(0, 4).intersect(FloatRange(8, 12)).isEmpty, isTrue);
    });

    test('shifts without changing length', () {
      expect(FloatRange(0, 4).shifted(8), FloatRange(8, 12));
      expect(FloatRange(0, 4).shifted(-2).length, 4);
    });
  });

  group('NoteEvent', () {
    test('rejects a position that is not a place', () {
      expect(
        () => NoteEvent(pitch: 60, positionInBeats: -1),
        throwsArgumentError,
      );
      expect(
        () => NoteEvent(pitch: 60, positionInBeats: double.nan),
        throwsArgumentError,
      );
    });

    test('knows when it is sounding', () {
      final n = note(2, 60, length: 2);
      expect(n.endInBeats, 4);
      expect(n.soundsAt(2), isTrue);
      expect(n.soundsAt(3.99), isTrue);
      expect(n.soundsAt(4), isFalse);
      expect(n.soundsAt(1.99), isFalse);
    });

    test('shifting never moves a note before the phrase', () {
      expect(note(1, 60).shifted(-4).positionInBeats, 0);
      expect(note(1, 60).shifted(3).positionInBeats, 4);
    });

    test('transposing clamps at the ends of the keyboard', () {
      expect(note(0, 2).transposedBy(-12).pitch, 0);
      expect(note(0, 125).transposedBy(12).pitch, 127);
    });

    test('tags are carried and can be read back', () {
      final tagged = note(0, 60).tagged('fill', true).tagged('target', 62);
      expect(tagged.hasTag('fill'), isTrue);
      expect(tagged.clientProperties['target'], 62);
      expect(note(0, 60).hasTag('fill'), isFalse);
      // Tags are not part of identity: two notes in the same place with
      // different working notes on them are the same note.
      expect(tagged, note(0, 60));
    });

    test('sorts by position, then by pitch', () {
      final sorted = <NoteEvent>[note(2, 60), note(0, 64), note(0, 60)]..sort();
      expect(
        sorted.map((n) => '${n.positionInBeats}:${n.pitch}').toList(),
        <String>['0.0:60', '0.0:64', '2.0:60'],
      );
    });
  });

  group('Phrase', () {
    test('rejects a channel that is not one', () {
      expect(() => Phrase(channel: -1), throwsArgumentError);
      expect(() => Phrase(channel: 16), throwsArgumentError);
    });

    test('keeps its notes sorted whatever order they arrive in', () {
      final phrase = Phrase(
        channel: 0,
        notes: <NoteEvent>[note(3, 60), note(0, 62), note(1, 64)],
      );
      expect(phrase.notes.map((n) => n.positionInBeats).toList(), <double>[
        0,
        1,
        3,
      ]);
    });

    test('reports the span its notes occupy', () {
      final phrase = Phrase(
        channel: 0,
        notes: <NoteEvent>[note(1, 60, length: 2), note(0, 62, length: 0.5)],
      );
      expect(phrase.startBeat, 0);
      expect(phrase.endBeat, 3);
      expect(phrase.extent, FloatRange(0, 3));
      expect(Phrase.empty(channel: 0).extent, FloatRange(0, 0));
    });

    test('transposing moves pitched notes', () {
      final phrase = Phrase(channel: 0, notes: <NoteEvent>[note(0, 60)]);
      expect(phrase.transposed(2).notes.single.pitch, 62);
      expect(phrase.transposed(0), same(phrase));
    });

    test('transposing a drum phrase does nothing at all', () {
      // A drum "pitch" is an instrument: moving it turns a snare into a tom.
      final kit = Phrase(
        channel: 9,
        isDrums: true,
        notes: <NoteEvent>[note(0, 38)],
      );
      expect(kit.transposed(5), same(kit));
      expect(kit.transposed(5).notes.single.pitch, 38);
    });

    test('shifting moves every note', () {
      final phrase = Phrase(
        channel: 0,
        notes: <NoteEvent>[note(0, 60), note(2, 62)],
      );
      expect(
        phrase.shifted(4).notes.map((n) => n.positionInBeats).toList(),
        <double>[4, 6],
      );
      expect(phrase.shifted(0), same(phrase));
    });

    test('processed filters and maps in one pass', () {
      final phrase = Phrase(
        channel: 0,
        notes: <NoteEvent>[
          note(0, 60, velocity: 40),
          note(1, 62, velocity: 90),
        ],
      );
      final loud = phrase.processed(keep: (n) => n.velocity > 50);
      expect(loud.length, 1);
      expect(loud.notes.single.pitch, 62);

      final quieter = phrase.processed(
        map: (n) => n.copyWith(velocity: n.velocity ~/ 2),
      );
      expect(quieter.notes.map((n) => n.velocity).toList(), <int>[20, 45]);
    });

    test('slicing takes the notes that start inside the range', () {
      final phrase = Phrase(
        channel: 0,
        notes: <NoteEvent>[note(0, 60), note(2, 62), note(4, 64)],
      );
      final slice = phrase.sliced(FloatRange(1, 4));
      expect(slice.notes.map((n) => n.pitch).toList(), <int>[62]);
    });

    test('slicing can cut a note that runs past the end', () {
      final phrase = Phrase(
        channel: 0,
        notes: <NoteEvent>[note(2, 60, length: 8)],
      );
      expect(phrase.sliced(FloatRange(0, 4)).notes.single.beatDuration, 8);
      expect(
        phrase
            .sliced(FloatRange(0, 4), cutNotes: true)
            .notes
            .single
            .beatDuration,
        2,
      );
    });

    test('notesAt finds what is sounding', () {
      final phrase = Phrase(
        channel: 0,
        notes: <NoteEvent>[note(0, 60, length: 4), note(2, 64, length: 1)],
      );
      expect(phrase.notesAt(0).map((n) => n.pitch), <int>[60]);
      expect(phrase.notesAt(2).map((n) => n.pitch), <int>[60, 64]);
      expect(phrase.notesAt(3.5).map((n) => n.pitch), <int>[60]);
      expect(phrase.notesAt(4), isEmpty);
    });

    test('reports its range of pitches', () {
      final phrase = Phrase(
        channel: 0,
        notes: <NoteEvent>[note(0, 40), note(1, 70), note(2, 55)],
      );
      expect(phrase.lowestPitch, 40);
      expect(phrase.highestPitch, 70);
      expect(Phrase.empty(channel: 0).lowestPitch, isNull);
    });

    test('merging keeps this phrase channel and sorts the result', () {
      final a = Phrase(channel: 0, notes: <NoteEvent>[note(0, 60)]);
      final b = Phrase(channel: 5, notes: <NoteEvent>[note(1, 62)]);
      final merged = a.merged(b);
      expect(merged.channel, 0);
      expect(merged.notes.map((n) => n.pitch).toList(), <int>[60, 62]);
    });

    test('every operation leaves the original alone', () {
      final phrase = Phrase(channel: 0, notes: <NoteEvent>[note(0, 60)]);
      phrase
        ..transposed(5)
        ..shifted(4)
        ..withNote(note(8, 70))
        ..sliced(FloatRange(0, 1));
      expect(phrase.notes, hasLength(1));
      expect(phrase.notes.single.pitch, 60);
    });
  });

  group('SizedPhrase', () {
    SizedPhrase bar({Iterable<NoteEvent> notes = const <NoteEvent>[]}) =>
        SizedPhrase(
          channel: 0,
          beatRange: FloatRange(0, 4),
          timeSignature: TimeSignature.fourFour,
          notes: notes,
        );

    test('drops notes written outside its own span', () {
      // A generator that writes past the end of its span has made a mistake,
      // and carrying it forward turns one bug into an overlap later.
      final phrase = bar(
        notes: <NoteEvent>[note(0, 60), note(4, 62), note(9, 64)],
      );
      expect(phrase.notes, hasLength(1));
      expect(phrase.notes.single.pitch, 60);
    });

    test('knows how many bars it covers', () {
      expect(bar().barCount, 1);
      expect(
        SizedPhrase(
          channel: 0,
          beatRange: FloatRange(0, 16),
          timeSignature: TimeSignature.fourFour,
        ).barCount,
        4,
      );
      expect(
        SizedPhrase(
          channel: 0,
          beatRange: FloatRange(0, 6),
          timeSignature: TimeSignature.threeFour,
        ).barCount,
        2,
      );
    });

    test('shifting moves the span with the notes', () {
      // Moving only the notes would push them outside the range, and the
      // constructor drops notes outside the range — so the phrase would
      // silently empty itself. This is the bug that lost every song part after
      // the first.
      final moved = bar(notes: <NoteEvent>[note(1, 60)]).shifted(64);
      expect(moved.beatRange, FloatRange(64, 68));
      expect(moved.notes, hasLength(1));
      expect(moved.notes.single.positionInBeats, 65);
    });

    test('moving takes the notes and the span together', () {
      final moved = bar(notes: <NoteEvent>[note(1, 60)]).movedTo(8);
      expect(moved.beatRange, FloatRange(8, 12));
      expect(moved.notes.single.positionInBeats, 9);
    });

    test('moving before the start of the song is refused, not clamped', () {
      // NoteEvent.shifted clamps negative positions onto beat 0: shifting a
      // sized phrase backwards would pile distinct notes onto one onset
      // instead of dropping them, so the move is rejected outright.
      final phrase = bar(notes: <NoteEvent>[note(0.5, 60), note(1, 62)]);
      expect(() => phrase.shifted(-1), throwsArgumentError);
      expect(() => phrase.movedTo(-0.5), throwsArgumentError);
      expect(phrase.movedTo(0).notes, hasLength(2));
    });

    test('processing keeps it sized', () {
      final processed = bar(notes: <NoteEvent>[note(0, 60), note(1, 62)])
          .processed(keep: (n) => n.pitch == 60);
      expect(processed, isA<SizedPhrase>());
      expect(processed.beatRange, FloatRange(0, 4));
    });

    test('withNote, withNotes, merged and onChannel keep it sized', () {
      // L-S1: the four used to come from `Phrase` and quietly returned a
      // plain phrase, dropping `beatRange` and the protection it carries.
      final phrase = bar(notes: <NoteEvent>[note(0, 60)]);

      final withOne = phrase.withNote(note(1, 62));
      expect(withOne, isA<SizedPhrase>());
      expect(withOne.beatRange, FloatRange(0, 4));
      expect(withOne.timeSignature, TimeSignature.fourFour);
      expect(withOne.notes, hasLength(2));

      final withMany = phrase.withNotes(<NoteEvent>[note(2, 64)]);
      expect(withMany, isA<SizedPhrase>());
      expect(withMany.beatRange, FloatRange(0, 4));
      expect(withMany.notes, hasLength(2));

      final merged = phrase.merged(
        Phrase(channel: 0, notes: <NoteEvent>[note(3, 65)]),
      );
      expect(merged, isA<SizedPhrase>());
      expect(merged.beatRange, FloatRange(0, 4));
      expect(merged.notes, hasLength(2));

      final rechanneled = phrase.onChannel(5);
      expect(rechanneled, isA<SizedPhrase>());
      expect(rechanneled.channel, 5);
      expect(rechanneled.beatRange, FloatRange(0, 4));
      expect(rechanneled.timeSignature, TimeSignature.fourFour);

      // The protection still bites: a note added past the span is dropped,
      // as the constructor does everywhere else.
      expect(phrase.withNote(note(9, 72)).notes, hasLength(1));
    });
  });
}
