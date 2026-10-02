/// The seven letter names, without accidentals.
///
/// Letters and semitones are kept apart deliberately: letter arithmetic is
/// modular in seven, pitch arithmetic is modular in twelve, and spelling only
/// works if the two never get confused. See `docs/rules/pitch-and-spelling.md`
/// §2.
enum Natural {
  c(1, 0, 'C'),
  d(2, 2, 'D'),
  e(3, 4, 'E'),
  f(4, 5, 'F'),
  g(5, 7, 'G'),
  a(6, 9, 'A'),
  b(7, 11, 'B');

  const Natural(this.degreeNumber, this.semitones, this.letter);

  /// One-based scale-degree number: C is 1, B is 7.
  ///
  /// Not `index`: `Enum` already defines that as the zero-based ordinal, and a
  /// letter's *number* is what music theory means.
  final int degreeNumber;

  /// Semitones above C.
  final int semitones;

  /// The upper-case letter.
  final String letter;

  /// The natural with the given one-based number, wrapping outside 1–7.
  static Natural fromDegreeNumber(int number) {
    final wrapped = ((number - 1) % 7 + 7) % 7;
    return Natural.values[wrapped];
  }

  /// The natural for a letter, upper or lower case.
  ///
  /// Returns null rather than throwing: callers are parsers, and a parser that
  /// has to catch exceptions to look ahead is a parser nobody can read.
  static Natural? fromLetter(String letter) {
    if (letter.length != 1) {
      return null;
    }
    final upper = letter.toUpperCase();
    for (final natural in Natural.values) {
      if (natural.letter == upper) {
        return natural;
      }
    }
    return null;
  }

  /// The natural `steps` letters above this one, wrapping.
  Natural stepped(int steps) => fromDegreeNumber(degreeNumber + steps);

  /// How many letter steps upwards it takes to reach [other], 0–6.
  int stepsTo(Natural other) =>
      ((other.degreeNumber - degreeNumber) % 7 + 7) % 7;
}
