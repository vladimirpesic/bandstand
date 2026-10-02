import 'dart:convert';

import '../chord_symbol.dart';
import '../pitch_spelling.dart';
import 'chord_diagram.dart';

/// The schema version this build understands.
const int chordDiagramsSchemaVersion = 1;

/// Every instrument's shapes.
///
/// Format: `docs/format/chord-diagrams.md`. Data, not code (§15): a search over
/// playable fingerings is a genuinely hard problem whose results are worse than
/// a table someone played.
class ChordDiagramLibrary {
  /// Index a set of instruments.
  ///
  /// Throws [ArgumentError] if two share an id.
  factory ChordDiagramLibrary(Iterable<DiagramInstrument> instruments) {
    final list = List<DiagramInstrument>.unmodifiable(instruments);
    final seen = <String>{};
    for (final instrument in list) {
      if (!seen.add(instrument.id)) {
        throw ArgumentError.value(
          instrument.id,
          'instruments',
          'two instruments share this id',
        );
      }
    }
    return ChordDiagramLibrary._(list);
  }

  const ChordDiagramLibrary._(this.instruments);

  /// Parse `chord_diagrams.json`.
  ///
  /// Throws [FormatException] on anything malformed, naming the instrument.
  factory ChordDiagramLibrary.fromJson(String source) {
    final Object? decoded = jsonDecode(source);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('chord_diagrams.json must be a JSON object');
    }
    if (decoded['schemaVersion'] != chordDiagramsSchemaVersion) {
      throw FormatException(
        'chord_diagrams.json is schema version ${decoded['schemaVersion']}; '
        'this build understands $chordDiagramsSchemaVersion',
      );
    }
    final raw = decoded['instruments'];
    if (raw is! List || raw.isEmpty) {
      throw const FormatException('chord_diagrams.json has no instruments');
    }
    return ChordDiagramLibrary(<DiagramInstrument>[
      for (final entry in raw) _readInstrument(entry),
    ]);
  }

  /// The instruments, in file order.
  final List<DiagramInstrument> instruments;

  /// The instrument with this id, or null.
  DiagramInstrument? operator [](String id) {
    for (final instrument in instruments) {
      if (instrument.id == id) {
        return instrument;
      }
    }
    return null;
  }

  /// The shape for a chord on an instrument, or null when there is none.
  ///
  /// A slash chord looks up its own entry rather than falling back to the
  /// chord without the bass note: `C/G` is a different shape from `C`, and
  /// showing `C` for it is worse than showing nothing, because it is
  /// confidently wrong (`docs/rules/chord-diagrams.md` §2).
  ChordShape? shapeFor(String instrumentId, ChordSymbol chord) =>
      this[instrumentId]?.shapeFor(chord);

  static DiagramInstrument _readInstrument(Object? raw) {
    if (raw is! Map<String, Object?>) {
      throw const FormatException('every instrument must be an object');
    }
    final id = raw['id'];
    if (id is! String || id.trim().isEmpty) {
      throw const FormatException('every instrument needs an id');
    }
    final tuning = raw['tuning'];
    if (tuning is! List || tuning.isEmpty) {
      throw FormatException('instrument "$id" needs a tuning');
    }
    final displayNameRaw = raw['displayName'];
    if (displayNameRaw != null && displayNameRaw is! String) {
      // Checked before the cast below, so a wrong-typed field is a format
      // error naming the field — not a TypeError through the FFI (L-TQ6).
      throw FormatException('instrument "$id" has a non-string displayName');
    }
    final displayName = displayNameRaw as String?;
    final shapes = raw['shapes'];
    if (shapes is! List || shapes.isEmpty) {
      throw FormatException('instrument "$id" has no shapes');
    }
    try {
      return DiagramInstrument(
        id: id,
        displayName: displayName ?? id,
        tuning: <int>[
          for (final pitch in tuning)
            if (pitch is int)
              pitch
            else
              throw FormatException(
                'instrument "$id" has a non-integer tuning',
              ),
        ],
        shapes: <ChordShape>[for (final shape in shapes) _readShape(id, shape)],
      );
    } on ArgumentError catch (error) {
      throw FormatException('instrument "$id": ${error.message}');
    } on TypeError catch (error) {
      // A backstop for fields added later without their own check above:
      // the failing cast is a format problem in the file, and it must not
      // escape as a TypeError (L-TQ6).
      throw FormatException('instrument "$id": $error');
    }
  }

  static ChordShape _readShape(String instrument, Object? raw) {
    if (raw is! Map<String, Object?>) {
      throw FormatException('instrument "$instrument" has a malformed shape');
    }
    final type = raw['type'];
    if (type is! String) {
      throw FormatException('a shape of "$instrument" has no type');
    }
    final frets = raw['frets'];
    if (frets is! List || frets.isEmpty) {
      throw FormatException('shape "$type" of "$instrument" has no frets');
    }
    final rootText = raw['root'];
    final rootString = raw['rootString'];
    if (rootString != null && rootString is! int) {
      throw FormatException(
        'shape "$type" of "$instrument" has a non-integer rootString',
      );
    }
    final baseFretRaw = raw['baseFret'];
    if (baseFretRaw != null && baseFretRaw is! int) {
      // Checked before the cast below, so a wrong-typed field is a format
      // error naming the field — not a TypeError through the FFI (L-TQ6).
      throw FormatException(
        'shape "$type" of "$instrument" has a non-integer baseFret',
      );
    }
    final baseFret = baseFretRaw as int?;
    try {
      return ChordShape(
        type: type,
        root: rootText is String ? PitchSpelling.parse(rootText) : null,
        rootString: rootString as int?,
        baseFret: baseFret ?? 1,
        frets: <int>[
          for (final fret in frets)
            if (fret is int)
              fret
            else
              throw FormatException('shape "$type" has a non-integer fret'),
        ],
        barre: _readBarre(type, raw['barre']),
      );
    } on ArgumentError catch (error) {
      throw FormatException('shape "$type" of "$instrument": ${error.message}');
    } on TypeError catch (error) {
      // The backstop of `_readInstrument`, for the casts here (L-TQ6).
      throw FormatException('shape "$type" of "$instrument": $error');
    }
  }

  static Barre? _readBarre(String type, Object? raw) {
    if (raw == null) {
      return null;
    }
    if (raw is! Map<String, Object?>) {
      throw FormatException('shape "$type" has a malformed barre');
    }
    final fret = raw['fret'];
    final from = raw['fromString'];
    final to = raw['toString'];
    if (fret is! int || from is! int || to is! int) {
      throw FormatException('shape "$type" has an incomplete barre');
    }
    try {
      return Barre(fret: fret, fromString: from, toString_: to);
    } on ArgumentError catch (error) {
      throw FormatException('shape "$type": ${error.message}');
    } on TypeError catch (error) {
      throw FormatException('shape "$type": $error');
    }
  }
}
