import '../harmony/chord_type.dart';
import '../harmony/ext_chord_symbol.dart';

/// A chord reduced to the pitch-class sets a generator asks about.
///
/// `docs/rules/corpus-tiling.md` §4.1 grades every note as a chord tone, a
/// scale tone, or chromatic. Both questions are asked once per note per
/// candidate, so both answers are precomputed here and the scorer does set
/// lookups rather than arithmetic.
class ChordTones {
  const ChordTones._(this.rootPitchClass, this.chordTones, this.scaleTones);

  /// Reduce a chord.
  factory ChordTones.of(ExtChordSymbol chord) {
    final root = chord.root.pitchClass;
    final tones = <int>{
      for (final pitchClass in chord.pitchClasses) pitchClass,
    };
    // A chart rarely names the scale, and the scorer needs one for every chord.
    // The chord's own scale wins when the arranger has chosen it; otherwise the
    // ordinary chord-scale mapping applies, which is the same table the M0.5
    // probe used.
    final scale = chord.scale;
    final scaleTones = scale != null
        ? <int>{...scale.pitchClasses}
        : <int>{
            for (final interval in _defaultScale(chord.type))
              (root + interval) % 12,
          };
    return ChordTones._(root, tones, scaleTones.union(tones));
  }

  /// The chord's root, as a pitch class.
  final int rootPitchClass;

  /// Pitch classes of the chord's own notes.
  final Set<int> chordTones;

  /// Pitch classes of the chord's scale. Always a superset of [chordTones]: a
  /// note in the chord is in its scale by definition, whatever table said
  /// otherwise.
  final Set<int> scaleTones;

  /// Whether `pitch` is a chord tone, in any octave.
  bool isChordTone(int pitch) => chordTones.contains(pitch % 12);

  /// Whether `pitch` is in the chord's scale, in any octave.
  bool isScaleTone(int pitch) => scaleTones.contains(pitch % 12);

  /// Whether `pitch` is the root, in any octave.
  bool isRoot(int pitch) => pitch % 12 == rootPitchClass;

  /// Semitones above the root, for the chord's default scale.
  ///
  /// The ordinary chord-scale mapping: Ionian over a major seventh, Dorian over
  /// a minor seventh, Mixolydian over a dominant, Locrian over a half
  /// diminished, whole-half over a diminished seventh, Lydian augmented over an
  /// augmented, Mixolydian over a suspension.
  static List<int> _defaultScale(ChordType type) {
    switch (type.family) {
      case ChordFamily.major:
        return const <int>[0, 2, 4, 5, 7, 9, 11];
      case ChordFamily.minor:
        // Dorian rather than Aeolian: over a m7 in a ii-V the sixth is major,
        // and a walking line uses it constantly.
        return type.hasDegreeNumber(6)
            ? const <int>[0, 2, 3, 5, 7, 9, 11]
            : const <int>[0, 2, 3, 5, 7, 9, 10];
      case ChordFamily.dominant:
        return const <int>[0, 2, 4, 5, 7, 9, 10];
      case ChordFamily.diminished:
        // A diminished seventh takes the whole-half scale; a m7b5 is Locrian.
        return type.degrees.any((degree) => degree.semitones == 9)
            ? const <int>[0, 2, 3, 5, 6, 8, 9, 11]
            : const <int>[0, 1, 3, 5, 6, 8, 10];
      case ChordFamily.augmented:
        return const <int>[0, 2, 4, 6, 8, 10];
      case ChordFamily.sus:
        return const <int>[0, 2, 4, 5, 7, 9, 10];
      case ChordFamily.other:
        // A power chord names no third, so nothing beyond the chord itself
        // can be asserted: the table adds the fifth and nothing else, and
        // every other note is chromatic, which the weak-beat scoring of
        // §4.1 treats generously anyway.
        return const <int>[0, 7];
    }
  }
}
