import 'package:bandstand/domain/generation/bass/root_profile.dart';
import 'package:bandstand/domain/generation/bass/wbp_scorer.dart';
import 'package:bandstand/domain/generation/bass/wbp_source.dart';
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

void main() {
  installTestHarmony();

  final scorer = WbpScorer(tempo: 160);

  group('interval score (§7.1)', () {
    test('a step is the strongest join there is', () {
      expect(scorer.intervalScore(1), 1.0);
      expect(scorer.intervalScore(-2), 1.0);
    });

    test('it falls away monotonically as the leap widens', () {
      final scores = <double>[
        for (final interval in <int>[1, 3, 6, 8, 13])
          scorer.intervalScore(interval),
      ];
      for (var i = 1; i < scores.length; i++) {
        expect(scores[i], lessThan(scores[i - 1]), reason: 'step $i');
      }
    });

    test('a repeated note is penalised, but less than a wide leap', () {
      // §4.2 — not wrong, but the one thing that makes two phrases sound like
      // two phrases.
      expect(scorer.intervalScore(0), 0.35);
      expect(scorer.intervalScore(0), greaterThan(scorer.intervalScore(15)));
      expect(scorer.intervalScore(0), lessThan(scorer.intervalScore(4)));
    });

    test('direction does not matter, only distance', () {
      for (final interval in <int>[1, 4, 7, 9, 14]) {
        expect(scorer.intervalScore(interval), scorer.intervalScore(-interval));
      }
    });
  });

  group('tempo sensitivity (§9)', () {
    test('a wide join costs more at a fast tempo than a slow one', () {
      final slow = WbpScorer(tempo: 100).intervalScore(10);
      final medium = WbpScorer(tempo: 160).intervalScore(10);
      final fast = WbpScorer(tempo: 280).intervalScore(10);
      expect(slow, greaterThan(medium));
      expect(medium, greaterThan(fast));
    });

    test('a step costs nothing at any tempo', () {
      // A player makes a step at 300 as easily as at 60; only the wide shifts
      // get harder.
      for (final tempo in <int>[60, 160, 300]) {
        expect(WbpScorer(tempo: tempo).intervalScore(2), 1.0);
        expect(WbpScorer(tempo: tempo).intervalScore(5), 0.85);
      }
    });

    test('the factor is clamped, so an absurd tempo does not invert it', () {
      for (final tempo in <int>[1, 40, 600, 10000]) {
        final score = WbpScorer(tempo: tempo).intervalScore(10);
        expect(score, inInclusiveRange(0.0, 1.0));
      }
    });
  });

  group('contour continuity (§7.2)', () {
    test('a line stepping down that keeps going scores full marks', () {
      expect(scorer.contourScore(-2, -1), 1.0);
    });

    test('a step reversed costs more than a leap reversed', () {
      // A leap then a reversal is how a player recovers register. A step then a
      // reversal is a line changing its mind.
      expect(scorer.contourScore(2, -1), 0.7);
      expect(scorer.contourScore(-3, 5), 0.9);
      expect(scorer.contourScore(2, -1), lessThan(scorer.contourScore(-3, 5)));
    });

    test('a leap continued in the same direction is the suspicious one', () {
      expect(scorer.contourScore(5, 4), 0.75);
      expect(scorer.contourScore(5, 4), lessThan(scorer.contourScore(-5, 4)));
    });

    test('with no contour to contradict, it says nothing', () {
      expect(scorer.contourScore(3, null), 1.0);
      expect(scorer.contourScore(0, 3), 1.0);
      expect(scorer.contourScore(3, 0), 1.0);
    });
  });

  group('approach quality (§7.3)', () {
    test('a semitone into the target is the strongest idiom', () {
      expect(scorer.approachScore(37, 36), 1.0);
      expect(scorer.approachScore(35, 36), 1.0);
    });

    test('a fifth or a fourth away is the dominant approach', () {
      expect(scorer.approachScore(43, 36), 0.95);
      expect(scorer.approachScore(41, 36), 0.95);
    });

    test('landing on the note you left is the weakest', () {
      expect(scorer.approachScore(36, 36), 0.4);
      expect(scorer.approachScore(48, 36), 0.4);
    });

    test('a whole tone beats a third, which beats nothing in particular', () {
      expect(scorer.approachScore(38, 36), 0.85);
      expect(scorer.approachScore(40, 36), 0.7);
      expect(scorer.approachScore(42, 36), 0.5);
      expect(
        scorer.approachScore(38, 36),
        greaterThan(scorer.approachScore(40, 36)),
      );
    });
  });

  group('landing (§7.4)', () {
    test('opening away from the join reads as deliberate', () {
      // Joined upward by 3, then continuing up.
      expect(scorer.landingScore(3, 40, 42), 1.0);
    });

    test('doubling straight back over the join is a hiccup', () {
      expect(scorer.landingScore(3, 40, 37), 0.6);
    });

    test('a partial retrace is in between', () {
      expect(scorer.landingScore(5, 40, 39), 0.85);
    });

    test('with one note, or no join, it says nothing', () {
      expect(scorer.landingScore(3, 40, null), 1.0);
      expect(scorer.landingScore(0, 40, 42), 1.0);
    });
  });

  group('register (§4.3)', () {
    final phrase = walking('ii-V', <String>['Dm7'], <int>[38, 41, 45, 48]);

    test('out of range scores zero', () {
      expect(scorer.register(phrase, -40), 0);
      expect(scorer.register(phrase, 40), 0);
    });

    test('the middle of the instrument scores best', () {
      // The range is 28..55, so its centre is 41.
      final centred = scorer.register(phrase, -2); // 36..46
      final low = scorer.register(phrase, -10); // 28..38
      expect(centred, greaterThan(low));
      expect(centred, inInclusiveRange(0.0, 1.0));
    });
  });

  group('the blended placement score', () {
    final phrase = walking(
      'ii-V',
      <String>['Dm7', 'G7'],
      <int>[
        38, 41, 45, 48, //
        47, 45, 43, 41,
      ],
    );

    test('the first placement has no seam, so the join is a full mark', () {
      final score = scorer.score(phrase, 0, null);
      expect(score.join, 1.0);
      expect(score.joinInterval, isNull);
      expect(score.total, inInclusiveRange(0.0, 1.0));
    });

    test('a stepwise join beats a leap of an octave and a half', () {
      final step = scorer.score(
        phrase,
        0,
        const JoinApproach(lastPitch: 37, previousPitch: 36),
      );
      final leap = scorer.score(
        phrase,
        0,
        const JoinApproach(lastPitch: 20, previousPitch: 19),
      );
      expect(step.join, greaterThan(leap.join));
      expect(step.total, greaterThan(leap.total));
    });

    test('the join interval is reported for the tiling log', () {
      final score = scorer.score(
        phrase,
        0,
        const JoinApproach(lastPitch: 36, previousPitch: 35),
      );
      expect(score.joinInterval, 2); // 38 - 36
    });

    test('every term stays inside 0..1, whatever the input', () {
      for (final last in <int>[28, 36, 45, 55]) {
        for (final transposition in <int>[-12, 0, 5]) {
          final score = scorer.score(
            phrase,
            transposition,
            JoinApproach(lastPitch: last, previousPitch: last - 3),
          );
          expect(score.harmonicFit, inInclusiveRange(0.0, 1.0));
          expect(score.join, inInclusiveRange(0.0, 1.0));
          expect(score.register, inInclusiveRange(0.0, 1.0));
          expect(score.total, inInclusiveRange(0.0, 1.0));
        }
      }
    });

    test('the memo returns the same answer as a fresh scorer (§10)', () {
      final approach = const JoinApproach(lastPitch: 37, previousPitch: 36);
      final first = scorer.score(phrase, 0, approach);
      final again = scorer.score(phrase, 0, approach);
      final fresh = WbpScorer(tempo: 160).score(phrase, 0, approach);
      expect(again.total, first.total);
      expect(fresh.total, closeTo(first.total, 1e-12));
      scorer.clearCache();
      expect(
        scorer.score(phrase, 0, approach).total,
        closeTo(first.total, 1e-12),
      );
    });
  });
}
