import 'dart:convert';

import '../../harmony/time_signature.dart';
import 'comping_cell.dart';

/// The schema version this build understands.
const int compingCellsSchemaVersion = 1;

/// The rhythmic cell corpus of `docs/rules/comping.md` §1.
///
/// Data, not code (§15). Read from `app/assets/comping_cells.json` by the io
/// layer, which passes the contents rather than a path (ADR 0006).
class CompingCellSet {
  /// Index a set of cells.
  ///
  /// Throws [ArgumentError] if two cells share an id — the freshness rule
  /// tracks cells by id, so duplicates would be heard as one.
  factory CompingCellSet(Iterable<CompingCell> cells) {
    final list = List<CompingCell>.unmodifiable(cells);
    final seen = <String>{};
    for (final cell in list) {
      if (!seen.add(cell.id)) {
        throw ArgumentError.value(cell.id, 'cells', 'two cells share this id');
      }
    }
    return CompingCellSet._(list);
  }

  const CompingCellSet._(this.cells);

  /// Parse `comping_cells.json`.
  ///
  /// Throws [FormatException] on anything malformed, naming the cell.
  factory CompingCellSet.fromJson(String source) {
    final Object? decoded = jsonDecode(source);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('comping_cells.json must be a JSON object');
    }
    if (decoded['schemaVersion'] != compingCellsSchemaVersion) {
      throw FormatException(
        'comping_cells.json is schema version ${decoded['schemaVersion']}; '
        'this build understands $compingCellsSchemaVersion',
      );
    }
    final rawCells = decoded['cells'];
    if (rawCells is! List || rawCells.isEmpty) {
      throw const FormatException('comping_cells.json has no cells');
    }
    return CompingCellSet(<CompingCell>[
      for (final raw in rawCells) _readCell(raw),
    ]);
  }

  /// Every cell, in the order the file listed them.
  final List<CompingCell> cells;

  /// How many.
  int get length => cells.length;

  /// Whether there is nothing to comp with.
  bool get isEmpty => cells.isEmpty;

  /// The meters the corpus covers (§4.6).
  Set<TimeSignature> get meters => <TimeSignature>{
    for (final cell in cells) cell.timeSignature,
  };

  /// Cells for a meter and an intensity, that fit in `barsAvailable`.
  ///
  /// The room check is §7.4, and it is the same bug the two-bar drum groove
  /// had: a two-bar cell must not start in the last bar.
  List<CompingCell> candidates({
    required TimeSignature meter,
    required int intensity,
    required int barsAvailable,
  }) => <CompingCell>[
    for (final cell in cells)
      if (cell.timeSignature == meter &&
          cell.admits(intensity) &&
          cell.bars <= barsAvailable)
        cell,
  ];

  static CompingCell _readCell(Object? raw) {
    if (raw is! Map<String, Object?>) {
      throw const FormatException('every cell must be an object');
    }
    final id = raw['id'];
    if (id is! String || id.trim().isEmpty) {
      throw const FormatException('every cell needs an id');
    }
    final meter = raw['meter'];
    if (meter is! String) {
      throw FormatException('cell "$id" needs a meter');
    }
    final bars = raw['bars'] ?? 1;
    if (bars is! int) {
      throw FormatException('cell "$id" has a non-integer bar count');
    }
    final rawOnsets = raw['onsets'];
    if (rawOnsets is! List || rawOnsets.isEmpty) {
      throw FormatException('cell "$id" has no onsets');
    }

    try {
      return CompingCell(
        id: id,
        timeSignature: TimeSignature.parse(meter),
        bars: bars,
        onsets: <CellOnset>[
          for (final onset in rawOnsets) _readOnset(id, onset),
        ],
        minimumIntensity: _readInt(raw['minimumIntensity'], 0, id),
        maximumIntensity: _readInt(raw['maximumIntensity'], 100, id),
        tags: _readTags(id, raw['tags']),
      );
    } on ArgumentError catch (error) {
      throw FormatException('cell "$id": ${error.message}');
    }
  }

  static CellOnset _readOnset(String id, Object? raw) {
    if (raw is! Map<String, Object?>) {
      throw FormatException('cell "$id" has a malformed onset');
    }
    final beat = raw['beat'];
    final duration = raw['duration'];
    if (beat is! num || duration is! num) {
      throw FormatException('cell "$id" has an onset without a beat or length');
    }
    final accent = raw['accent'] ?? 0.5;
    if (accent is! num) {
      throw FormatException('cell "$id" has a non-numeric accent');
    }
    try {
      return CellOnset(
        beat: beat.toDouble(),
        durationBeats: duration.toDouble(),
        accent: accent.toDouble(),
      );
    } on ArgumentError catch (error) {
      throw FormatException('cell "$id": ${error.message}');
    }
  }

  static int _readInt(Object? raw, int fallback, String id) {
    if (raw == null) {
      return fallback;
    }
    if (raw is! int) {
      throw FormatException('cell "$id" has a non-integer intensity bound');
    }
    return raw;
  }

  static Set<String> _readTags(String id, Object? raw) {
    if (raw == null) {
      return const <String>{};
    }
    if (raw is! List) {
      throw FormatException('cell "$id" has non-list tags');
    }
    return <String>{
      for (final tag in raw)
        if (tag is String)
          tag
        else
          throw FormatException('cell "$id" has a non-string tag'),
    };
  }
}
