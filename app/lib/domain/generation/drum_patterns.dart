import 'dart:convert';

import '../harmony/time_signature.dart';

/// The schema version this code understands.
const int drumPatternsSchemaVersion = 1;

/// What a pattern is for.
enum PatternRole {
  /// The groove.
  groove,

  /// A fill, at a section boundary or every few bars.
  fill,

  /// The last bar of the last part.
  ending,
}

/// One hit: an instrument, a place, a loudness and a likelihood.
class DrumHit {
  /// Create a hit.
  const DrumHit({
    required this.instrument,
    required this.beat,
    required this.velocity,
    this.chance = 1.0,
  });

  /// The instrument's name, mapped to a key by the pattern set.
  final String instrument;

  /// Where it is played, in beats from the start of the pattern.
  final double beat;

  /// How hard, 1–127, before weighting and intensity.
  final int velocity;

  /// How often it is played, 0 to 1.
  ///
  /// What stops a two-bar loop being a two-bar loop. The draw is deterministic:
  /// it comes from the generation seed (`docs/rules/drum-generation.md` §3).
  final double chance;

  /// Whether this hit is played every time.
  bool get isCertain => chance >= 1.0;
}

/// One or two bars of drums.
class DrumPattern {
  /// Create a pattern.
  DrumPattern({
    required this.id,
    required this.name,
    required this.timeSignature,
    required this.bars,
    required this.role,
    required this.lowestIntensity,
    required this.highestIntensity,
    required List<DrumHit> hits,
  }) : hits = List<DrumHit>.unmodifiable(hits);

  /// Stable identifier.
  final String id;

  /// What it is called.
  final String name;

  /// The meter it is written for.
  final TimeSignature timeSignature;

  /// How many bars it covers.
  final int bars;

  /// What it is for.
  final PatternRole role;

  /// Lowest intensity this pattern suits, 0–100.
  final int lowestIntensity;

  /// Highest intensity it suits.
  final int highestIntensity;

  /// The hits.
  final List<DrumHit> hits;

  /// How long it lasts, in beats.
  double get lengthBeats => (bars * timeSignature.upper).toDouble();

  /// Whether it suits a part at `intensity`.
  bool suits(int intensity) =>
      intensity >= lowestIntensity && intensity <= highestIntensity;

  @override
  String toString() => '$id (${role.name}, $bars bar)';
}

/// The pattern library, loaded from `assets/drum_patterns.json`.
///
/// Pure Dart: it takes the file's contents, never a path (ADR 0006).
class DrumPatternSet {
  DrumPatternSet._(this.instruments, List<DrumPattern> patterns)
    : patterns = List<DrumPattern>.unmodifiable(patterns);

  /// Parse the library from the contents of `drum_patterns.json`.
  ///
  /// Throws [FormatException] if the schema version is unknown, a pattern names
  /// an instrument the file does not define, or a hit falls outside its own
  /// pattern.
  factory DrumPatternSet.fromJson(String source) {
    final Object? decoded = jsonDecode(source);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('drum_patterns.json must be a JSON object');
    }
    if (decoded['schemaVersion'] != drumPatternsSchemaVersion) {
      throw FormatException(
        'drum_patterns.json is schema version ${decoded['schemaVersion']}; '
        'this build understands $drumPatternsSchemaVersion',
      );
    }

    final rawInstruments = decoded['instruments'];
    if (rawInstruments is! Map<String, Object?>) {
      throw const FormatException('drum_patterns.json has no instrument table');
    }
    final instruments = <String, int>{
      for (final entry in rawInstruments.entries)
        if (entry.value case final int key) entry.key: key,
    };
    if (instruments.isEmpty) {
      throw const FormatException('the instrument table is empty');
    }

    final rawPatterns = decoded['patterns'];
    if (rawPatterns is! List) {
      throw const FormatException('drum_patterns.json has no patterns');
    }

