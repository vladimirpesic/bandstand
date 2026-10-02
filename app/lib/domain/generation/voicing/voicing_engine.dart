import '../../harmony/ext_chord_symbol.dart';
import 'chord_degrees.dart';
import 'voicing.dart';
import 'voicing_builder.dart';
import 'voicing_constraints.dart';

/// How far the engine had to bend to find a voicing (§7).
enum VoicingRelaxation {
  /// Nothing was relaxed.
  none,

  /// The movement cap of §6.7 was lifted.
  movementCap,

  /// A shell was allowed where a fuller voicing was wanted.
  shell,

  /// The root was allowed, because nothing rootless survived.
  root,
}

/// A chosen voicing, with why it was chosen.
class VoicingChoice {
  /// Create a choice.
  const VoicingChoice({
    required this.voicing,
    required this.relaxation,
    required this.movement,
    required this.largestMove,
  });

  /// The notes to play.
  final Voicing voicing;

  /// What had to be relaxed to find it.
  final VoicingRelaxation relaxation;

  /// Total semitone movement from the previous voicing, or 0 for the first.
  final int movement;

  /// The largest distance any one voice moved.
  final int largestMove;

  /// Whether the engine found this without bending a rule.
  bool get isClean => relaxation == VoicingRelaxation.none;

  @override
  String toString() =>
      '$voicing (moved $movement, largest $largestMove'
      '${isClean ? '' : ', relaxed ${relaxation.name}'})';
}

/// Chooses voicings, leading each from the last.
///
/// Rules: `docs/rules/voicings.md`. Pure and deterministic — the same chord
/// after the same previous voicing gives the same notes, which is what §6.5
/// means by "extremely testable".
///
/// The engine holds no state of its own: the caller passes the previous
/// voicing, because a comper's hands are the caller's business (`comping.md`
/// §5) and an engine that remembered would be one that could not be asked a
/// hypothetical.
class VoicingEngine {
  /// Create an engine.
  const VoicingEngine({this.preferRootless = true});

  /// Whether a rootless voicing is preferred, which it is when a bass player
  /// has the root. Solo piano sets this false and gets shells.
  final bool preferRootless;

  static const double _leadingWeight = 3;
  static const double _registerWeight = 1;
  static const double _familyWeight = 0.5;

  /// Choose a voicing for `chord`, leading from `previous`.
  ///
  /// Returns null only when the chord is `N.C.` or when no family can express
  /// it at all — a genuinely unvoiceable chord, which the caller reports rather
  /// than papers over.
  VoicingChoice? choose(ExtChordSymbol chord, {Voicing? previous}) {
    if (chord.isNoChord) {
      return null;
    }
    final degrees = ChordDegrees.of(chord);
    final candidates = VoicingBuilder.candidates(chord);
    if (candidates.isEmpty) {
      return null;
    }

    // §7 — relax in a fixed order, so a failure is predictable rather than a
    // surprise, and record which step was needed.
    for (final relaxation in VoicingRelaxation.values) {
      final survivors = <Voicing>[
        for (final candidate in candidates)
          if (_admits(candidate, degrees, previous, relaxation)) candidate,
      ];
      if (survivors.isEmpty) {
        continue;
      }
      final best = _best(survivors, previous);
      return VoicingChoice(
        voicing: best,
        relaxation: relaxation,
        movement: previous == null
            ? 0
            : VoicingConstraints.totalMovement(previous, best),
        largestMove: previous == null
            ? 0
            : VoicingConstraints.largestMove(previous, best),
      );
    }
    return null;
  }

  /// Voice a whole sequence, each chord leading from the one before.
  ///
  /// The first chord is not chosen on register alone. Where a hand starts
  /// decides everything after it, and a seed that is comfortable in isolation
  /// can be a bad one for the tune: `Gm7 | C7 | Fmaj7` seeded on register picks
  /// `D F A Bb`, from which no `C7` voicing moves less than four semitones —
  /// over the cap of §6.7, on an ordinary ii-V-I. Seeded on the whole sequence
  /// it picks a `Gm7` that leads, and nothing is relaxed.
  ///
  /// So every candidate for the first voiceable chord is tried as a seed, the
  /// rest chained greedily from it, and the best chain kept. Bounded and cheap:
  /// a few dozen seeds times the length of the sequence, with no search after
  /// the seed. Greedy from a good start is not optimal, and where it is not,
  /// [VoicingChoice.relaxation] says so rather than hiding it.
  List<VoicingChoice?> voiceSequence(Iterable<ExtChordSymbol> chords) {
    final list = chords.toList();
    if (list.isEmpty) {
      return const <VoicingChoice?>[];
    }

    final firstVoiceable = list.indexWhere((chord) => !chord.isNoChord);
    if (firstVoiceable < 0) {
      return List<VoicingChoice?>.filled(list.length, null);
    }
    final seeds = VoicingBuilder.candidates(list[firstVoiceable]);
    if (seeds.isEmpty) {
      return _chainFrom(list, null);
    }

    List<VoicingChoice?>? best;
    ({int relaxations, int worst, int movement, double register})? bestScore;
    for (final seed in seeds) {
      final chain = _chainFrom(list, seed);
      final score = _chainScore(chain);
      if (bestScore == null || _chainOrder(score, bestScore) < 0) {
        bestScore = score;
        best = chain;
      }
    }
    return best ?? _chainFrom(list, null);
  }

