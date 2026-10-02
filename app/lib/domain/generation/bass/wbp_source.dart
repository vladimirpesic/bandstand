import '../../harmony/ext_chord_symbol.dart';
import '../chord_tones.dart';
import 'root_profile.dart';

/// The range a phrase must fit after transposition.
///
/// Defaults to the double bass of `docs/rules/corpus-tiling.md` §4.3.
class BassRange {
  /// Create a range.
  const BassRange({this.lowest = 28, this.highest = 55});

  /// E1, the lowest note of a four-string bass.
  final int lowest;

  /// G3, about as high as a walking line goes before it stops being one.
  final int highest;

  /// The middle, which the register term pulls towards.
  int get centre => (lowest + highest) ~/ 2;

  /// Whether every pitch from `low` to `high` fits.
  bool admits(int low, int high) => low >= lowest && high <= highest;

  @override
  String toString() => '$lowest..$highest';

  @override
  bool operator ==(Object other) =>
      other is BassRange && other.lowest == lowest && other.highest == highest;

  @override
  int get hashCode => Object.hash(lowest, highest);
}

/// One note of a source phrase.
class BassNoteSpec {
  /// Create a note.
  ///
  /// Throws [ArgumentError] on a position that is not finite and non-negative,
  /// a non-positive duration, a pitch outside MIDI range, or a velocity outside
  /// 1–127.
  BassNoteSpec({
    required this.beat,
    required this.pitch,
    this.durationBeats = 0.92,
    this.velocity = 82,
  }) {
    if (!beat.isFinite || beat < 0) {
      throw ArgumentError.value(beat, 'beat', 'must be finite and at least 0');
    }
    if (!durationBeats.isFinite || durationBeats <= 0) {
      throw ArgumentError.value(
        durationBeats,
        'durationBeats',
        'must be finite and positive',
      );
    }
    if (pitch < 0 || pitch > 127) {
      throw ArgumentError.value(pitch, 'pitch', 'must be a MIDI pitch');
    }
    if (velocity < 1 || velocity > 127) {
      throw ArgumentError.value(velocity, 'velocity', 'must be 1 to 127');
    }
  }

  /// Onset in beats from the phrase's start.
  final double beat;

  /// MIDI pitch, as written in the corpus — before any transposition.
  final int pitch;

  /// Length in beats. Just short of a beat by default, the way a walking line
  /// sits.
  final double durationBeats;

  /// MIDI velocity.
  final int velocity;

  /// One beat past the end.
  double get endBeat => beat + durationBeats;

  @override
  String toString() => '$pitch@$beat';
}

/// The tempo band a phrase belongs in (`docs/rules/corpus-tiling.md` §9).
class TempoRange {
  /// Create a range.
  ///
  /// Throws [ArgumentError] unless `0 < lowest <= highest`.
  TempoRange(this.lowest, this.highest) {
    if (lowest <= 0 || highest < lowest) {
      throw ArgumentError('a tempo range needs 0 < lowest <= highest');
    }
  }

  /// Usable anywhere. The right default: the corpus should not have to answer a
  /// question nobody asked.
  static final TempoRange any = TempoRange(1, 10000);

  /// Slowest tempo the phrase suits.
  final int lowest;

  /// Fastest tempo the phrase suits.
  final int highest;

  /// Whether `tempo` is inside the band.
  bool admits(int tempo) => tempo >= lowest && tempo <= highest;

  @override
  String toString() => '$lowest-$highest';
}

/// A walking-bass source phrase: 1–4 bars of bass, with the harmony it was
/// played over and everything derived from the pair.
///
/// `docs/rules/corpus-tiling.md` §2. Every derived field is computed once, in
/// the constructor, because §10 makes that the difference between a tiler that
/// fits the §3 budget and one that does not.
class WbpSource {
  /// Build a source phrase and derive its statistics.
  ///
  /// Throws [ArgumentError] on an empty phrase, a phrase without harmony, or a
  /// note that falls outside the harmony it is played over.
  WbpSource({
    required this.name,
    required List<BassChordSpan> harmony,
    required List<BassNoteSpec> notes,
    Set<String> tags = const <String>{},
    TempoRange? tempoRange,
    this.range = const BassRange(),
  }) : harmony = List<BassChordSpan>.unmodifiable(harmony),
       notes = List<BassNoteSpec>.unmodifiable(
         notes.toList()..sort((a, b) => a.beat.compareTo(b.beat)),
       ),
       tags = Set<String>.unmodifiable(tags),
       tempoRange = tempoRange ?? TempoRange.any,
       rootProfile = RootProfile.of(harmony) {
    if (this.notes.isEmpty) {
      throw ArgumentError.value(notes, 'notes', 'a phrase needs notes');
    }
    final end = this.harmony.last.endBeat;
    for (final note in this.notes) {
      if (note.beat >= end) {
        throw ArgumentError(
          'phrase "$name": note at beat ${note.beat} is past the harmony, '
          'which ends at $end',
        );
      }
    }

    _colours = <ChordTones>[
      for (final span in this.harmony) ChordTones.of(span.chord),
    ];
    lowestPitch = this.notes
        .map((note) => note.pitch)
        .reduce((a, b) => a < b ? a : b);
    highestPitch = this.notes
        .map((note) => note.pitch)
        .reduce((a, b) => a > b ? a : b);
    harmonicFit = _computeHarmonicFit();
    _transposibility = _computeTransposibility();
  }

  /// Identifier, unique within a corpus. It is what the reuse window of §6
  /// tracks, so two phrases sharing a name would be heard as one.
  final String name;