    final patterns = <DrumPattern>[];
    final seen = <String>{};
    for (final entry in rawPatterns) {
      if (entry is! Map<String, Object?>) {
        throw const FormatException('a pattern is not an object');
      }
      final id = entry['id'];
      if (id is! String || id.isEmpty) {
        throw const FormatException('a pattern has no id');
      }
      if (!seen.add(id)) {
        throw FormatException('two patterns are called "$id"');
      }
      final meter = TimeSignature.tryParse('${entry['meter']}');
      if (meter == null) {
        throw FormatException('"$id" has no meter');
      }
      final bars = entry['bars'];
      if (bars is! int || bars < 1) {
        throw FormatException('"$id" does not say how many bars it is');
      }
      final intensity = entry['intensity'];
      final lowest = intensity is List && intensity.isNotEmpty
          ? (intensity[0] as num).toInt()
          : 0;
      final highest = intensity is List && intensity.length > 1
          ? (intensity[1] as num).toInt()
          : 100;

      final rawHits = entry['hits'];
      if (rawHits is! List || rawHits.isEmpty) {
        throw FormatException('"$id" has no hits');
      }
      final length = bars * meter.upper;
      final hits = <DrumHit>[];
      for (final rawHit in rawHits) {
        if (rawHit is! Map<String, Object?>) {
          throw FormatException('"$id" has a hit that is not an object');
        }
        final instrument = rawHit['instrument'];
        if (instrument is! String || !instruments.containsKey(instrument)) {
          throw FormatException(
            '"$id" names an unknown instrument $instrument',
          );
        }
        final beat = (rawHit['beat'] as num?)?.toDouble();
        if (beat == null || beat < 0 || beat >= length) {
          throw FormatException(
            '"$id" has a hit at $beat, outside its $length beats',
          );
        }
        final velocity = (rawHit['velocity'] as num?)?.toInt() ?? 80;
        hits.add(
          DrumHit(
            instrument: instrument,
            beat: beat,
            velocity: velocity.clamp(1, 127),
            chance: (rawHit['chance'] as num?)?.toDouble() ?? 1.0,
          ),
        );
      }

      patterns.add(
        DrumPattern(
          id: id,
          name: entry['name'] is String ? entry['name']! as String : id,
          timeSignature: meter,
          bars: bars,
          role: switch (entry['role']) {
            'fill' => PatternRole.fill,
            'ending' => PatternRole.ending,
            _ => PatternRole.groove,
          },
          lowestIntensity: lowest,
          highestIntensity: highest,
          hits: hits..sort((a, b) => a.beat.compareTo(b.beat)),
        ),
      );
    }

    if (patterns.isEmpty) {
      throw const FormatException('drum_patterns.json has no patterns');
    }
    return DrumPatternSet._(
      Map<String, int>.unmodifiable(instruments),
      patterns,
    );
  }

  /// Instrument name to General MIDI percussion key.
  final Map<String, int> instruments;

  /// Every pattern, in file order.
  final List<DrumPattern> patterns;

  /// The key an instrument name maps to, or null.
  int? keyFor(String instrument) => instruments[instrument];

  /// Every pattern for a meter and a role.
  List<DrumPattern> matching(TimeSignature meter, PatternRole role) => patterns
      .where((p) => p.timeSignature == meter && p.role == role)
      .toList();

  /// Every pattern for a meter, role and intensity.
  List<DrumPattern> candidates(
    TimeSignature meter,
    PatternRole role,
    int intensity,
  ) {
    final byMeter = matching(meter, role);
    final suited = byMeter.where((p) => p.suits(intensity)).toList();
    // A meter with patterns but none at this intensity still plays: the
    // intensity range is a preference, and silence is not.
    return suited.isEmpty ? byMeter : suited;
  }

  /// The meters this set covers.
  Set<TimeSignature> get meters => patterns.map((p) => p.timeSignature).toSet();
}
