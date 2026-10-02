import 'harmony.dart';

/// One note of a bass phrase.
class BassNote {
  const BassNote(this.beat, this.durationBeats, this.pitch, this.velocity);

  /// Onset in beats from the phrase start.
  final double beat;

  /// Length in beats.
  final double durationBeats;

  /// MIDI pitch.
  final int pitch;

  /// MIDI velocity.
  final int velocity;

  /// This note moved by `semitones` and shifted to `beat + offsetBeats`.
  BassNote placed(int semitones, double offsetBeats) =>
      BassNote(beat + offsetBeats, durationBeats, pitch + semitones, velocity);
}

/// A source phrase: bass notes plus the harmony they were played over.
///
/// See `docs/rules/corpus-tiling.md` §2.
class BassPhrase {
  BassPhrase({
    required this.name,
    required this.harmony,
    required this.notes,
    this.tags = const <String>{},
    this.beatsPerBar = 4,
  }) : assert(notes.isNotEmpty, 'a phrase needs notes'),
       assert(harmony.isNotEmpty, 'a phrase needs harmony'),
       rootProfile = RootProfile.of(harmony);

  /// Build a phrase of consecutive quarter notes over one chord per bar span.
  ///
  /// The corpus is written this way because every phrase in it is a walking
  /// line: four quarter notes to the bar, one or two chords to the bar.
  factory BassPhrase.walking({
    required String name,
    required List<String> chordsPerBar,
    required List<int> pitches,
    Set<String> tags = const <String>{},
    int beatsPerBar = 4,
  }) {
    if (pitches.length != chordsPerBar.length * beatsPerBar) {
      throw ArgumentError(
        'phrase "$name" has ${pitches.length} notes for '
        '${chordsPerBar.length} bars of $beatsPerBar',
      );
    }
    final harmony = <ChordSpan>[
      for (var bar = 0; bar < chordsPerBar.length; bar++)
        ChordSpan(
          (bar * beatsPerBar).toDouble(),
          beatsPerBar.toDouble(),
          Chord.parse(chordsPerBar[bar]),
        ),
    ];
    final notes = <BassNote>[
      for (var i = 0; i < pitches.length; i++)
        BassNote(
          i.toDouble(),
          _noteLength,
          pitches[i],
          i % beatsPerBar == 0 ? _accentVelocity : _velocity,
        ),
    ];
    return BassPhrase(
      name: name,
      harmony: harmony,
      notes: notes,
      tags: tags,
      beatsPerBar: beatsPerBar,
    );
  }

  /// Quarter notes played just short of legato, the way a walking line sits.
  static const double _noteLength = 0.92;
  static const int _velocity = 82;
  static const int _accentVelocity = 94;

  /// Identifier, used in the tiling report.
  final String name;

  /// The chords this phrase was played over.
  final List<ChordSpan> harmony;

  /// The notes.
  final List<BassNote> notes;

  /// Style tags.
  final Set<String> tags;

  /// Beats per bar this phrase is written in. The walking corpus is 4/4,
  /// but `lengthBars` must not assume that for phrases built with a
  /// different `beatsPerBar`.
  final int beatsPerBar;

  /// The harmony reduced to what survives transposition.
  final RootProfile rootProfile;

  /// Length in beats.
  double get lengthBeats => harmony.last.endBeat;

  /// Length in bars, at the phrase's own `beatsPerBar`.
  int get lengthBars => lengthBeats ~/ beatsPerBar;

  /// Root pitch class of the first chord.
  int get firstRootPitchClass => harmony.first.chord.rootPitchClass;

  /// The first note.
  BassNote get firstNote => notes.first;

  /// The last note.
  BassNote get lastNote => notes.last;

  /// The chord sounding at `beat`.
  Chord chordAt(double beat) {
    for (final span in harmony) {
      if (beat >= span.startBeat && beat < span.endBeat) {
        return span.chord;
      }
    }
    return harmony.last.chord;
  }

  /// Whether the phrase opens on the root of its first chord.
  ///
  /// Constraint 1 of `docs/rules/corpus-tiling.md` §5.
  bool get startsOnRoot =>
      firstNote.pitch % 12 == harmony.first.chord.rootPitchClass;

  /// Whether the phrase closes on a chord tone.
  ///
  /// Constraint 2 of `docs/rules/corpus-tiling.md` §5.
  bool get endsOnChordTone =>
      chordAt(lastNote.beat).isChordTone(lastNote.pitch);

  /// The lowest pitch in the phrase.
  int get lowestPitch =>
      notes.map((n) => n.pitch).reduce((a, b) => a < b ? a : b);

  /// The highest pitch in the phrase.
  int get highestPitch =>
      notes.map((n) => n.pitch).reduce((a, b) => a > b ? a : b);

  @override
  String toString() => '$name ($lengthBars bar, $rootProfile)';
}
