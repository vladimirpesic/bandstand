import 'chord_symbol.dart';
import 'key_signature.dart';

/// A chord written as a number in a key, rather than as a letter.
///
/// The Nashville number system: `Dm7 | G7 | Cmaj7` in C is `2m7 | 57 | 1maj7`,
/// and the same numbers in any other key are the same tune. §9 puts it at M8
/// and says it *"falls out of the degree model almost free"*, which is true —
/// the degree is the interval from the tonic, and the harmony core already
/// knows how to measure one.
///
/// What it is *for* is playing a tune in a key nobody wrote it in, which is
/// most of them: a singer's key is not the Real Book's.
abstract final class Nashville {
  /// How each interval above the tonic is written.
  ///
  /// Flats rather than sharps above the fourth degree, which is the convention
  /// and which matches how the degrees are heard: a b6 is a flattened sixth,
  /// not a raised fifth, in every context this system is used in.
  static const List<String> _degrees = <String>[
    '1', 'b2', '2', 'b3', '3', '4', 'b5', '5', 'b6', '6', 'b7', '7', //
  ];

  /// `chord` written as a number in `key`.
  ///
  /// The quality comes across unchanged: the number says *which* chord, and the
  /// symbol after it says what kind. `2m7` is the minor seventh on the second
  /// degree, whatever key it is in.
  ///
  /// A slash chord keeps its bass, also as a number: `1/3` is a first
  /// inversion, and writing it as `1/E` would defeat the point.
  static String format(ChordSymbol chord, KeySignature key) {
    final tonic = key.tonic.pitchClass;
    final degree = _degrees[(chord.root.pitchClass - tonic + 12) % 12];
    final bass = chord.bass;
    if (bass == null || bass.pitchClass == chord.root.pitchClass) {
      return '$degree${chord.type.name}';
    }
    final under = _degrees[(bass.pitchClass - tonic + 12) % 12];
    return '$degree${chord.type.name}/$under';
  }

  /// The degree of a pitch class in a key, as it would be written.
  static String degreeOf(int pitchClass, KeySignature key) =>
      _degrees[(pitchClass - key.tonic.pitchClass + 12) % 12];

  /// Whether a chord is diatonic to a key.
  ///
  /// Not needed to write the number — every chord has one — but it is what a
  /// display uses to mark the chords that are *not*, which are the ones worth
  /// looking at twice.
  static bool isDiatonic(ChordSymbol chord, KeySignature key) {
    // key.mode.semitones is one entry per letter step; as a set it is exactly
    // the key's pitch classes, so the two cannot drift apart.
    final scale = key.mode.semitones;
    final tonic = key.tonic.pitchClass;
    return chord.pitchClasses.every(
      (pitchClass) => scale.contains((pitchClass - tonic + 12) % 12),
    );
  }
}
