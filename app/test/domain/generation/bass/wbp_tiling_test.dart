import 'dart:io';

import 'package:bandstand/domain/generation/bass/bass_corpus.dart';
import 'package:bandstand/domain/generation/bass/bass_corpus_codec.dart';
import 'package:bandstand/domain/generation/bass/root_profile.dart';
import 'package:bandstand/domain/generation/bass/wbp_scorer.dart';
import 'package:bandstand/domain/generation/bass/wbp_source.dart';
import 'package:bandstand/domain/generation/bass/wbp_tiling.dart';
import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../harmony/harmony_test_support.dart';

WbpSource walking(String name, List<String> chords, List<int> pitches) =>
    WbpSource(
      name: name,
      harmony: <BassChordSpan>[
        for (final (index, symbol) in chords.indexed)
          BassChordSpan(
            (index * 4).toDouble(),
            4,
            ExtChordSymbol.parse(symbol),
          ),
      ],
      notes: <BassNoteSpec>[
        for (final (index, pitch) in pitches.indexed)
          BassNoteSpec(beat: index.toDouble(), pitch: pitch),
      ],
    );

BassProgression progression(List<String> bars) =>
    BassProgression(bars.map(ExtChordSymbol.parse));

void main() {
  installTestHarmony();

  final shipped = BassCorpusCodec.decode(
    File('assets/bass_corpus.json').readAsStringSync(),
  );

  /// Three choruses of a 32-bar AABA — the form M0.5 ran on.
  BassProgression aaba({int choruses = 1}) {
    const a = <String>[
      'Cmaj7', 'A7', 'Dm7', 'G7', 'Cmaj7', 'A7', 'Dm7', 'G7', //
    ];
    const b = <String>[
      'Cmaj7', 'Cmaj7', 'Dm7', 'G7', 'Cmaj7', 'A7', 'Dm7', 'G7', //
    ];
    return progression(<String>[
      for (var chorus = 0; chorus < choruses; chorus++) ...<String>[
        ...a,
        ...a,
        ...b,
        ...a,
      ],
    ]);
  }

  group('placing a phrase', () {
    test('it covers the bars it claims and lands on the right pitches', () {
      final corpus = BassCorpus(
        name: 'one',
        phrases: <WbpSource>[
          walking(
            'ii-V',
            <String>['Dm7', 'G7'],
            <int>[
              38, 41, 45, 48, //
              47, 45, 43, 41,
            ],
          ),
        ],
      );
      final tiling = WbpTiler(
        corpus: corpus,
        tempo: 160,
      ).tile(progression(<String>['Dm7', 'G7']));

      expect(tiling.placements, hasLength(1));
      expect(tiling.gaps, isEmpty);
      final placement = tiling.placements.single;
      expect(placement.startBar, 0);
      expect(placement.endBar, 2);
      expect(placement.transposition % 12, 0);
      expect(tiling.notes(4), hasLength(8));
      expect(tiling.notes(4).first.beat, 0);
      expect(tiling.notes(4).last.beat, 7);
    });

    test('a phrase is transposed onto the key the chart asks for', () {
      final corpus = BassCorpus(
        name: 'one',
        phrases: <WbpSource>[
          walking(
            'ii-V',
            <String>['Dm7', 'G7'],
            <int>[
              38, 41, 45, 48, //
              47, 45, 43, 41,
            ],
          ),
        ],
      );
      // Fm7 is three semitones above Dm7.
      final tiling = WbpTiler(
        corpus: corpus,
        tempo: 160,
      ).tile(progression(<String>['Fm7', 'Bb7']));
      final first = tiling.notes(4).first;
      expect(first.pitch % 12, 5, reason: 'lands on F');
      expect(tiling.placements.single.transposition % 12, 3);
    });

    test('every note of a tiling stays inside the instrument', () {
      final tiling = WbpTiler(
        corpus: shipped,
        tempo: 160,
      ).tile(aaba(choruses: 3));
      for (final note in tiling.notes(4)) {
        expect(
          note.pitch,
          inInclusiveRange(shipped.range.lowest, shipped.range.highest),
        );
      }
    });

    test('placements cover the form end to end with no gap or overlap', () {
      final form = aaba(choruses: 3);
      final tiling = WbpTiler(corpus: shipped, tempo: 160).tile(form);
      var expected = 0;
      for (final placement in tiling.placements) {
        expect(placement.startBar, expected);
        expected = placement.endBar;
      }
      expect(expected, form.barCount);
    });
  });

  group('M0.5 finding 1 — longest-first must not collapse', () {
    test('three choruses do not become a four-placement loop', () {
      // The first probe implementation always took the longest match, so five
      // four-bar phrases covered everything and the result repeated every 16
      // bars. That is the failure this whole rule exists to prevent.
      final tiling = WbpTiler(
        corpus: shipped,
        tempo: 160,
      ).tile(aaba(choruses: 3));
      expect(tiling.placements.length, greaterThan(12));
      expect(tiling.distinctPhrases, greaterThan(8));
    });

    test('no phrase is reused inside the freshness window', () {
      const window = 6;
      final tiling = WbpTiler(
        corpus: shipped,
        tempo: 160,
        reuseWindow: window,
      ).tile(aaba(choruses: 3));

      final lastSeen = <String, int>{};
      final tooSoon = <String>[];
      for (final (index, placement) in tiling.placements.indexed) {
        final previous = lastSeen[placement.name];
        if (previous != null && index - previous <= window) {
          tooSoon.add('${placement.name} at $index, last at $previous');
        }
        lastSeen[placement.name] = index;
      }
      // §6.2 forbids reuse within the window; §6.3's escape hatch permits it
      // only when every length is stale. This asserts the stricter property —
      // no reuse at all inside the window — which the shipped corpus is deep
      // enough to achieve over three choruses without the hatch.
      expect(tooSoon, isEmpty);
    });

    test(
      'a phrase heard exactly reuseWindow placements ago is fresh (§6.2)',
      () {
        // Q outranks P outranks R on harmonic fit alone (all chord tones vs. a
        // scale passing note vs. a chromatic passing note on a weak beat);
        // their first and last pitches are identical, so join and register
        // score the same and the ranking is exact. With reuseWindow 1 the bar-2
        // decision is between Q — heard one placement back, at the window's
        // edge — and fresh R: §6.2 takes Q. An off-by-one window makes Q stale
        // there and the tiler falls back to R.
        final corpus = BassCorpus(
          name: 'edge',
          phrases: <WbpSource>[
            walking('Q', <String>['Cmaj7'], <int>[36, 40, 43, 47]),
            walking('P', <String>['Cmaj7'], <int>[36, 38, 43, 47]),
            walking('R', <String>['Cmaj7'], <int>[36, 42, 40, 47]),
          ],
        );
        final tiling = WbpTiler(
          corpus: corpus,
          tempo: 160,
          reuseWindow: 1,
        ).tile(progression(<String>['Cmaj7', 'Cmaj7', 'Cmaj7', 'Cmaj7']));
        expect(
          tiling.placements.map((placement) => placement.name).toList(),
          <String>['Q', 'P', 'Q', 'P'],
        );
      },
    );
  });

  group('§11 — the chooser must value variety, not only smoothness', () {
    test('quality is mean score less a repetition penalty', () {
      final smooth = WbpTiler(
        corpus: shipped,
        tempo: 160,
        strategy: TilingStrategy.longestFirst,
      ).tile(aaba(choruses: 3));
      final varied = WbpTiler(
        corpus: shipped,
        tempo: 160,
        strategy: TilingStrategy.maximumDistanceBetweenReuses,
      ).tile(aaba(choruses: 3));

      // Measured, not supposed: the smooth tiler wins on mean score using
      // barely half the phrases. A generator ranking on mean score alone picks
      // the line that repeats, which §10 of the plan forbids over three
      // choruses.
      expect(smooth.meanScore, greaterThan(varied.meanScore));
      expect(varied.distinctPhrases, greaterThan(smooth.distinctPhrases));
      expect(varied.quality, greaterThan(smooth.quality));
    });

    test('a line that never repeats pays no penalty', () {
      final tiling = WbpTiler(
        corpus: shipped,
        tempo: 160,
      ).tile(progression(<String>['Dm7', 'G7', 'Cmaj7', 'Cmaj7']));
      expect(tiling.distinctPhrases, tiling.placements.length);
      expect(tiling.repetitionPenalty, 0);
      expect(tiling.quality, tiling.meanScore);
    });
  });

  group('M0.5 finding 2 — freshness gates, score ranks', () {
    test('the widest join stays inside a musical bound', () {
      // Ranking by recency first produced a 14-semitone join in the probe.
      for (final strategy in TilingStrategy.values) {
        final tiling = WbpTiler(
          corpus: shipped,
          tempo: 160,
          strategy: strategy,
        ).tile(aaba(choruses: 3));
        expect(tiling.widestJoin, lessThanOrEqualTo(10), reason: '$strategy');
      }
    });

    test('no tiling ever exceeds the hard interval gate (§5.4)', () {
      // A wide leap is a constraint, not a score: full marks on contour,
      // approach and landing drag a 14-semitone join's blend to 0.65, well
      // clear of the seam floor, so the floor alone does not catch it.
      for (final tempo in <int>[80, 160, 300]) {
        for (final strategy in TilingStrategy.values) {
          final tiling = WbpTiler(
            corpus: shipped,
            tempo: tempo,
            strategy: strategy,
          ).tile(aaba(choruses: 3));
          expect(
            tiling.widestJoin,
            lessThanOrEqualTo(WbpScorer.maximumJoinInterval),
            reason: '$strategy at $tempo',
          );
        }
      }
    });

    test('the mean placement score is high across a whole form', () {
      final tiling = WbpTiler(
        corpus: shipped,
        tempo: 160,
      ).tile(aaba(choruses: 3));
      expect(tiling.meanScore, greaterThan(0.8));
    });
  });

  group('M0.5 finding 4 — a bad seam is rejected, not accepted (§5.4)', () {
    test('a phrase whose only octave makes a bad seam is passed over', () {
      // "tall" spans 19 semitones, so at C it has exactly one octave and no
      // freedom; "narrow" can be placed wherever it joins best.
      final corpus = BassCorpus(
        name: 'seam',
        phrases: <WbpSource>[
          walking('lead-in', <String>['G7'], <int>[31, 33, 35, 36]),
          walking('tall', <String>['Cmaj7'], <int>[36, 43, 48, 55]),
          walking('narrow', <String>['Cmaj7'], <int>[36, 38, 40, 43]),
        ],
      );
      final tiling = WbpTiler(
        corpus: corpus,
        tempo: 160,
      ).tile(progression(<String>['G7', 'Cmaj7']));
      expect(tiling.placements, hasLength(2));
      // Whichever it picked, the seam it accepted must be a musical one.
      expect(tiling.widestJoin, lessThanOrEqualTo(7));
    });

    test('a candidate below the seam floor is not placed at all', () {
      // The only phrase available at bar 2 joins by 24 semitones however it is
      // placed, so the tiler must report a gap rather than accept the stitch.
      final corpus = BassCorpus(
        name: 'floor',
        phrases: <WbpSource>[
          walking('low lead-in', <String>['G7'], <int>[31, 30, 29, 28]),
          walking('one octave only', <String>['Cmaj7'], <int>[48, 50, 52, 55]),
        ],
      );
      final tiling = WbpTiler(
        corpus: corpus,
        tempo: 160,
      ).tile(progression(<String>['G7', 'Cmaj7']));
      expect(tiling.fallbackBars, 1);
      expect(tiling.gaps, hasLength(1));
    });
  });

  group('§11 — failure is reported, never thrown', () {
    test('an uncoverable chord becomes a root-and-fifth bar and a gap', () {
      final corpus = BassCorpus(
        name: 'thin',
        phrases: <WbpSource>[
          walking('major bar', <String>['Cmaj7'], <int>[36, 40, 43, 47]),
        ],
      );
      final tiling = WbpTiler(
        corpus: corpus,
        tempo: 160,
      ).tile(progression(<String>['Cmaj7', 'F#m7b5']));

      expect(tiling.placements, hasLength(2));
      expect(tiling.fallbackBars, 1);
      expect(tiling.gaps, hasLength(1));
      expect(tiling.gaps.single, contains('bar 2'));
      expect(tiling.gaps.single, contains('F#m7b5'));
    });

    test('the fallback plays the root and a chord tone, in range', () {
      final tiling = WbpTiler(
        corpus: BassCorpus.empty(),
        tempo: 160,
      ).tile(progression(<String>['Cmaj7']));
      final notes = tiling.notes(4);
      expect(notes, hasLength(4));
      expect(notes.first.pitch % 12, 0, reason: 'starts on the root');
      for (final note in notes) {
        expect(note.pitch, inInclusiveRange(28, 55));
      }
      // Root and fifth, alternating — deliberately dull, so the gap is audible.
      expect(notes.map((note) => note.pitch % 12).toSet(), <int>{0, 7});
    });

    test(
      'the fallback stays in range when the range is under an octave wide',
      () {
        // One -12 correction is not always enough: with E's fifth at the top of
        // a 40..45 range, a single wrap lands below the range's floor.
        final corpus = BassCorpus(
          name: 'narrow',
          phrases: const <WbpSource>[],
          range: const BassRange(lowest: 40, highest: 45),
        );
        final tiling = WbpTiler(
          corpus: corpus,
          tempo: 160,
        ).tile(progression(<String>['E7']));
        for (final note in tiling.notes(4)) {
          expect(note.pitch, inInclusiveRange(40, 45));
        }
      },
    );

    test(
      'a diminished chord does not get a perfect fifth it does not have',
      () {
        final tiling = WbpTiler(
          corpus: BassCorpus.empty(),
          tempo: 160,
        ).tile(progression(<String>['Co7']));
        final classes = tiling.notes(4).map((note) => note.pitch % 12).toSet();
        expect(classes, isNot(contains(7)), reason: 'Co7 has no perfect fifth');
      },
    );

    test('an empty corpus yields a gap for every bar rather than throwing', () {
      final tiling = WbpTiler(
        corpus: BassCorpus.empty(),
        tempo: 160,
      ).tile(progression(<String>['Cmaj7', 'A7', 'Dm7', 'G7']));
      expect(tiling.fallbackBars, 4);
      expect(tiling.gaps, hasLength(4));
      expect(tiling.meanScore, 0);
    });
  });

  group('the two strategies (§11)', () {
    test('both cover the form completely', () {
      for (final strategy in TilingStrategy.values) {
        final tiling = WbpTiler(
          corpus: shipped,
          tempo: 160,
          strategy: strategy,
        ).tile(aaba(choruses: 3));
        expect(tiling.fallbackBars, 0, reason: '$strategy');
        expect(tiling.placements.last.endBar, 96, reason: '$strategy');
      }
    });

    test('maximum-distance spreads the corpus at least as wide', () {
      final smooth = WbpTiler(
        corpus: shipped,
        tempo: 160,
        strategy: TilingStrategy.longestFirst,
      ).tile(aaba(choruses: 3));
      final varied = WbpTiler(
        corpus: shipped,
        tempo: 160,
        strategy: TilingStrategy.maximumDistanceBetweenReuses,
      ).tile(aaba(choruses: 3));
      expect(
        varied.distinctPhrases,
        greaterThanOrEqualTo(smooth.distinctPhrases),
      );
    });
  });

  group('determinism (§6.2)', () {
    test('the same corpus and progression give the same line, every time', () {
      final form = aaba(choruses: 2);
      List<int> run() => WbpTiler(
        corpus: shipped,
        tempo: 160,
      ).tile(form).notes(4).map((note) => note.pitch).toList();
      expect(run(), run());
      expect(run(), run());
    });

    test('tempo changes the line, because §9 says it should', () {
      final form = aaba();
      String run(int tempo) => WbpTiler(
        corpus: shipped,
        tempo: tempo,
      ).tile(form).placements.map((placement) => placement.name).join('|');
      // §9 sharpens the penalty on wide joins as tempo rises, so a form with
      // register choices must tile differently at a ballad tempo than at a
      // burner — and each tempo must be reproducible.
      expect(run(90), run(90));
      expect(run(280), run(280));
      expect(run(90), isNot(run(280)));
    });
  });

  group('BassProgression', () {
    test('a profile is taken over a window of bars', () {
      final form = progression(<String>['Cmaj7', 'A7', 'Dm7', 'G7']);
      expect(form.profileAt(0, 2).toString(), '+0maj7 +97');
      expect(form.profileAt(2, 2).toString(), '+0m7 +57');
      expect(form.rootAt(2), 2);
    });

    test('an empty progression is refused', () {
      expect(
        () => BassProgression(const <ExtChordSymbol>[]),
        throwsArgumentError,
      );
    });
  });
}
