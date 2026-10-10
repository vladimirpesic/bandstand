import 'package:bandstand/domain/harmony/natural.dart';
import 'package:bandstand/domain/harmony/pitch_spelling.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('construction', () {
    test('rejects more than a double accidental', () {
      expect(() => PitchSpelling(Natural.c, 3), throwsArgumentError);
      expect(() => PitchSpelling(Natural.c, -3), throwsArgumentError);
      expect(PitchSpelling(Natural.c, 2).toString(), 'C##');
      expect(PitchSpelling(Natural.c, -2).toString(), 'Cbb');
    });
  });

  group('parsing', () {
    test('reads the ordinary forms', () {
      expect(PitchSpelling.parse('C'), PitchSpelling(Natural.c));
      expect(PitchSpelling.parse('Bb'), PitchSpelling(Natural.b, -1));
      expect(PitchSpelling.parse('F#'), PitchSpelling(Natural.f, 1));
      expect(PitchSpelling.parse('Ebb'), PitchSpelling(Natural.e, -2));
      expect(PitchSpelling.parse('G##'), PitchSpelling(Natural.g, 2));
      expect(PitchSpelling.parse('Gx'), PitchSpelling(Natural.g, 2));
      expect(PitchSpelling.parse('  A  '), PitchSpelling(Natural.a));
      expect(PitchSpelling.parse('e'), PitchSpelling(Natural.e));
    });

    test('reads typographic accidentals', () {
      expect(PitchSpelling.parse('B♭'), PitchSpelling(Natural.b, -1));
      expect(PitchSpelling.parse('F♯'), PitchSpelling(Natural.f, 1));
    });

    test('refuses anything else', () {
      for (final text in <String>['', 'H', 'C-', 'Cbbb', '#', 'C#b#b#', '7']) {
        expect(PitchSpelling.tryParse(text), isNull, reason: text);
      }
      expect(() => PitchSpelling.parse('H'), throwsFormatException);
    });

    test('round-trips through toString', () {
      for (final natural in Natural.values) {
        for (var alteration = -2; alteration <= 2; alteration++) {
          final spelling = PitchSpelling(natural, alteration);
          expect(PitchSpelling.parse(spelling.toString()), spelling);
        }
      }
    });
  });

  group('pitch classes', () {
    test('are computed with accidentals and wrap', () {
      expect(PitchSpelling.parse('C').pitchClass, 0);
      expect(PitchSpelling.parse('B#').pitchClass, 0);
      expect(PitchSpelling.parse('Cb').pitchClass, 11);
      expect(PitchSpelling.parse('Fb').pitchClass, 4);
      expect(PitchSpelling.parse('E#').pitchClass, 5);
      expect(PitchSpelling.parse('Cbb').pitchClass, 10);
    });

    test('enharmonic is not equal', () {
      final fSharp = PitchSpelling.parse('F#');
      final gFlat = PitchSpelling.parse('Gb');
      expect(fSharp.isEnharmonicWith(gFlat), isTrue);
      expect(fSharp, isNot(gFlat));
      expect(fSharp == gFlat, isFalse);
    });
  });

  group('simplestFor', () {
    test('leans flat, as the jazz repertoire does', () {
      const expected = <String>[
        'C', 'Db', 'D', 'Eb', 'E', 'F', 'Gb', 'G', 'Ab', 'A', 'Bb', 'B', //
      ];
      for (var pc = 0; pc < 12; pc++) {
        expect(PitchSpelling.simplestFor(pc).toString(), expected[pc]);
      }
    });

    test('leans sharp when asked', () {
      const expected = <String>[
        'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B', //
      ];
      for (var pc = 0; pc < 12; pc++) {
        expect(
          PitchSpelling.simplestFor(pc, preferSharps: true).toString(),
          expected[pc],
        );
      }
    });

    test(
      'never needs a double accidental, and handles values out of range',
      () {
        for (var pc = -24; pc < 36; pc++) {
          for (final sharps in <bool>[false, true]) {
            final spelling = PitchSpelling.simplestFor(
              pc,
              preferSharps: sharps,
            );
            expect(spelling.accidentalCount, lessThanOrEqualTo(1));
            expect(spelling.pitchClass, ((pc % 12) + 12) % 12);
          }
        }
      },
    );
  });

  group('steppedTo', () {
    test('finds the spelling a given number of letters away', () {
      final eFlat = PitchSpelling.parse('Eb');
      // Eb up a minor third is Gb: two letters, pitch class 6.
      expect(eFlat.steppedTo(2, 6).toString(), 'Gb');
      // Eb up a perfect fifth is Bb: four letters, pitch class 10.
      expect(eFlat.steppedTo(4, 10).toString(), 'Bb');
      expect(PitchSpelling.parse('C').steppedTo(6, 11).toString(), 'B');
    });

    test('gives up rather than emit a triple accidental', () {
      // C cannot name pitch class 6: that would be C###.
      expect(PitchSpelling.parse('C').steppedTo(0, 6), isNull);
      expect(PitchSpelling.parse('C##').steppedTo(0, 6), isNull);
    });
  });

  test('sorts by letter, then accidental', () {
    final sorted = <PitchSpelling>[
      PitchSpelling.parse('D'),
      PitchSpelling.parse('Cb'),
      PitchSpelling.parse('C#'),
      PitchSpelling.parse('C'),
    ]..sort();
    expect(sorted.map((s) => s.toString()).toList(), <String>[
      'Cb', 'C', 'C#', 'D', //
    ]);
  });
}
