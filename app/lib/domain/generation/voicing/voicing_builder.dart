import '../../harmony/chord_type.dart';
import '../../harmony/ext_chord_symbol.dart';
import 'chord_degrees.dart';
import 'voicing.dart';
import 'voicing_constraints.dart';

/// Builds the candidate shapes of `docs/rules/voicings.md` §3.
///
/// Shapes only: this decides what a family *is*, never which one to play. The
/// engine does the choosing, and keeping the two apart is what makes the tables
/// below readable as music rather than as policy.
abstract final class VoicingBuilder {
  /// The degree numbers each rootless form stacks, by chord family (§3.1).
  ///
  /// Read as "from the third" and "from the seventh": the forms hold the same
  /// four notes in different inversions, which is what lets a ii-V alternate
  /// between them and move almost nothing.
  ///
  /// A dominant gets **two** shapes per form. The 13th is the more colourful
  /// and the one the textbooks lead with, but `3 5 7 9` is equally standard and
  /// it is sometimes the only one that leads well: going from `Cmaj7` as
  /// `E G B D` to `A7`, the shape with the fifth holds E, G and B where they
  /// are and moves D to C# — one semitone, where the 13th shape needs four.
  /// Offering only the 13th made a plain I-VI turnaround break the movement
  /// cap of §6.7.
  static const Map<ChordFamily, List<List<int>>> _rootlessSets =
      <ChordFamily, List<List<int>>>{
        ChordFamily.minor: <List<int>>[
          <int>[3, 5, 7, 9],
        ],
        ChordFamily.major: <List<int>>[
          <int>[3, 5, 7, 9],
        ],
        ChordFamily.dominant: <List<int>>[
          <int>[3, 13, 7, 9],
          <int>[3, 5, 7, 9],
        ],
        ChordFamily.diminished: <List<int>>[
          <int>[3, 5, 7, 9],
        ],
      };

  /// The inversions of a rootless set, as stacking orders.
  ///
  /// Rotating the set gives four; the engine is offered three. The rotation
  /// that puts the **ninth at the bottom** is dropped, because it lands the
  /// ninth a semitone under the third — `Dm7` as `E F A C` — and that rub at
  /// the bottom of a voicing is the one place the interval is not a colour.
  /// The remaining three are the textbook type A (third lowest), type B
  /// (seventh lowest), and the one starting on the fifth, which is what a I-VI
  /// turnaround needs and what neither named form can supply.
  static List<List<int>> _inversions(List<int> set) => <List<int>>[
    for (var start = 0; start < set.length; start++)
      if (set[start] != 9)
        <int>[
          for (var i = 0; i < set.length; i++) set[(start + i) % set.length],
        ],
  ];

  /// Every candidate for a chord, at every octave that keeps it in the band.
  ///
  /// Unfiltered: the engine applies the constraints, because a rejection is
  /// information (§7) and throwing it away here would hide it.
  static List<Voicing> candidates(ExtChordSymbol chord) {
    if (chord.isNoChord) {
      return const <Voicing>[];
    }
    final degrees = ChordDegrees.of(chord);
    final shapes = <Voicing>[];
    for (final family in VoicingFamily.values) {
      for (final shape in _build(family, chord, degrees)) {
        shapes.addAll(_atEveryOctave(shape, family, chord));
      }
    }
    return shapes;
  }

  /// The shapes a family gives for a chord, in their lowest octave.
  static List<List<int>> _build(
    VoicingFamily family,
    ExtChordSymbol chord,
    ChordDegrees degrees,
  ) {
    final built = switch (family) {
      VoicingFamily.rootless => _rootless(
        _rootlessSets[chord.type.family],
        degrees,
      ),
      VoicingFamily.shell => <List<int>?>[_shell(degrees)],
      VoicingFamily.drop2 => <List<int>?>[_drop2(degrees)],
      VoicingFamily.quartal => <List<int>?>[_quartal(chord, degrees)],
      VoicingFamily.triad => <List<int>?>[_triad(degrees)],
    };
    return <List<int>>[for (final shape in built) ?shape];
  }

