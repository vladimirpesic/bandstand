import 'dart:io';

import 'package:bandstand/domain/generation/bass/bass_corpus_codec.dart';
import 'package:bandstand/domain/harmony/chord_type_database.dart';
import 'package:bandstand/domain/harmony/harmony_registry.dart';
import 'package:bandstand/domain/harmony/scale.dart';
import 'package:bandstand/io/midi/midi_file.dart';
import 'package:bandstand/io/midi/midi_writer.dart';
import 'package:corpus_import/annotation.dart';
import 'package:corpus_import/slicer.dart';
import 'package:test/test.dart';

const int ppq = 480;

/// A take of consecutive quarter notes, the way a walking line is played.
MidiFileData take(List<int> pitches) {
  final events = <MidiWriteEvent>[];
  for (final (index, pitch) in pitches.indexed) {
    final tick = index * ppq;
    events
      ..add(MidiWriteEvent.noteOn(tick, 0, pitch, 84))
      ..add(MidiWriteEvent.noteOff(tick + (ppq * 0.9).round(), 0, pitch));
  }
  return MidiFileReader.read(
    MidiFileWriter.write(
      ticksPerQuarter: ppq,
      tracks: <List<MidiWriteEvent>>[
        <MidiWriteEvent>[MidiWriteEvent.tempo(0, 140)],
        events,
      ],
    ),
  );
}