  /// The chords this phrase was played over, in order.
  final List<BassChordSpan> harmony;

  /// The notes, in time order.
  final List<BassNoteSpec> notes;

  /// Free-form style tags.
  final Set<String> tags;

  /// The tempo band this phrase suits.
  final TempoRange tempoRange;

  /// The instrument range it must fit after transposition.
  final BassRange range;

  /// The harmony reduced to what survives transposition.
  final RootProfile rootProfile;

  late final List<ChordTones> _colours;

  /// The lowest pitch as written.
  late final int lowestPitch;

  /// The highest pitch as written.
  late final int highestPitch;

  /// Harmonic fit, 0..1 (§4.1).
  ///
  /// Invariant under transposition, so it is a property of the phrase and is
  /// computed exactly once — the first and largest of the §10 caches.
  late final double harmonicFit;

  /// Octave transpositions that keep the phrase in range, per destination root.
  late final Map<int, List<int>> _transposibility;

  /// Length in beats.
  double get lengthBeats => harmony.last.endBeat;

  /// Length in bars, given the beats per bar the phrase was written in.
  int get lengthBars => harmony.length;

  /// Root pitch class of the first chord.
  int get firstRootPitchClass => harmony.first.chord.root.pitchClass;

  /// The first note.
  BassNoteSpec get firstNote => notes.first;

  /// The last note.
  BassNoteSpec get lastNote => notes.last;

  /// Whether the phrase opens on the root of its first chord (§5 constraint 1).
  bool get startsOnRoot => _colours.first.isRoot(firstNote.pitch);

  /// Whether the phrase closes on a chord tone (§5 constraint 2).
  bool get endsOnChordTone =>
      colourAt(lastNote.beat).isChordTone(lastNote.pitch);

  /// Whether the phrase can be used at all. A phrase failing this is dead
  /// weight that looks like coverage, which is why the corpus test asserts it.
  bool get isPlayable => startsOnRoot && endsOnChordTone;

  /// The chord sounding at `beat`.
  ExtChordSymbol chordAt(double beat) => harmony[_spanIndexAt(beat)].chord;

  /// The chord tones sounding at `beat`.
  ChordTones colourAt(double beat) => _colours[_spanIndexAt(beat)];

  int _spanIndexAt(double beat) {
    for (var i = 0; i < harmony.length; i++) {
      if (harmony[i].contains(beat)) {
        return i;
      }
    }
    return harmony.length - 1;
  }

  /// The transpositions that place this phrase on `destinationRoot` and keep
  /// every note in range, lowest first.
  ///
  /// Empty means the phrase cannot be played at that root at all — §8's filter,
  /// and the reason the tiler never scores a candidate it could not place.
  List<int> transpositionsTo(int destinationRoot) =>
      _transposibility[destinationRoot % 12] ?? const <int>[];

  /// Whether the phrase can reach `destinationRoot` in any octave.
  bool canReach(int destinationRoot) =>
      transpositionsTo(destinationRoot).isNotEmpty;

  /// How many of the twelve roots the phrase can reach. A phrase that reaches
  /// few roots is a phrase with a wide span, and it is the first thing to look
  /// at when the corpus has a gap.
  int get reachableRootCount =>
      _transposibility.values.where((list) => list.isNotEmpty).length;

  double _computeHarmonicFit() {
    // Strong beats follow the meter the phrase was written in, not a
    // hardcoded 4/4 grid: the corpus format allows any beatsPerBar. A
    // chromatic note is the substance of a walking line on a weak beat and
    // a mistake on a strong one.
    final beatsPerBar = lengthBeats / harmony.length;
    var total = 0.0;
    for (final note in notes) {
      final colour = colourAt(note.beat);
      final strong = _isStrongBeat(note.beat % beatsPerBar, beatsPerBar);
      if (colour.isChordTone(note.pitch)) {
        total += 1.0;
      } else if (colour.isScaleTone(note.pitch)) {
        total += strong ? 0.55 : 0.9;
      } else {
        total += strong ? 0.1 : 0.8;
      }
    }
    return total / notes.length;
  }

  /// Whether `beatInBar` is a strong beat of a bar `beatsPerBar` long.
  ///
  /// Compound meters divide into threes, so every third beat is strong (beats
  /// 1 and 4 of 6/8); even simple meters add the halfway beats (beats 1 and 3
  /// of 4/4); odd simple meters have the downbeat alone — beat 3 of 3/4 is
  /// medium, not strong.
  static bool _isStrongBeat(double beatInBar, double beatsPerBar) {
    if (beatsPerBar > 3 && beatsPerBar % 3 == 0) {
      return beatInBar % 3 == 0;
    }
    if (beatsPerBar % 2 == 0) {
      return beatInBar % 2 == 0;
    }
    return beatInBar == 0;
  }

  Map<int, List<int>> _computeTransposibility() {
    final map = <int, List<int>>{};
    for (var root = 0; root < 12; root++) {
      final shift = (root - firstRootPitchClass + 144) % 12;
      final octaves = <int>[];
      for (var octave = -4; octave <= 4; octave++) {
        final transposition = shift + octave * 12;
        if (range.admits(
          lowestPitch + transposition,
          highestPitch + transposition,
        )) {
          octaves.add(transposition);
        }
      }
      map[root] = List<int>.unmodifiable(octaves);
    }
    return Map<int, List<int>>.unmodifiable(map);
  }

  @override
  String toString() => '$name ($lengthBars bar, $rootProfile)';
}
