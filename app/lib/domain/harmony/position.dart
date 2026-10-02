import 'time_signature.dart';

/// A place in a song: a bar and a beat within it.
///
/// Bars are zero-based internally and one-based when displayed — a chart says
/// "bar 1", the model says `bar: 0`. Every conversion is in this class so the
/// off-by-one lives in exactly one place.
class Position implements Comparable<Position> {
  /// Create a position.
  ///
  /// Throws [ArgumentError] if `bar` is negative or `beat` is negative or not
  /// finite.
  Position(this.bar, [this.beat = 0.0]) {
    if (bar < 0) {
      throw ArgumentError.value(bar, 'bar', 'must not be negative');
    }
    if (!beat.isFinite || beat < 0) {
      throw ArgumentError.value(
        beat,
        'beat',
        'must be finite and non-negative',
      );
    }
  }

  /// The start of the song.
  static final Position zero = Position(0);

  /// Zero-based bar number.
  final int bar;

  /// Beats from the start of the bar, in the meter's own beats.
  final double beat;

  /// One-based bar number, as a chart writes it.
  int get displayBar => bar + 1;

  /// One-based beat number, as a musician counts it.
  double get displayBeat => beat + 1;

  /// Whether the position is exactly on a bar line.
  bool get isBarStart => beat == 0;

  /// This position expressed in quarter notes from the start of the song,
  /// assuming [signature] throughout.
  ///
  /// Songs with meter changes convert through the song's own meter map (M2);
  /// this is the constant-meter case, which is almost every chart.
  double toQuarters(TimeSignature signature) =>
      bar * signature.barDurationInQuarters +
      beat * signature.beatDurationInQuarters;

  /// The position [quarters] quarter notes into a song in [signature].
  static Position fromQuarters(double quarters, TimeSignature signature) {
    if (!quarters.isFinite || quarters < 0) {
      throw ArgumentError.value(
        quarters,
        'quarters',
        'must be finite and non-negative',
      );
    }
    final barLength = signature.barDurationInQuarters;
    final bar = quarters ~/ barLength;
    final remainder = quarters - bar * barLength;
    return Position(bar, remainder / signature.beatDurationInQuarters);
  }

  /// This position moved by [beats] within [signature], carrying into the next
  /// bar or back into the previous one.
  ///
  /// Clamped at the start of the song: moving back from bar 0 beat 0 stays
  /// there, because a negative bar is not a place.
  Position shifted(double beats, TimeSignature signature) {
    final total =
        toQuarters(signature) + beats * signature.beatDurationInQuarters;
    return total <= 0 ? Position(0) : fromQuarters(total, signature);
  }

  /// The start of the bar this position is in.
  Position get barStart => Position(bar);

  /// A copy with some fields replaced.
  Position copyWith({int? bar, double? beat}) =>
      Position(bar ?? this.bar, beat ?? this.beat);

  @override
  int compareTo(Position other) {
    final byBar = bar.compareTo(other.bar);
    return byBar != 0 ? byBar : beat.compareTo(other.beat);
  }

  /// Whether this position comes before [other].
  bool operator <(Position other) => compareTo(other) < 0;

  /// Whether this position comes before or at [other].
  bool operator <=(Position other) => compareTo(other) <= 0;

  /// Whether this position comes after [other].
  bool operator >(Position other) => compareTo(other) > 0;

  /// Whether this position comes after or at [other].
  bool operator >=(Position other) => compareTo(other) >= 0;

  @override
  String toString() => 'bar $displayBar beat ${displayBeat.toStringAsFixed(3)}';

  @override
  bool operator ==(Object other) =>
      other is Position && other.bar == bar && other.beat == beat;

  @override
  int get hashCode => Object.hash(bar, beat);
}
