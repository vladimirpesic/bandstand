import 'package:bandstand/domain/harmony/key_signature.dart';
import 'package:bandstand/domain/harmony/pitch_spelling.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  KeySignature key(String text) => KeySignature.parse(text);

  group('the circle of fifths', () {
    test('counts sharps for major keys', () {
      const expected = <String, int>{
        'Cb': -7, 'Gb': -6, 'Db': -5, 'Ab': -4, 'Eb': -3, 'Bb': -2, 'F': -1, //
        'C': 0,
        'G': 1, 'D': 2, 'A': 3, 'E': 4, 'B': 5, 'F#': 6, 'C#': 7,
      };
      expected.forEach((tonic, sharps) {
        expect(key(tonic).sharpCount, sharps, reason: tonic);
      });
    });

    test(
      'counts sharps for minor keys, three fifths below the relative major',
      () {
        const expected = <String, int>{
          'Abm': -7, 'Ebm': -6, 'Bbm': -5, 'Fm': -4, 'Cm': -3, 'Gm': -2, //
          'Dm': -1, 'Am': 0,
          'Em': 1, 'Bm': 2, 'F#m': 3, 'C#m': 4, 'G#m': 5, 'D#m': 6, 'A#m': 7,
        };
        expected.forEach((tonic, sharps) {
          expect(key(tonic).sharpCount, sharps, reason: tonic);
        });
      },
    );

    test('refuses keys beyond seven accidentals', () {
      expect(() => key('G#'), throwsArgumentError);
      expect(() => key('Fb'), throwsArgumentError);
      expect(() => key('Ebbm'), throwsArgumentError);
    });
  });

  group('parsing', () {
    test('reads majors and minors in the forms charts use', () {
      expect(key('C').mode, KeyMode.major);
      expect(key('Cmaj').mode, KeyMode.major);
      expect(key('Cmajor').mode, KeyMode.major);
      expect(key('CM').mode, KeyMode.major);
      expect(key('Am').mode, KeyMode.minor);
      expect(key('Amin').mode, KeyMode.minor);
      expect(key('Aminor').mode, KeyMode.minor);
      expect(key('A-').mode, KeyMode.minor);
      expect(key('Bbm').tonic, PitchSpelling.parse('Bb'));
    });

    test('round-trips through toString', () {
      for (final text in <String>['C', 'Bb', 'F#', 'Eb', 'Am', 'F#m', 'Bbm']) {
        expect(key(text).toString(), text);
      }
    });

    test('refuses anything else', () {
      expect(() => key(''), throwsFormatException);
      expect(() => key('H'), throwsFormatException);
      expect(() => key('Cwobble'), throwsFormatException);
    });
  });

  group('diatonic spellings', () {
    test('E major is E F# G# A B C# D#', () {
      expect(
        key('E').scaleSpellings.map((s) => s.toString()).toList(),
        <String>['E', 'F#', 'G#', 'A', 'B', 'C#', 'D#'],
      );
    });

    test('Db major is Db Eb F Gb Ab Bb C', () {
      expect(
        key('Db').scaleSpellings.map((s) => s.toString()).toList(),
        <String>['Db', 'Eb', 'F', 'Gb', 'Ab', 'Bb', 'C'],
      );
    });

    test('C# major needs every sharp, including B#', () {
      expect(
        key('C#').scaleSpellings.map((s) => s.toString()).toList(),
        <String>['C#', 'D#', 'E#', 'F#', 'G#', 'A#', 'B#'],
      );
    });

    test('C minor is C D Eb F G Ab Bb', () {
      expect(
        key('Cm').scaleSpellings.map((s) => s.toString()).toList(),
        <String>['C', 'D', 'Eb', 'F', 'G', 'Ab', 'Bb'],
      );
    });

    test('every key spells seven different letters', () {
      for (final tonic in <String>[
        'Cb', 'Gb', 'Db', 'Ab', 'Eb', 'Bb', 'F', 'C', 'G', 'D', 'A', 'E', //
        'B', 'F#', 'C#',
      ]) {
        for (final suffix in <String>['', 'm']) {
          final signature = KeySignature.tryParse('$tonic$suffix');
          if (signature == null) {
            continue;
          }
          final letters = signature.scaleSpellings
              .map((s) => s.natural)
              .toSet();
          expect(letters, hasLength(7), reason: '$tonic$suffix');
        }
      }
    });
  });

  group('spelling a pitch class', () {
    test('uses the diatonic spelling where there is one', () {
      expect(key('E').spell(6).toString(), 'F#');
      expect(key('Db').spell(6).toString(), 'Gb');
      expect(key('E').spell(1).toString(), 'C#');
      expect(key('Bb').spell(10).toString(), 'Bb');
    });

    test('follows the accidental direction for chromatic notes', () {
      // Not in E major, so it takes the key's sharp side.
      expect(key('E').spell(10).toString(), 'A#');
      // Not in Eb major, so it takes the key's flat side.
      expect(key('Eb').spell(6).toString(), 'Gb');
    });

    test('C major and A minor lean flat, as jazz does', () {
      expect(key('C').spell(3).toString(), 'Eb');
      expect(key('C').spell(6).toString(), 'Gb');
      expect(key('C').spell(10).toString(), 'Bb');
      expect(key('Am').spell(3).toString(), 'Eb');
    });

    test('never returns a double accidental', () {
      for (final tonic in <String>['Cb', 'Gb', 'C', 'E', 'B', 'F#', 'C#']) {
        final signature = key(tonic);
        for (var pitchClass = 0; pitchClass < 12; pitchClass++) {
          expect(
            signature.spell(pitchClass).accidentalCount,
            lessThanOrEqualTo(1),
            reason:
                '$tonic spells $pitchClass as '
                '${signature.spell(pitchClass)}',
          );
        }
      }
    });

    test('always returns the pitch class it was asked for', () {
      for (final tonic in <String>['C', 'Db', 'E', 'F#', 'Bb', 'Am', 'F#m']) {
        final signature = key(tonic);
        for (var pitchClass = 0; pitchClass < 12; pitchClass++) {
          expect(signature.spell(pitchClass).pitchClass, pitchClass);
        }
      }
    });
  });

  test('relative majors share a signature', () {
    expect(key('Am').relativeMajor, key('C'));
    expect(key('F#m').relativeMajor, key('A'));
    expect(key('Bbm').relativeMajor, key('Db'));
    expect(key('C').relativeMajor, key('C'));
    for (final tonic in <String>['Am', 'Em', 'Bm', 'Dm', 'Gm', 'Cm', 'F#m']) {
      expect(key(tonic).relativeMajor.sharpCount, key(tonic).sharpCount);
    }
  });

  test('C major is the default a chart falls back to', () {
    expect(KeySignature.cMajor().toString(), 'C');
    expect(KeySignature.cMajor().sharpCount, 0);
  });
}