  /// Voice the sequence greedily, optionally forcing the first voicing.
  List<VoicingChoice?> _chainFrom(List<ExtChordSymbol> chords, Voicing? seed) {
    final choices = <VoicingChoice?>[];
    Voicing? previous;
    var seeded = false;
    for (final chord in chords) {
      if (chord.isNoChord) {
        // A chord that could not be voiced does not reset the hand: the next
        // one still leads from the last thing actually played (`comping.md`
        // §5).
        choices.add(null);
        continue;
      }
      if (!seeded && seed != null) {
        seeded = true;
        previous = seed;
        // Seeds are deliberately unfiltered (`voicing_builder.dart`), so a
        // seed can break a rule `choose()` would have enforced. The choice
        // must say so: `isClean` is a claim about the notes, not about how
        // the search started, and a chain begun by a rule-breaking seed is
        // not a clean chain — the chain score counts the relaxation like any
        // other, so a cleaner seed still wins when one exists.
        final relaxation = _seedRelaxation(seed, ChordDegrees.of(chord));
        choices.add(
          VoicingChoice(
            voicing: seed,
            relaxation: relaxation,
            movement: 0,
            largestMove: 0,
          ),
        );
        continue;
      }
      final choice = choose(chord, previous: previous);
      choices.add(choice);
      if (choice != null) {
        previous = choice.voicing;
      }
    }
    return choices;
  }

  /// How bent a forced seed actually is: the first relaxation level that
  /// would have admitted it through `choose()`'s ladder. When no level
  /// admits it the seed is the most bent of all — `root` — which the chain
  /// score punishes so that a cleaner seed wins whenever one exists.
  VoicingRelaxation _seedRelaxation(Voicing seed, ChordDegrees degrees) {
    for (final relaxation in VoicingRelaxation.values) {
      if (_admits(seed, degrees, null, relaxation)) {
        return relaxation;
      }
    }
    return VoicingRelaxation.root;
  }

  /// How good a whole chain is, as a lexicographic key: fewer relaxations
  /// first, then the smaller worst leap, then the less total movement, then
  /// the more comfortable register.
  ///
  /// A relaxation is a rule bent, and no amount of smoothness elsewhere buys
  /// one back — lexicographic now, the same ordering the bass tiler uses for
  /// its gaps (`walking_bass_generator.dart`'s `_better`). The sum this
  /// replaced weighted a relaxation at −1000, which a long enough chain of
  /// maximal movement could outvote: a false claim roughly seven chords in
  /// (L-G2).
  ///
  /// Register comes last and small. Seeds an octave apart give chains with
  /// identical movement, so without it the choice between them is arbitrary
  /// and the tune can end up sitting at the top of the band for no reason;
  /// with it, the comfortable octave wins and nothing else changes.
  ({int relaxations, int worst, int movement, double register}) _chainScore(
    List<VoicingChoice?> chain,
  ) {
    var relaxations = 0;
    var movement = 0;
    var worst = 0;
    var voiced = 0;
    var register = 0.0;
    for (final choice in chain) {
      if (choice == null) {
        continue;
      }
      voiced++;
      if (!choice.isClean) {
        relaxations++;
      }
      movement += choice.movement;
      if (choice.largestMove > worst) {
        worst = choice.largestMove;
      }
      register += _registerScore(choice.voicing);
    }
    if (voiced == 0) {
      // Unreachable when a seed exists (the seed itself is a choice), but a
      // chain with nothing in it is the worst chain there is, not a crash.
      return (
        relaxations: 1 << 30,
        worst: 1 << 30,
        movement: 1 << 30,
        register: double.negativeInfinity,
      );
    }
    return (
      relaxations: relaxations,
      worst: worst,
      movement: movement,
      register: register / voiced,
    );
  }

  /// Negative when [a] is the better chain: the lexicographic order of
  /// [`_chainScore`]'s key.
  int _chainOrder(
    ({int relaxations, int worst, int movement, double register}) a,
    ({int relaxations, int worst, int movement, double register}) b,
  ) {
    if (a.relaxations != b.relaxations) {
      return a.relaxations < b.relaxations ? -1 : 1;
    }
    if (a.worst != b.worst) {
      return a.worst < b.worst ? -1 : 1;
    }
    if (a.movement != b.movement) {
      return a.movement < b.movement ? -1 : 1;
    }
    return a.register > b.register ? -1 : 1;
  }

