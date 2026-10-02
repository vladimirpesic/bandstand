import '../chord_symbol.dart';
import '../pitch_spelling.dart';

/// A barre: one finger across several strings at one fret.
///
/// Stored rather than derived. Three fingers at the same fret is not a barre,
/// and only the person who worked the shape out knows which it was
/// (`docs/rules/chord-diagrams.md` §1).
class Barre {
  /// Create a barre.
  ///
  /// Throws [ArgumentError] on a fret below 1 or a string range that does not
  /// run low to high.
  Barre({
    required this.fret,
    required this.fromString,
    required this.toString_,
  }) {
    if (fret < 1) {
      throw ArgumentError.value(fret, 'fret', 'must be at least 1');
    }
    if (fromString < 0 || toString_ < fromString) {
      throw ArgumentError('a barre runs from a low string to a higher one');
    }
  }

  /// Which fret of the diagram, counting from its first row.
  final int fret;

  /// The lowest string it covers, zero-based from the low string.
  final int fromString;

  /// The highest string it covers, inclusive.
  final int toString_;

  /// How many strings it covers.
  int get stringCount => toString_ - fromString + 1;
}

/// A fretted shape for one chord.
class ChordShape {
  /// Create a shape.
  ///
  /// Throws [ArgumentError] on an empty shape, a fret outside `-1..24`, a base
  /// fret outside `1..20`, a shape whose highest stopped fret reaches past the
  /// 24th, a barre outside the diagram, or an open shape with no root — an
  /// open string cannot be moved, so a shape with one belongs to its root
  /// (`docs/rules/chord-diagrams.md` §3).
  ChordShape({
    required this.type,
    required List<int> frets,
    this.root,
    this.rootString,
    this.baseFret = 1,
    this.barre,
  }) : frets = List<int>.unmodifiable(frets) {
    if (this.frets.isEmpty) {
      throw ArgumentError.value(frets, 'frets', 'a shape needs strings');
    }
    if (baseFret < 1 || baseFret > 20) {
      throw ArgumentError.value(baseFret, 'baseFret', 'must be 1 to 20');
    }
    for (final fret in this.frets) {
      if (fret < -1 || fret > 24) {
        throw ArgumentError.value(fret, 'frets', 'must be -1, 0, or 1 to 24');
      }
    }
    if (reach > 0 && baseFret + reach - 1 > 24) {
      // The same combined bound transposed() enforces: a stored shape must not
      // claim a fret the very next transpose would have to reject.
      throw ArgumentError(
        'a shape at base fret $baseFret reaching fret '
        '${baseFret + reach - 1} is past the 24th fret',
      );
    }
    final where = barre;
    if (where != null) {
      if (where.toString_ >= this.frets.length) {
        throw ArgumentError('the barre reaches past the last string');
      }
    }
    if (hasOpenStrings && root == null) {
      throw ArgumentError(
        'a shape with an open string cannot be moved, so it must name its root',
      );
    }
    final onString = rootString;
    if (onString != null) {
      if (onString < 0 || onString >= this.frets.length) {
        throw ArgumentError.value(
          rootString,
          'rootString',
          'must name a string of this shape',
        );
      }
      if (this.frets[onString] < 0) {
        throw ArgumentError('the root cannot be on a muted string');
      }
    }
    if (root == null && rootString == null) {
      throw ArgumentError(
        'a movable shape must say which string carries its root, or the '
        'interval to slide it by cannot be worked out',
      );
    }
  }

  /// The canonical chord-type symbol this shape is for.
  final String type;

  /// The root this shape is for, or null when it is movable.
  final PitchSpelling? root;

  /// Which string carries the root, zero-based from the low string.
  ///
  /// Required on a movable shape. Sliding a shape means putting its root under
  /// the right fret, and *which* string that is differs by shape: an E-shape
  /// barre is rooted on the sixth string and an A-shape on the fifth. Inferring
  /// it from the lowest played string is wrong for every rootless and
  /// inverted shape.
  final int? rootString;

  /// The fret the diagram's first row is.
  final int baseFret;

  /// One entry per string, low first: `-1` muted, `0` open, otherwise the fret
  /// counting from [baseFret].
  final List<int> frets;

  /// The barre, if there is one.
  final Barre? barre;

  /// How many strings.
  int get stringCount => frets.length;

  /// Whether any string is played open.
  bool get hasOpenStrings => frets.any((fret) => fret == 0);

  /// Whether the shape can be slid up the neck (§3).
  bool get isMovable => !hasOpenStrings;

  /// The highest fret the shape reaches, or 0 when nothing is stopped.
  int get highestFret =>
      frets.where((fret) => fret > 0).fold(0, (a, b) => a > b ? a : b);

  /// The highest fret the *hand* reaches, barre included.
  ///
  /// [highestFret] is derived from the stopped strings alone, and the fret
  /// bounds used it — so a barre above every stopped fret was never counted.
  /// `baseFret: 20` with a barre at 10 passed validation while sounding at
  /// the 29th fret of an instrument that has 24.
  int get reach {
    final stopped = highestFret;
    final barred = barre?.fret ?? 0;
    return stopped > barred ? stopped : barred;
  }

  /// The lowest stopped fret, or 0 when nothing is stopped.
  int get lowestFret => frets
      .where((fret) => fret > 0)
      .fold(0, (a, b) => a == 0 || b < a ? b : a);

