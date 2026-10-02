import 'song.dart';

/// Which way a key cycle moves (`docs/rules/practice.md` §3).
enum KeyCycleOrder {
  /// `C F Bb Eb Ab Db Gb B E A D G` — the cycle a ii-V-I actually moves
  /// through, and the one a player's hands already know.
  fourths(5),

  /// Up a semitone each time, for when the point is the hard keys.
  chromaticUp(1),

  /// Down a semitone each time.
  chromaticDown(11);

  const KeyCycleOrder(this.semitonesPerStep);

  /// How far each step moves, upward, in semitones.
  final int semitonesPerStep;
}

/// A range of written bars to loop (§4).
class LoopRange {
  /// Create a range.
  ///
  /// Throws [ArgumentError] on an empty or inverted range — a loop of no bars
  /// is silence, and refusing it here is better than producing it.
  LoopRange({required this.firstBar, required this.lastBar}) {
    if (firstBar < 0) {
      throw ArgumentError.value(firstBar, 'firstBar', 'must not be negative');
    }
    if (lastBar < firstBar) {
      throw ArgumentError.value(
        lastBar,
        'lastBar',
        'must not be before firstBar',
      );
    }
  }

  /// The first bar, zero-based.
  final int firstBar;

  /// The last bar, zero-based and inclusive. A one-bar loop has
  /// `firstBar == lastBar`, which is legal and useful.
  final int lastBar;

  /// How many bars.
  int get barCount => lastBar - firstBar + 1;

  /// This range clamped to a form of `bars` bars (§4).
  ///
  /// Clamped, never wrapped: a loop that ran off the end and reappeared at the
  /// start would be a different exercise from the one that was asked for.
  LoopRange clampedTo(int bars) {
    if (bars <= 0) {
      return this;
    }
    final last = lastBar >= bars ? bars - 1 : lastBar;
    final first = firstBar > last ? last : firstBar;
    return LoopRange(firstBar: first, lastBar: last);
  }

  @override
  String toString() => 'bars ${firstBar + 1}–${lastBar + 1}';

  @override
  bool operator ==(Object other) =>
      other is LoopRange &&
      other.firstBar == firstBar &&
      other.lastBar == lastBar;

  @override
  int get hashCode => Object.hash(firstBar, lastBar);
}

/// What a session says to play for one chorus.
class ChorusPlan {
  /// Create a plan.
  const ChorusPlan({
    required this.chorus,
    required this.tempo,
    required this.transposition,
    this.loop,
  });

  /// Which chorus this is, from zero.
  final int chorus;

  /// The tempo to play it at.
  final int tempo;

  /// Semitones to transpose the chart by, 0 to 11.
  final int transposition;

  /// The bars to loop, or null for the whole form.
  final LoopRange? loop;

  /// Whether the key differs from the chorus before, and so the band must be
  /// regenerated (§5).
  bool differsInKeyFrom(ChorusPlan? previous) =>
      previous != null && previous.transposition != transposition;

  @override
  String toString() =>
      'chorus ${chorus + 1}: $tempo bpm'
      '${transposition == 0 ? '' : ', +$transposition semitones'}'
      '${loop == null ? '' : ', $loop'}';
}

/// A plan for how a song changes as it repeats.
///
/// Rules: `docs/rules/practice.md`. A value, like everything else in this
/// layer: it owns no music and drives nothing. It answers one question per
/// chorus, which is what makes a twenty-minute ramp testable in milliseconds.
class PracticeSession {
  /// Create a session.
  ///
  /// Throws [ArgumentError] on a step interval below one, or a tempo band that
  /// is not a band.
  PracticeSession({
    required this.startingTempo,
    this.tempoStep = 0,
    this.tempoStepEveryChoruses = 1,
    this.tempoCeiling = maxTempo,
    this.tempoFloor = minTempo,
    this.keyStep = 0,
    this.keyStepEveryChoruses = 1,
    this.keyOrder = KeyCycleOrder.fourths,
    this.loop,
  }) {
    if (tempoStepEveryChoruses < 1) {
      throw ArgumentError.value(
        tempoStepEveryChoruses,
        'tempoStepEveryChoruses',
        'must be at least 1',
      );
    }
    if (keyStepEveryChoruses < 1) {
      throw ArgumentError.value(
        keyStepEveryChoruses,
        'keyStepEveryChoruses',
        'must be at least 1',
      );
    }
    if (tempoFloor < minTempo ||
        tempoCeiling > maxTempo ||
        tempoFloor > tempoCeiling) {
      throw ArgumentError(
        'the tempo band $tempoFloor..$tempoCeiling is not a band',
      );
    }
  }

  /// The tempo of the first chorus.
  final int startingTempo;

  /// How much to change the tempo by, in bpm. Negative descends, which is how
  /// you practise playing slower (§2).
  final int tempoStep;

  /// How many choruses between tempo changes. Changing every chorus is a
  /// fairground ride; four is a rehearsal.
  final int tempoStepEveryChoruses;

  /// The tempo stops rising here.
  final int tempoCeiling;

  /// And stops falling here.
  final int tempoFloor;

  /// How many *steps of the cycle* to move each time, usually 0 or 1.
  final int keyStep;

  /// How many choruses between key changes.
  final int keyStepEveryChoruses;

  /// Which way the cycle goes.
  final KeyCycleOrder keyOrder;

  /// The bars to loop, or null for the whole form.
  final LoopRange? loop;

  /// Whether anything changes at all.
  bool get isStatic => tempoStep == 0 && keyStep == 0;

  /// Whether the session transposes.
  bool get cyclesKeys => keyStep != 0;

  /// The plan for `chorus`, counting from zero.
  ///
  /// Pure, and computed from the index rather than accumulated: the fortieth
  /// chorus of a twenty-minute session is as cheap and as exact as the first,
  /// and a session cannot drift.
  ///
  /// Throws [ArgumentError] on a negative chorus.
  ChorusPlan planFor(int chorus, {int? formBars}) {
    if (chorus < 0) {
      throw ArgumentError.value(chorus, 'chorus', 'must not be negative');
    }
    final steps = chorus ~/ tempoStepEveryChoruses;
    final raw = startingTempo + tempoStep * steps;
    // Clamped to the session's own band, then to what the song model can
    // represent at all (§2).
    final tempo = raw.clamp(tempoFloor, tempoCeiling).clamp(minTempo, maxTempo);

    final keySteps = keyStep * (chorus ~/ keyStepEveryChoruses);
    final transposition = (keySteps * keyOrder.semitonesPerStep) % 12;

    return ChorusPlan(
      chorus: chorus,
      tempo: tempo,
      transposition: transposition,
      loop: formBars == null ? loop : loop?.clampedTo(formBars),
    );
  }

  /// The plans for `count` choruses.
  List<ChorusPlan> plans(int count, {int? formBars}) => <ChorusPlan>[
    for (var chorus = 0; chorus < count; chorus++)
      planFor(chorus, formBars: formBars),
  ];

  /// How many choruses until the key returns to where it started.
  ///
  /// Twelve steps of any cycle, by definition — but only when the session
  /// actually cycles, and the caller usually wants to know rather than assume.
  int? get chorusesPerKeyCycle {
    if (!cyclesKeys) {
      return null;
    }
    var steps = 1;
    while ((steps * keyStep * keyOrder.semitonesPerStep) % 12 != 0) {
      steps++;
      if (steps > 12) {
        return null;
      }
    }
    return steps * keyStepEveryChoruses;
  }
}