void main() {
  // Installed here rather than in setUpAll: a group body runs while the tests
  // are being collected, which is before any setUp has fired, and the fixtures
  // below parse chords as they are built.
  Harmony.install(
    chordTypes: ChordTypeDatabase.fromJson(
      File('../../app/assets/chord_types.json').readAsStringSync(),
    ),
    scales: ScaleLibrary.fromJson(
      File('../../app/assets/scales.json').readAsStringSync(),
    ),
  );

  group('the annotation format', () {
    test('reads headers and chords', () {
      final annotation = ChordAnnotation.parse('''
# A ii-V-I, twice.
name: my-take
tags: walking swing
tempoRange: 100 200
track: 1

Dm7 G7  Cmaj7 Cmaj7
Dm7 G7  Cmaj7 Cmaj7
''');
      expect(annotation.name, 'my-take');
      expect(annotation.tags, <String>{'walking', 'swing'});
      expect(annotation.tempoRange!.lowest, 100);
      expect(annotation.tempoRange!.highest, 200);
      expect(annotation.track, 1);
      expect(annotation.barCount, 8);
      expect(annotation.bars.first.format(), 'Dm7');
      expect(annotation.bars.last.format(), 'Cmaj7');
    });

    test('a comment on a chord line is stripped, not parsed', () {
      final annotation = ChordAnnotation.parse('name: t\nDm7 G7  # the ii-V\n');
      expect(annotation.barCount, 2);
    });

    test('a sharp in a chord is not a comment', () {
      // `#` after whitespace starts a comment; inside a token it is the
      // chord's sharp, or a sharp-side take would harvest as `F`.
      final annotation = ChordAnnotation.parse(
        'name: t\nF#7 C#m7  # two chords, then a comment\n',
      );
      expect(annotation.bars.map((chord) => chord.format()), <String>[
        'F#7',
        'C#m7',
      ]);
      expect(annotation.barCount, 2);
    });

    test('an unreadable chord names its line', () {
      expect(
        () => ChordAnnotation.parse('name: t\nDm7 G7\nH9 G7\n'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('line 3'), contains('H9')),
          ),
        ),
      );
    });

    test('an unknown header is refused rather than ignored', () {
      expect(
        () => ChordAnnotation.parse('name: t\nwobble: 3\nDm7\n'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('unknown header'),
          ),
        ),
      );
    });

    test('an annotation with no name, or no chords, is refused', () {
      expect(() => ChordAnnotation.parse('Dm7 G7\n'), throwsFormatException);
      expect(() => ChordAnnotation.parse('name: t\n'), throwsFormatException);
    });
  });

  group('slicing a take', () {
    // Four bars of ii-V-I-I, played as quarter notes.
    final midi = take(<int>[
      38, 41, 45, 48, //
      47, 45, 43, 41, //
      36, 40, 43, 45, //
      47, 45, 43, 40,
    ]);
    final annotation = ChordAnnotation.parse(
      'name: cadence\ntrack: 1\nDm7 G7 Cmaj7 Cmaj7\n',
    );
    final result = const CorpusSlicer().slice(midi, annotation);

    test('it harvests every window that satisfies §5', () {
      expect(result.corpus.isEmpty, isFalse);
      for (final phrase in result.corpus.phrases) {
        expect(phrase.startsOnRoot, isTrue, reason: phrase.name);
        expect(phrase.endsOnChordTone, isTrue, reason: phrase.name);
        expect(phrase.reachableRootCount, 12, reason: phrase.name);
      }
    });

    test('one take yields more than its bar count in phrases', () {
      // The point of harvesting every window: a player recording four bars
      // contributes far more than four phrases.
      expect(result.corpus.length, greaterThan(1));
    });

    test('the notes really come from the take', () {
      final fourBar = result.corpus.phrases
          .where((phrase) => phrase.lengthBars == 4)
          .toList();
      expect(fourBar, hasLength(1));
      expect(fourBar.single.notes.map((note) => note.pitch), <int>[
        38,
        41,
        45,
        48,
        47,
        45,
        43,
        41,
        36,
        40,
        43,
        45,
        47,
        45,
        43,
        40,
      ]);
      expect(fourBar.single.notes.first.beat, 0);
      expect(fourBar.single.notes.last.beat, 15);
    });

    test('a slice is positioned from its own start, not the take', () {
      // Bars 3–4 of the take, which begin eight beats in.
      final third = result.corpus.phrases.firstWhere(
        (phrase) => phrase.name.endsWith(' 3+2'),
      );
      expect(third.notes.first.beat, 0);
      expect(third.notes.first.pitch, 36);
      expect(third.notes.last.beat, 7);
    });

    test('a window that ends off the chord is rejected, and says so', () {
      // Bar 3 alone is C E G A over Cmaj7: A is not a chord tone, so the bar
      // is a fragment of a longer line rather than a phrase.
      expect(
        result.rejections.any(
          (rejection) =>
              rejection.startBar == 2 &&
              rejection.lengthBars == 1 &&
              rejection.reason == RejectionReason.doesNotEndOnChordTone,
        ),
        isTrue,
      );
    });

    test('velocity and duration survive the round trip', () {
      final phrase = result.corpus.phrases.first;
      expect(phrase.notes.first.velocity, 84);
      expect(phrase.notes.first.durationBeats, closeTo(0.9, 0.01));
    });

    test('what it rejected is reported, with a reason', () {
      expect(result.rejections, isNotEmpty);
      // Bar 2 opens on B over G7 — a continuation, not a phrase start.
      expect(
        result.rejections.any(
          (rejection) => rejection.reason == RejectionReason.doesNotStartOnRoot,
        ),
        isTrue,
      );
      expect(
        result.rejectionCounts.values.reduce((a, b) => a + b),
        result.rejections.length,
      );
    });

    test('the same lick over the same changes is harvested once', () {
      // Two identical bars of Dm7 back to back.
      final repeated = const CorpusSlicer().slice(
        take(<int>[38, 41, 45, 48, 38, 41, 45, 48]),
        ChordAnnotation.parse('name: repeat\ntrack: 1\nDm7 Dm7\n'),
      );
      expect(
        repeated.rejections.any(
          (rejection) => rejection.reason == RejectionReason.duplicate,
        ),
        isTrue,
      );
      final oneBar = repeated.corpus.phrases
          .where((phrase) => phrase.lengthBars == 1)
          .length;
      expect(oneBar, 1);
    });

    test('a bar of rest is reported as empty, not as a phrase', () {
      final sparse = const CorpusSlicer().slice(
        take(<int>[38, 41, 45, 48]),
        ChordAnnotation.parse('name: rest\ntrack: 1\nDm7 G7\n'),
      );
      expect(
        sparse.rejections.any(
          (rejection) => rejection.reason == RejectionReason.empty,
        ),
        isTrue,
      );
    });

    test('a phrase too wide for the instrument is rejected, not clipped', () {
      final wide = const CorpusSlicer().slice(
        take(<int>[36, 48, 60, 72]),
        ChordAnnotation.parse('name: wide\ntrack: 1\nCmaj7\n'),
      );
      expect(wide.corpus.isEmpty, isTrue);
      expect(
        wide.rejections.single.reason,
        RejectionReason.cannotReachEveryRoot,
      );
    });
  });

  group('what it writes is what the app reads', () {
    test('the output round-trips through the app codec', () {
      final result = const CorpusSlicer().slice(
        take(<int>[38, 41, 45, 48, 47, 45, 43, 41]),
        ChordAnnotation.parse(
          'name: ii-V\ntags: walking\ntempoRange: 90 240\ntrack: 1\nDm7 G7\n',
        ),
      );
      final encoded = BassCorpusCodec.encode(result.corpus);
      final again = BassCorpusCodec.decode(encoded);

      expect(again.length, result.corpus.length);
      expect(again.name, 'ii-V');
      for (var i = 0; i < again.length; i++) {
        expect(again.phrases[i].name, result.corpus.phrases[i].name);
        expect(
          again.phrases[i].rootProfile,
          result.corpus.phrases[i].rootProfile,
        );
        expect(again.phrases[i].tags, <String>{'walking'});
        expect(again.phrases[i].tempoRange.lowest, 90);
      }
    });
  });

  group('reading the take', () {
    test('merging every track is the default', () {
      final annotation = ChordAnnotation.parse('name: t\nDm7\n');
      expect(annotation.track, isNull);
      final result = const CorpusSlicer().slice(
        take(<int>[38, 41, 45, 48]),
        annotation,
      );
      expect(result.corpus.isEmpty, isFalse);
    });

    test('asking for a track the file does not have is an error', () {
      expect(
        () => const CorpusSlicer().slice(
          take(<int>[38, 41, 45, 48]),
          ChordAnnotation.parse('name: t\ntrack: 9\nDm7\n'),
        ),
        throwsArgumentError,
      );
    });
  });

  group('the annotation format rejects a bad tempo range', () {
    // `TempoRange`'s own constructor asserts this with an `ArgumentError`,
    // which used to escape `parse` and crash the CLI with a stack trace. The
    // parser's contract is a `FormatException` naming the line.
    test(
      'a reversed tempoRange is a FormatException, not an ArgumentError',
      () {
        expect(
          () => ChordAnnotation.parse('name: t\ntempoRange: 200 100\nDm7\n'),
          throwsFormatException,
        );
      },
    );

    test('a zero or negative tempoRange is refused', () {
      expect(
        () => ChordAnnotation.parse('name: t\ntempoRange: 0 100\nDm7\n'),
        throwsFormatException,
      );
      expect(
        () => ChordAnnotation.parse('name: t\ntempoRange: -10 100\nDm7\n'),
        throwsFormatException,
      );
    });

    test('an equal low and high is allowed — a take played at one tempo', () {
      final annotation = ChordAnnotation.parse(
        'name: t\ntempoRange: 120 120\nDm7\n',
      );
      expect(annotation.tempoRange!.lowest, 120);
      expect(annotation.tempoRange!.highest, 120);
    });
  });

  group('the duplicate fingerprint', () {
    // Two windows with the same onsets and the same intervals but different
    // note lengths are a walking line and a series of held roots. Keying the
    // fingerprint on beat and pitch alone collapsed them into one phrase.
    test('durations are part of a slice identity', () {
      // Bar 1 staccato, bar 3 the same notes legato, over the same changes.
      // The two windows differ only in how long the notes are held.
      const line = <int>[38, 41, 45, 48, 38, 41, 45, 48];
      final events = <MidiWriteEvent>[];
      for (final (index, pitch) in line.indexed) {
        final tick = index * ppq;
        final gate = index < 4 ? 120 : 440;
        events
          ..add(MidiWriteEvent.noteOn(tick, 0, pitch, 84))
          ..add(MidiWriteEvent.noteOff(tick + gate, 0, pitch));
      }
      final midi = MidiFileReader.read(
        MidiFileWriter.write(
          ticksPerQuarter: ppq,
          tracks: <List<MidiWriteEvent>>[
            <MidiWriteEvent>[MidiWriteEvent.tempo(0, 140)],
            events,
          ],
        ),
      );
      final result = const CorpusSlicer().slice(
        midi,
        ChordAnnotation.parse('name: t\ntrack: 1\nDm7 Dm7 Dm7 Dm7\n'),
      );
      final oneBar = result.corpus.phrases
          .where((phrase) => phrase.lengthBars == 1)
          .toList();
      // Bars 1 and 3 carry the same pitches at the same beats; only the
      // durations differ. Both must survive.
      expect(oneBar.length, greaterThanOrEqualTo(2));
      final gates = oneBar
          .map((phrase) => phrase.notes.first.durationBeats)
          .toSet();
      expect(
        gates.length,
        greaterThan(1),
        reason: 'the staccato and legato bars collapsed into one phrase',
      );
    });

    test('a rejected window does not poison the duplicate set', () {
      // Bar 1 opens off the root, so it is rejected for that reason. Bar 3
      // carries identical notes and is rejected for the same reason — it must
      // not be reported as a `duplicate` of a phrase that was never kept.
      final midi = take(<int>[
        41, 38, 45, 48, //
        36, 40, 43, 45, //
        41, 38, 45, 48, //
        47, 45, 43, 40,
      ]);
      final result = const CorpusSlicer().slice(
        midi,
        ChordAnnotation.parse('name: t\ntrack: 1\nDm7 Cmaj7 Dm7 Cmaj7\n'),
      );
      final duplicatesOfRejects = result.rejections.where(
        (rejection) =>
            rejection.lengthBars == 1 &&
            rejection.startBar == 2 &&
            rejection.reason == RejectionReason.duplicate,
      );
      expect(
        duplicatesOfRejects,
        isEmpty,
        reason: 'bar 3 was rejected before it could be judged on its merits',
      );
    });
  });
}
