import 'wbp_source.dart';

/// The note a join leaves from, with enough context to score the seam.
///
/// `docs/rules/corpus-tiling.md` §7 scores two notes either side of a join, not
/// one: an interval that is fine in isolation still sounds like a seam if it
/// contradicts the line arriving at it.
class JoinApproach {
  /// Create an approach.
  const JoinApproach({required this.lastPitch, this.previousPitch});

  /// The outgoing phrase's final pitch, after transposition.
  final int lastPitch;

  /// The pitch before it, or null when the outgoing phrase had only one note.
  final int? previousPitch;

  /// Semitones of the outgoing phrase's final motion, or null when there was
  /// none to speak of.
  int? get incomingMotion =>
      previousPitch == null ? null : lastPitch - previousPitch!;
}

/// How a candidate placement scores, broken into its terms.
///
/// Kept as a record of the parts rather than one number, because the weights
/// are the tunable part (§4) and tuning them by ear needs to see which term is
/// doing the work.
class PlacementScore {
  /// Create a score.
  const PlacementScore({
    required this.harmonicFit,
    required this.join,
    required this.register,
    required this.total,
    required this.joinInterval,
  });

  /// §4.1, 0..1. A property of the phrase, not the placement.
  final double harmonicFit;

  /// §7, 0..1. The blended seam score.
  final double join;

  /// §4.3, 0..1.
  final double register;

  /// The weighted sum, 0..1.
  final double total;

  /// Semitones between the previous phrase's last note and this one's first,
  /// or null for the first placement.
  final int? joinInterval;

  @override
  String toString() =>
      'total ${total.toStringAsFixed(3)} '
      '(harmony ${harmonicFit.toStringAsFixed(2)}, '
      'join ${join.toStringAsFixed(2)}, '
      'register ${register.toStringAsFixed(2)})';
}

/// Scores candidate placements.
///
/// Rules: `docs/rules/corpus-tiling.md` §4 and §7. Pure and stateless apart
/// from the join memo of §10, so the same inputs always give the same score —
/// which is what makes the generator reproducible and the tests possible.
class WbpScorer {
  /// Create a scorer for a tempo.
  WbpScorer({required this.tempo, this.range = const BassRange()});

  /// The song's tempo, which sharpens the penalty on wide joins (§9).
  final int tempo;

  /// The instrument's range.
  final BassRange range;

  static const double _harmonyWeight = 1;
  static const double _joinWeight = 2;
  static const double _registerWeight = 0.5;
  static const double _totalWeight =
      _harmonyWeight + _joinWeight + _registerWeight;

  // The sub-terms of the join (§7.1–§7.4).
  static const double _intervalWeight = 2;
  static const double _contourWeight = 1;
  static const double _approachWeight = 1.5;
  static const double _landingWeight = 1;
  static const double _joinTotalWeight =
      _intervalWeight + _contourWeight + _approachWeight + _landingWeight;

  /// A blended join below this is rejected outright rather than placed (§5.4).
  ///
  /// The value is deliberately low: it is a floor under what is audible as a
  /// stitch, not a target. Raising it trades coverage for smoothness, and that
  /// trade is a listening judgement (§15).
  static const double minimumJoinScore = 0.35;

  /// A join wider than this is rejected however well it scores otherwise.
  ///
  /// The blended score of §7 cannot express this on its own, and the arithmetic
  /// says why: a 14-semitone leap scores 0.05 on the interval term, but full
  /// marks on contour, approach and landing drag the blend up to 0.65 — clear
  /// of [minimumJoinScore] with room to spare. §4.2 is not ambiguous about what
  /// that interval sounds like, so it is a constraint and not a score. Measured
  /// on the shipped corpus, this is the difference between a widest join of 14
  /// and one of 9.
  static const int maximumJoinInterval = 12;

  /// Whether a placement's seam is acceptable at all (§5.4).
  ///
  /// Both tests, because they catch different faults: the blend catches a join
  /// that is unremarkable in every way and good in none, the interval catches
  /// a leap no amount of shapeliness excuses.
  static bool isAcceptableSeam(PlacementScore score) {
    final interval = score.joinInterval;
    if (interval == null) {
      return true;
    }
    return score.join >= minimumJoinScore &&
        interval.abs() <= maximumJoinInterval;
  }

  final Map<int, double> _joinMemo = <int, double>{};

