/// The smallest chord model that the probe needs.
///
/// **Throwaway.** The real harmony core is M1 (§4.1) and lives in
/// `app/lib/domain/harmony/`. This exists so that M0.5 can answer its question
/// without waiting for, or prejudicing, that design.
library;

/// Chord qualities the probe corpus uses.
enum Quality {
  major7('maj7', <int>[0, 4, 7, 11], <int>[0, 2, 4, 5, 7, 9, 11]),
  major6('6', <int>[0, 4, 7, 9], <int>[0, 2, 4, 5, 7, 9, 11]),
  minor7('m7', <int>[0, 3, 7, 10], <int>[0, 2, 3, 5, 7, 9, 10]),
  minor6('m6', <int>[0, 3, 7, 9], <int>[0, 2, 3, 5, 7, 9, 11]),
  dominant7('7', <int>[0, 4, 7, 10], <int>[0, 2, 4, 5, 7, 9, 10]),
  halfDiminished('m7b5', <int>[0, 3, 6, 10], <int>[0, 2, 3, 5, 6, 8, 10]),
  diminished7('dim7', <int>[0, 3, 6, 9], <int>[0, 2, 3, 5, 6, 8, 9, 11]);

  const Quality(this.symbol, this.chordTones, this.scaleTones);

  /// How the quality is written after the root, e.g. the `m7` of `Dm7`.
  final String symbol;

  /// Semitones above the root that are chord tones.
  final List<int> chordTones;

  /// Semitones above the root that belong to the chord's default scale.
  final List<int> scaleTones;
}

const List<String> _pitchClassNames = <String>[
  'C',
  'Db',
  'D',
  'Eb',
  'E',
  'F',
  'Gb',
  'G',
  'Ab',
  'A',
  'Bb',
  'B',
];

/// A chord: a root pitch class and a quality.
///
/// No spelling, no slash chords, no extensions — the probe does not need them,
/// and M1 does them properly.
class Chord {
  const Chord(this.rootPitchClass, this.quality);

  /// Parse `Dm7`, `Bbmaj7`, `A7`, `Ebmaj7`, `F#m7b5`.
  factory Chord.parse(String text) {
    final match = RegExp(r'^([A-G])([b#]?)(.*)$').firstMatch(text.trim());
    if (match == null) {
      throw FormatException('not a chord symbol', text);
    }
    const naturals = <String, int>{
      'C': 0,
      'D': 2,
      'E': 4,
      'F': 5,
      'G': 7,
      'A': 9,
      'B': 11,
    };
    var root = naturals[match.group(1)]!;
    switch (match.group(2)) {
      case 'b':
        root -= 1;
      case '#':
        root += 1;
    }
    final symbol = match.group(3)!;
    final quality = Quality.values.where((q) => q.symbol == symbol);
    if (quality.isEmpty) {
      throw FormatException('unknown chord quality "$symbol"', text);
    }
    return Chord((root + 12) % 12, quality.first);
  }

  /// Root as a pitch class, 0 = C.
  final int rootPitchClass;

  /// The quality.
  final Quality quality;

  /// Whether `pitch` is a chord tone, in any octave.
  bool isChordTone(int pitch) =>
      quality.chordTones.contains((pitch - rootPitchClass) % 12);

  /// Whether `pitch` is in the chord's default scale, in any octave.
  bool isScaleTone(int pitch) =>
      quality.scaleTones.contains((pitch - rootPitchClass) % 12);

  /// This chord moved by `semitones`.
  Chord transposed(int semitones) =>
      Chord((rootPitchClass + semitones) % 12, quality);

  @override
  String toString() => '${_pitchClassNames[rootPitchClass]}${quality.symbol}';

  @override
  bool operator ==(Object other) =>
      other is Chord &&
      other.rootPitchClass == rootPitchClass &&
      other.quality == quality;

  @override
  int get hashCode => Object.hash(rootPitchClass, quality);
}

/// One chord and how long it lasts, within a phrase or a progression.
class ChordSpan {
  const ChordSpan(this.startBeat, this.durationBeats, this.chord);

  /// Onset, in beats from the start of the phrase or progression.
  final double startBeat;

  /// Length in beats.
  final double durationBeats;

  /// The chord.
  final Chord chord;

  /// One beat past the end.
  double get endBeat => startBeat + durationBeats;

  /// This span moved by `semitones`.
  ChordSpan transposed(int semitones) =>
      ChordSpan(startBeat, durationBeats, chord.transposed(semitones));

  @override
  String toString() => '$chord@$startBeat+$durationBeats';
}

/// A chord sequence reduced to what survives transposition.
///
/// See `docs/rules/corpus-tiling.md` §2: the interval of each chord's root from
/// the *first* chord's root, its quality, and where it sits.
class RootProfile {
  const RootProfile(this.entries);

  /// Build the profile of a chord sequence.
  factory RootProfile.of(List<ChordSpan> spans) {
    if (spans.isEmpty) {
      throw ArgumentError('a root profile needs at least one chord');
    }
    final origin = spans.first.chord.rootPitchClass;
    return RootProfile(<RootProfileEntry>[
      for (final span in spans)
        RootProfileEntry(
          span.startBeat,
          span.durationBeats,
          (span.chord.rootPitchClass - origin + 12) % 12,
          span.chord.quality,
        ),
    ]);
  }

  /// The entries, in time order.
  final List<RootProfileEntry> entries;

  @override
  bool operator ==(Object other) {
    if (other is! RootProfile || other.entries.length != entries.length) {
      return false;
    }
    for (var i = 0; i < entries.length; i++) {
      if (entries[i] != other.entries[i]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(entries);

  @override
  String toString() => entries.join(' ');
}

/// One chord of a [RootProfile].
class RootProfileEntry {
  const RootProfileEntry(
    this.startBeat,
    this.durationBeats,
    this.rootInterval,
    this.quality,
  );

  /// Onset in beats, relative to the profile's start.
  final double startBeat;

  /// Length in beats.
  final double durationBeats;

  /// Semitones above the first chord's root, 0–11.
  final int rootInterval;

  /// The quality.
  final Quality quality;

  @override
  bool operator ==(Object other) =>
      other is RootProfileEntry &&
      other.startBeat == startBeat &&
      other.durationBeats == durationBeats &&
      other.rootInterval == rootInterval &&
      other.quality == quality;

  @override
  int get hashCode =>
      Object.hash(startBeat, durationBeats, rootInterval, quality);

  @override
  String toString() => '+$rootInterval${quality.symbol}';
}
