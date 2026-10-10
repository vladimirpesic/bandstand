import 'natural.dart';

/// The largest accidental the model accepts, in either direction.
///
/// Double sharps and flats occur in real music; triples are always an upstream
/// bug, and accepting one produces a chord symbol nobody can read.
const int maxAlteration = 2;

/// A run of accidentals read from text: how much they alter, and where they end.
class AccidentalRun {
  /// Create a run.
  const AccidentalRun(this.alteration, this.end);

  /// Total alteration, positive for sharps. Not range-checked.
  final int alteration;

  /// Index just past the last accidental read.
  final int end;
}

/// A letter plus an accidental: `Eb`, `F#`, `Cb`, `B#`.
///
/// Has a pitch *class* but no octave and no absolute pitch. This is what chord
/// roots, bass notes and key tonics are made of. See
/// `docs/rules/pitch-and-spelling.md` §1 and §3.
class PitchSpelling implements Comparable<PitchSpelling> {
  /// Create a spelling.
  ///
  /// Throws [ArgumentError] if `alteration` is outside `-2..2`.
  PitchSpelling(this.natural, [this.alteration = 0]) {
    if (alteration < -maxAlteration || alteration > maxAlteration) {
      throw ArgumentError.value(
        alteration,
        'alteration',
        'must be between -$maxAlteration and $maxAlteration',
      );
    }
  }

  /// Parse `C`, `Bb`, `F#`, `Ebb`, `G##`, `Gx`.
  ///
  /// Throws [FormatException] on anything else.
  factory PitchSpelling.parse(String text) {
    final spelling = PitchSpelling.tryParse(text);
    if (spelling == null) {
      throw FormatException('not a note name', text);
    }
    return spelling;
  }

  /// Parse, or null if `text` is not a note name.
  static PitchSpelling? tryParse(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final natural = Natural.fromLetter(trimmed[0]);
    if (natural == null) {
      return null;
    }
    final run = readAccidentals(trimmed, 1);
    if (run.end != trimmed.length ||
        run.alteration < -maxAlteration ||
        run.alteration > maxAlteration) {
      return null;
    }
    return PitchSpelling(natural, run.alteration);
  }

  /// Read a run of accidentals from [text] starting at [start].
  ///
  /// Accidentals in a run must all be the same kind: `bb` and `##` are note
  /// names, `#b#` is not. The run stops at the first character that is not the
  /// same kind, which is also what lets a chord parser tell `Cb5` (a C flat
  /// power chord) from `C#b5` (a C sharp with a flattened fifth).
  ///
  /// The caller checks the range: this reports `###` faithfully as +3 so the
  /// caller can reject it.
  static AccidentalRun readAccidentals(String text, int start) {
    if (start >= text.length) {
      return AccidentalRun(0, start);
    }
    final first = text[start];
    if (first == 'x' || first == 'X' || first == '\u{1D12A}') {
      return AccidentalRun(2, start + 1);
    }
    final isSharp = first == '#' || first == '\u266F';
    final isFlat = first == 'b' || first == '\u266D';
    if (!isSharp && !isFlat) {
      return AccidentalRun(0, start);
    }
    var cursor = start;
    var count = 0;
    while (cursor < text.length) {
      final character = text[cursor];
      final matches = isSharp
          ? character == '#' || character == '\u266F'
          : character == 'b' || character == '\u266D';
      if (!matches) {
        break;
      }
      count++;
      cursor++;
    }
    return AccidentalRun(isSharp ? count : -count, cursor);
  }

  /// The simplest spelling of a pitch class: the one needing fewest
  /// accidentals, breaking ties towards flats unless [preferSharps].
  ///
  /// Flats win ties because the jazz repertoire is flat-side: `Bb`, `Eb`, `Ab`
  /// and `Db` are ordinary keys and `D#` is not. See
  /// `docs/rules/pitch-and-spelling.md` §6.
  static PitchSpelling simplestFor(
    int pitchClass, {
    bool preferSharps = false,
  }) {
    final target = ((pitchClass % 12) + 12) % 12;
    PitchSpelling? best;
    for (final natural in Natural.values) {
      var alteration = (target - natural.semitones) % 12;
      if (alteration > 6) {
        alteration -= 12;
      }
      if (alteration.abs() > maxAlteration) {
        continue;
      }
      if (best == null ||
          alteration.abs() < best.accidentalCount ||
          (alteration.abs() == best.accidentalCount &&
              (preferSharps
                  ? alteration > best.alteration
                  : alteration < best.alteration))) {
        best = PitchSpelling(natural, alteration);
      }
    }
    // Every pitch class has a natural within one semitone, so this is total.
    return best!;
  }

  /// The letter.
  final Natural natural;

  /// Accidental, `-2..2`: −1 is flat, +1 is sharp.
  final int alteration;

  /// Pitch class, 0–11, 0 = C.
  int get pitchClass => (natural.semitones + alteration) % 12;

  /// How many accidentals the spelling needs, used to prefer simple spellings.
  int get accidentalCount => alteration.abs();

  /// The accidental as it is written: `bb`, `b`, ``, `#`, `##`.
  String get accidentalText => switch (alteration) {
    -2 => 'bb',
    -1 => 'b',
    0 => '',
    1 => '#',
    _ => '##',
  };

  /// This spelling with a different accidental.
  PitchSpelling withAlteration(int newAlteration) =>
      PitchSpelling(natural, newAlteration);

  /// Whether this and [other] sound the same, however they are written.
  ///
  /// `F#` and `Gb` are enharmonic and are *not* equal; nothing in the codebase
  /// may conflate the two.
  bool isEnharmonicWith(PitchSpelling other) => pitchClass == other.pitchClass;

  /// The spelling `letterSteps` letters away that lands on `targetPitchClass`,
  /// or null if that would need more than a double accidental.
  ///
  /// Used when an interval's letter distance is known — which, per
  /// `docs/rules/pitch-and-spelling.md` §7, is *not* how transposition chooses
  /// its spelling, but is how a diatonic scale is built.
  PitchSpelling? steppedTo(int letterSteps, int targetPitchClass) {
    final letter = natural.stepped(letterSteps);
    var alteration = (targetPitchClass - letter.semitones) % 12;
    if (alteration > 6) {
      alteration -= 12;
    }
    if (alteration < -maxAlteration || alteration > maxAlteration) {
      return null;
    }
    return PitchSpelling(letter, alteration);
  }

  @override
  int compareTo(PitchSpelling other) {
    final byLetter = natural.degreeNumber.compareTo(other.natural.degreeNumber);
    return byLetter != 0 ? byLetter : alteration.compareTo(other.alteration);
  }

  @override
  String toString() => '${natural.letter}$accidentalText';

  @override
  bool operator ==(Object other) =>
      other is PitchSpelling &&
      other.natural == natural &&
      other.alteration == alteration;

  @override
  int get hashCode => Object.hash(natural, alteration);
}