  /// How many frets the hand spans.
  int get span => highestFret == 0 ? 0 : highestFret - lowestFret + 1;

  /// How many strings are stopped outside the barre.
  int get fingeredStrings {
    final where = barre;
    var count = 0;
    for (var string = 0; string < frets.length; string++) {
      final fret = frets[string];
      if (fret <= 0) {
        continue;
      }
      final underBarre =
          where != null &&
          fret == where.fret &&
          string >= where.fromString &&
          string <= where.toString_;
      if (!underBarre) {
        count++;
      }
    }
    return count;
  }

  /// This shape moved by `semitones`, or null when it cannot be moved.
  ///
  /// A shape lands above the twelfth fret is brought down an octave instead: a
  /// guitarist plays `Bbmaj7` at fret 6, not fret 18 (§3).
  ChordShape? transposed(int semitones) {
    if (!isMovable) {
      return null;
    }
    var base = baseFret + semitones;
    while (base > 12) {
      base -= 12;
    }
    while (base < 1) {
      base += 12;
    }
    if (base + reach - 1 > 24) {
      return null;
    }
    return ChordShape(
      type: type,
      baseFret: base,
      frets: frets,
      rootString: rootString,
      barre: barre,
    );
  }

  /// The pitches this shape sounds, given a tuning, low string first.
  ///
  /// The check that a shape is what it claims to be: the chord tones come out
  /// of the tuning and the frets, not out of the label
  /// (`docs/format/chord-diagrams.md`).
  List<int> pitches(List<int> tuning) => <int>[
    for (
      var string = 0;
      string < frets.length && string < tuning.length;
      string++
    )
      if (frets[string] >= 0)
        tuning[string] +
            (frets[string] == 0 ? 0 : baseFret + frets[string] - 1),
  ];

  /// The pitch classes it sounds.
  Set<int> pitchClasses(List<int> tuning) => <int>{
    for (final pitch in pitches(tuning)) pitch % 12,
  };

  @override
  String toString() =>
      '${root?.toString() ?? ''}$type $frets'
      '${baseFret == 1 ? '' : ' @$baseFret'}';

  @override
  bool operator ==(Object other) =>
      other is ChordShape &&
      other.type == type &&
      other.root == root &&
      other.rootString == rootString &&
      other.baseFret == baseFret &&
      other.frets.length == frets.length &&
      _sameFrets(other.frets) &&
      other.barre?.fret == barre?.fret &&
      other.barre?.fromString == barre?.fromString &&
      other.barre?.toString_ == barre?.toString_;

  bool _sameFrets(List<int> other) {
    for (var i = 0; i < frets.length; i++) {
      if (frets[i] != other[i]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    type,
    root,
    rootString,
    baseFret,
    Object.hashAll(frets),
    barre?.fret,
    barre?.fromString,
    barre?.toString_,
  );
}

/// An instrument the diagrams are drawn for.
class DiagramInstrument {
  /// Create an instrument.
  ///
  /// Throws [ArgumentError] on an empty id or a tuning outside 1–12 strings.
  DiagramInstrument({
    required this.id,
    required this.displayName,
    required List<int> tuning,
    required List<ChordShape> shapes,
  }) : tuning = List<int>.unmodifiable(tuning),
       shapes = List<ChordShape>.unmodifiable(shapes) {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'an instrument needs an id');
    }
    if (this.tuning.isEmpty || this.tuning.length > 12) {
      throw ArgumentError.value(tuning, 'tuning', 'must be 1 to 12 strings');
    }
    for (final shape in this.shapes) {
      if (shape.stringCount != this.tuning.length) {
        throw ArgumentError(
          'shape "$shape" has ${shape.stringCount} strings, but $id has '
          '${this.tuning.length}',
        );
      }
    }
  }

  /// Stable identifier: `guitar`, `ukulele`, `bass`.
  final String id;

  /// What the picker calls it.
  final String displayName;

  /// MIDI pitch of each open string, low first.
  final List<int> tuning;

  /// The shapes.
  final List<ChordShape> shapes;

  /// How many strings.
  int get stringCount => tuning.length;

  /// The shape for a chord, moved to its root if need be, or null.
  ///
  /// An open shape for this exact root wins, because it is what a player
  /// reaches for; otherwise a movable shape is slid up the neck (§3).
  ChordShape? shapeFor(ChordSymbol chord) {
    final wanted = chord.type.name;
    ChordShape? movable;
    for (final shape in shapes) {
      if (shape.type != wanted) {
        continue;
      }
      final shapeRoot = shape.root;
      if (shapeRoot != null) {
        if (shapeRoot.pitchClass == chord.root.pitchClass) {
          return shape;
        }
        continue;
      }
      movable ??= shape;
    }
    if (movable == null) {
      return null;
    }
    // Slide it so its root string sounds the chord's root. Which string that
    // is comes from the shape, not from a guess: an E-shape barre is rooted on
    // the sixth string and an A-shape on the fifth, and the interval to move
    // by is different for each.
    final onString = movable.rootString;
    if (onString == null || onString >= tuning.length) {
      return null;
    }
    final currently =
        tuning[onString] + movable.baseFret + movable.frets[onString] - 1;
    final offset = (chord.root.pitchClass - currently % 12 + 24) % 12;
    return movable.transposed(offset);
  }
}
