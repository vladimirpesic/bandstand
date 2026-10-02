import 'package:bandstand/domain/song/practice_session.dart';
import 'package:bandstand/domain/song/song.dart';
import 'package:flutter_test/flutter_test.dart';

/// §10 M7: *"tempo ramp works over a 20-minute session"*.
void main() {
  group('the tempo ramp (§2)', () {
    test('it rises every n choruses, not every chorus', () {
      final session = PracticeSession(
        startingTempo: 120,
        tempoStep: 4,
        tempoStepEveryChoruses: 4,
      );
      expect(session.plans(9).map((plan) => plan.tempo), <int>[
        120,
        120,
        120,
        120,
        124,
        124,
        124,
        124,
        128,
      ]);
    });

    test('it works over a twenty-minute session', () {
      // A 32-bar form at 200 bpm is about 38 s a chorus, so twenty minutes is
      // roughly 32 choruses. The arithmetic has to still be right at the last
      // one, not just the second.
      final session = PracticeSession(
        startingTempo: 120,
        tempoStep: 4,
        tempoStepEveryChoruses: 2,
        tempoCeiling: 200,
      );
      // Long enough to reach the ceiling and sit on it: 4 bpm every 2 choruses
      // from 120 needs 40 choruses to make 200.
      final plans = session.plans(50);
      expect(plans.first.tempo, 120);
      expect(plans[2].tempo, 124);
      expect(plans[20].tempo, 160);
      expect(plans[39].tempo, 196);
      expect(plans[40].tempo, 200);
      expect(plans.last.tempo, 200, reason: 'and it holds there');
      for (var i = 1; i < plans.length; i++) {
        expect(plans[i].tempo, greaterThanOrEqualTo(plans[i - 1].tempo));
        expect(plans[i].tempo, lessThanOrEqualTo(200));
      }
    });

    test('the ceiling holds rather than wrapping or stopping', () {
      final session = PracticeSession(
        startingTempo: 190,
        tempoStep: 10,
        tempoCeiling: 220,
      );
      expect(session.plans(8).map((plan) => plan.tempo), <int>[
        190,
        200,
        210,
        220,
        220,
        220,
        220,
        220,
      ]);
    });

    test('a descending ramp is a real exercise, and has a floor', () {
      final session = PracticeSession(
        startingTempo: 200,
        tempoStep: -10,
        tempoFloor: 170,
      );
      expect(session.plans(6).map((plan) => plan.tempo), <int>[
        200,
        190,
        180,
        170,
        170,
        170,
      ]);
    });

    test('it never leaves what the song model can represent', () {
      final session = PracticeSession(startingTempo: maxTempo, tempoStep: 50);
      for (final plan in session.plans(10)) {
        expect(plan.tempo, inInclusiveRange(minTempo, maxTempo));
      }
    });

    test('a plan is computed, not accumulated, so it cannot drift', () {
      final session = PracticeSession(
        startingTempo: 100,
        tempoStep: 3,
        tempoStepEveryChoruses: 3,
      );
      // Asking for chorus 30 directly gives what walking there would.
      expect(session.planFor(30).tempo, session.plans(31).last.tempo);
    });

    test('a step interval below one is refused', () {
      expect(
        () => PracticeSession(startingTempo: 120, tempoStepEveryChoruses: 0),
        throwsArgumentError,
      );
      expect(
        () => PracticeSession(startingTempo: 120, keyStepEveryChoruses: 0),
        throwsArgumentError,
      );
    });

    test('a nonsensical tempo band is refused', () {
      expect(
        () => PracticeSession(
          startingTempo: 120,
          tempoFloor: 200,
          tempoCeiling: 100,
        ),
        throwsArgumentError,
      );
    });

    test('a negative chorus is refused', () {
      expect(
        () => PracticeSession(startingTempo: 120).planFor(-1),
        throwsArgumentError,
      );
    });
  });

  group('key cycling (§3)', () {
    test('fourths move up five semitones a step', () {
      final session = PracticeSession(startingTempo: 160, keyStep: 1);
      expect(session.plans(4).map((plan) => plan.transposition), <int>[
        0,
        5,
        10,
        3,
      ]);
    });

    test('it returns to the starting key after twelve steps', () {
      for (final order in KeyCycleOrder.values) {
        final session = PracticeSession(
          startingTempo: 160,
          keyStep: 1,
          keyOrder: order,
        );
        final plans = session.plans(13);
        expect(plans.first.transposition, 0);
        expect(plans.last.transposition, 0, reason: '$order');
        // And it visits all twelve on the way — a cycle that repeats early is
        // not a cycle.
        expect(
          plans.take(12).map((plan) => plan.transposition).toSet(),
          hasLength(12),
          reason: '$order',
        );
        expect(session.chorusesPerKeyCycle, 12);
      }
    });

    test('chromatic orders go the way they say', () {
      expect(
        PracticeSession(
          startingTempo: 160,
          keyStep: 1,
          keyOrder: KeyCycleOrder.chromaticUp,
        ).plans(3).map((plan) => plan.transposition),
        <int>[0, 1, 2],
      );
      expect(
        PracticeSession(
          startingTempo: 160,
          keyStep: 1,
          keyOrder: KeyCycleOrder.chromaticDown,
        ).plans(3).map((plan) => plan.transposition),
        <int>[0, 11, 10],
      );
    });

    test('it changes every n choruses, like the tempo', () {
      final session = PracticeSession(
        startingTempo: 160,
        keyStep: 1,
        keyStepEveryChoruses: 2,
      );
      expect(session.plans(6).map((plan) => plan.transposition), <int>[
        0,
        0,
        5,
        5,
        10,
        10,
      ]);
      expect(session.chorusesPerKeyCycle, 24);
    });

    test('a session that does not cycle says so', () {
      final session = PracticeSession(startingTempo: 160);
      expect(session.cyclesKeys, isFalse);
      expect(session.chorusesPerKeyCycle, isNull);
      expect(session.isStatic, isTrue);
    });

    test('cycling and ramping compose, counting independently (§3.3)', () {
      final session = PracticeSession(
        startingTempo: 120,
        tempoStep: 5,
        tempoStepEveryChoruses: 4,
        keyStep: 1,
      );
      final plans = session.plans(5);
      expect(plans.map((plan) => plan.tempo), <int>[120, 120, 120, 120, 125]);
      expect(plans.map((plan) => plan.transposition), <int>[0, 5, 10, 3, 8]);
    });

    test('a key change is flagged, because it forces a regeneration (§5)', () {
      final session = PracticeSession(startingTempo: 160, keyStep: 1);
      final plans = session.plans(3);
      expect(plans[0].differsInKeyFrom(null), isFalse);
      expect(plans[1].differsInKeyFrom(plans[0]), isTrue);

      final still = PracticeSession(startingTempo: 160, tempoStep: 5);
      final flat = still.plans(3);
      expect(flat[1].differsInKeyFrom(flat[0]), isFalse);
    });
  });

  group('loop practice (§4)', () {
    test('a one-bar loop is legal', () {
      final loop = LoopRange(firstBar: 4, lastBar: 4);
      expect(loop.barCount, 1);
    });

    test('an inverted or negative range is refused', () {
      expect(() => LoopRange(firstBar: 8, lastBar: 4), throwsArgumentError);
      expect(() => LoopRange(firstBar: -1, lastBar: 4), throwsArgumentError);
    });

    test('a loop past the end is clamped, never wrapped', () {
      final loop = LoopRange(firstBar: 28, lastBar: 40).clampedTo(32);
      expect(loop.firstBar, 28);
      expect(loop.lastBar, 31);
      // Wrapping would give a different exercise from the one asked for.
      expect(loop.barCount, 4);
    });

    test('a loop entirely past the end collapses onto the last bar', () {
      final loop = LoopRange(firstBar: 40, lastBar: 48).clampedTo(32);
      expect(loop.firstBar, 31);
      expect(loop.lastBar, 31);
    });

    test('the session carries the loop into every chorus, clamped', () {
      final session = PracticeSession(
        startingTempo: 160,
        loop: LoopRange(firstBar: 0, lastBar: 40),
      );
      for (final plan in session.plans(3, formBars: 16)) {
        expect(plan.loop, LoopRange(firstBar: 0, lastBar: 15));
      }
    });

    test('without a form length the loop is passed through as written', () {
      final session = PracticeSession(
        startingTempo: 160,
        loop: LoopRange(firstBar: 0, lastBar: 7),
      );
      expect(session.planFor(0).loop, LoopRange(firstBar: 0, lastBar: 7));
    });

    test('no loop means the whole form', () {
      expect(PracticeSession(startingTempo: 160).planFor(0).loop, isNull);
    });
  });
}
