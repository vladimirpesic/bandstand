import 'chord_degrees.dart';
import 'voicing.dart';

/// Why a candidate voicing was rejected.
///
/// Named rather than counted, because a chord that repeatedly fails for one
/// reason is a gap in the tables and should be legible as such
/// (`docs/rules/voicings.md` §7).
enum VoicingRejection {
  /// It does not state the third or the seventh (§6.1).
  missingGuideTone,

  /// A rootless family sounded the root the bass is already playing (§6.2).
  doublesTheRoot,

  /// Two voices on the same pitch class (§6.3).
  doubledPitchClass,

  /// Thirteen semitones between two voices (§6.4).
  minorNinth,

  /// A minor second too low to be a colour (§6.5).
  lowMinorSecond,

  /// Outside the comping band, or an interval below its low limit (§6.6).
  outOfRegister,

  /// A voice moved four semitones or more from the previous voicing (§6.7).
  voiceLeapsTooFar,
}

/// The register band and the low interval limits of `docs/rules/voicings.md`
/// §4, and the constraints of §6.
abstract final class VoicingConstraints {
  /// The lowest note comping plays, C3.
  static const int lowestPitch = 48;

  /// The highest, C6.
  static const int highestPitch = 84;

  /// Where a rootless voicing sits, F3 to A5 — a narrower band inside the
  /// comping range, because that is where the Bill Evans left hand lives.
  static const int rootlessLowest = 53;

  /// The top of the rootless band.
  static const int rootlessHighest = 81;

  /// The middle of the comping band, which the register term pulls towards.
  static const int centre = (lowestPitch + highestPitch) ~/ 2;

  /// How far a voice may move between successive chords, exclusive.
  ///
  /// §10 of the plan asks for "voice movement under 4 semitones", so 4 is the
  /// first value that fails.
  static const int maximumVoiceMovement = 4;

  /// The lowest note an interval may sit on before it turns to mud (§4).
  ///
  /// Keyed by the interval in semitones, reduced inside an octave. The standard
  /// low-interval-limit table; intervals wider than a major sixth are not
  /// constrained, because by then the spacing is doing the work.
  static const Map<int, int> lowIntervalLimits = <int, int>{
    1: 52, // minor 2nd — E3
    2: 51, // major 2nd — Eb3
    3: 48, // minor 3rd — C3
    4: 46, // major 3rd — Bb2
    5: 41, // perfect 4th — F2
    6: 51, // tritone — Eb3
    7: 34, // perfect 5th — Bb1
    8: 41, // minor 6th — F2
    9: 39, // major 6th — Eb2
  };

  /// Check a candidate against §6, returning the first failure or null.
  ///
  /// `previous` is the voicing this one follows, or null for the first chord of
  /// a tune, which has nothing to lead from.
  static VoicingRejection? check(
    Voicing voicing,
    ChordDegrees degrees, {
    Voicing? previous,
  }) {
    final failures = checkAll(voicing, degrees, previous: previous);
    return failures.isEmpty ? null : failures.first;
  }

