/// A half-open range of beats: `start` included, `end` excluded.
///
/// The unit a `SizedPhrase` is measured in, and the thing every "does this note
/// belong here" question is asked against.
class FloatRange {
  /// Create a range.
  ///
  /// Throws [ArgumentError] if the bounds are not finite or `end` is before
  /// `start`.
  FloatRange(this.start, this.end) {
    if (!start.isFinite || !end.isFinite) {
      throw ArgumentError.value(
        '$start..$end',
        'range',
        'bounds must be finite',
      );
    }
    if (end < start) {
      throw ArgumentError.value(
        '$start..$end',
        'range',
        'the end is before the start',
      );
    }
  }

  /// A range of `length` beats from zero.
  factory FloatRange.ofLength(double length) => FloatRange(0, length);

  /// The empty range at zero.
  static final FloatRange empty = FloatRange(0, 0);

  /// First beat in the range.
  final double start;

  /// One beat past the last.
  final double end;

  /// How long the range is.
  double get length => end - start;

  /// Whether it holds nothing.
  bool get isEmpty => end <= start;

  /// Whether `position` is in the range.
  bool contains(double position) => position >= start && position < end;

  /// Whether this range and `other` share any beat.
  bool overlaps(FloatRange other) => start < other.end && other.start < end;

  /// This range moved by `beats`.
  FloatRange shifted(double beats) => FloatRange(start + beats, end + beats);

  /// The part of this range that is also in `other`, possibly empty.
  FloatRange intersect(FloatRange other) {
    final low = start > other.start ? start : other.start;
    final high = end < other.end ? end : other.end;
    return high <= low ? FloatRange(low, low) : FloatRange(low, high);
  }

  @override
  String toString() => '[$start, $end)';

  @override
  bool operator ==(Object other) =>
      other is FloatRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);
}
