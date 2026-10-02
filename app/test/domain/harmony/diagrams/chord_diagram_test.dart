import 'dart:io';

import 'package:bandstand/domain/harmony/diagrams/chord_diagram.dart';
import 'package:bandstand/domain/harmony/diagrams/chord_diagram_library.dart';
import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harmony_test_support.dart';

/// The invariants of `docs/format/chord-diagrams.md` — properties of the data,
/// better caught here than by a wrong diagram on a stand.
void main() {
  installTestHarmony();

  final library = ChordDiagramLibrary.fromJson(
    File('assets/chord_diagrams.json').readAsStringSync(),
  );

  /// Semitones above the root, by canonical symbol. Written out rather than
  /// taken from the chord-type table, so a fault in that table cannot make a
  /// wrong shape look right.
  const tones = <String, List<int>>{
    '': <int>[0, 4, 7],
    'm': <int>[0, 3, 7],
    '7': <int>[0, 4, 7, 10],
    'maj7': <int>[0, 4, 7, 11],
    'm7': <int>[0, 3, 7, 10],
    'm7b5': <int>[0, 3, 6, 10],
    'o7': <int>[0, 3, 6, 9],
    '6': <int>[0, 4, 7, 9],
    'm6': <int>[0, 3, 7, 9],
    'sus4': <int>[0, 5, 7],
    '7sus4': <int>[0, 5, 7, 10],
    '+': <int>[0, 4, 8],
    '9': <int>[0, 4, 7, 10, 2],
    'm9': <int>[0, 3, 7, 10, 2],
    'maj9': <int>[0, 4, 7, 11, 2],
  };

  /// The root a shape sounds: its own, or the one its root string carries.
  int rootOf(DiagramInstrument instrument, ChordShape shape) {
    final named = shape.root;
    if (named != null) {
      return named.pitchClass;
    }
    final string = shape.rootString!;
    return (instrument.tuning[string] +
            shape.baseFret +
            shape.frets[string] -
            1) %
        12;
  }

  group('the shipped shapes', () {
    test('every shape sounds the chord it claims', () {
      // The one that catches a typo in a fret number — the fault a reader
      // cannot see and a player finds on stage.
      final wrong = <String>[];
      for (final instrument in library.instruments) {
        for (final shape in instrument.shapes) {
          final want = <int>{
            for (final tone in tones[shape.type]!)
              (rootOf(instrument, shape) + tone) % 12,
          };
          final got = shape.pitchClasses(instrument.tuning);
          if (got.isEmpty || !got.every(want.contains)) {
            wrong.add('${instrument.id} $shape sounds $got, wants $want');
          }
        }
      }
      expect(wrong, isEmpty);
    });

    test('every shape states the notes that name the chord', () {
      // The fifth may be dropped; the third and the seventh may not. A bass
      // diagram is the exception — it shows the root and the fifth, which is
      // what a player checks.
      final thin = <String>[];
      for (final instrument in library.instruments) {
        for (final shape in instrument.shapes) {
          final root = rootOf(instrument, shape);
          final essential = instrument.id == 'bass'
              ? <int>{root}
              : <int>{
                  for (final tone in tones[shape.type]!)
                    if (tone != 7) (root + tone) % 12,
                };
          final got = shape.pitchClasses(instrument.tuning);
          if (!essential.every(got.contains)) {
            thin.add('${instrument.id} $shape is missing part of its chord');
          }
        }
      }
      expect(thin, isEmpty);
    });

    test('every shape is playable by a hand', () {
      for (final instrument in library.instruments) {
        for (final shape in instrument.shapes) {
          expect(shape.span, lessThanOrEqualTo(4), reason: '$shape spans wide');
          expect(
            shape.fingeredStrings,
            lessThanOrEqualTo(4),
            reason: '$shape needs ${shape.fingeredStrings} fingers',
          );
        }
      }
    });

    test('a movable shape has no open strings, and names its root string', () {
      for (final instrument in library.instruments) {
        for (final shape in instrument.shapes) {
          if (shape.root == null) {
            expect(shape.hasOpenStrings, isFalse, reason: '$shape');
            expect(shape.rootString, isNotNull, reason: '$shape');
            expect(shape.isMovable, isTrue, reason: '$shape');
          }
        }
      }
    });

    test('every shape has one fret per string', () {
      for (final instrument in library.instruments) {
        for (final shape in instrument.shapes) {
          expect(shape.stringCount, instrument.stringCount, reason: '$shape');
        }
      }
    });

    test('the three instruments are there, tuned as they should be', () {
      expect(library['guitar']!.tuning, <int>[40, 45, 50, 55, 59, 64]);
      // The ukulele's G is above its C — re-entrant.
      expect(library['ukulele']!.tuning, <int>[67, 60, 64, 69]);
      expect(
        library['ukulele']!.tuning.first,
        greaterThan(library['ukulele']!.tuning[1]),
      );
      expect(library['bass']!.tuning, <int>[28, 33, 38, 43]);
    });
  });

  group('looking a chord up', () {
    test('every common type resolves on guitar, in all twelve keys', () {
      const common = <String>['', 'm', '7', 'maj7', 'm7', 'm7b5', 'o7', '6'];
      const roots = <String>[
        'C', 'Db', 'D', 'Eb', 'E', 'F', 'Gb', 'G', 'Ab', 'A', 'Bb', 'B', //
      ];
      final missing = <String>[];
      for (final root in roots) {
        for (final type in common) {
          final chord = ChordSymbol.parse('$root$type');
          if (library.shapeFor('guitar', chord) == null) {
            missing.add('$root$type');
          }
        }
      }
      expect(missing, isEmpty);
    });

    test('a resolved shape really sounds the chord asked for', () {
      // The end-to-end check: an open shape is used as stored, and a movable
      // one is slid so its root string carries the right note. Getting the
      // slide wrong is silent, and this is what would catch it.
      const roots = <String>[
        'C', 'Db', 'D', 'Eb', 'E', 'F', 'Gb', 'G', 'Ab', 'A', 'Bb', 'B', //
      ];
      for (final instrumentId in <String>['guitar', 'ukulele']) {
        final instrument = library[instrumentId]!;
        for (final root in roots) {
          for (final type in <String>['', 'm', '7', 'maj7', 'm7']) {
            final chord = ChordSymbol.parse('$root$type');
            final shape = library.shapeFor(instrumentId, chord);
            if (shape == null) {
              continue;
            }
            final want = <int>{
              for (final tone in tones[type]!)
                (chord.root.pitchClass + tone) % 12,
            };
            final got = shape.pitchClasses(instrument.tuning);
            expect(
              got.every(want.contains),
              isTrue,
              reason:
                  '$instrumentId $root$type resolved to $shape, which '
                  'sounds $got but should be inside $want',
            );
            expect(
              got.contains(chord.root.pitchClass),
              isTrue,
              reason: '$instrumentId $root$type does not sound its root',
            );
          }
        }
      }
    });

    test('an open shape is preferred to sliding one', () {
      // A guitarist plays open C, not a barre at fret 3.
      final open = library.shapeFor('guitar', ChordSymbol.parse('C'))!;
      expect(open.hasOpenStrings, isTrue);
      expect(open.baseFret, 1);
    });

    test('a movable shape lands somewhere a hand goes', () {
      // Never above the twelfth fret: a guitarist plays Bbmaj7 at fret 6, not
      // at fret 18 (§3).
      for (final root in <String>['Bb', 'B', 'Ab']) {
        final shape = library.shapeFor(
          'guitar',
          ChordSymbol.parse('${root}m9'),
        );
        expect(shape, isNotNull, reason: '$root m9 has no shape at all');
        expect(shape!.baseFret, inInclusiveRange(1, 12), reason: '$root m9');
      }
    });

    test('a chord with no shape says so rather than guessing', () {
      // `13b9#11` is not in the table, and a wrong diagram is worse than none.
      expect(library.shapeFor('guitar', ChordSymbol.parse('C13b9#11')), isNull);
      expect(library.shapeFor('nonesuch', ChordSymbol.parse('C')), isNull);
    });
  });

  group('the model refuses what it cannot draw', () {
    test('an open shape with no root', () {
      expect(
        () => ChordShape(type: '', frets: <int>[0, 2, 2, 1, 0, 0]),
        throwsArgumentError,
      );
    });

    test('a movable shape with no root string', () {
      expect(
        () => ChordShape(type: '', frets: <int>[1, 3, 3, 2, 1, 1]),
        throwsArgumentError,
      );
    });

    test('a root on a muted string', () {
      expect(
        () => ChordShape(
          type: '',
          frets: <int>[-1, 3, 3, 2, 1, 1],
          rootString: 0,
        ),
        throwsArgumentError,
      );
    });

    test('a fret off the neck, or a base fret that is not one', () {
      expect(
        () => ChordShape(type: '', frets: <int>[1, 99], rootString: 0),
        throwsArgumentError,
      );
      expect(
        () => ChordShape(
          type: '',
          frets: <int>[1, 2],
          baseFret: 0,
          rootString: 0,
        ),
        throwsArgumentError,
      );
    });

    test('a shape whose frets and base fret together reach past the 24th', () {
      // Each bound holds on its own — every fret is 1..24, the base fret is
      // 1..20 — but base 20 with a 10th-fret stop lands on fret 29.
      expect(
        () => ChordShape(
          type: '',
          frets: <int>[1, 10],
          baseFret: 20,
          rootString: 0,
        ),
        throwsArgumentError,
      );
      // The same numbers an octave lower are fine.
      expect(
        ChordShape(type: '', frets: <int>[1, 10], baseFret: 8, rootString: 0),
        isNotNull,
      );
    });

    test('an instrument whose shapes do not fit its strings', () {
      expect(
        () => DiagramInstrument(
          id: 'four',
          displayName: 'Four',
          tuning: <int>[40, 45, 50, 55],
          shapes: <ChordShape>[
            ChordShape(type: '', frets: <int>[1, 3, 3, 2, 1, 1], rootString: 0),
          ],
        ),
        throwsArgumentError,
      );
    });

    test('two instruments sharing an id', () {
      DiagramInstrument one() => DiagramInstrument(
        id: 'same',
        displayName: 'Same',
        tuning: <int>[40],
        shapes: <ChordShape>[
          ChordShape(type: '', frets: <int>[1], rootString: 0),
        ],
      );
      expect(
        () => ChordDiagramLibrary(<DiagramInstrument>[one(), one()]),
        throwsArgumentError,
      );
    });
  });

  group('the codec', () {
    test('a schema version this build does not know is refused', () {
      expect(
        () => ChordDiagramLibrary.fromJson(
          '{"schemaVersion": 99, "instruments": []}',
        ),
        throwsFormatException,
      );
    });

    test('a shape with the wrong number of frets names its instrument', () {
      expect(
        () => ChordDiagramLibrary.fromJson('''
{"schemaVersion": 1, "instruments": [
  {"id": "guitar", "tuning": [40, 45], "shapes": [
    {"type": "", "frets": [1, 2, 3], "rootString": 0}
  ]}
]}
'''),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('guitar'),
          ),
        ),
      );
    });
  });

  group('the fret bound counts the barre', () {
    test('a barre past the 24th fret is refused', () {
      // The bound was derived from `highestFret`, which comes from the
      // stopped strings alone — so a barre above every stopped fret was never
      // counted. `baseFret: 20` with a barre at 10 passed validation while
      // sounding at the 29th fret of an instrument that has 24.
      expect(
        () => ChordShape(
          type: 'maj7',
          rootString: 0,
          baseFret: 20,
          frets: const <int>[1, 1, 1, 1, 1, 1],
          barre: Barre(fret: 10, fromString: 0, toString_: 5),
        ),
        throwsArgumentError,
      );
    });

    test('reach is the higher of the stopped frets and the barre', () {
      final shape = ChordShape(
        type: 'maj7',
        rootString: 0,
        baseFret: 1,
        frets: const <int>[1, 1, 1, 1, 1, 1],
        barre: Barre(fret: 4, fromString: 0, toString_: 5),
      );
      expect(shape.highestFret, 1);
      expect(shape.reach, 4);
    });

    test('transposing stops where the barre would run off the neck', () {
      final shape = ChordShape(
        type: 'maj7',
        rootString: 0,
        baseFret: 1,
        frets: const <int>[1, 1, 1, 1, 1, 1],
        barre: Barre(fret: 22, fromString: 0, toString_: 5),
      );
      // Base 1 with a reach of 22 fits; base 12 would reach the 33rd fret.
      expect(shape.transposed(11), isNull);
    });
  });

  group('a scale names each degree once', () {
    test('a repeated degree is refused, as it is for a chord type', () {
      // `ChordType` has always rejected this; its sibling did not, so a typo
      // in the table became a scale whose note count did not match its name.
      expect(
        () => StandardScale(
          name: 'Broken',
          aliases: const <String>['broken'],
          degrees: <Degree>[
            Degree.parse('1'),
            Degree.parse('2'),
            Degree.parse('2'),
          ],
          preferredFor: const <String>[],
        ),
        throwsArgumentError,
      );
    });

    test('a scale with distinct degrees is fine', () {
      expect(
        StandardScale(
          name: 'Whole tone',
          aliases: const <String>['whole tone'],
          degrees: <Degree>[
            Degree.parse('1'),
            Degree.parse('2'),
            Degree.parse('3'),
          ],
          preferredFor: const <String>[],
        ).degrees,
        hasLength(3),
      );
    });
  });
}
