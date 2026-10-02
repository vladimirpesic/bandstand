import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harmony_test_support.dart';

/// The twelve roots a chart actually uses, plus the sharp side, so a root's
/// spelling is exercised as well as its pitch class.
const List<String> _roots = <String>[
  'C', 'Db', 'D', 'Eb', 'E', 'F', 'Gb', 'G', 'Ab', 'A', 'Bb', 'B', //
  'C#', 'F#', 'G#', 'A#', 'Cb',
];

void main() {
  late ChordTypeDatabase database;

  setUpAll(() {
    installTestHarmony();
    database = Harmony.chordTypes;
  });

  group('the data file itself', () {
    test('loads, and has the entries the rules describe', () {
      expect(database.cores.length, greaterThanOrEqualTo(40));
      expect(database.modifiers.length, greaterThanOrEqualTo(15));
    });

    test('has exactly one core with an empty alias, so a bare C parses', () {
      final bare = database.cores
          .where((core) => core.aliases.contains(''))
          .toList();
      expect(bare, hasLength(1));
      expect(bare.single.type.degrees.map((d) => d.symbol).join(' '), '1 3 5');
      expect(database.majorTriad.name, '');
    });

    test('never gives two entries the same alias', () {
      for (final table in <List<List<String>>>[
        <List<String>>[for (final core in database.cores) core.aliases],
        <List<String>>[
          for (final modifier in database.modifiers) modifier.aliases,
        ],
      ]) {
        final seen = <String>{};
        for (final aliases in table) {
          for (final alias in aliases) {
            expect(seen.add(alias), isTrue, reason: 'duplicate alias "$alias"');
          }
        }
      }
    });

    test(
      'every core degree list is ascending and free of exact duplicates',
      () {
        for (final core in database.cores) {
          final degrees = core.type.degrees;
          for (var i = 1; i < degrees.length; i++) {
            expect(
              degrees[i - 1].compareTo(degrees[i]),
              lessThan(0),
              reason: '${core.type.name}: ${degrees.join(' ')}',
            );
          }
        }
      },
    );

    test('rejects a malformed table rather than half-loading it', () {
      expect(
        () => ChordTypeDatabase.fromJson('{"schemaVersion": 99, "cores": []}'),
        throwsFormatException,
      );
      expect(
        () => ChordTypeDatabase.fromJson('not json at all'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => ChordTypeDatabase.fromJson(
          '{"schemaVersion": 1, "cores": ['
          '{"name":"a","aliases":["a",""],"family":"major","degrees":["1"]},'
          '{"name":"b","aliases":["a"],"family":"major","degrees":["1"]}],'
          '"modifiers": []}',
        ),
        throwsFormatException,
      );
    });
  });

  group('the parser suite', () {
    test('every core alias parses to its own core, from every root', () {
      var cases = 0;
      for (final core in database.cores) {
        for (final alias in core.aliases) {
          for (final root in _roots) {
            final text = '$root$alias';
            final parsed = ChordSymbol.tryParse(text);
            expect(parsed, isNotNull, reason: 'could not parse "$text"');
            expect(
              parsed!.root,
              PitchSpelling.parse(root),
              reason: '"$text" root',
            );
            expect(
              parsed.type.name,
              core.aliases.first,
              reason: '"$text" should be ${core.aliases.first}',
            );
            expect(
              parsed.type.degrees,
              core.type.degrees,
              reason: '"$text" degrees',
            );
            expect(
              parsed.format(),
              '$root${core.aliases.first}',
              reason: '"$text" formats',
            );
            cases++;
          }
        }
      }
      // §10 M1 asks for a 500-case parser suite. This is that, and then some.
      expect(cases, greaterThanOrEqualTo(500));
    });

    test('real-world symbols parse to the expected canonical form', () {
      const expected = <String, String>{
        // Plain triads and their aliases.
        'C': 'C', 'CM': 'C', 'Cmaj': 'C', 'Cma': 'C',
        'Cm': 'Cm', 'Cmin': 'Cm', 'Cmi': 'Cm', 'C-': 'Cm',
        'C+': 'C+', 'Caug': 'C+',
        'Co': 'Co', 'Cdim': 'Co',
        'Csus': 'Csus4', 'Csus4': 'Csus4', 'Csus2': 'Csus2',
        'C5': 'C5',
        // Sixths.
        'C6': 'C6', 'Cm6': 'Cm6', 'C6/9': 'C69', 'C69': 'C69',
        'Cm6/9': 'Cm69', 'C6sus': 'C6sus4',
        // Sevenths, in every notation a chart uses.
        'C7': 'C7', 'Cdom7': 'C7',
        'Cmaj7': 'Cmaj7', 'CM7': 'Cmaj7', 'CΔ7': 'Cmaj7', 'CΔ': 'Cmaj7',
        'C^7': 'Cmaj7', 'C^': 'Cmaj7', 'Cj7': 'Cmaj7', 'Cma7': 'Cmaj7',
        'Cm7': 'Cm7', 'C-7': 'Cm7', 'Cmi7': 'Cm7', 'Cmin7': 'Cm7',
        'Cm7b5': 'Cm7b5', 'Cø': 'Cm7b5', 'Cø7': 'Cm7b5', 'Ch': 'Cm7b5',
        'Ch7': 'Cm7b5', 'C-7b5': 'Cm7b5', 'Cm7-5': 'Cm7b5',
        'Co7': 'Co7', 'Cdim7': 'Co7',
        'CmMaj7': 'CmMaj7', 'CmM7': 'CmMaj7', 'Cm(maj7)': 'CmMaj7',
        'CminMaj7': 'CmMaj7', 'C-Δ7': 'CmMaj7',
        'C7sus4': 'C7sus4', 'C7sus': 'C7sus4',
        'C7b5': 'C7b5', 'C7-5': 'C7b5',
        'C7#5': 'C7#5', 'C+7': 'C7#5', 'Caug7': 'C7#5', 'C7+5': 'C7#5',
        'Cmaj7#5': 'Cmaj7#5', 'C+maj7': 'Cmaj7#5', 'CΔ7#5': 'Cmaj7#5',
        'Cmaj7b5': 'Cmaj7b5',
        // Ninths and beyond.
        'C9': 'C9', 'Cmaj9': 'Cmaj9', 'CM9': 'Cmaj9', 'Cm9': 'Cm9',
        'C-9': 'Cm9', 'Cm9b5': 'Cm9b5', 'Cø9': 'Cm9b5',
        'C9sus': 'C9sus4', 'C9sus4': 'C9sus4',
        'Cadd9': 'Cadd9', 'Cadd2': 'Cadd9', 'Cmadd9': 'Cmadd9',
        'Cm(add9)': 'Cmadd9',
        'C11': 'C11', 'Cm11': 'Cm11', 'Cmaj11': 'Cmaj11', 'Cm11b5': 'Cm11b5',
        'C13': 'C13', 'Cm13': 'Cm13', 'Cmaj13': 'Cmaj13',
        'C13sus': 'C13sus4', 'C13sus4': 'C13sus4',
        // Alterations composed by the grammar.
        'C7b9': 'C7b9', 'C7#9': 'C7#9', 'C7#11': 'C7#11', 'C7b13': 'C7b13',
        'C13b9': 'C13b9', 'C13#11': 'C13#11', 'C13b9#11': 'C13b9#11',
        'C7b9#11': 'C7b9#11', 'Cmaj7#11': 'Cmaj7#11', 'Cmaj9#11': 'Cmaj9#11',
        'C9#11': 'C9#11', 'Cm7b9': 'Cm7b9',
        'C7alt': 'C7alt', 'Calt': 'C7alt', 'C7altered': 'C7alt',
        'C7(b9)': 'C7b9', 'C7(b9,#11)': 'C7b9#11', 'C7 b9': 'C7b9',
        'C13(b9)': 'C13b9', 'Cmaj7(#11)': 'Cmaj7#11',
        'C7no5': 'C7no5', 'C7omit5': 'C7no5',
        // Roots that are not C.
        'Bbmaj7': 'Bbmaj7', 'F#m7b5': 'F#m7b5', 'Ebm6': 'Ebm6',
        'Abmaj9': 'Abmaj9', 'Dbm11': 'Dbm11', 'G#7alt': 'G#7alt',
        'Cb7': 'Cb7', 'Cbmaj7': 'Cbmaj7',
        // Slash chords.
        'C/E': 'C/E', 'Dm7/G': 'Dm7/G', 'Bb/D': 'Bb/D', 'F#m7b5/C': 'F#m7b5/C',
        'C7b9/E': 'C7b9/E', 'Ab/Bb': 'Ab/Bb',
        // Lower-case roots, which text charts use.
        'c': 'C', 'bb7': 'Bb7', 'f#m7': 'F#m7',
      };
      expected.forEach((input, canonical) {
        final parsed = ChordSymbol.tryParse(input);
        expect(parsed, isNotNull, reason: 'could not parse "$input"');
        expect(parsed!.format(), canonical, reason: '"$input"');
      });
      expect(expected.length, greaterThanOrEqualTo(100));
    });

    test('composed alterations produce the right notes', () {
      const expected = <String, String>{
        'C7b9': '1 3 5 b7 b9',
        'C13b9': '1 3 5 b7 b9 13',
        'C13b9#11': '1 3 5 b7 b9 #11 13',
        'C7alt': '1 3 b7 b9 #9 #11 b13',
        'Cmaj7#11': '1 3 5 7 #11',
        'C7sus4': '1 4 5 b7',
        'C7no5': '1 3 b7',
        'Csus2': '1 2 5',
        'C11': '1 5 b7 9 11',
        'Cm11': '1 b3 5 b7 9 11',
      };
      expected.forEach((input, degrees) {
        expect(
          ChordSymbol.parse(input).type.degrees.map((d) => d.symbol).join(' '),
          degrees,
          reason: input,
        );
      });
    });

    test('an altered dominant keeps both its ninths', () {
      final alt = ChordSymbol.parse('C7alt').type;
      expect(alt.degreeFor(1)!.symbol, 'b9');
      expect(alt.degreeFor(3)!.symbol, '#9');
      expect(alt.degrees.where((d) => d.number == 9), hasLength(2));
    });

    test('b9 and #9 coexist, however they are written', () {
      // They share a letter, so the letter-index match alone would let the
      // second one delete the first. Both must survive, in either order.
      for (final text in <String>['C7b9#9', 'C7(#9b9)']) {
        final chord = ChordSymbol.parse(text);
        expect(
          chord.type.degrees.map((d) => d.symbol).join(' '),
          '1 3 5 b7 b9 #9',
          reason: text,
        );
        expect(
          ChordSymbol.parse(chord.format()),
          chord,
          reason: '$text formatted as ${chord.format()}',
        );
      }
    });

    test('a set modifier replaces rather than doubles', () {
      // 13 already has a 9; b9 must displace it, not sit beside it.
      final thirteenFlatNine = ChordSymbol.parse('C13b9').type;
      expect(thirteenFlatNine.degreeFor(2), isNull);
      expect(thirteenFlatNine.degreeFor(1)!.symbol, 'b9');
    });

    test('separators are noise wherever they appear', () {
      for (final text in <String>[
        'C7(b9)', 'C7 (b9)', 'C7b9', 'C7 b9', 'C7,b9', 'C 7 b9', //
      ]) {
        expect(ChordSymbol.parse(text).format(), 'C7b9', reason: text);
      }
    });

    test('refuses what is not a chord, rather than guessing', () {
      for (final text in <String>[
        '', '  ', 'H7', 'Cwobble', 'C7x', 'Cm7b', '/E', 'C/', 'C/H', //
        'C###7', 'Cmaj7/', '7', 'x', 'C/E/G', 'Cbbb',
      ]) {
        expect(ChordSymbol.tryParse(text), isNull, reason: '"$text"');
      }
      expect(() => ChordSymbol.parse('Cwobble'), throwsFormatException);
    });

    test('reads a root greedily, so Cb5 is a C flat power chord', () {
      expect(ChordSymbol.parse('Cb5').root.toString(), 'Cb');
      expect(ChordSymbol.parse('Cb5').type.name, '5');
      // A flattened fifth on C is written with the accidental after the type.
      expect(ChordSymbol.parse('C7b5').root.toString(), 'C');
      expect(
        ChordSymbol.parse('C(b5)').type.degrees.map((d) => d.symbol).join(' '),
        '1 3 b5',
      );
    });
  });

  group('families', () {
    test('are what the table says', () {
      const expected = <String, ChordFamily>{
        'C': ChordFamily.major,
        'C6': ChordFamily.major,
        'Cmaj7': ChordFamily.major,
        'Cm': ChordFamily.minor,
        'Cm7': ChordFamily.minor,
        'CmMaj7': ChordFamily.minor,
        'C7': ChordFamily.dominant,
        'C13b9': ChordFamily.dominant,
        'C7alt': ChordFamily.dominant,
        'Cm7b5': ChordFamily.diminished,
        'Co7': ChordFamily.diminished,
        'C+': ChordFamily.augmented,
        'Csus4': ChordFamily.sus,
        'C7sus4': ChordFamily.sus,
        'C5': ChordFamily.other,
      };
      expected.forEach((input, family) {
        expect(ChordSymbol.parse(input).type.family, family, reason: input);
      });
    });

    test('a suspension makes the chord sus, whatever it started as', () {
      expect(ChordSymbol.parse('Cmaj7sus4').type.family, ChordFamily.sus);
    });

    test('isMinorish asks about the third, not the family', () {
      for (final text in <String>[
        'Cm',
        'Cm7',
        'Cm7b5',
        'Co7',
        'CmMaj7',
        'Cm9',
      ]) {
        expect(ChordSymbol.parse(text).isMinorish, isTrue, reason: text);
      }
      for (final text in <String>['C', 'C7', 'C7#9', 'Cmaj7', 'Csus4', 'C+']) {
        expect(ChordSymbol.parse(text).isMinorish, isFalse, reason: text);
      }
    });
  });

  group('chord tones', () {
    test('pitch classes are computed from the root', () {
      expect(ChordSymbol.parse('C7').pitchClasses, <int>[0, 4, 7, 10]);
      expect(ChordSymbol.parse('Ebm7').pitchClasses, <int>[3, 6, 10, 1]);
      expect(ChordSymbol.parse('Bo7').pitchClasses, <int>[11, 2, 5, 8]);
    });

    test('pitch classes ascend from the root, extensions included', () {
      // A 13th chord wraps past the octave; the list must come out in the
      // order it sounds, not in written-degree order.
      expect(ChordSymbol.parse('C13').pitchClasses, <int>[0, 2, 4, 7, 9, 10]);
      expect(ChordSymbol.parse('Fm13').pitchClasses, <int>[5, 7, 8, 0, 2, 3]);
    });

    test('spellings keep the letters a musician expects', () {
      expect(
        ChordSymbol.parse('Ebm7').spellings.map((s) => s.toString()).toList(),
        <String>['Eb', 'Gb', 'Bb', 'Db'],
      );
      expect(
        ChordSymbol.parse('F#7').spellings.map((s) => s.toString()).toList(),
        <String>['F#', 'A#', 'C#', 'E'],
      );
      expect(
        ChordSymbol.parse('C7alt').spellings.map((s) => s.toString()).toList(),
        <String>['C', 'E', 'Bb', 'Db', 'D#', 'F#', 'Ab'],
      );
    });

    test('degreeFor finds a degree by its distance from the root', () {
      final chord = ChordSymbol.parse('Cmaj7');
      expect(chord.degreeFor(0)!.symbol, '1');
      expect(chord.degreeFor(4)!.symbol, '3');
      expect(chord.degreeFor(11)!.symbol, '7');
      expect(chord.degreeFor(10), isNull);
      expect(chord.degreeFor(12)!.symbol, '1');
    });
  });

  group('slash chords', () {
    test('the bass is a note, not a chord', () {
      final chord = ChordSymbol.parse('Dm7/G');
      expect(chord.bass, PitchSpelling.parse('G'));
      expect(chord.type.name, 'm7');
      expect(chord.isSlashChord, isTrue);
    });

    test('a bass on the root is not a slash chord', () {
      expect(ChordSymbol.parse('C/C').isSlashChord, isFalse);
      expect(ChordSymbol.parse('C').isSlashChord, isFalse);
    });
  });

  group('a modifier never deletes a differently spelled degree', () {
    // §5: `isMinorish` asks whether a chord holds three semitones *spelled as
    // a third*, which only means anything if `b3` and `#9` can coexist. The
    // modifier used to displace by semitone count regardless of spelling, so
    // `#9` deleted the minor third and `#11` deleted the flat fifth — leaving
    // a minor chord with no third and a half-diminished chord with no
    // diminished fifth, both silently and both still named as though they had
    // one.
    const expected = <String, String>{
      'Cm7#9': '1 b3 5 b7 #9',
      'Cm7b5#11': '1 b3 b5 b7 #11',
      'C7#5b13': '1 3 #5 b7 b13',
      // Unchanged, and the point of comparison: on a dominant the `#9` sits
      // beside a major third and always did.
      'C7#9': '1 3 5 b7 #9',
    };
    expected.forEach((symbol, degrees) {
      test('$symbol keeps every degree it names', () {
        expect(ChordSymbol.parse(symbol).type.degrees.join(' '), degrees);
      });
    });

    test('a minor chord with a sharp ninth is still minor', () {
      // The consequence a generator sees. `isMinorish` drives whether a voicing
      // treats the chord as minor at all.
      expect(ChordSymbol.parse('Cm7#9').type.isMinorish, isTrue);
      expect(ChordSymbol.parse('C7#9').type.isMinorish, isFalse);
    });

    test('a half-diminished chord keeps its diminished fifth', () {
      expect(
        ChordSymbol.parse('Cm7b5#11').type.degrees.map((d) => '$d'),
        contains('b5'),
      );
    });

    test('an unmodified degree still yields to its altered spelling', () {
      // The other half of the rule, and why it cannot simply keep everything:
      // `13` carries a natural ninth, and `13b9` has to replace it rather than
      // sound both.
      expect(
        ChordSymbol.parse('C13b9').type.degrees.join(' '),
        '1 3 5 b7 b9 13',
      );
      expect(ChordSymbol.parse('C13').type.degrees.join(' '), '1 3 5 b7 9 13');
    });

    test('an altered dominant still carries both ninths', () {
      // Which is why the rule cannot key on the degree number alone either.
      expect(
        ChordSymbol.parse('C7alt').type.degrees.join(' '),
        '1 3 b7 b9 #9 #11 b13',
      );
    });
  });
}