  /// Every §6 failure of a candidate, in the order the rules are written.
  ///
  /// [check] answers "may I play this"; a caller that excuses one rule needs
  /// the rest of the list. The engine's `root` relaxation forgives sounding
  /// the root and missing a guide tone — and a candidate whose *first*
  /// failure is one of those can still carry a clash behind it, which a
  /// first-failure-only reading would pass.
  static List<VoicingRejection> checkAll(
    Voicing voicing,
    ChordDegrees degrees, {
    Voicing? previous,
  }) {
    final failures = <VoicingRejection>[];

    // §6.6 — the band.
    final low = voicing.family.isRootless ? rootlessLowest : lowestPitch;
    final high = voicing.family.isRootless ? rootlessHighest : highestPitch;
    if (voicing.lowest < low || voicing.highest > high) {
      failures.add(VoicingRejection.outOfRegister);
    }

    // §6.5 — a minor second between adjacent voices, too low to be a colour.
    // Before the low interval limits of §4: a minor second *is* interval 1,
    // and evaluating it there would report the mud as `outOfRegister`, which
    // names a different rule and hides what was actually wrong.
    for (var i = 1; i < voicing.pitches.length; i++) {
      if (voicing.pitches[i] - voicing.pitches[i - 1] == 1 &&
          voicing.pitches[i - 1] < lowIntervalLimits[1]!) {
        failures.add(VoicingRejection.lowMinorSecond);
      }
    }

    // §4 — the low interval limits. Interval 1 is §6.5's own ground, reported
    // there under its own name; the limits still judge its compounds (13, 25…)
    // as the dissonances they are.
    for (var i = 1; i < voicing.pitches.length; i++) {
      final interval = voicing.pitches[i] - voicing.pitches[i - 1];
      if (interval == 1) {
        continue;
      }
      final limit = lowIntervalLimits[interval % 12];
      if (limit != null && voicing.pitches[i - 1] < limit) {
        failures.add(VoicingRejection.outOfRegister);
      }
    }

    // §6.3 — four voices, four notes.
    if (voicing.pitchClasses.length != voicing.length) {
      failures.add(VoicingRejection.doubledPitchClass);
    }

    // §6.2 — the bass has the root.
    if (voicing.family.isRootless && voicing.hasRoot) {
      failures.add(VoicingRejection.doublesTheRoot);
    }

    // §6.1 — both guide tones, where the chord has them.
    if (!_statesGuideTones(voicing, degrees)) {
      failures.add(VoicingRejection.missingGuideTone);
    }

    // §6.4 — a minor ninth between *any* two voices, not just adjacent ones.
    for (var i = 0; i < voicing.pitches.length; i++) {
      for (var j = i + 1; j < voicing.pitches.length; j++) {
        if (voicing.pitches[j] - voicing.pitches[i] == 13) {
          failures.add(VoicingRejection.minorNinth);
        }
      }
    }

    // §6.7 — no voice leaps between successive chords.
    if (previous != null &&
        largestMove(previous, voicing) >= maximumVoiceMovement) {
      failures.add(VoicingRejection.voiceLeapsTooFar);
    }

    return failures;
  }

  /// Whether the voicing sounds both guide tones the chord actually has.
  static bool _statesGuideTones(Voicing voicing, ChordDegrees degrees) {
    final classes = voicing.pitchClasses;
    if (degrees.hasThird) {
      final third = degrees.pitchClassFor(3);
      if (third != null && !classes.contains(third)) {
        return false;
      }
    }
    if (degrees.hasSeventh) {
      final seventh = degrees.pitchClassFor(7);
      if (seventh != null && !classes.contains(seventh)) {
        return false;
      }
    }
    return true;
  }

  /// Total semitone movement between two voicings, voice by voice (§5).
  ///
  /// Where the two have different voice counts, the extra voices count their
  /// distance from the nearest voice they could have come from.
  static int totalMovement(Voicing from, Voicing to) {
    var total = 0;
    for (var i = 0; i < to.length; i++) {
      total += _distanceForVoice(from, to, i);
    }
    return total;
  }

  /// The largest distance any single voice moved (§5.1).
  static int largestMove(Voicing from, Voicing to) {
    var largest = 0;
    for (var i = 0; i < to.length; i++) {
      final distance = _distanceForVoice(from, to, i);
      if (distance > largest) {
        largest = distance;
      }
    }
    return largest;
  }

  static int _distanceForVoice(Voicing from, Voicing to, int index) {
    if (index < from.length) {
      return (to.pitches[index] - from.pitches[index]).abs();
    }
    // A voice the previous voicing did not have: measure it from the nearest
    // note that was actually sounding, which is what a hand does.
    var nearest = (to.pitches[index] - from.pitches.last).abs();
    for (final pitch in from.pitches) {
      final distance = (to.pitches[index] - pitch).abs();
      if (distance < nearest) {
        nearest = distance;
      }
    }
    return nearest;
  }

  /// How many voices did not move at all (§5.2).
  static int commonTones(Voicing from, Voicing to) {
    var held = 0;
    final remaining = <int>[...from.pitches];
    for (final pitch in to.pitches) {
      if (remaining.remove(pitch)) {
        held++;
      }
    }
    return held;
  }
}
