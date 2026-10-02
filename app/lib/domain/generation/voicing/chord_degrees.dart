import '../../harmony/ext_chord_symbol.dart';
import '../chord_tones.dart';

/// Resolves a written degree number to semitones above the root.
///
/// The voicing families of `docs/rules/voicings.md` §3 are written in degree
/// numbers — a rootless type A is "3 5 7 9" — and turning those into notes is
/// not a lookup. `7` is eleven semitones over a major seventh and ten over a
/// dominant; `9` is two semitones normally and one over a `7b9`; a chord with
/// no seventh at all has to offer its sixth instead.
///
/// Two sources, in order:
///
/// 1. **The chord type**, when it names the degree. This is what makes `7b9`,
///    `13b9#11` and `m6` come out right — the alteration is in the symbol and
///    the symbol is authoritative.
/// 2. **The chord's scale**, when it does not. A `Dm7` does not name a ninth,
///    but every pianist plays one in a rootless voicing, because the ninth is
///    available over a minor seventh. The scale is what says so.
class ChordDegrees {
  const ChordDegrees._(this._chord, this._colour, this._byNumber);

  /// Resolve a chord's degrees once.
  factory ChordDegrees.of(ExtChordSymbol chord) {
    final colour = ChordTones.of(chord);
    final byNumber = <int, int>{};
    for (final degree in chord.type.degrees) {
      // A chord may name two degrees with one number — `7alt` has both b9 and
      // #9 — and the first is the one a voicing reaches for.
      byNumber.putIfAbsent(degree.number, () => degree.semitones);
    }
    return ChordDegrees._(chord, colour, byNumber);
  }

  final ExtChordSymbol _chord;
  final ChordTones _colour;
  final Map<int, int> _byNumber;

  /// The chord's root, as a pitch class.
  int get rootPitchClass => _chord.root.pitchClass;

  /// The chord.
  ExtChordSymbol get chord => _chord;

  /// Semitones above the root for a written degree number, or null when the
  /// chord cannot offer it.
  ///
  /// `1` is the root, `3` the third, `7` the seventh, `9` and `13` the
  /// tensions. A number the chord neither names nor has a scale note for comes
  /// back null, and the family that asked for it is not available.
  int? semitonesFor(int number) {
    final named = _byNumber[number];
    if (named != null) {
      return named;
    }
    // A sixth chord has no seventh; its sixth does that job in a voicing, and
    // asking for a seventh over `C6` must give A rather than nothing.
    if (number == 7 && _byNumber.containsKey(6)) {
      return _byNumber[6];
    }
    final fromScale = _scaleDegree(number);
    if (fromScale != null) {
      return fromScale;
    }
    return null;
  }

  /// Whether the chord can supply every degree in `numbers`.
  bool canSupply(Iterable<int> numbers) =>
      numbers.every((number) => semitonesFor(number) != null);

  /// The pitch class of a written degree number, or null.
  int? pitchClassFor(int number) {
    final semitones = semitonesFor(number);
    return semitones == null ? null : (rootPitchClass + semitones) % 12;
  }

  /// The third, whatever it is called.
  int? get third => semitonesFor(3);

  /// The seventh, or the sixth standing in for it.
  int? get seventh => semitonesFor(7);

  /// Whether the chord has a third — a power chord and a `sus` do not.
  bool get hasThird => third != null && _byNumber.containsKey(3);

  /// Whether the chord names a seventh or a sixth of its own.
  bool get hasSeventh => _byNumber.containsKey(7) || _byNumber.containsKey(6);

  /// Whether a pitch is one of the chord's own notes, in any octave.
  bool isChordTone(int pitch) => _colour.isChordTone(pitch);

  /// The degree taken from the chord's scale, for a tension the symbol does not
  /// name.
  ///
  /// Only the degrees a voicing asks for: the ninth, the eleventh and the
  /// thirteenth, plus the plain 3/5/7 for a chord whose symbol is terse.
  int? _scaleDegree(int number) {
    // Degree numbers count scale steps: 9 is the second, 11 the fourth, 13 the
    // sixth. Reduce to a step index and read the chord's scale.
    const stepForNumber = <int, int>{
      1: 0,
      3: 2,
      5: 4,
      7: 6,
      9: 1,
      11: 3,
      13: 5,
    };
    final step = stepForNumber[number];
    if (step == null) {
      return null;
    }
    final scale = _colour.scaleTones.toList()..sort();
    // scaleTones is a pitch-class set including the chord's own notes; order it
    // from the root so a step index means what it says.
    final ascending = <int>[
      for (final pitchClass in scale) (pitchClass - rootPitchClass + 12) % 12,
    ]..sort();
    if (step >= ascending.length) {
      return null;
    }
    return ascending[step];
  }
}
