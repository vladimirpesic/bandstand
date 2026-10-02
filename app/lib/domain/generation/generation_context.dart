import '../harmony/ext_chord_symbol.dart';
import '../harmony/time_signature.dart';
import '../phrase/float_range.dart';
import '../song/song_chord_sequence.dart';
import '../song/song_part.dart';

/// One chord, with where it sits inside the part being generated.
class ContextChord {
  /// Create a chord in context.
  const ContextChord({
    required this.chord,
    required this.startBeat,
    required this.endBeat,
  });

  /// The chord.
  final ExtChordSymbol chord;

  /// Where it starts, in beats from the start of the part.
  final double startBeat;

  /// Where the next chord starts, or the end of the part.
  final double endBeat;

  /// How long it sounds.
  double get durationBeats => endBeat - startBeat;

  /// Whether it is sounding at `beat`.
  bool contains(double beat) => beat >= startBeat && beat < endBeat;

  @override
  String toString() => '${chord.format()} @$startBeat for ${durationBeats}b';
}

/// Everything a generator is given (§6.2).
///
/// Positions are relative to the part, not the song: a generator that has to
/// know where it sits in the song is one that cannot be tested on its own.
class GenerationContext {
  /// Create a context.
  GenerationContext({
    required Iterable<ContextChord> chords,
    required this.beatRange,
    required this.timeSignature,
    required this.tempo,
    required this.randomSeed,
    required Map<String, Object> parameterValues,
    this.partIndex = 0,
    this.partCount = 1,
    this.isFirstPart = true,
    this.isLastPart = true,
  }) : chords = List<ContextChord>.unmodifiable(chords),
       parameterValues = Map<String, Object>.unmodifiable(parameterValues);

  /// The chords in this part, in order.
  final List<ContextChord> chords;

  /// The span to fill, in beats from the start of the part.
  final FloatRange beatRange;

  /// The meter.
  final TimeSignature timeSignature;

  /// The tempo, in beats per minute.
  final int tempo;

  /// The seed for every random choice.
  ///
  /// §6.2 is emphatic: no generator may touch a global random source.
  /// Determinism is what makes the test strategy possible, and it is what makes
  /// "reroll" a button rather than a lottery.
  final int randomSeed;

  /// The rhythm parameter values for this part, by parameter id.
  final Map<String, Object> parameterValues;

  /// Which part of the arrangement this is.
  final int partIndex;

  /// How many parts there are, for shaping density across a song (§6.6).
  final int partCount;

  /// Whether this is the first part — an intro rather than a continuation.
  final bool isFirstPart;

  /// Whether this is the last — where an ending goes.
  final bool isLastPart;

  /// How many bars to fill.
  double get barCount => beatRange.length / timeSignature.upper;

  /// How far through the song this part is, 0 to 1.
  double get positionInSong => partCount <= 1 ? 0 : partIndex / (partCount - 1);

  /// The chord sounding at `beat`, or null before the first starts or after
  /// the last has stopped.
  ContextChord? chordAt(double beat) {
    ContextChord? current;
    for (final chord in chords) {
      if (chord.endBeat <= beat) {
        // It has stopped sounding; a later chord may still contain `beat`.
        continue;
      }
      if (chord.startBeat <= beat) {
        current = chord;
      } else {
        break;
      }
    }
    return current;
  }

  /// An integer parameter, or `fallback` if it is missing or the wrong shape.
  int intParameter(String id, int fallback) {
    final value = parameterValues[id];
    return value is int ? value : fallback;
  }

  /// A fractional parameter, or `fallback`.
  double doubleParameter(String id, double fallback) {
    final value = parameterValues[id];
    return value is num && value.isFinite ? value.toDouble() : fallback;
  }

  /// A choice parameter, or `fallback`.
  String stringParameter(String id, String fallback) {
    final value = parameterValues[id];
    return value is String ? value : fallback;
  }

  /// A toggle, or `fallback`.
  bool boolParameter(String id, {required bool fallback}) {
    final value = parameterValues[id];
    return value is bool ? value : fallback;
  }

  /// Build the context for one song part of a flattened song.
  ///
  /// The chords come from [SongChordSequence], which has already resolved the
  /// written page's repeats and the arrangement (§4.3, §4.5).
  static GenerationContext forPart({
    required SongChordSequence sequence,
    required int partIndex,
    required int partCount,
    required SongPart part,
    required int tempo,
    required int randomSeed,
  }) {
    final bars = sequence.barsOfPart(partIndex);
    if (bars.isEmpty) {
      return GenerationContext(
        chords: const <ContextChord>[],
        beatRange: FloatRange.empty,
        timeSignature: TimeSignature.fourFour,
        tempo: tempo,
        randomSeed: randomSeed,
        parameterValues: part.parameterValues,
        partIndex: partIndex,
        partCount: partCount,
        isFirstPart: partIndex == 0,
        isLastPart: partIndex == partCount - 1,
      );
    }

    final signature = bars.first.timeSignature;
    final endQuarters = bars.last.endQuarters;
    final beatLength = signature.beatDurationInQuarters;

    // A part may span a meter change (§4.6) — `_expandPart` follows jumps,
    // and a jump can land in a section in another meter. The context reports
    // one time signature, so its beat is the first bar's throughout and the
    // conversion is a single division.
    //
    // It has to be a single division. Dividing a position inside a bar by that
    // bar's own beat length while accumulating whole bars by the first bar's
    // made the map non-monotonic: in a [4/4, 6/8] part the last eighth of bar
    // 2 came out at beat 9 while the part's own `beatRange` ended at 7, so
    // notes were written past the end of the part they belonged to.
    //
    // A mid-part meter change still cannot be expressed on one beat grid;
    // `SongGenerator` reports it as a problem rather than letting the grid lie
    // about it.
    final startQuarters = bars.first.startQuarters;
    double beatAt(double quarters) => (quarters - startQuarters) / beatLength;

    final events = <ContextChord>[];
    final inPart = sequence.chords
        .where(
          (event) =>
              event.barIndex >= bars.first.index &&
              event.barIndex <= bars.last.index,
        )
        .toList();
    for (var i = 0; i < inPart.length; i++) {
      final start = beatAt(inPart[i].startQuarters);
      final end = i + 1 < inPart.length
          ? beatAt(inPart[i + 1].startQuarters)
          : beatAt(endQuarters);
      events.add(
        ContextChord(chord: inPart[i].chord, startBeat: start, endBeat: end),
      );
    }

    return GenerationContext(
      chords: events,
      beatRange: FloatRange(0, beatAt(endQuarters)),
      timeSignature: signature,
      tempo: tempo,
      randomSeed: randomSeed,
      parameterValues: part.parameterValues,
      partIndex: partIndex,
      partCount: partCount,
      isFirstPart: partIndex == 0,
      isLastPart: partIndex == partCount - 1,
    );
  }
}
