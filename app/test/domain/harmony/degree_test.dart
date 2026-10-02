import 'package:bandstand/domain/harmony/degree.dart';
import 'package:bandstand/domain/harmony/natural.dart';
import 'package:bandstand/domain/harmony/pitch_spelling.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parsing', () {
    test('reads plain and altered degrees', () {
      expect(Degree.parse('1').semitones, 0);
      expect(Degree.parse('b3').semitones, 3);
      expect(Degree.parse('3').semitones, 4);
      expect(Degree.parse('4').semitones, 5);
      expect(Degree.parse('b5').semitones, 6);
      expect(Degree.parse('5').semitones, 7);
      expect(Degree.parse('#5').semitones, 8);
      expect(Degree.parse('6').semitones, 9);
      expect(Degree.parse('bb7').semitones, 9);
      expect(Degree.parse('b7').semitones, 10);
      expect(Degree.parse('7').semitones, 11);
    });

    test('reads extensions and folds them to their simple degree', () {
      expect(Degree.parse('9').semitones, 2);
      expect(Degree.parse('b9').semitones, 1);
      expect(Degree.parse('#9').semitones, 3);
      expect(Degree.parse('11').semitones, 5);
      expect(Degree.parse('#11').semitones, 6);
      expect(Degree.parse('13').semitones, 9);
      expect(Degree.parse('b13').semitones, 8);
      expect(Degree.parse('9').natural, Natural.d);
      expect(Degree.parse('9').asExtension, isTrue);
      expect(Degree.parse('2').asExtension, isFalse);
    });

    test('refuses anything else', () {
      for (final text in <String>['', '0', '14', 'b', 'x', '#b3', 'three']) {
        expect(Degree.tryParse(text), isNull, reason: text);
      }
      expect(() => Degree.parse('14'), throwsFormatException);
    });

    test('round-trips through its symbol', () {
      for (final symbol in <String>[
        '1', 'b2', '2', '#2', 'b3', '3', '4', '#4', 'b5', '5', '#5', //
        '6', 'bb7', 'b7', '7', 'b9', '9', '#9', '11', '#11', 'b13', '13',
      ]) {
        expect(Degree.parse(symbol).symbol, symbol, reason: symbol);
      }
    });
  });

  group('spelling matters, semitones do not settle it', () {
    test('a sharp ninth and a flat third are three semitones apart from the '
        'root and are different degrees', () {
      final sharpNine = Degree.parse('#9');
      final flatThree = Degree.parse('b3');
      expect(sharpNine.semitones, flatThree.semitones);
      expect(sharpNine, isNot(flatThree));
    });

    test('a flat fifth and a sharp eleventh are different degrees', () {
      expect(Degree.parse('b5'), isNot(Degree.parse('#11')));
      expect(Degree.parse('b5').semitones, Degree.parse('#11').semitones);
    });

    test('the 2/9 distinction is presentation only', () {
      expect(Degree.parse('9'), Degree.parse('2'));
      expect(Degree.parse('9').symbol, '9');
      expect(Degree.parse('9').asSimple.symbol, '2');
      expect(Degree.parse('2').asExtended.symbol, '9');
      expect(Degree.parse('1').asExtended.symbol, '1');
    });
  });

  group('from a root', () {
    test('spells the interval, keeping the letter distance', () {
      final eFlat = PitchSpelling.parse('Eb');
      expect(Degree.parse('b3').from(eFlat).toString(), 'Gb');
      expect(Degree.parse('3').from(eFlat).toString(), 'G');
      expect(Degree.parse('5').from(eFlat).toString(), 'Bb');
      expect(Degree.parse('b7').from(eFlat).toString(), 'Db');
      expect(Degree.parse('#9').from(eFlat).toString(), 'F#');
      expect(Degree.parse('#11').from(eFlat).toString(), 'A');
      expect(Degree.parse('b13').from(eFlat).toString(), 'Cb');
    });

    test('spells from a sharp root too', () {
      final fSharp = PitchSpelling.parse('F#');
      expect(Degree.parse('b3').from(fSharp).toString(), 'A');
      expect(Degree.parse('5').from(fSharp).toString(), 'C#');
      expect(Degree.parse('b7').from(fSharp).toString(), 'E');
      expect(Degree.parse('7').from(fSharp).toString(), 'E#');
    });

    test('always lands on the right pitch class, from every root', () {
      for (final natural in Natural.values) {
        for (var alteration = -2; alteration <= 2; alteration++) {
          final root = PitchSpelling(natural, alteration);
          for (final symbol in <String>[
            '1', 'b2', '2', 'b3', '3', '4', '#4', 'b5', '5', '#5', '6', //
            'bb7', 'b7', '7', 'b9', '9', '#9', '11', '#11', 'b13', '13',
          ]) {
            final degree = Degree.parse(symbol);
            expect(
              degree.from(root).pitchClass,
              (root.pitchClass + degree.semitones) % 12,
              reason: '$symbol from $root',
            );
          }
        }
      }
    });
  });

  test('sorts by written number so a degree list reads 1 3 5 b7 9', () {
    final sorted = <Degree>[
      Degree.parse('9'),
      Degree.parse('1'),
      Degree.parse('b7'),
      Degree.parse('#9'),
      Degree.parse('5'),
      Degree.parse('3'),
      Degree.parse('b9'),
    ]..sort();
    expect(sorted.map((d) => d.symbol).join(' '), '1 3 5 b7 b9 9 #9');
  });

  test('rejects more than a double accidental', () {
    expect(() => Degree(Natural.e, 3), throwsArgumentError);
  });
}
