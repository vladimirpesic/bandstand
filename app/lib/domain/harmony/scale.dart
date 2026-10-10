import 'dart:convert';

import 'chord_type.dart';
import 'degree.dart';
import 'pitch_spelling.dart';

/// The schema version this code understands.
const int scalesSchemaVersion = 1;

/// A scale, as a name and a degree list.
///
/// §4.1 asks for scales to be modelled now, because voicing and improvisation
/// hints (§6.5, §9) need them later. Loaded from `assets/scales.json`.
class StandardScale {
  /// Create a scale.
  StandardScale({
    required this.name,
    required List<String> aliases,
    required Iterable<Degree> degrees,
    required List<String> preferredFor,
  }) : aliases = List<String>.unmodifiable(aliases),
       degrees = List<Degree>.unmodifiable(degrees.toList()..sort()),
       preferredFor = List<String>.unmodifiable(preferredFor) {
    if (this.degrees.isEmpty) {
      throw ArgumentError.value(name, 'degrees', 'a scale needs degrees');
    }
    // The same check `ChordType` makes, for the same reason: a repeated degree
    // is a typo in the table, and one that survives into the app as a scale
    // whose note count does not match its name.
    final seen = <Degree>{};
    for (final degree in this.degrees) {
      if (!seen.add(degree)) {
        throw ArgumentError.value(
          name,
          'degrees',
          'the degree $degree is named twice',
        );
      }
    }
  }

  /// The scale's name, e.g. `Lydian dominant`.
  final String name;

  /// Every way the scale is named. The first is [name].
  final List<String> aliases;

  /// The degrees, ascending.
  final List<Degree> degrees;

  /// Canonical chord-type symbols a player would normally reach for this scale
  /// over. A hint, not a constraint — see [fits].
  final List<String> preferredFor;

  /// How many notes the scale has.
  int get noteCount => degrees.length;

  /// Semitones above the root, ascending.
  List<int> get semitones =>
      <int>[for (final degree in degrees) degree.semitones]..sort();

  /// Whether every note of [type] is in the scale.
  ///
  /// This is the structural answer, and it is the one that generalises: a scale
  /// fits a chord when playing the scale cannot contradict the chord.
  bool fits(ChordType type) {
    final available = semitones.toSet();
    return type.degrees.every((d) => available.contains(d.semitones));
  }

  /// Whether the scale is one a player would normally choose for [type].
  bool isPreferredFor(ChordType type) => preferredFor.contains(type.name);

  /// The scale's pitch classes from a root pitch class.
  List<int> pitchClassesFrom(int rootPitchClass) => <int>[
    for (final degree in degrees) (rootPitchClass + degree.semitones) % 12,
  ];

  /// The scale's notes as spellings, from a spelled root.
  List<PitchSpelling> spellingsFrom(PitchSpelling root) => <PitchSpelling>[
    for (final degree in degrees) degree.from(root),
  ];

  @override
  String toString() => name;

  @override
  bool operator ==(Object other) =>
      other is StandardScale && other.name == name;

  @override
  int get hashCode => name.hashCode;
}

/// A scale rooted on a note: `D Dorian`, `Ab Lydian dominant`.
class StandardScaleInstance {
  /// Create an instance.
  const StandardScaleInstance(this.scale, this.root);

  /// The scale.
  final StandardScale scale;

  /// Where it starts.
  final PitchSpelling root;

  /// The scale's notes, spelled from [root].
  List<PitchSpelling> get spellings => scale.spellingsFrom(root);

  /// The scale's pitch classes.
  List<int> get pitchClasses => scale.pitchClassesFrom(root.pitchClass);

  /// This scale moved to a new root.
  StandardScaleInstance transposedTo(PitchSpelling newRoot) =>
      StandardScaleInstance(scale, newRoot);

  @override
  String toString() => '$root ${scale.name}';

