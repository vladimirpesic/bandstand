import 'rhythm.dart';

/// One block of the arrangement: play this section, this many bars, with this
/// style and these parameter values (§4.3).
///
/// A song part *points at* a section of the lead sheet by name. It does not
/// own bars — the lead sheet does — which is what lets the same eight bars be
/// played three times with different intensities.
class SongPart {
  /// Create a song part.
  ///
  /// Throws [ArgumentError] if the section name is empty, the start bar is
  /// negative or the bar count is not positive.
  SongPart({
    required this.parentSectionName,
    required this.startBar,
    required this.barCount,
    required this.rhythmId,
    Map<String, Object> parameterValues = const <String, Object>{},
    this.name,
  }) : parameterValues = Map<String, Object>.unmodifiable(parameterValues) {
    if (parentSectionName.trim().isEmpty) {
      throw ArgumentError.value(
        parentSectionName,
        'parentSectionName',
        'a song part points at a section',
      );
    }
    if (startBar < 0) {
      throw ArgumentError.value(startBar, 'startBar', 'must not be negative');
    }
    if (barCount < 1) {
      throw ArgumentError.value(barCount, 'barCount', 'must be at least one');
    }
  }

  /// The lead-sheet section this part plays.
  final String parentSectionName;

  /// Where the part starts in the *arrangement*, zero-based.
  final int startBar;

  /// How many bars it lasts.
  final int barCount;

  /// The style, by id. Resolved through a [RhythmRegistry] when one is
  /// installed; a song whose style is missing still opens and still edits.
  final String rhythmId;

  /// Values for the rhythm's parameters, keyed by parameter id.
  final Map<String, Object> parameterValues;

  /// An override for the display name, or null to use the section's.
  final String? name;

  /// One past the last bar.
  int get endBar => startBar + barCount;

  /// What the arrangement screen calls this part.
  String get displayName => name ?? parentSectionName;

  /// Whether [bar] falls inside this part.
  bool contains(int bar) => bar >= startBar && bar < endBar;

  /// The value of [parameterId], falling back to the rhythm's default.
  Object? parameterValue(String parameterId, {Rhythm? rhythm}) {
    final stored = parameterValues[parameterId];
    final spec = rhythm?.parameter(parameterId);
    if (spec == null) {
      return stored;
    }
    return spec.coerce(stored);
  }

  /// A copy with some fields replaced.
  SongPart copyWith({
    String? parentSectionName,
    int? startBar,
    int? barCount,
    String? rhythmId,
    Map<String, Object>? parameterValues,
    String? name,
    bool clearName = false,
  }) => SongPart(
    parentSectionName: parentSectionName ?? this.parentSectionName,
    startBar: startBar ?? this.startBar,
    barCount: barCount ?? this.barCount,
    rhythmId: rhythmId ?? this.rhythmId,
    parameterValues: parameterValues ?? this.parameterValues,
    name: clearName ? null : (name ?? this.name),
  );

  /// A copy with one parameter changed.
  SongPart withParameter(String parameterId, Object value) => copyWith(
    parameterValues: <String, Object>{...parameterValues, parameterId: value},
  );

  @override
  String toString() => '$displayName bars ${startBar + 1}–$endBar ($rhythmId)';

  @override
  bool operator ==(Object other) =>
      other is SongPart &&
      other.parentSectionName == parentSectionName &&
      other.startBar == startBar &&
      other.barCount == barCount &&
      other.rhythmId == rhythmId &&
      other.name == name &&
      _sameParameters(other.parameterValues);

  bool _sameParameters(Map<String, Object> other) {
    if (other.length != parameterValues.length) {
      return false;
    }
    for (final entry in parameterValues.entries) {
      if (other[entry.key] != entry.value) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    parentSectionName,
    startBar,
    barCount,
    rhythmId,
    name,
    Object.hashAllUnordered(
      parameterValues.entries.map((e) => Object.hash(e.key, e.value)),
    ),
  );
}
