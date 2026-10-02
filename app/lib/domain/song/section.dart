import '../harmony/time_signature.dart';

/// A named span of the written chart: `A`, `B`, `Intro`, `Solos`.
///
/// A section owns a time signature, because meter changes happen at section
/// boundaries far more often than anywhere else, and because the arrangement
/// layer points at sections by name.
class Section implements Comparable<Section> {
  /// Create a section starting at [startBar].
  ///
  /// Throws [ArgumentError] if the name is empty or the bar is negative.
  Section({
    required this.name,
    required this.startBar,
    this.timeSignature = TimeSignature.fourFour,
  }) {
    if (name.trim().isEmpty) {
      throw ArgumentError.value(name, 'name', 'a section needs a name');
    }
    if (startBar < 0) {
      throw ArgumentError.value(startBar, 'startBar', 'must not be negative');
    }
  }

  /// The section's name, unique within a lead sheet.
  final String name;

  /// Zero-based bar the section starts at.
  final int startBar;

  /// The meter from this section onwards.
  final TimeSignature timeSignature;

  /// A copy with some fields replaced.
  Section copyWith({
    String? name,
    int? startBar,
    TimeSignature? timeSignature,
  }) => Section(
    name: name ?? this.name,
    startBar: startBar ?? this.startBar,
    timeSignature: timeSignature ?? this.timeSignature,
  );

  @override
  int compareTo(Section other) {
    final byBar = startBar.compareTo(other.startBar);
    return byBar != 0 ? byBar : name.compareTo(other.name);
  }

  @override
  String toString() => '$name@${startBar + 1} $timeSignature';

  @override
  bool operator ==(Object other) =>
      other is Section &&
      other.name == name &&
      other.startBar == startBar &&
      other.timeSignature == timeSignature;

  @override
  int get hashCode => Object.hash(name, startBar, timeSignature);
}
