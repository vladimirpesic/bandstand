import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:bandstand/domain/song/written_part.dart';
import 'package:flutter_test/flutter_test.dart';

/// `docs/rules/written-parts.md` §1.
void main() {
  WrittenNote note(int bar, double beat, int key, {double duration = 1}) =>
      WrittenNote(bar: bar, beat: beat, key: key, durationBeats: duration);

  group('a written note', () {
    test('refuses a position that is not one', () {
      expect(() => note(-1, 0, 60), throwsArgumentError);
      expect(() => note(0, -1, 60), throwsArgumentError);
      expect(() => note(0, double.nan, 60), throwsArgumentError);
      expect(() => note(0, 0, 60, duration: 0), throwsArgumentError);
      expect(() => note(0, 0, 60, duration: -1), throwsArgumentError);
      expect(() => note(0, 0, 128), throwsArgumentError);
      expect(() => note(0, 0, -1), throwsArgumentError);
      expect(
        () => WrittenNote(
          bar: 0,
          beat: 0,
          key: 60,
          durationBeats: 1,
          velocity: 0,
        ),
        throwsArgumentError,
      );
    });

    test('sorts by bar, then beat, then pitch', () {
      final sorted = <WrittenNote>[
        note(1, 0, 60),
        note(0, 2, 67),
        note(0, 2, 60),
        note(0, 0, 72),
      ]..sort();
      expect(sorted.map((n) => '${n.bar}:${n.beat}:${n.key}'), <String>[
        '0:0.0:72',
        '0:2.0:60',
        '0:2.0:67',
        '1:0.0:60',
      ]);
    });

    test('may run past the end of its bar', () {
      // A note tied over the bar line is one note. Refusing it would force the
      // importer to cut it, which is the thing §2 says not to do.
      expect(note(0, 3.5, 60, duration: 4.5).durationBeats, 4.5);
    });
  });

  group('a written part', () {
    test('needs an id, a name and a real program', () {
      expect(
        () => WrittenPart(id: ' ', displayName: 'Melody', notes: const []),
        throwsArgumentError,
      );
      expect(
        () => WrittenPart(id: 'm', displayName: '', notes: const []),
        throwsArgumentError,
      );
      expect(
        () => WrittenPart(
          id: 'm',
          displayName: 'Melody',
          notes: const [],
          program: 128,
        ),
        throwsArgumentError,
      );
    });

    test('is muted by default', () {
      // §4: a singer with the melody covered does not want a synthesised one
      // doubling them.
      final part = WrittenPart(
        id: 'm',
        displayName: 'Melody',
        notes: <WrittenNote>[note(0, 0, 60)],
      );
      expect(part.muted, isTrue);
      expect(part.copyWith(muted: false).muted, isFalse);
    });

    test('sorts its notes however they arrive', () {
      final part = WrittenPart(
        id: 'm',
        displayName: 'Melody',
        notes: <WrittenNote>[note(3, 0, 60), note(0, 1, 62), note(0, 0, 64)],
      );
      expect(part.notes.map((n) => n.bar), <int>[0, 0, 3]);
      expect(part.notes.first.key, 64);
      expect(part.barCount, 4);
    });

    test('barCount counts start bars, not sustained ones', () {
      // A note tied over the bar line is one note (§2): it starts in bar 0
      // even though it sounds into bar 2, and barCount is a count of written
      // bars. Sounded length is lengthInBeats' job.
      final part = WrittenPart(
        id: 'm',
        displayName: 'Melody',
        notes: <WrittenNote>[
          WrittenNote(bar: 0, beat: 2, key: 60, durationBeats: 8),
        ],
      );
      expect(part.barCount, 1);
      expect(part.bars, <int>[0]);
    });

    test('buckets its notes by bar', () {
      final part = WrittenPart(
        id: 'm',
        displayName: 'Melody',
        notes: <WrittenNote>[note(0, 0, 60), note(0, 2, 62), note(2, 0, 64)],
      );
      final byBar = part.notesByBar;
      expect(byBar.keys.toSet(), <int>{0, 2});
      expect(byBar[0]!.length, 2);
      expect(byBar[1], isNull);
      expect(part.notesInBar(0).length, 2);
      expect(part.notesInBar(1), isEmpty);
    });

    test('knows its range', () {
      expect(
        WrittenPart(id: 'm', displayName: 'M', notes: const []).range,
        isNull,
      );
      final part = WrittenPart(
        id: 'm',
        displayName: 'M',
        notes: <WrittenNote>[note(0, 0, 72), note(1, 0, 55), note(2, 0, 64)],
      );
      expect(part.range, (55, 72));
    });

    test('measures its length through the meter of each bar', () {
      // A part that starts in 4/4 and ends in 3/4 is not four beats a bar.
      final part = WrittenPart(
        id: 'm',
        displayName: 'M',
        notes: <WrittenNote>[note(0, 0, 60), note(1, 0, 62)],
      );
      expect(
        part.lengthInBeats(
          (bar) => bar == 0 ? TimeSignature.fourFour : TimeSignature(3, 4),
        ),
        7,
      );
    });

    test('is equal by value, notes included', () {
      WrittenPart make(int key) => WrittenPart(
        id: 'm',
        displayName: 'M',
        notes: <WrittenNote>[note(0, 0, key)],
      );
      expect(make(60), make(60));
      expect(make(60).hashCode, make(60).hashCode);
      expect(make(60), isNot(make(61)));
    });
  });
}
