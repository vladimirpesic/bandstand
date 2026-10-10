/// A time signature.
///
/// Modelled generally from day one, per §4.6 — but the app only *offers* the
/// meters it has phrases for, which at M1 means 4/4.
class TimeSignature implements Comparable<TimeSignature> {
  /// Create a time signature.
  ///
  /// **Asserts** that the upper number is 1–32 and the lower a power of two
  /// between 1 and 32. It is `const`, so it cannot throw — and an assert is
  /// stripped in a release build, which makes this a guard against a
  /// programmer's mistake and *not* a validator.
  ///
  /// For anything read from a file or typed by a user, use [tryParse], which
  /// checks the same bounds and returns null.
  const TimeSignature(this.upper, this.lower)
    : assert(upper >= 1 && upper <= 32, 'beats per bar must be 1–32'),
      assert(
        lower == 1 ||
            lower == 2 ||
            lower == 4 ||
            lower == 8 ||
            lower == 16 ||
            lower == 32,
        'the beat unit must be a power of two, 1–32',
      );

  /// Parse `4/4`, `3/4`, `6/8`.
  ///
  /// Throws [FormatException] on anything else.
  factory TimeSignature.parse(String text) {
    final signature = TimeSignature.tryParse(text);
    if (signature == null) {
      throw FormatException('not a time signature', text);
    }
    return signature;
  }

  /// Parse, or null if `text` is not a time signature.
  static TimeSignature? tryParse(String text) {
    final parts = text.trim().split('/');
    if (parts.length != 2) {
      return null;
    }
    final upper = int.tryParse(parts[0].trim());
    final lower = int.tryParse(parts[1].trim());
    if (upper == null || lower == null) {
      return null;
    }
    if (upper < 1 || upper > 32) {
      return null;
    }
    if (!const <int>{1, 2, 4, 8, 16, 32}.contains(lower)) {
      return null;
    }
    return TimeSignature(upper, lower);
  }

  /// Four four, and the only meter the corpus covers at M1.
  static const TimeSignature fourFour = TimeSignature(4, 4);

  /// Three four.
  static const TimeSignature threeFour = TimeSignature(3, 4);

  /// Six eight.
  static const TimeSignature sixEight = TimeSignature(6, 8);

  /// Five four.
  static const TimeSignature fiveFour = TimeSignature(5, 4);

  /// Seven four.
  static const TimeSignature sevenFour = TimeSignature(7, 4);

  /// Beats per bar, as written.
  final int upper;

  /// What kind of note gets one beat, as written: 4 is a quarter note.
  final int lower;

  /// How long a bar is in *quarter notes*, which is the unit the transport,
  /// the sequencer and every phrase use.
  ///
  /// 6/8 is three quarter notes to the bar, not six.
  double get barDurationInQuarters => upper * 4.0 / lower;

  /// How long one written beat is in quarter notes.
  double get beatDurationInQuarters => 4.0 / lower;

  /// Whether the meter is normally felt in compound time — 6/8, 9/8, 12/8.
  bool get isCompound => lower >= 8 && upper % 3 == 0 && upper > 3;

  /// How many beats are felt in a bar: two for 6/8, four for 4/4.
  int get feltBeats => isCompound ? upper ~/ 3 : upper;

  @override
  int compareTo(TimeSignature other) {
    final byUpper = upper.compareTo(other.upper);
    return byUpper != 0 ? byUpper : lower.compareTo(other.lower);
  }

  @override
  String toString() => '$upper/$lower';

  @override
  bool operator ==(Object other) =>
      other is TimeSignature && other.upper == upper && other.lower == lower;

  @override
  int get hashCode => Object.hash(upper, lower);
}
