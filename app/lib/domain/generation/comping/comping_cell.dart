import '../../harmony/time_signature.dart';

/// One hit in a rhythmic cell.
class CellOnset {
  /// Create an onset.
  ///
  /// Throws [ArgumentError] on a position or length that is not finite and
  /// positive, or an accent outside 0..1.
  CellOnset({
    required this.beat,
    required this.durationBeats,
    this.accent = 0.5,
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
    if (accent < 0 || accent > 1) {
      throw ArgumentError.value(accent, 'accent', 'must be 0..1');
    }
  }

  /// Where it falls, in beats from the cell's start.
  final double beat;

  /// How long it is held, in beats.
  final double durationBeats;

  /// How hard, 0 to 1. Scaled to velocity by the generator.
  final double accent;

  /// One beat past the end.
  double get endBeat => beat + durationBeats;

  @override
  String toString() => '@$beat×$durationBeats';
}

/// One or two bars of comping rhythm, with nothing about pitch.
///
/// `docs/rules/comping.md` §1. The separation is the point: this says *when*,
/// the voicing engine says *what*, and neither can be blamed for the other's
/// mistakes.
class CompingCell {
  /// Create a cell and derive its density.
  ///
  /// Throws [ArgumentError] on a cell with no onsets, an onset past the end of
  /// the cell, or an intensity band that is not a band.
  CompingCell({
    required this.id,
    required this.timeSignature,
    required this.bars,
    required List<CellOnset> onsets,
    this.minimumIntensity = 0,
    this.maximumIntensity = 100,
    Set<String> tags = const <String>{},
  }) : onsets = List<CellOnset>.unmodifiable(
         onsets.toList()..sort((a, b) => a.beat.compareTo(b.beat)),
       ),
       tags = Set<String>.unmodifiable(tags) {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'a cell needs an id');
    }
    if (bars < 1 || bars > 2) {
      throw ArgumentError.value(bars, 'bars', 'a cell is one or two bars');
    }
    if (this.onsets.isEmpty) {
      throw ArgumentError.value(onsets, 'onsets', 'a cell needs a hit');
    }
    if (minimumIntensity < 0 ||
        maximumIntensity > 100 ||
        minimumIntensity > maximumIntensity) {
      throw ArgumentError('cell "$id" has a bad intensity band');
    }
    final end = lengthBeats;
    for (final onset in this.onsets) {
      if (onset.beat >= end) {
        throw ArgumentError(
          'cell "$id": an onset at ${onset.beat} is past its $end beats',
        );
      }
    }
  }

  /// Stable identifier, which the freshness rule tracks.
  final String id;

  /// The meter it was written for (§4.6).
  final TimeSignature timeSignature;

  /// One or two.
  final int bars;

  /// The hits, in time order.
  final List<CellOnset> onsets;

  /// The lowest intensity this cell suits.
  final int minimumIntensity;

  /// The highest.
  final int maximumIntensity;

  /// Free-form style tags.
  final Set<String> tags;

  /// How long the cell is, in beats.
  double get lengthBeats => bars * timeSignature.upper.toDouble();

  /// Hits per bar — what the density arc of §6 selects on.
  double get density => onsets.length / bars;

  /// Whether the cell suits this intensity.
  bool admits(int intensity) =>
      intensity >= minimumIntensity && intensity <= maximumIntensity;

  /// Whether a held note may sound across a chord change (§7.3).
  bool get isPedal => tags.contains('pedal');

  /// Whether the cell states the downbeat of its first bar, which is what a
  /// section start wants (§6).
  bool get statesDownbeat => onsets.any((onset) => onset.beat == 0);

  /// Whether the cell leaves the last beat alone, which is what the bar before
  /// a section wants.
  bool get leavesSpaceAtTheEnd =>
      onsets.every((onset) => onset.endBeat <= lengthBeats - 1);

  /// Whether the cell hits every beat of every bar — a metronome with chords on
  /// it, and excluded by §7.1.
  bool get isOnEveryBeat {
    final beats = <double>{
      for (final onset in onsets)
        if (onset.beat == onset.beat.roundToDouble()) onset.beat,
    };
    return beats.length >= lengthBeats;
  }

  /// The closest two onsets, in beats, or null when there is only one.
  double? get tightestGap {
    if (onsets.length < 2) {
      return null;
    }
    var tightest = double.infinity;
    for (var i = 1; i < onsets.length; i++) {
      final gap = onsets[i].beat - onsets[i - 1].beat;
      if (gap < tightest) {
        tightest = gap;
      }
    }
    return tightest;
  }

  @override
  String toString() => '$id ($bars bar, ${onsets.length} hits)';
}