  /// Score a placement of `source` at `transposition`.
  ///
  /// `approach` is null for the first placement in a tiling, which has no seam
  /// and so scores the join term as a full mark.
  PlacementScore score(
    WbpSource source,
    int transposition,
    JoinApproach? approach,
  ) {
    final firstPitch = source.firstNote.pitch + transposition;
    final joinInterval = approach == null
        ? null
        : firstPitch - approach.lastPitch;
    final join = approach == null
        ? 1.0
        : _join(source, transposition, approach);
    final registerScore = register(source, transposition);
    final total =
        (_harmonyWeight * source.harmonicFit +
            _joinWeight * join +
            _registerWeight * registerScore) /
        _totalWeight;
    return PlacementScore(
      harmonicFit: source.harmonicFit,
      join: join,
      register: registerScore,
      total: total,
      joinInterval: joinInterval,
    );
  }

  /// The blended join score of §7.
  double _join(WbpSource source, int transposition, JoinApproach approach) {
    final firstPitch = source.firstNote.pitch + transposition;
    final interval = firstPitch - approach.lastPitch;

    // §10's third cache. The score depends only on the pitches involved and the
    // incoming motion, so a greedy tiler asking the same question twice — and
    // it does, because two tilers run over the same progression (§11) — pays
    // for it once.
    final secondPitch = source.notes.length > 1
        ? source.notes[1].pitch + transposition
        : null;
    final key = Object.hash(
      interval,
      approach.incomingMotion,
      secondPitch == null ? null : secondPitch - firstPitch,
      (firstPitch - source.colourAt(source.firstNote.beat).rootPitchClass) % 12,
      approach.lastPitch % 12,
      firstPitch % 12,
    );
    final memoised = _joinMemo[key];
    if (memoised != null) {
      return memoised;
    }

    final blended =
        (_intervalWeight * intervalScore(interval) +
            _contourWeight * contourScore(interval, approach.incomingMotion) +
            _approachWeight * approachScore(approach.lastPitch, firstPitch) +
            _landingWeight * landingScore(interval, firstPitch, secondPitch)) /
        _joinTotalWeight;
    _joinMemo[key] = blended;
    return blended;
  }

  /// §7.1 — the interval itself, sharpened by tempo (§9).
  double intervalScore(int interval) {
    final distance = interval.abs();
    final base = switch (distance) {
      0 => 0.35,
      1 || 2 => 1.0,
      3 || 4 || 5 => 0.85,
      6 || 7 => 0.6,
      >= 8 && <= 12 => 0.3,
      _ => 0.05,
    };
    if (distance <= 7) {
      return base;
    }
    // A tenth between two phrases is nothing at 120 and a scramble at 280, so
    // the shortfall below a full mark is scaled rather than the score itself.
    final factor = (tempo / 160).clamp(0.75, 1.5);
    return (1 - (1 - base) * factor).clamp(0.0, 1.0);
  }

  /// §7.2 — whether the join continues or reverses the line arriving at it.
  double contourScore(int interval, int? incomingMotion) {
    if (incomingMotion == null || incomingMotion == 0 || interval == 0) {
      return 1;
    }
    final continues = incomingMotion.sign == interval.sign;
    final byStep = incomingMotion.abs() <= 2;
    if (byStep) {
      return continues ? 1.0 : 0.7;
    }
    // A leap then a reversal is how a player recovers register; a leap then
    // another leap the same way is how a tiling gives itself away.
    return continues ? 0.75 : 0.9;
  }

  /// §7.3 — how the outgoing note leans into the incoming root.
  ///
  /// The strongest idiom in walking bass, and the term that tells a phrase
  /// written to lead somewhere from one that merely stops.
  double approachScore(int lastPitch, int firstPitch) {
    final distance = (lastPitch - firstPitch).abs() % 12;
    return switch (distance) {
      1 || 11 => 1.0,
      7 => 0.95,
      5 => 0.95,
      2 || 10 => 0.85,
      3 || 4 || 8 || 9 => 0.7,
      0 => 0.4,
      _ => 0.5,
    };
  }

  /// §7.4 — whether the incoming phrase doubles back over the join.
  double landingScore(int interval, int firstPitch, int? secondPitch) {
    if (secondPitch == null || interval == 0) {
      return 1;
    }
    final opening = secondPitch - firstPitch;
    if (opening == 0 || opening.sign == interval.sign) {
      return 1;
    }
    final retraced = opening.abs();
    if (retraced >= interval.abs()) {
      return 0.6;
    }
    return 0.85;
  }

  /// §4.3 — how well a transposed phrase sits in the register.
  double register(WbpSource source, int transposition) {
    final low = source.lowestPitch + transposition;
    final high = source.highestPitch + transposition;
    if (!range.admits(low, high)) {
      return 0;
    }
    final centre = (low + high) / 2;
    final drift = (centre - range.centre).abs();
    return (1 - drift / 12).clamp(0.0, 1.0);
  }

  /// Forget the memoised joins. Called between generations so a long session
  /// does not accumulate a map nobody reads again.
  void clearCache() => _joinMemo.clear();
}