  /// Whether a candidate passes, at this level of relaxation.
  bool _admits(
    Voicing candidate,
    ChordDegrees degrees,
    Voicing? previous,
    VoicingRelaxation relaxation,
  ) {
    switch (relaxation) {
      case VoicingRelaxation.none:
        if (preferRootless && !candidate.family.isRootless) {
          return false;
        }
        return VoicingConstraints.check(
              candidate,
              degrees,
              previous: previous,
            ) ==
            null;
      case VoicingRelaxation.movementCap:
        if (preferRootless && !candidate.family.isRootless) {
          return false;
        }
        // Everything but §6.7 — the leap is allowed, the clashes are not.
        return VoicingConstraints.check(candidate, degrees) == null;
      case VoicingRelaxation.shell:
        if (candidate.family == VoicingFamily.triad) {
          return false;
        }
        return VoicingConstraints.check(candidate, degrees) == null;
      case VoicingRelaxation.root:
        // Anything the register allows and that does not clash. A chord this
        // far down the list is one the family tables do not cover, and that is
        // worth seeing in the report.
        return VoicingConstraints.check(candidate, degrees) == null ||
            _onlyFailsRootRules(candidate, degrees);
    }
  }

  /// Whether the only objections are ones the `root` step forgives: sounding
  /// the root, or missing a guide tone.
  ///
  /// The first failure cannot answer that alone — a candidate can fail a
  /// root rule *and* carry a clash, and the clash must still veto it. Every
  /// failure is read; one non-root rule is enough to refuse.
  bool _onlyFailsRootRules(Voicing candidate, ChordDegrees degrees) {
    final failures = VoicingConstraints.checkAll(candidate, degrees);
    return failures.isNotEmpty &&
        failures.every(
          (failure) =>
              failure == VoicingRejection.doublesTheRoot ||
              failure == VoicingRejection.missingGuideTone,
        );
  }

  /// The best of the survivors (§7.3).
  Voicing _best(List<Voicing> survivors, Voicing? previous) {
    Voicing? best;
    var bestScore = double.negativeInfinity;
    for (final candidate in survivors) {
      final score = _score(candidate, previous);
      if (score > bestScore) {
        bestScore = score;
        best = candidate;
      }
    }
    return best!;
  }

  double _score(Voicing candidate, Voicing? previous) {
    final register = _registerScore(candidate);
    final family = _familyScore(candidate);
    if (previous == null) {
      // §5 — the first voicing of a tune has nothing to lead from, so register
      // decides it.
      return _registerWeight * register + _familyWeight * family;
    }

    final movement = VoicingConstraints.totalMovement(previous, candidate);
    // Four voices moving three semitones each is the worst a passing candidate
    // can do, so that is the scale.
    final worst = candidate.length * VoicingConstraints.maximumVoiceMovement;
    final leading = (1 - movement / worst).clamp(0.0, 1.0);
    final held =
        VoicingConstraints.commonTones(previous, candidate) / candidate.length;
    final direction = _directionScore(previous, candidate);

    return _leadingWeight * (leading * 0.7 + held * 0.2 + direction * 0.1) +
        _registerWeight * register +
        _familyWeight * family;
  }

  /// How near the middle of the band the voicing sits (§7.3).
  double _registerScore(Voicing candidate) {
    final drift = (candidate.centre - VoicingConstraints.centre).abs();
    return (1 - drift / 18).clamp(0.0, 1.0);
  }

  /// Family preference (§7.3): rootless for a band, shell without one.
  double _familyScore(Voicing candidate) {
    if (preferRootless) {
      return switch (candidate.family) {
        VoicingFamily.rootless => 1.0,
        VoicingFamily.drop2 || VoicingFamily.quartal => 0.6,
        VoicingFamily.shell => 0.4,
        VoicingFamily.triad => 0.2,
      };
    }
    return switch (candidate.family) {
      VoicingFamily.shell => 1.0,
      VoicingFamily.drop2 => 0.8,
      VoicingFamily.triad || VoicingFamily.quartal => 0.5,
      VoicingFamily.rootless => 0.3,
    };
  }

  /// Whether the voices that moved went the same way (§5.3).
  double _directionScore(Voicing previous, Voicing candidate) {
    var up = 0;
    var down = 0;
    final shared = previous.length < candidate.length
        ? previous.length
        : candidate.length;
    for (var i = 0; i < shared; i++) {
      final delta = candidate.pitches[i] - previous.pitches[i];
      if (delta > 0) {
        up++;
      } else if (delta < 0) {
        down++;
      }
    }
    if (up + down == 0) {
      return 1;
    }
    final agreement = (up > down ? up : down) / (up + down);
    return agreement;
  }
}