  /// Stack the degree numbers upward from the lowest, never crossing.
  ///
  /// The numbers are a *stacking order*, not intervals: `7 9 3 5` means the
  /// seventh at the bottom and then each following degree at the next octave
  /// that keeps the stack ascending.
  static List<int>? _stack(List<int> numbers, ChordDegrees degrees) {
    if (!degrees.canSupply(numbers)) {
      return null;
    }
    final pitches = <int>[];
    // Start the bottom voice in the octave beginning at C3, so every shape is
    // built from the same floor and the octave search below does the rest.
    var previous = VoicingConstraints.lowestPitch - 1;
    for (final number in numbers) {
      final semitones = degrees.semitonesFor(number)!;
      var pitch = degrees.rootPitchClass + semitones;
      while (pitch <= previous) {
        pitch += 12;
      }
      pitches.add(pitch);
      previous = pitch;
    }
    return pitches;
  }

  static List<List<int>?> _rootless(
    List<List<int>>? sets,
    ChordDegrees degrees,
  ) {
    if (sets == null) {
      return const <List<int>?>[];
    }
    return <List<int>?>[
      for (final set in sets)
        for (final order in _inversions(set)) _stack(order, degrees),
    ];
  }

  /// Root, third, seventh (§3.2).
  static List<int>? _shell(ChordDegrees degrees) {
    if (!degrees.hasThird || !degrees.hasSeventh) {
      return null;
    }
    return _stack(<int>[1, 3, 7], degrees);
  }

  /// A close four-note voicing with the second voice from the top dropped an
  /// octave (§3.3).
  static List<int>? _drop2(ChordDegrees degrees) {
    final close = _stack(<int>[1, 3, 5, 7], degrees);
    if (close == null || close.length != 4) {
      return null;
    }
    // Drop the second from the top, then re-sort: that note becomes the bass.
    final dropped = <int>[close[0], close[1], close[3], close[2] - 12]..sort();
    for (var i = 1; i < dropped.length; i++) {
      if (dropped[i] == dropped[i - 1]) {
        return null;
      }
    }
    return dropped;
  }

  /// Stacked fourths (§3.4) — offered only where the harmony is static.
  ///
  /// A dominant that has to resolve is not a quartal chord: the shape states a
  /// scale rather than a function, and using it on a V is how a modal voicing
  /// ends up somewhere functional.
  static List<int>? _quartal(ExtChordSymbol chord, ChordDegrees degrees) {
    const modal = <ChordFamily>{ChordFamily.minor, ChordFamily.sus};
    if (!modal.contains(chord.type.family)) {
      return null;
    }
    // The "So What" shape: three perfect fourths and a major third on top,
    // built from the chord's own fifth so the stack stays inside the harmony.
    final fifth = degrees.semitonesFor(5);
    if (fifth == null) {
      return null;
    }
    final bottom =
        VoicingConstraints.lowestPitch +
        ((degrees.rootPitchClass + fifth - VoicingConstraints.lowestPitch) %
            12);
    return <int>[bottom, bottom + 5, bottom + 10, bottom + 15, bottom + 19];
  }

  /// A plain triad (§3.5).
  static List<int>? _triad(ChordDegrees degrees) {
    if (!degrees.canSupply(<int>[1, 3, 5])) {
      return null;
    }
    return _stack(<int>[1, 3, 5], degrees);
  }

  /// Every octave transposition of a shape that lands inside the band.
  ///
  /// The band is the family's own — a rootless voicing has a narrower one than
  /// a shell (§4) — so a shape is offered exactly where its family belongs and
  /// the engine never has to think about octaves at all.
  static List<Voicing> _atEveryOctave(
    List<int>? shape,
    VoicingFamily family,
    ExtChordSymbol chord,
  ) {
    if (shape == null || shape.isEmpty) {
      return const <Voicing>[];
    }
    final low = family.isRootless
        ? VoicingConstraints.rootlessLowest
        : VoicingConstraints.lowestPitch;
    final high = family.isRootless
        ? VoicingConstraints.rootlessHighest
        : VoicingConstraints.highestPitch;
    final bottom = shape.first;
    final top = shape.last;

    final voicings = <Voicing>[];
    for (var octave = -4; octave <= 4; octave++) {
      final shift = octave * 12;
      if (bottom + shift < low || top + shift > high) {
        continue;
      }
      voicings.add(
        Voicing(
          pitches: <int>[for (final pitch in shape) pitch + shift],
          chord: chord,
          family: family,
        ),
      );
    }
    return voicings;
  }
}
