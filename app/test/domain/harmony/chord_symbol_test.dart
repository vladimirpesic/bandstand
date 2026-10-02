import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harmony_test_support.dart';

/// The flat-side default table of `docs/rules/pitch-and-spelling.md` §6.
const List<String> _automaticSpellings = <String>[
  'C', 'Db', 'D', 'Eb', 'E', 'F', 'Gb', 'G', 'Ab', 'A', 'Bb', 'B', //
];

const List<String> _roots = <String>[
  'C', 'Db', 'D', 'Eb', 'E', 'F', 'Gb', 'G', 'Ab', 'A', 'Bb', 'B', //
  'C#', 'D#', 'F#', 'G#', 'A#', 'Cb', 'Fb', 'E#', 'B#',
];

void main() {
  late ChordTypeDatabase database;

  setUpAll(() {
    installTestHarmony();
    database = Harmony.chordTypes;
  });

  group('parse(format(x)) == x', () {
    test('holds for every core type on every root', () {
      var cases = 0;
      for (final core in database.cores) {
        for (final root in _roots) {
          final chord = ChordSymbol(PitchSpelling.parse(root), core.type);
          expect(
            ChordSymbol.parse(chord.format()),
            chord,
            reason: chord.format(),
          );
          cases++;
        }
      }
      expect(cases, greaterThanOrEqualTo(500));
    });

    test('holds for slash chords', () {
      for (final core in database.cores) {
        for (final root in <String>['C', 'Eb', 'F#', 'Bb']) {
          for (final bass in <String>['E', 'G', 'Bb', 'Ab']) {
            final chord = ChordSymbol(
              PitchSpelling.parse(root),
              core.type,
              bass: PitchSpelling.parse(bass),
            );
            expect(
              ChordSymbol.parse(chord.format()),
              chord,
              reason: chord.format(),
            );
          }
        }
      }
    });

    test('holds for composed alterations', () {
      for (final text in <String>[
        'C13b9#11', 'C7b9', 'C7#9', 'Cmaj7#11', 'C7no5', 'Cm7b9', //
        'C7b13', 'Cmaj9#11', 'C13#11', 'C7alt', 'Csus2', 'C6sus4',
      ]) {
        final chord = ChordSymbol.parse(text);
        expect(ChordSymbol.parse(chord.format()), chord, reason: text);
      }
    });
  });

  group('transposition through all twelve keys', () {
    test('every core type, from every root, lands on the right pitch class '
        'with the right spelling', () {
      var cases = 0;
      for (final core in database.cores) {
        for (final root in <String>['C', 'Eb', 'F#', 'A', 'Bb']) {
          final source = ChordSymbol(PitchSpelling.parse(root), core.type);
          for (var semitones = 0; semitones < 12; semitones++) {
            final moved = source.transposed(semitones);
            final expectedPitchClass = (source.rootPitchClass + semitones) % 12;
            expect(
              moved.rootPitchClass,
              expectedPitchClass,
              reason: '$source + $semitones',
            );
            expect(moved.type, source.type, reason: '$source + $semitones');
            if (semitones != 0) {
              expect(
                moved.root.toString(),
                _automaticSpellings[expectedPitchClass],
                reason: '$source + $semitones',
              );
            }
            expect(ChordSymbol.parse(moved.format()), moved);
            cases++;
          }
        }
      }
      expect(cases, greaterThanOrEqualTo(500));
    });

    test('the examples §4.1 names', () {
      final ebSeven = ChordSymbol.parse('Eb7');
      // Up a semitone gives E7, not Fb7. This is the bug the whole spelling
      // engine exists to avoid.
      expect(ebSeven.transposed(1).format(), 'E7');
      // Up a tritone gives A7.
      expect(ebSeven.transposed(6).format(), 'A7');
    });

    test('a slash chord moves its bass by the same interval', () {
      final chord = ChordSymbol.parse('Dm7/G');
      expect(chord.transposed(2).format(), 'Em7/A');
      expect(chord.transposed(-2).format(), 'Cm7/F');
      expect(chord.transposed(5).format(), 'Gm7/C');
    });

    test(
      'transposing by nothing changes nothing, however the chord is spelled',
      () {
        for (final text in <String>['C7', 'D#7', 'Fb', 'Cbmaj7', 'B#m7']) {
          final chord = ChordSymbol.parse(text);
          expect(chord.transposed(0), same(chord), reason: text);
          expect(chord.transposed(12), same(chord), reason: text);
          expect(chord.transposed(-24), same(chord), reason: text);
        }
      },
    );

    test('octaves do not change a chord symbol', () {
      final chord = ChordSymbol.parse('Bbmaj7');
      expect(chord.transposed(14).format(), chord.transposed(2).format());
      expect(chord.transposed(-10).format(), chord.transposed(2).format());
    });
  });

  group('transpose by n then by -n', () {
    test('always preserves what is played', () {
      for (final text in <String>[
        'C7', 'D#7', 'Cbmaj7', 'B#m7', 'F#m7b5/C', 'Ebm69', 'G#7alt', //
      ]) {
        final chord = ChordSymbol.parse(text);
        for (var semitones = -11; semitones <= 11; semitones++) {
          final round = chord.transposed(semitones).transposed(-semitones);
          expect(
            round.isEnharmonicWith(chord),
            isTrue,
            reason: '$text by $semitones gives $round',
          );
        }
      }
    });

    test('is exactly the identity for canonically spelled chords', () {
      const preference = SpellingPreference.automatic;
      for (final core in database.cores) {
        for (final root in _automaticSpellings) {
          final chord = ChordSymbol(PitchSpelling.parse(root), core.type);
          expect(preference.isCanonical(chord.root), isTrue);
          for (var semitones = -11; semitones <= 11; semitones++) {
            expect(
              chord.transposed(semitones).transposed(-semitones),
              chord,
              reason: '${chord.format()} by $semitones',
            );
          }
        }
      }
    });

    test('corrects the spelling of a chord that was written awkwardly', () {
      // D#7 up a semitone is E7, and E7 back down is Eb7 — the round trip has
      // fixed the spelling, which is the behaviour §7.1 of the rules asks for.
      final awkward = ChordSymbol.parse('D#7');
      final round = awkward.transposed(1).transposed(-1);
      expect(round.format(), 'Eb7');
      expect(round.isEnharmonicWith(awkward), isTrue);
      expect(round, isNot(awkward));
    });
  });

  group('spelling preferences', () {
    test('a key signature decides the accidental direction', () {
      final chord = ChordSymbol.parse('C7');
      expect(
        chord
            .transposed(
              6,
              preference: SpellingPreference.key(KeySignature.parse('E')),
            )
            .format(),
        'F#7',
      );
      expect(
        chord
            .transposed(
              6,
              preference: SpellingPreference.key(KeySignature.parse('Db')),
            )
            .format(),
        'Gb7',
      );
    });

    test('a forced direction overrides the default table', () {
      final chord = ChordSymbol.parse('C7');
      expect(
        chord.transposed(1, preference: SpellingPreference.sharps).format(),
        'C#7',
      );
      expect(
        chord.transposed(1, preference: SpellingPreference.flats).format(),
        'Db7',
      );
      expect(chord.transposed(1).format(), 'Db7');
    });

    test('respelling moves nothing', () {
      final chord = ChordSymbol.parse('D#7');
      expect(chord.respelled(SpellingPreference.automatic).format(), 'Eb7');
      expect(chord.respelled(SpellingPreference.sharps).format(), 'D#7');
      expect(
        chord.respelled(SpellingPreference.automatic).rootPitchClass,
        chord.rootPitchClass,
      );
    });

    test('a whole chart transposed into a key spells consistently', () {
      // A ii-V-I in C, taken up to Db: every root should come from the Db table.
      final key = KeySignature.parse('Db');
      final preference = SpellingPreference.key(key);
      final progression = <String>['Dm7', 'G7', 'Cmaj7'];
      final moved = <String>[
        for (final text in progression)
          ChordSymbol.parse(text)
              .transposed(1, preference: preference)
              .format(),
      ];
      expect(moved, <String>['Ebm7', 'Ab7', 'Dbmaj7']);
    });

    test('preferences compare by value', () {
      expect(SpellingPreference.automatic, SpellingPreference.automatic);
      expect(SpellingPreference.sharps, isNot(SpellingPreference.flats));
      expect(
        SpellingPreference.key(KeySignature.parse('E')),
        SpellingPreference.key(KeySignature.parse('E')),
      );
      expect(
        SpellingPreference.key(KeySignature.parse('E')),
        isNot(SpellingPreference.key(KeySignature.parse('Eb'))),
      );
    });
  });

  group('equality', () {
    test('is by root spelling, type and bass', () {
      expect(ChordSymbol.parse('C7'), ChordSymbol.parse('C7'));
      expect(ChordSymbol.parse('C7'), isNot(ChordSymbol.parse('B#7')));
      expect(ChordSymbol.parse('C7'), isNot(ChordSymbol.parse('C7/E')));
      expect(ChordSymbol.parse('Cmaj7'), ChordSymbol.parse('CΔ7'));
    });

    test('enharmonic chords are not equal but sound the same', () {
      final cSharp = ChordSymbol.parse('C#7');
      final dFlat = ChordSymbol.parse('Db7');
      expect(cSharp, isNot(dFlat));
      expect(cSharp.isEnharmonicWith(dFlat), isTrue);
      expect(cSharp.pitchClasses, dFlat.pitchClasses);
    });

    test('hash codes agree with equality', () {
      final chords = <ChordSymbol>{
        ChordSymbol.parse('C7'),
        ChordSymbol.parse('C7'),
        ChordSymbol.parse('CΔ7'),
        ChordSymbol.parse('Cmaj7'),
      };
      expect(chords, hasLength(2));
    });
  });

  test('withType and withBass leave everything else alone', () {
    final chord = ChordSymbol.parse('Dm7/G');
    expect(chord.withBass(null).format(), 'Dm7');
    expect(chord.withType(ChordSymbol.parse('C7').type).format(), 'D7/G');
  });
}
