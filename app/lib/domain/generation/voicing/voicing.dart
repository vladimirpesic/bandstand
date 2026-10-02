import '../../harmony/ext_chord_symbol.dart';

/// The families of `docs/rules/voicings.md` §3.
enum VoicingFamily {
  /// Four notes, no root (§3.1).
  ///
  /// The textbook names two of its inversions — type A with the third at the
  /// bottom, type B with the seventh — and the engine considers those plus the
  /// one starting on the fifth. Which inversion is a voice-leading question,
  /// not a family one, so it is not in this enum.
  rootless('Rootless'),

  /// Root, third, seventh — the minimum that states the chord (§3.2).
  shell('Shell'),

  /// A close voicing with the second voice from the top dropped an octave.
  drop2('Drop 2'),

  /// Stacked fourths — modal rather than functional (§3.4).
  quartal('Quartal'),

  /// A plain triad, for slash chords and whatever the tables cannot express.
  triad('Triad');

  const VoicingFamily(this.displayName);

  /// What to call it in a report.
  final String displayName;

  /// Whether the family deliberately omits the root, because the bass has it.
  bool get isRootless => this == VoicingFamily.rootless;
}

/// A chord, as notes to put down.
///
/// `docs/rules/voicings.md` §1: a shape, with nothing about time. The comping
/// rhythm decides when it sounds.
class Voicing {
  /// Create a voicing.
  ///
  /// Throws [ArgumentError] on an empty voicing, or on pitches that are not
  /// strictly ascending — a voicing is an ordered stack, and two voices on one
  /// pitch is the doubling §6.3 forbids.
  Voicing({
    required List<int> pitches,
    required this.chord,
    required this.family,
  }) : pitches = List<int>.unmodifiable(pitches) {
    if (this.pitches.isEmpty) {
      throw ArgumentError.value(pitches, 'pitches', 'a voicing needs notes');
    }
    for (var i = 1; i < this.pitches.length; i++) {
      if (this.pitches[i] <= this.pitches[i - 1]) {
        throw ArgumentError.value(
          pitches,
          'pitches',
          'must ascend strictly; got ${this.pitches}',
        );
      }
    }
    for (final pitch in this.pitches) {
      if (pitch < 0 || pitch > 127) {
        throw ArgumentError.value(pitch, 'pitches', 'must be a MIDI pitch');
      }
    }
  }

  /// The notes, low to high.
  final List<int> pitches;

  /// The chord this states.
  final ExtChordSymbol chord;

  /// Which family it came from.
  final VoicingFamily family;

  /// How many voices.
  int get length => pitches.length;

  /// The lowest note.
  int get lowest => pitches.first;

  /// The highest note.
  int get highest => pitches.last;

  /// The middle of the voicing, for the register term.
  double get centre => (lowest + highest) / 2;

  /// The span from lowest to highest, in semitones.
  int get span => highest - lowest;

  /// The gaps between adjacent voices, low to high.
  List<int> get intervals => <int>[
    for (var i = 1; i < pitches.length; i++) pitches[i] - pitches[i - 1],
  ];

  /// The pitch classes present.
  Set<int> get pitchClasses => <int>{for (final pitch in pitches) pitch % 12};

  /// Whether the voicing sounds the chord's root.
  bool get hasRoot => pitchClasses.contains(chord.root.pitchClass);

  /// This voicing moved by `semitones`.
  Voicing transposed(int semitones) => Voicing(
    pitches: <int>[for (final pitch in pitches) pitch + semitones],
    chord: chord,
    family: family,
  );

  @override
  String toString() => '${chord.format()} ${family.displayName} $pitches';

  @override
  bool operator ==(Object other) =>
      other is Voicing &&
      other.family == family &&
      other.chord == chord &&
      other.pitches.length == pitches.length &&
      _samePitches(other.pitches);

  bool _samePitches(List<int> other) {
    for (var i = 0; i < pitches.length; i++) {
      if (pitches[i] != other[i]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(chord, family, Object.hashAll(pitches));
}
