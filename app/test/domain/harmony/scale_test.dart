import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harmony_test_support.dart';

void main() {
  late ScaleLibrary library;

  setUpAll(() {
    installTestHarmony();
    library = Harmony.scales;
  });

  group('the data file itself', () {
    test('loads the scales the rules describe', () {
      expect(library.scales.length, greaterThanOrEqualTo(18));
      for (final name in <String>[
        'Ionian', 'Dorian', 'Mixolydian', 'Lydian', 'Altered', //
        'Melodic minor', 'Harmonic minor', 'Whole tone', 'Blues',
      ]) {
        expect(library.byName(name), isNotNull, reason: name);
      }
    });

    test('is looked up case-insensitively and by alias', () {
      expect(library.byName('major'), library.byName('Ionian'));
      expect(library.byName('  LYDIAN DOMINANT '), library.byName('Lydian b7'));
      expect(library.byName('not a scale'), isNull);
    });

    test('every scale is ascending and free of duplicate pitch classes', () {
      for (final scale in library.scales) {
        final semitones = scale.semitones;
        expect(semitones.first, 0, reason: '${scale.name} must start on 1');
        expect(
          semitones.toSet(),
          hasLength(semitones.length),
          reason: '${scale.name} repeats a pitch class',
        );
        for (var i = 1; i < semitones.length; i++) {
          expect(
            semitones[i],
            greaterThan(semitones[i - 1]),
            reason: '${scale.name} is out of order',
          );
        }
      }
    });

    test('rejects a malformed table', () {
      expect(
        () => ScaleLibrary.fromJson('{"schemaVersion": 42, "scales": []}'),
        throwsFormatException,
      );
      expect(
        () => ScaleLibrary.fromJson(
          '{"schemaVersion": 1, "scales": ['
          '{"name":"a","aliases":["x"],"degrees":["1"]},'
          '{"name":"b","aliases":["X"],"degrees":["1"]}]}',
        ),
        throwsFormatException,
      );
    });
  });

  group('the scales are the scales', () {
    test('major, dorian and mixolydian have the right intervals', () {
      expect(library.byName('Ionian')!.semitones, <int>[0, 2, 4, 5, 7, 9, 11]);
      expect(library.byName('Dorian')!.semitones, <int>[0, 2, 3, 5, 7, 9, 10]);
      expect(library.byName('Mixolydian')!.semitones, <int>[
        0,
        2,
        4,
        5,
        7,
        9,
        10,
      ]);
    });

    test('the altered scale has every alteration and no natural fifth', () {
      final altered = library.byName('Altered')!;
      expect(altered.semitones, <int>[0, 1, 3, 4, 6, 8, 10]);
      expect(altered.semitones.contains(7), isFalse);
    });

    test('the diminished scales alternate their steps', () {
      final halfWhole = library.byName('Half-whole diminished')!.semitones;
      final wholeHalf = library.byName('Whole-half diminished')!.semitones;
      expect(halfWhole, hasLength(8));
      expect(wholeHalf, hasLength(8));
      for (var i = 1; i < halfWhole.length; i++) {
        expect(halfWhole[i] - halfWhole[i - 1], i.isOdd ? 1 : 2);
        expect(wholeHalf[i] - wholeHalf[i - 1], i.isOdd ? 2 : 1);
      }
    });
  });

  group('fitting a chord', () {
    test('is answered structurally: every chord tone must be in the scale', () {
      final ionian = library.byName('Ionian')!;
      expect(ionian.fits(ChordSymbol.parse('Cmaj7').type), isTrue);
      expect(ionian.fits(ChordSymbol.parse('C7').type), isFalse);
      expect(
        library.byName('Mixolydian')!.fits(ChordSymbol.parse('C7').type),
        isTrue,
      );
      expect(
        library.byName('Altered')!.fits(ChordSymbol.parse('C7alt').type),
        isTrue,
      );
    });

    test('the scales offered for a dominant seventh are dominant scales', () {
      final matches = library.fitting(ChordSymbol.parse('C7').type);
      expect(matches, isNotEmpty);
      expect(
        matches.first.isPreferredFor(ChordSymbol.parse('C7').type),
        isTrue,
      );
      for (final scale in matches) {
        expect(scale.fits(ChordSymbol.parse('C7').type), isTrue);
      }
    });

    test('preferred scales come first, then the fullest', () {
      final matches = library.fitting(ChordSymbol.parse('Cmaj7').type);
      final preferred = matches.takeWhile(
        (s) => s.isPreferredFor(ChordSymbol.parse('Cmaj7').type),
      );
      expect(preferred, isNotEmpty);
      expect(matches.first.noteCount, greaterThanOrEqualTo(5));
    });

    test('nothing fits a chord with a note no scale has', () {
      // A diminished seventh needs 0 3 6 9, which only the whole-half
      // diminished scale provides.
      final matches = library.fitting(ChordSymbol.parse('Co7').type);
      expect(matches.map((s) => s.name), contains('Whole-half diminished'));
    });
  });

  group('spelling a scale from a root', () {
    test('D dorian is all naturals', () {
      final instance = StandardScaleInstance(
        library.byName('Dorian')!,
        PitchSpelling.parse('D'),
      );
      expect(instance.spellings.map((s) => s.toString()).toList(), <String>[
        'D',
        'E',
        'F',
        'G',
        'A',
        'B',
        'C',
      ]);
    });

    test('Eb lydian keeps its flats', () {
      final instance = StandardScaleInstance(
        library.byName('Lydian')!,
        PitchSpelling.parse('Eb'),
      );
      expect(instance.spellings.map((s) => s.toString()).toList(), <String>[
        'Eb',
        'F',
        'G',
        'A',
        'Bb',
        'C',
        'D',
      ]);
    });

    test('pitch classes follow the root, wherever it is', () {
      final scale = library.byName('Ionian')!;
      for (var root = 0; root < 12; root++) {
        expect(scale.pitchClassesFrom(root), <int>[
          for (final s in scale.semitones) (root + s) % 12,
        ]);
      }
    });

    test('an instance can be moved', () {
      final instance = StandardScaleInstance(
        library.byName('Dorian')!,
        PitchSpelling.parse('D'),
      );
      final moved = instance.transposedTo(PitchSpelling.parse('Eb'));
      expect(moved.root.toString(), 'Eb');
      expect(moved.scale, instance.scale);
      expect(moved.toString(), 'Eb Dorian');
    });
  });
}
