import 'chord_type.dart';
import 'chord_type_database.dart';
import 'degree.dart';
import 'harmony_registry.dart';
import 'natural.dart';
import 'pitch_spelling.dart';
import 'spelling_preference.dart';

/// A chord: a spelled root, a type, and optionally a bass note.
///
/// The bass of a slash chord is a *note*, not a chord — `C/E` is a C major
/// triad with an E underneath. See `docs/rules/chord-symbols.md` §3.
class ChordSymbol {
  /// Create a chord symbol.
  const ChordSymbol(this.root, this.type, {this.bass});

  /// Parse a chord symbol: `C`, `Dm7`, `Bbmaj7#11`, `F#m7b5`, `C7(b9)`, `Dm7/G`.
  ///
  /// Throws [FormatException] on anything that is not a chord. The parser never
  /// guesses: a silently mis-parsed chord is worse on stage than a loud failure
  /// in the editor.
  factory ChordSymbol.parse(String text, {ChordTypeDatabase? database}) {
    final symbol = ChordSymbol.tryParse(text, database: database);
    if (symbol == null) {
      throw FormatException('not a chord symbol', text);
    }
    return symbol;
  }

  /// Parse, or null if `text` is not a chord symbol.
  static ChordSymbol? tryParse(String text, {ChordTypeDatabase? database}) {
    final types = database ?? Harmony.chordTypes;
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    final root = _readRoot(trimmed, 0);
    if (root == null) {
      return null;
    }

    final quality = types.matchQualityAt(trimmed, root.end);
    if (quality == null) {
      return null;
    }

    var cursor = quality.end;
    PitchSpelling? bass;
    if (cursor < trimmed.length && trimmed[cursor] == '/') {
      final parsed = _readRoot(trimmed, cursor + 1);
      if (parsed == null) {
        return null;
      }
      bass = parsed.spelling;
      cursor = parsed.end;
    }
    if (cursor != trimmed.length) {
      return null;
    }

    return ChordSymbol(root.spelling, quality.type, bass: bass);
  }

  /// The root, spelled.
  final PitchSpelling root;

  /// The quality.
  final ChordType type;

  /// The bass note of a slash chord, or null.
  final PitchSpelling? bass;

  /// The root's letter. Named as §4.1 names it.
  Natural get rootNatural => root.natural;

  /// The root's accidental. Named as §4.1 names it.
  int get rootAlteration => root.alteration;

  /// The root's pitch class, 0–11.
  int get rootPitchClass => root.pitchClass;

  /// Whether the chord has a bass note other than its root.
  bool get isSlashChord => bass != null && bass!.pitchClass != root.pitchClass;

  /// Whether the chord contains a minor third.
  bool get isMinorish => type.isMinorish;

  /// The chord's pitch classes, from the root upwards, bass note excluded.
  List<int> get pitchClasses => type.pitchClassesFrom(root.pitchClass);

  /// The chord's notes as spellings.
  List<PitchSpelling> get spellings => type.spellingsFrom(root);

  /// The degree of [semitones] above the root, or null.
  Degree? degreeFor(int semitones) => type.degreeFor(semitones);

  /// This chord moved by [semitones].
  ///
  /// The spelling of the result comes from [preference], **not** from letter
  /// arithmetic on the source — which is why `Eb7` up a semitone is `E7` and
  /// not `Fb7`. See `docs/rules/pitch-and-spelling.md` §7.
  ChordSymbol transposed(int semitones, {SpellingPreference? preference}) {
    // Transposing by nothing is the identity, even when the chord is spelled
    // unusually. Re-spelling is [respelled], and it is a different intent.
    if (semitones % 12 == 0) {
      return this;
    }
    return respelledAt(semitones, preference ?? SpellingPreference.automatic);
  }

  /// This chord written the way [preference] would write it, without moving it.
  ///
  /// `D#7.respelled(SpellingPreference.automatic)` is `Eb7`.
  ChordSymbol respelled(SpellingPreference preference) =>
      respelledAt(0, preference);

  /// This chord moved by [semitones] and spelled by [preference].
  ///
  /// The building block behind [transposed] and [respelled]; use those unless
  /// you mean both at once.
  ChordSymbol respelledAt(int semitones, SpellingPreference preference) {
    final currentBass = bass;
    return ChordSymbol(
      preference.spell(root.pitchClass + semitones),
      type,
      bass: currentBass == null
          ? null
          : preference.spell(currentBass.pitchClass + semitones),
    );
  }

  /// This chord with a different type.
  ChordSymbol withType(ChordType newType) =>
      ChordSymbol(root, newType, bass: bass);

  /// This chord with a different bass, or none.
  ChordSymbol withBass(PitchSpelling? newBass) =>
      ChordSymbol(root, type, bass: newBass);

  /// The chord as it is written: root, type, then `/bass`.
  ///
  /// `ChordSymbol.parse(x.format()) == x` for every chord this library
  /// produces — see `docs/rules/chord-symbols.md` §6.
  String format() {
    final buffer = StringBuffer()
      ..write(root)
      ..write(type.name);
    final currentBass = bass;
    if (currentBass != null) {
      buffer
        ..write('/')
        ..write(currentBass);
    }
    return buffer.toString();
  }

  /// Whether this chord sounds the same as [other], however it is written.
  bool isEnharmonicWith(ChordSymbol other) =>
      rootPitchClass == other.rootPitchClass &&
      type == other.type &&
      (bass?.pitchClass) == (other.bass?.pitchClass);

  static _RootMatch? _readRoot(String text, int start) {
    if (start >= text.length) {
      return null;
    }
    final natural = Natural.fromLetter(text[start]);
    if (natural == null) {
      return null;
    }
    final run = PitchSpelling.readAccidentals(text, start + 1);
    if (run.alteration < -maxAlteration || run.alteration > maxAlteration) {
      return null;
    }
    return _RootMatch(PitchSpelling(natural, run.alteration), run.end);
  }

  @override
  String toString() => format();

  @override
  bool operator ==(Object other) =>
      other is ChordSymbol &&
      other.root == root &&
      other.type == type &&
      other.bass == bass;

  @override
  int get hashCode => Object.hash(root, type, bass);
}

class _RootMatch {
  const _RootMatch(this.spelling, this.end);
  final PitchSpelling spelling;
  final int end;
}
