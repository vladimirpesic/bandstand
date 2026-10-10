import 'dart:convert';

import 'chord_type.dart';
import 'degree.dart';

/// The schema version this code understands.
const int chordTypesSchemaVersion = 1;

/// One entry of the `modifiers` table: an operation on a degree set.
///
/// See `docs/rules/chord-symbols.md` §2.
class ChordModifier {
  /// Create a modifier.
  const ChordModifier({
    required this.symbol,
    required this.aliases,
    required this.order,
    this.setDegrees = const <Degree>[],
    this.removeNumbers = const <int>[],
    this.replacementDegrees,
    this.family,
  });

  /// The canonical symbol, written when the chord is formatted.
  final String symbol;

  /// Every way the modifier is written. The first is [symbol].
  final List<String> aliases;

  /// Sort key for canonical formatting: fifths, then ninths, then elevenths,
  /// then thirteenths, then suspensions and omissions.
  final int order;

  /// Degrees to ensure are present, each replacing any existing degree with the
  /// same degree index.
  final List<Degree> setDegrees;

  /// Degree indices (1–7) to drop.
  final List<int> removeNumbers;

  /// Replaces the entire degree set. Only `alt` uses this.
  final List<Degree>? replacementDegrees;

  /// Family this modifier forces, if any.
  final ChordFamily? family;

  /// Apply this modifier to a degree list, in place.
  ///
  /// A `set` degree displaces an existing degree of the **same number**, so
  /// `13b9` replaces the ninth rather than sitting beside it, and a chord never
  /// carries two fifths or two ninths. It cannot key on the number alone: an
  /// altered dominant carries both `b9` and `#9`, so a modified degree only
  /// yields to another spelling of itself.
  ///
  /// It deliberately does **not** collapse by semitone count across degrees.
  /// `#9` and `b3` are both three semitones and `#11` and `b5` are both six,
  /// and §5 of `docs/rules/chord-symbols.md` turns on their being different
  /// degrees — `isMinorish` is true for `m7b5` and false for `7#9` precisely
  /// because one spells those three semitones as a third and the other as a
  /// ninth. Collapsing them let a `#9` delete the minor third of `Cm7#9` and a
  /// `#11` delete the flat fifth of `Cm7b5#11`, leaving a minor chord with no
  /// third and a half-diminished chord with no diminished fifth.
  ///
  /// The cost is that a redundant symbol such as `C7b5#11` keeps both
  /// spellings of the one note. That is faithful to what was written, and it
  /// costs nothing downstream: everything that sounds a chord goes through
  /// `ChordTones`, which is a set of pitch classes.
  void applyTo(List<Degree> degrees) {
    final replacement = replacementDegrees;
    if (replacement != null) {
      degrees
        ..clear()
        ..addAll(replacement);
      return;
    }
    for (final number in removeNumbers) {
      degrees.removeWhere((d) => d.natural.degreeNumber == number);
    }
    for (final degree in setDegrees) {
      degrees.removeWhere(
        (existing) =>
            existing.natural.degreeNumber == degree.natural.degreeNumber &&
            (existing.alteration == 0 ||
                existing.alteration == degree.alteration),
      );
      degrees.add(degree);
    }
  }

  @override
  String toString() => symbol;
}

/// A core entry: a complete chord with an explicit degree list.
class CoreChordType {
  /// Create a core entry.
  const CoreChordType({required this.type, required this.aliases});

  /// The chord type itself.
  final ChordType type;

  /// Every way it is written. The first is the canonical symbol.
  final List<String> aliases;

  @override
  String toString() => type.name;
}

/// Where a quality string ended, and what it meant.
class QualityMatch {
  /// Create a match.
  const QualityMatch(this.type, this.end);

  /// The chord type the quality denotes.
  final ChordType type;

  /// Index just past the last character consumed.
  final int end;
}

/// The chord-type database of §4.1, loaded from `assets/chord_types.json`.
///
/// Pure Dart: it takes the file's *contents*, never a path. The Flutter asset
/// plumbing lives in `lib/io/harmony_assets.dart`; see ADR 0006.
class ChordTypeDatabase {
  ChordTypeDatabase._({
    required List<CoreChordType> cores,
    required List<ChordModifier> modifiers,
  }) : cores = List<CoreChordType>.unmodifiable(cores),
       modifiers = List<ChordModifier>.unmodifiable(modifiers) {
    for (final core in this.cores) {
      for (final alias in core.aliases) {
        if (alias.isNotEmpty) {
          _coreByAlias[alias] = core;
        }
      }
      _coreByDegrees.putIfAbsent(_degreeKey(core.type.degrees), () => core);
    }
    for (final modifier in this.modifiers) {
      for (final alias in modifier.aliases) {
        _modifierByAlias[alias] = modifier;
      }
    }
    _coreAliases = _byDescendingLength(_coreByAlias.keys);
    _modifierAliases = _byDescendingLength(_modifierByAlias.keys);
    _majorTriad = this.cores
        .firstWhere(
          (core) => core.aliases.contains(''),
          orElse: () => throw const FormatException(
            'chord_types.json has no core entry with an empty alias, so a bare '
            '"C" cannot be parsed',
          ),
        )
        .type;
  }

