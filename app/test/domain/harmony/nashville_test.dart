import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harmony_test_support.dart';

void main() {
  installTestHarmony();

  String number(String chord, String key) =>
      Nashville.format(ChordSymbol.parse(chord), KeySignature.parse(key));

  group('writing a chord as a number', () {
    test('a ii-V-I is 2-5-1 in any key', () {
      expect(number('Dm7', 'C'), '2m7');
      expect(number('G7', 'C'), '57');
      expect(number('Cmaj7', 'C'), '1maj7');

      // The same tune in Eb is the same numbers.
      expect(number('Fm7', 'Eb'), '2m7');
      expect(number('Bb7', 'Eb'), '57');
      expect(number('Ebmaj7', 'Eb'), '1maj7');
    });

    test('the quality comes across unchanged', () {
      expect(number('Am7b5', 'C'), '6m7b5');
      expect(number('Co7', 'C'), '1o7');
      expect(number('F6', 'C'), '46');
      expect(number('G7sus4', 'C'), '57sus4');
      expect(number('C', 'C'), '1');
    });

    test('chromatic degrees are written with flats', () {
      // A b6 is a flattened sixth, not a raised fifth, in every context this
      // system is used in.
      expect(number('Ab7', 'C'), 'b67');
      expect(number('Db', 'C'), 'b2');
      expect(number('Eb', 'C'), 'b3');
      expect(number('Gb7', 'C'), 'b57');
      expect(number('Bb7', 'C'), 'b77');
    });

    test('a slash chord keeps its bass, also as a number', () {
      // Writing it as `1/E` would defeat the point of the system.
      expect(number('C/E', 'C'), '1/3');
      expect(number('C/G', 'C'), '1/5');
      expect(number('Dm7/G', 'C'), '2m7/5');
    });

    test('a slash chord whose bass is its root is not a slash chord', () {
      expect(number('C/C', 'C'), '1');
    });

    test('it works in a minor key', () {
      expect(number('Am', 'Am'), '1m');
      expect(number('Dm', 'Am'), '4m');
      expect(number('E7', 'Am'), '57');
    });

    test('every root in every key gives a degree', () {
      const roots = <String>[
        'C', 'Db', 'D', 'Eb', 'E', 'F', 'Gb', 'G', 'Ab', 'A', 'Bb', 'B', //
      ];
      for (final key in roots) {
        for (final root in roots) {
          final written = number(root, key);
          expect(written, isNotEmpty, reason: '$root in $key');
          // A degree is a digit, optionally flattened.
          expect(
            RegExp(r'^b?[1-7]').hasMatch(written),
            isTrue,
            reason: '$root in $key gave "$written"',
          );
        }
      }
    });

    test('transposing a tune does not change its numbers', () {
      // The property the whole system exists for.
      const progression = <String>['Cmaj7', 'A7', 'Dm7', 'G7'];
      final inC = <String>[for (final c in progression) number(c, 'C')];
      for (var semitones = 1; semitones < 12; semitones++) {
        final key = KeySignature.parse('C').tonic.pitchClass;
        final moved = <String>[
          for (final c in progression)
            Nashville.format(
              ChordSymbol.parse(c).transposed(semitones),
              KeySignature.parse('C').transposed(semitones),
            ),
        ];
        expect(moved, inC, reason: 'moved by $semitones from $key');
      }
    });
  });

  group('degrees and diatonicism', () {
    test('a degree can be asked for on its own', () {
      final c = KeySignature.parse('C');
      expect(Nashville.degreeOf(0, c), '1');
      expect(Nashville.degreeOf(4, c), '3');
      expect(Nashville.degreeOf(10, c), 'b7');
    });

    test('it marks what is not in the key', () {
      final c = KeySignature.parse('C');
      expect(Nashville.isDiatonic(ChordSymbol.parse('Dm7'), c), isTrue);
      expect(Nashville.isDiatonic(ChordSymbol.parse('G7'), c), isTrue);
      expect(Nashville.isDiatonic(ChordSymbol.parse('Cmaj7'), c), isTrue);
      // The chords worth looking at twice.
      expect(Nashville.isDiatonic(ChordSymbol.parse('A7'), c), isFalse);
      expect(Nashville.isDiatonic(ChordSymbol.parse('Ab7'), c), isFalse);
    });

    test('a minor key has its own scale', () {
      final a = KeySignature.parse('Am');
      expect(Nashville.isDiatonic(ChordSymbol.parse('Am7'), a), isTrue);
      expect(Nashville.isDiatonic(ChordSymbol.parse('Dm7'), a), isTrue);
      // The raised seventh of a dominant V is outside the natural minor, which
      // is exactly the thing worth marking.
      expect(Nashville.isDiatonic(ChordSymbol.parse('E7'), a), isFalse);
    });
  });
}
