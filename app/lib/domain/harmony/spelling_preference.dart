import 'key_signature.dart';
import 'pitch_spelling.dart';

/// How to spell a pitch class that has more than one name.
///
/// This is the single most visible correctness concern in a transposing chart
/// reader (§4.1). See `docs/rules/pitch-and-spelling.md` §6.
sealed class SpellingPreference {
  const SpellingPreference();

  /// No key known: use the flat-side default table.
  ///
  /// Flat-side because the jazz repertoire is flat-side — `Bb`, `Eb`, `Ab` and
  /// `Db` are ordinary keys and `D#` is not.
  static const SpellingPreference automatic = _AutomaticSpelling();

  /// Force the sharp side.
  static const SpellingPreference sharps = _DirectionalSpelling(sharps: true);

  /// Force the flat side.
  static const SpellingPreference flats = _DirectionalSpelling(sharps: false);

  /// Spell according to a key signature — what the app uses whenever the
  /// destination key is known, which is whenever the user transposes a song.
  const factory SpellingPreference.key(KeySignature key) = _KeySpelling;

  /// How this preference spells [pitchClass]. Never needs a double accidental.
  PitchSpelling spell(int pitchClass);

  /// Whether [spelling] is the one this preference would choose for its own
  /// pitch class.
  ///
  /// Round-tripping a transposition is exactly the identity for canonically
  /// spelled chords, and only for those — see
  /// `docs/rules/pitch-and-spelling.md` §7.1.
  bool isCanonical(PitchSpelling spelling) =>
      spell(spelling.pitchClass) == spelling;
}

class _AutomaticSpelling extends SpellingPreference {
  const _AutomaticSpelling();

  @override
  PitchSpelling spell(int pitchClass) => PitchSpelling.simplestFor(pitchClass);

  @override
  String toString() => 'SpellingPreference.automatic';

  @override
  bool operator ==(Object other) => other is _AutomaticSpelling;

  @override
  int get hashCode => (_AutomaticSpelling).hashCode;
}

class _DirectionalSpelling extends SpellingPreference {
  const _DirectionalSpelling({required this.sharps});

  final bool sharps;

  @override
  PitchSpelling spell(int pitchClass) =>
      PitchSpelling.simplestFor(pitchClass, preferSharps: sharps);

  @override
  String toString() =>
      sharps ? 'SpellingPreference.sharps' : 'SpellingPreference.flats';

  @override
  bool operator ==(Object other) =>
      other is _DirectionalSpelling && other.sharps == sharps;

  @override
  int get hashCode => Object.hash(_DirectionalSpelling, sharps);
}

class _KeySpelling extends SpellingPreference {
  const _KeySpelling(this.key);

  final KeySignature key;

  @override
  PitchSpelling spell(int pitchClass) => key.spell(pitchClass);

  @override
  String toString() => 'SpellingPreference.key($key)';

  @override
  bool operator ==(Object other) => other is _KeySpelling && other.key == key;

  @override
  int get hashCode => Object.hash(_KeySpelling, key);
}
