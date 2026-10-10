import 'natural.dart';
import 'pitch_spelling.dart';

/// A spelled interval from a root: `1`, `b3`, `#9`, `bb7`, `13`.
///
/// Not a semitone count. `#9` and `b3` are both three semitones and are
/// different degrees; a voicing engine that cannot tell them apart will double
/// the third of an altered dominant. See `docs/rules/pitch-and-spelling.md` §4.
///
/// The degree is written as if the root were C, which makes the letter
/// unambiguous: `b3` is `E` flattened, `#9` is `D` sharpened.
class Degree implements Comparable<Degree> {
  /// Create a degree.
  ///
  /// Throws [ArgumentError] if `alteration` is outside `-2..2`.
  Degree(this.natural, [this.alteration = 0, this.asExtension = false]) {
    if (alteration < -maxAlteration || alteration > maxAlteration) {
      throw ArgumentError.value(
        alteration,
        'alteration',
        'must be between -$maxAlteration and $maxAlteration',
      );
    }
  }

  /// Parse `1`, `b3`, `#11`, `bb7`, `13`.
  ///
  /// Throws [FormatException] on anything else.
  factory Degree.parse(String text) {
    final degree = Degree.tryParse(text);
    if (degree == null) {
      throw FormatException('not a degree', text);
    }
    return degree;
  }

  /// Parse, or null if `text` is not a degree.
  static Degree? tryParse(String text) {
    final trimmed = text.trim();
    final run = PitchSpelling.readAccidentals(trimmed, 0);
    final number = int.tryParse(trimmed.substring(run.end));
    if (number == null || number < 1 || number > 13) {
      return null;
    }
    if (run.alteration < -maxAlteration || run.alteration > maxAlteration) {
      return null;
    }
    return Degree(Natural.fromDegreeNumber(number), run.alteration, number > 7);
  }

  /// The letter, taken as if the root were C.
  final Natural natural;

  /// Accidental, `-2..2`.
  final int alteration;

  /// Whether the degree is *written* as 9, 11 or 13 rather than 2, 4 or 6.
  ///
  /// Display only: `add9` and `add2` are the same degree.
  final bool asExtension;

  /// Semitones above the root, 0–11.
  int get semitones => (natural.semitones + alteration) % 12;

  /// The number as written: 1–7, or 9/11/13 when [asExtension].
  int get number => natural.degreeNumber + (asExtension ? 7 : 0);

  /// The accidental as it is written.
  String get accidentalText => switch (alteration) {
    -2 => 'bb',
    -1 => 'b',
    0 => '',
    1 => '#',
    _ => '##',
  };

  /// The degree as it is written: `b3`, `#11`, `bb7`.
  String get symbol => '$accidentalText$number';

  /// The same degree written as an extension, or as a simple degree.
  ///
  /// `Degree.parse('9').asSimple` is `2`; they compare equal.
  Degree get asSimple => asExtension ? Degree(natural, alteration) : this;

  /// This degree written as 9/11/13 where that is possible.
  Degree get asExtended =>
      natural.degreeNumber >= 2 && natural.degreeNumber <= 6
      ? Degree(natural, alteration, true)
      : this;

  /// The spelling this degree reaches, from a root spelled [root].
  ///
  /// `b3` from `Eb` is `Gb`; `#9` from `Eb` is `F#`.
  PitchSpelling from(PitchSpelling root) {
    final letter = root.natural.stepped(natural.degreeNumber - 1);
    final target = (root.pitchClass + semitones) % 12;
    var accidental = (target - letter.semitones) % 12;
    if (accidental > 6) {
      accidental -= 12;
    }
    if (accidental < -maxAlteration || accidental > maxAlteration) {
      // This degree from this root would need a triple accidental — reachable
      // only from a root that is itself doubly altered, e.g. the #11 of G##.
      // Fall back to the simplest enharmonic rather than emit a symbol nobody
      // can read.
      return PitchSpelling.simplestFor(
        target,
        preferSharps: root.alteration > 0,
      );
    }
    return PitchSpelling(letter, accidental);
  }

  /// Degrees order by written number, so a degree list reads `1 3 5 b7 9 #11`.
  @override
  int compareTo(Degree other) {
    final byNumber = number.compareTo(other.number);
    return byNumber != 0 ? byNumber : alteration.compareTo(other.alteration);
  }

  @override
  String toString() => symbol;

  /// Two degrees are equal when they are written the same way apart from the
  /// 2/9 distinction, which is presentation.
  @override
  bool operator ==(Object other) =>
      other is Degree &&
      other.natural == natural &&
      other.alteration == alteration;

  @override
  int get hashCode => Object.hash(natural, alteration);
}