  /// Parse the database from the contents of `chord_types.json`.
  ///
  /// Throws [FormatException] if the schema version is unknown, an alias is
  /// duplicated within a table, or a degree cannot be read.
  factory ChordTypeDatabase.fromJson(String source) {
    final Object? decoded = jsonDecode(source);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('chord_types.json must be a JSON object');
    }
    final version = decoded['schemaVersion'];
    if (version != chordTypesSchemaVersion) {
      throw FormatException(
        'chord_types.json is schema version $version; this build understands '
        '$chordTypesSchemaVersion',
      );
    }

    final cores = <CoreChordType>[];
    final seenCoreAliases = <String, String>{};
    for (final entry in _list(decoded['cores'], 'cores')) {
      final name = _string(entry['name'], 'core name');
      final aliases = _aliases(entry['aliases'], name);
      for (final alias in aliases) {
        final existing = seenCoreAliases[alias];
        if (existing != null) {
          throw FormatException(
            'chord_types.json: core alias "$alias" is claimed by both '
            '"$existing" and "$name"',
          );
        }
        seenCoreAliases[alias] = name;
      }
      cores.add(
        CoreChordType(
          type: ChordType(
            degrees: _degrees(entry['degrees'], name),
            name: aliases.first,
            family: ChordFamily.parse(_string(entry['family'], 'family')),
          ),
          aliases: aliases,
        ),
      );
    }

    final modifiers = <ChordModifier>[];
    final seenModifierAliases = <String, String>{};
    for (final entry in _list(decoded['modifiers'], 'modifiers')) {
      final symbol = _string(entry['symbol'], 'modifier symbol');
      final aliases = _aliases(entry['aliases'], symbol);
      for (final alias in aliases) {
        final existing = seenModifierAliases[alias];
        if (existing != null) {
          throw FormatException(
            'chord_types.json: modifier alias "$alias" is claimed by both '
            '"$existing" and "$symbol"',
          );
        }
        seenModifierAliases[alias] = symbol;
      }
      final familyName = entry['family'];
      modifiers.add(
        ChordModifier(
          symbol: aliases.first,
          aliases: aliases,
          order: _int(entry['order'], 'order in "$symbol"'),
          setDegrees: entry['set'] == null
              ? const <Degree>[]
              : _degrees(entry['set'], symbol),
          removeNumbers: entry['remove'] == null
              ? const <int>[]
              : <int>[
                  for (final value in _rawList(entry['remove'], 'remove'))
                    _int(value, 'remove in "$symbol"'),
                ],
          replacementDegrees: entry['degrees'] == null
              ? null
              : _degrees(entry['degrees'], symbol),
          family: familyName == null
              ? null
              : ChordFamily.parse(_string(familyName, 'family')),
        ),
      );
    }

