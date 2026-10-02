import 'package:bandstand/domain/generation/bass/root_profile.dart';
import 'package:bandstand/domain/generation/bass/wbp_source.dart';
import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../harmony/harmony_test_support.dart';

/// A walking phrase: a pitch per beat over one chord per bar.
WbpSource walking(
  String name,
  List<String> chords,
  List<int> pitches, {
  TempoRange? tempoRange,
  BassRange range = const BassRange(),
}) => WbpSource(
  name: name,
  harmony: <BassChordSpan>[
    for (final (index, symbol) in chords.indexed)
      BassChordSpan((index * 4).toDouble(), 4, ExtChordSymbol.parse(symbol)),
  ],
  notes: <BassNoteSpec>[
    for (final (index, pitch) in pitches.indexed)
      BassNoteSpec(beat: index.toDouble(), pitch: pitch),
  ],
  tempoRange: tempoRange,
  range: range,
);

void main() {
  installTestHarmony();

  group('derived statistics', () {
    final phrase = walking(
      'ii-V',
      <String>['Dm7', 'G7'],
      <int>[
        38, 41, 45, 48, //
        47, 45, 43, 41,
      ],
    );

    test('length, extremes and profile come from the notes and harmony', () {
      expect(phrase.lengthBars, 2);
      expect(phrase.lengthBeats, 8);
      expect(phrase.lowestPitch, 38);
      expect(phrase.highestPitch, 48);
      expect(phrase.rootProfile.toString(), '+0m7 +57');
      expect(phrase.firstRootPitchClass, 2);
    });

    test('the constraints of §5 are answered', () {
      expect(phrase.startsOnRoot, isTrue);
      expect(phrase.endsOnChordTone, isTrue);
      expect(phrase.isPlayable, isTrue);
    });

    test('a phrase starting on the third is not playable', () {
      // §5 constraint 1: it was played as a continuation, and using it as a
      // phrase start sounds like a mistake.
      final third = walking(
        'bad start',
        <String>['Dm7'],
        <int>[41, 43, 45, 48],
      );
      expect(third.startsOnRoot, isFalse);
      expect(third.isPlayable, isFalse);
    });

    test('a phrase ending off the chord is not playable', () {
      final off = walking('bad end', <String>['Dm7'], <int>[38, 40, 41, 43]);
      expect(off.endsOnChordTone, isFalse);
      expect(off.isPlayable, isFalse);
    });

    test('the chord sounding at a beat follows the harmony', () {
      expect(phrase.chordAt(0).format(), 'Dm7');
      expect(phrase.chordAt(3.9).format(), 'Dm7');
      expect(phrase.chordAt(4).format(), 'G7');
      expect(phrase.chordAt(99).format(), 'G7');
    });

    test('notes are sorted, however they arrive', () {
      final scrambled = WbpSource(
        name: 'scrambled',
        harmony: <BassChordSpan>[
          BassChordSpan(0, 4, ExtChordSymbol.parse('Dm7')),
        ],
        notes: <BassNoteSpec>[
          BassNoteSpec(beat: 3, pitch: 48),
          BassNoteSpec(beat: 0, pitch: 38),
          BassNoteSpec(beat: 2, pitch: 45),
          BassNoteSpec(beat: 1, pitch: 41),
        ],
      );
      expect(scrambled.notes.map((note) => note.pitch), <int>[38, 41, 45, 48]);
      expect(scrambled.startsOnRoot, isTrue);
    });
  });

  group('harmonic fit (§4.1)', () {
    test('an all-chord-tone phrase scores full marks', () {
      final arpeggio = walking(
        'arpeggio',
        <String>['Dm7'],
        <int>[38, 41, 45, 48],
      );
      expect(arpeggio.harmonicFit, 1.0);
    });

    test('a chromatic note on a strong beat costs much more than on a weak', () {
      // The substance of walking bass is chromatic notes on weak beats, so the
      // two must not be graded the same.
      final weak = walking('weak', <String>['Dm7'], <int>[38, 39, 45, 48]);
      final strong = walking('strong', <String>['Dm7'], <int>[38, 41, 39, 48]);
      expect(weak.harmonicFit, greaterThan(strong.harmonicFit));
      expect(weak.harmonicFit, greaterThan(0.9));
      expect(strong.harmonicFit, lessThan(0.8));
    });

    test('strong beats follow the meter, not a hardcoded 4/4 grid', () {
      // Beat 3 of a 3/4 bar is weak: a chromatic passing note there is the
      // substance of a walking line. On a 4/4 grid (beat index 2) it would
      // grade strong and cost 0.1 instead of earning 0.8.
      WbpSource waltz(String name, List<int> pitches) => WbpSource(
        name: name,
        harmony: <BassChordSpan>[
          BassChordSpan(0, 3, ExtChordSymbol.parse('Dm7')),
        ],
        notes: <BassNoteSpec>[
          for (final (index, pitch) in pitches.indexed)
            BassNoteSpec(beat: index.toDouble(), pitch: pitch),
        ],
      );
      final chromaticOnBeatThree = waltz('beat three', <int>[38, 40, 39]);
      expect(chromaticOnBeatThree.harmonicFit, closeTo(0.9, 1e-9));

      // In 6/8 the bar's divisions — beats 1 and 4 — are strong, so the
      // chromatic note on beat 4 costs the strong-beat price there.
      final compound = WbpSource(
        name: 'six eight',
        harmony: <BassChordSpan>[
          BassChordSpan(0, 6, ExtChordSymbol.parse('Dm7')),
        ],
        notes: <BassNoteSpec>[
          for (final (index, pitch) in <int>[38, 40, 41, 39, 43, 45].indexed)
            BassNoteSpec(beat: index.toDouble(), pitch: pitch),
        ],
      );
      // Fit = (1 + 0.9 + 1 + 0.1 + 0.9 + 1) / 6: beat 4 (index 3) is strong.
      expect(
        compound.harmonicFit,
        closeTo((1 + 0.9 + 1 + 0.1 + 0.9 + 1) / 6, 1e-9),
      );
    });

    test('it is invariant under transposition, which is why it is cached', () {
      // §4.1 — the match requires an identical root profile and transposition
      // preserves every interval, so this term scores the corpus, not the
      // placement.
      final inD = walking(
        'in D',
        <String>['Dm7', 'G7'],
        <int>[
          38, 40, 41, 42, //
          43, 45, 47, 50,
        ],
      );
      final inF = walking(
        'in F',
        <String>['Fm7', 'Bb7'],
        <int>[
          41, 43, 44, 45, //
          46, 48, 50, 53,
        ],
      );
      expect(inF.harmonicFit, closeTo(inD.harmonicFit, 1e-9));
    });
  });

  group('transposibility (§8)', () {
    test('a narrow phrase reaches every root', () {
      final narrow = walking('narrow', <String>['Dm7'], <int>[38, 41, 45, 48]);
      expect(narrow.reachableRootCount, 12);
      for (var root = 0; root < 12; root++) {
        expect(narrow.canReach(root), isTrue, reason: 'root $root');
      }
    });

    test('every transposition it offers really does fit the range', () {
      final phrase = walking('wide', <String>['Cmaj7'], <int>[36, 43, 48, 52]);
      for (var root = 0; root < 12; root++) {
        for (final transposition in phrase.transpositionsTo(root)) {
          expect(phrase.lowestPitch + transposition, greaterThanOrEqualTo(28));
          expect(phrase.highestPitch + transposition, lessThanOrEqualTo(55));
          // And it lands on the root it claims to.
          expect((phrase.firstNote.pitch + transposition) % 12, root);
        }
      }
    });

    test('a phrase too wide for the instrument reaches nothing', () {
      // Four octaves will not fit in E1..G3 at any root, and the map says so
      // rather than the tiler finding out by scoring twelve candidates.
      final huge = walking('huge', <String>['Cmaj7'], <int>[24, 48, 72, 96]);
      expect(huge.reachableRootCount, 0);
      expect(huge.transpositionsTo(0), isEmpty);
    });

    test('a phrase with one octave at a root offers exactly one', () {
      // The case M0.5 finding 4 was about: no freedom, so §5.4 has to be able
      // to reject it rather than accept its seam.
      final tall = walking('tall', <String>['Cmaj7'], <int>[36, 43, 48, 52]);
      final counts = <int>[
        for (var root = 0; root < 12; root++)
          tall.transpositionsTo(root).length,
      ];
      expect(counts.every((count) => count >= 1), isTrue);
      expect(counts.any((count) => count == 1), isTrue);
    });

    test('a root is asked for modulo twelve', () {
      final phrase = walking('any', <String>['Dm7'], <int>[38, 41, 45, 48]);
      expect(phrase.transpositionsTo(14), phrase.transpositionsTo(2));
    });
  });

  group('tempo range (§9)', () {
    test('no declared range means usable anywhere', () {
      final phrase = walking(
        'any tempo',
        <String>['Dm7'],
        <int>[38, 41, 45, 48],
      );
      expect(phrase.tempoRange.admits(40), isTrue);
      expect(phrase.tempoRange.admits(320), isTrue);
    });

    test('a declared range excludes what is outside it', () {
      final phrase = walking(
        'ballad',
        <String>['Dm7'],
        <int>[38, 41, 45, 48],
        tempoRange: TempoRange(60, 120),
      );
      expect(phrase.tempoRange.admits(59), isFalse);
      expect(phrase.tempoRange.admits(60), isTrue);
      expect(phrase.tempoRange.admits(120), isTrue);
      expect(phrase.tempoRange.admits(121), isFalse);
    });

    test('a backwards range is refused', () {
      expect(() => TempoRange(200, 100), throwsArgumentError);
      expect(() => TempoRange(0, 100), throwsArgumentError);
    });
  });

  group('malformed phrases are refused', () {
    test('a phrase with no notes', () {
      expect(
        () => WbpSource(
          name: 'empty',
          harmony: <BassChordSpan>[
            BassChordSpan(0, 4, ExtChordSymbol.parse('Dm7')),
          ],
          notes: const <BassNoteSpec>[],
        ),
        throwsArgumentError,
      );
    });

    test('a phrase with no harmony', () {
      expect(
        () => WbpSource(
          name: 'no harmony',
          harmony: const <BassChordSpan>[],
          notes: <BassNoteSpec>[BassNoteSpec(beat: 0, pitch: 38)],
        ),
        throwsArgumentError,
      );
    });

    test('a note past the end of the harmony', () {
      expect(
        () => WbpSource(
          name: 'overhang',
          harmony: <BassChordSpan>[
            BassChordSpan(0, 4, ExtChordSymbol.parse('Dm7')),
          ],
          notes: <BassNoteSpec>[BassNoteSpec(beat: 4, pitch: 38)],
        ),
        throwsArgumentError,
      );
    });

    test('a note outside MIDI range, or with no length', () {
      expect(() => BassNoteSpec(beat: 0, pitch: 200), throwsArgumentError);
      expect(() => BassNoteSpec(beat: -1, pitch: 38), throwsArgumentError);
      expect(
        () => BassNoteSpec(beat: 0, pitch: 38, durationBeats: 0),
        throwsArgumentError,
      );
      expect(
        () => BassNoteSpec(beat: 0, pitch: 38, velocity: 0),
        throwsArgumentError,
      );
    });
  });
}