  @override
  bool operator ==(Object other) =>
      other is StandardScaleInstance &&
      other.scale == scale &&
      other.root == root;

  @override
  int get hashCode => Object.hash(scale, root);
}

/// The scale table, loaded from `assets/scales.json`.
class ScaleLibrary {
  ScaleLibrary._(List<StandardScale> scales)
    : scales = List<StandardScale>.unmodifiable(scales) {
    for (final scale in this.scales) {
      for (final alias in scale.aliases) {
        _byAlias[alias.toLowerCase()] = scale;
      }
    }
  }

  /// Parse the library from the contents of `scales.json`.
  ///
  /// Throws [FormatException] if the schema version is unknown, an alias is
  /// duplicated, or a degree cannot be read.
  factory ScaleLibrary.fromJson(String source) {
    final Object? decoded = jsonDecode(source);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('scales.json must be a JSON object');
    }
    final version = decoded['schemaVersion'];
    if (version != scalesSchemaVersion) {
      throw FormatException(
        'scales.json is schema version $version; this build understands '
        '$scalesSchemaVersion',
      );
    }
    final entries = decoded['scales'];
    if (entries is! List) {
      throw const FormatException('scales.json: "scales" must be a list');
    }

    final scales = <StandardScale>[];
    final seen = <String, String>{};
    for (final entry in entries) {
      if (entry is! Map<String, Object?>) {
        throw const FormatException('scales.json: "scales" has a non-object');
      }
      final name = entry['name'];
      if (name is! String) {
        throw const FormatException('scales.json: a scale has no name');
      }
      final rawAliases = entry['aliases'];
      if (rawAliases is! List || rawAliases.isEmpty) {
        throw FormatException('scales.json: "$name" has no aliases');
      }
      final aliases = <String>[
        for (final alias in rawAliases)
          if (alias is String)
            alias
          else
            throw FormatException(
              'scales.json: "$name" has a non-string alias',
            ),
      ];
      for (final alias in aliases) {
        final existing = seen[alias.toLowerCase()];
        if (existing != null) {
          throw FormatException(
            'scales.json: alias "$alias" is claimed by both "$existing" and '
            '"$name"',
          );
        }
        seen[alias.toLowerCase()] = name;
      }
      final rawDegrees = entry['degrees'];
      if (rawDegrees is! List) {
        throw FormatException('scales.json: "$name" has no degrees');
      }
      final rawPreferred = entry['preferredFor'];
      scales.add(
        StandardScale(
          name: aliases.first,
          aliases: aliases,
          degrees: <Degree>[
            for (final degree in rawDegrees)
              Degree.tryParse(degree is String ? degree : '') ??
                  (throw FormatException(
                    'scales.json: "$degree" in "$name" is not a degree',
                  )),
          ],
          preferredFor: <String>[
            if (rawPreferred is List)
              for (final symbol in rawPreferred)
                if (symbol is String) symbol,
          ],
        ),
      );
    }
    if (scales.isEmpty) {
      throw const FormatException('scales.json has no scales');
    }
    return ScaleLibrary._(scales);
  }

  /// Every scale, in file order.
  final List<StandardScale> scales;

  final Map<String, StandardScale> _byAlias = <String, StandardScale>{};

  /// The scale with this name or alias, case-insensitively, or null.
  StandardScale? byName(String name) => _byAlias[name.trim().toLowerCase()];

  /// Every scale that fits [type], preferred ones first.
  List<StandardScale> fitting(ChordType type) {
    final matches = scales.where((scale) => scale.fits(type)).toList();
    matches.sort((a, b) {
      final aPreferred = a.isPreferredFor(type);
      final bPreferred = b.isPreferredFor(type);
      if (aPreferred != bPreferred) {
        return aPreferred ? -1 : 1;
      }
      // Then the scale that says the most: more notes, fewer choices left open.
      return b.noteCount.compareTo(a.noteCount);
    });
    return matches;
  }
}