    if (cores.isEmpty) {
      throw const FormatException('chord_types.json has no core types');
    }
    return ChordTypeDatabase._(cores: cores, modifiers: modifiers);
  }

  /// The core entries.
  final List<CoreChordType> cores;

  /// The modifier entries.
  final List<ChordModifier> modifiers;

  final Map<String, CoreChordType> _coreByAlias = <String, CoreChordType>{};
  final Map<String, ChordModifier> _modifierByAlias = <String, ChordModifier>{};
  final Map<String, CoreChordType> _coreByDegrees = <String, CoreChordType>{};
  late final List<String> _coreAliases;
  late final List<String> _modifierAliases;
  late final ChordType _majorTriad;

  /// The major triad — what a bare `C` means.
  ChordType get majorTriad => _majorTriad;

  /// Every core type, in file order.
  Iterable<ChordType> get coreTypes => cores.map((core) => core.type);

  /// The type a whole quality string denotes, or null if it does not parse.
  ///
  /// `''` gives the major triad; `'m7b5'`, `'13b9#11'` and `'7(b9)'` all work.
  ChordType? typeFor(String quality) {
    final match = matchQualityAt(quality, 0);
    if (match == null || match.end != quality.length) {
      return null;
    }
    return match.type;
  }

  /// Read a quality starting at [start], stopping at `/` or the end.
  ///
  /// Returns null only when a character cannot be accounted for. See
  /// `docs/rules/chord-symbols.md` §3.
  QualityMatch? matchQualityAt(String text, int start) {
    var cursor = start;
    // Separators are noise wherever they appear, including before the quality:
    // some charts write `C maj7`.
    while (cursor < text.length && _isSeparator(text[cursor])) {
      cursor++;
    }
    final core = _matchLongest(text, cursor, _coreAliases, _coreByAlias);
    ChordFamily family;
    final degrees = <Degree>[];
    final applied = <ChordModifier>[];

    if (core != null) {
      cursor += core.key.length;
      family = core.value.type.family;
      degrees.addAll(core.value.type.degrees);
    } else {
      family = _majorTriad.family;
      degrees.addAll(_majorTriad.degrees);
    }

    while (cursor < text.length) {
      final character = text[cursor];
      if (character == '/') {
        break;
      }
      if (_isSeparator(character)) {
        cursor++;
        continue;
      }
      final modifier = _matchLongest(
        text,
        cursor,
        _modifierAliases,
        _modifierByAlias,
      );
      if (modifier == null) {
        return null;
      }
      cursor += modifier.key.length;
      modifier.value.applyTo(degrees);
      applied.add(modifier.value);
      family = modifier.value.family ?? family;
    }

    if (degrees.isEmpty) {
      return null;
    }

    final resolved = degrees.toList()..sort();
    final canonical = _coreByDegrees[_degreeKey(resolved)];
    if (canonical != null) {
      return QualityMatch(canonical.type, cursor);
    }

    final coreSymbol = core?.value.aliases.first ?? '';
    // Tie-broken by the order they were written in, because `List.sort` is not
    // a stable sort and the `order` values are shared in groups — `b9`, `#9`
    // and `9` all sit at 20, and seven other groups collide the same way.
    // Dart's sort happens to preserve input order for lists this small, so
    // `C7b9#9` names itself the same way every time today; nothing in the
    // language says it must, and a chord that renamed itself between SDK
    // versions would break `parse(format(x)) == x` (§6) in a way nobody would
    // think to look for.
    final ordered = applied.indexed.toList()
      ..sort((a, b) {
        final byOrder = a.$2.order.compareTo(b.$2.order);
        return byOrder != 0 ? byOrder : a.$1.compareTo(b.$1);
      });
    final name = StringBuffer(coreSymbol);
    for (final (_, modifier) in ordered) {
      name.write(modifier.symbol);
    }
    return QualityMatch(
      ChordType(degrees: resolved, name: name.toString(), family: family),
      cursor,
    );
  }

  /// The core entry whose degrees are exactly [degrees], or null.
  ChordType? canonicalFor(Iterable<Degree> degrees) =>
      _coreByDegrees[_degreeKey(degrees.toList()..sort())]?.type;

  static bool _isSeparator(String character) =>
      character == '(' ||
      character == ')' ||
      character == ' ' ||
      character == ',';

  static MapEntry<String, T>? _matchLongest<T>(
    String text,
    int start,
    List<String> aliases,
    Map<String, T> table,
  ) {
    for (final alias in aliases) {
      if (start + alias.length <= text.length &&
          text.startsWith(alias, start)) {
        return MapEntry<String, T>(alias, table[alias] as T);
      }
    }
    return null;
  }

  static List<String> _byDescendingLength(Iterable<String> aliases) =>
      aliases.toList()..sort((a, b) {
        final byLength = b.length.compareTo(a.length);
        return byLength != 0 ? byLength : a.compareTo(b);
      });

  static String _degreeKey(List<Degree> degrees) =>
      degrees.map((d) => d.symbol).join(' ');

  static List<Map<String, Object?>> _list(Object? value, String what) {
    if (value is! List) {
      throw FormatException('chord_types.json: "$what" must be a list');
    }
    return <Map<String, Object?>>[
      for (final entry in value)
        if (entry is Map<String, Object?>)
          entry
        else
          throw FormatException('chord_types.json: "$what" has a non-object'),
    ];
  }

  static List<Object?> _rawList(Object? value, String what) {
    if (value is! List) {
      throw FormatException('chord_types.json: "$what" must be a list');
    }
    return value;
  }

  static String _string(Object? value, String what) {
    if (value is! String) {
      throw FormatException('chord_types.json: $what must be a string');
    }
    return value;
  }

  static int _int(Object? value, String what) {
    if (value is! int) {
      throw FormatException('chord_types.json: $what must be an integer');
    }
    return value;
  }

  static List<String> _aliases(Object? value, String owner) {
    final raw = _rawList(value, 'aliases of "$owner"');
    if (raw.isEmpty) {
      throw FormatException('chord_types.json: "$owner" has no aliases');
    }
    return <String>[
      for (final alias in raw) _string(alias, 'an alias of "$owner"'),
    ];
  }

  static List<Degree> _degrees(Object? value, String owner) {
    final raw = _rawList(value, 'degrees of "$owner"');
    return <Degree>[
      for (final entry in raw)
        Degree.tryParse(_string(entry, 'a degree of "$owner"')) ??
            (throw FormatException(
              'chord_types.json: "$entry" in "$owner" is not a degree',
            )),
    ];
  }
}
