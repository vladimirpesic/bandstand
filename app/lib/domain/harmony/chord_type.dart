import 'degree.dart';
import 'natural.dart';
import 'pitch_spelling.dart';

/// The broad character of a chord.
///
/// See `docs/rules/chord-symbols.md` §5. Not the same question as
/// [ChordType.isMinorish].
enum ChordFamily {
  /// Major triads, sixths, major sevenths and their extensions.
  major,

  /// Minor triads, minor sixths and sevenths, minor-major sevenths.
  minor,

  /// Dominant sevenths and their alterations.
  dominant,

  /// Diminished triads, diminished and half-diminished sevenths.
  diminished,

  /// Augmented triads.
  augmented,

  /// Suspended chords.
  sus,

  /// Anything else — power chords, and whatever a chart invents.
  other;

  /// Parse the name used in `chord_types.json`.
  ///
  /// Throws [FormatException] on an unknown family.
  static ChordFamily parse(String text) {
    for (final family in ChordFamily.values) {
      if (family.name == text) {
        return family;
      }
    }
    throw FormatException('unknown chord family', text);
  }
}

/// A chord quality: an ordered set of degrees, plus how it is written.
///
/// Immutable, and equal by degree *spelling*: two types are the same when they
/// carry the same degrees written the same way. `C7b5` reached through the core
/// `7b5` and through the core `7` plus the modifier `b5` are indistinguishable,
/// as they should be.
///
/// Spelling, not pitch. `==` compares each degree's `asExtension` as well as
/// the degree itself, so a third and a ninth three semitones from the root stay
/// different types — which is the distinction §5 of
/// `docs/rules/chord-symbols.md` turns on, and the one `isMinorish` reads.
class ChordType {
  /// Create a chord type from an unordered degree collection.
  ///
  /// Throws [ArgumentError] if `degrees` is empty or lists the same degree
  /// twice.
  ///
  /// Two degrees may share a written number: an altered dominant has both `b9`
  /// and `#9`, and they are different notes. They may even share a semitone
  /// count — `b5` and `#11` — because that is a spelling distinction the
  /// voicing engine needs. What they may not be is literally the same degree.
  ChordType({
    required Iterable<Degree> degrees,
    required this.name,
    required this.family,
  }) : degrees = List<Degree>.unmodifiable(degrees.toList()..sort()) {
    if (this.degrees.isEmpty) {
      throw ArgumentError.value(name, 'degrees', 'a chord type needs degrees');
    }
    final seen = <Degree>{};
    for (final degree in this.degrees) {
      if (!seen.add(degree)) {
        throw ArgumentError.value(
          name,
          'degrees',
          'the degree ${degree.symbol} repeats an earlier entry: the same '
              'degree may not be listed twice',
        );
      }
    }
  }

  /// The degrees, ascending by written number.
  final List<Degree> degrees;

  /// The canonical symbol, e.g. `m7b5` or `13b9#11`. Written after the root.
  final String name;

  /// The chord's broad character.
  final ChordFamily family;

  /// Whether the chord contains a minor third — a third, three semitones up.
  ///
  /// Not the same as `family == ChordFamily.minor`: `m7b5` and `o7` are
  /// minorish and are diminished, and `7#9` is not minorish even though its
  /// `#9` is the same three semitones. See `docs/rules/chord-symbols.md` §5.
  bool get isMinorish => degrees.any(
    (d) => d.natural == Natural.e && d.alteration == -1 && !d.asExtension,
  );

  /// The degree at [semitones] above the root, or null.
  Degree? degreeFor(int semitones) {
    final wanted = ((semitones % 12) + 12) % 12;
    for (final degree in degrees) {
      if (degree.semitones == wanted) {
        return degree;
      }
    }
    return null;
  }

  /// Whether the chord contains a degree with the given written number.
  bool hasDegreeNumber(int number) => degrees.any((d) => d.number == number);

  /// The pitch classes of the chord on [root], ascending from the root.
  List<int> pitchClassesFrom(int rootPitchClass) =>
      <int>[
        for (final degree in degrees) (rootPitchClass + degree.semitones) % 12,
      ]..sort(
        (a, b) =>
            ((a - rootPitchClass) % 12).compareTo((b - rootPitchClass) % 12),
      );

  /// The chord's notes as spellings, from a spelled root.
  List<PitchSpelling> spellingsFrom(PitchSpelling root) => <PitchSpelling>[
    for (final degree in degrees) degree.from(root),
  ];

  /// Whether every degree of [other] is also in this type.
  bool contains(ChordType other) =>
      other.degrees.every((d) => degreeFor(d.semitones) != null);

  @override
  String toString() => name;

  @override
  bool operator ==(Object other) {
    if (other is! ChordType || other.degrees.length != degrees.length) {
      return false;
    }
    for (var i = 0; i < degrees.length; i++) {
      if (degrees[i] != other.degrees[i] ||
          degrees[i].asExtension != other.degrees[i].asExtension) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hashAll(<Object>[for (final degree in degrees) degree.symbol]);
}
