import '../../harmony/chord_type.dart';
import '../../harmony/ext_chord_symbol.dart';

/// One chord of a phrase, with where it sounds.
class BassChordSpan {
  /// Create a span.
  const BassChordSpan(this.startBeat, this.durationBeats, this.chord);

  /// Where the chord starts, in beats from the phrase's start.
  final double startBeat;

  /// How long it sounds, in beats.
  final double durationBeats;

  /// The chord.
  final ExtChordSymbol chord;

  /// One beat past the end.
  double get endBeat => startBeat + durationBeats;

  /// Whether the chord is sounding at `beat`.
  bool contains(double beat) => beat >= startBeat && beat < endBeat;

  @override
  String toString() => '${chord.format()}@$startBeat';
}

/// A chord sequence reduced to what survives transposition.
///
/// `docs/rules/corpus-tiling.md` §2: for each chord span, the interval in
/// semitones from the *first* chord's root, plus the chord quality. `Dm7 | G7`
/// and `Fm7 | Bb7` reduce to the same profile, so a phrase played over one can
/// be transposed onto the other.
///
/// This is the whole reason a corpus of fifty phrases covers a repertoire of
/// hundreds of tunes, and it is why matching is exact rather than fuzzy (§3):
/// two sequences with the same profile are the same sequence in a different
/// key, and nothing else is close enough to substitute.
class RootProfile {
  const RootProfile._(this.entries);

  /// Reduce a chord sequence.
  ///
  /// Throws [ArgumentError] on an empty sequence — a phrase without harmony is
  /// a phrase nothing can be said about.
  factory RootProfile.of(Iterable<BassChordSpan> spans) {
    final list = spans.toList();
    if (list.isEmpty) {
      throw ArgumentError.value(spans, 'spans', 'a root profile needs a chord');
    }
    final first = list.first.chord.root.pitchClass;
    return RootProfile._(
      List<RootProfileEntry>.unmodifiable(<RootProfileEntry>[
        for (final span in list)
          RootProfileEntry(
            (span.chord.root.pitchClass - first + 144) % 12,
            span.chord.type,
          ),
      ]),
    );
  }

  /// Reduce a bar-per-chord sequence, which is what a corpus phrase is.
  factory RootProfile.ofChords(Iterable<ExtChordSymbol> chords) =>
      RootProfile.of(<BassChordSpan>[
        for (final (index, chord) in chords.indexed)
          BassChordSpan(index.toDouble(), 1, chord),
      ]);

  /// The chords, as (interval from the first root, quality) pairs.
  final List<RootProfileEntry> entries;

  /// How many chords.
  int get length => entries.length;

  @override
  String toString() => entries.join(' ');

  @override
  bool operator ==(Object other) =>
      other is RootProfile &&
      other.entries.length == entries.length &&
      _sameEntries(other.entries);

  bool _sameEntries(List<RootProfileEntry> other) {
    for (var i = 0; i < entries.length; i++) {
      if (entries[i] != other[i]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(entries);
}

/// One chord of a [RootProfile].
class RootProfileEntry {
  /// Create an entry.
  const RootProfileEntry(this.semitonesFromFirst, this.type);

  /// Semitones above the sequence's first root, 0 to 11.
  final int semitonesFromFirst;

  /// The chord quality. [ChordType] is equal by degree set, so two spellings of
  /// the same quality are the same entry — which is what transposition needs.
  final ChordType type;

  @override
  String toString() =>
      '${semitonesFromFirst >= 0 ? '+' : ''}$semitonesFromFirst${type.name}';

  @override
  bool operator ==(Object other) =>
      other is RootProfileEntry &&
      other.semitonesFromFirst == semitonesFromFirst &&
      other.type == type;

  @override
  int get hashCode => Object.hash(semitonesFromFirst, type);
}
