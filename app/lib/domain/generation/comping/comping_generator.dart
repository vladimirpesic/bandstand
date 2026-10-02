import 'dart:math';

import '../../harmony/ext_chord_symbol.dart';
import '../../harmony/time_signature.dart';
import '../../phrase/note_event.dart';
import '../../phrase/phrase.dart';
import '../../song/rhythm.dart';
import '../generation_context.dart';
import '../music_generator.dart';
import '../post_processing.dart';
import '../voicing/voicing_engine.dart';
import 'comping_cell.dart';
import 'comping_cells.dart';

/// Piano comping — §6.5 item 3.
///
/// Rules: `docs/rules/comping.md` for *when*, `docs/rules/voicings.md` for
/// *what*. This class is the join, and it is deliberately thin: everything
/// musical lives in the cell corpus or the voicing engine, and a fault in
/// either is visible in the place responsible for it.
class CompingGenerator implements MusicGenerator {
  /// Create a generator over a cell corpus.
  CompingGenerator(this.cells, {this.reuseWindow = 4});

  /// The rhythmic cells it chooses from.
  final CompingCellSet cells;

  /// How many placements back a cell counts as recently heard (§3.4).
  final int reuseWindow;

  /// How loud, 0–100. Also selects the cells' density band (§6).
  static const String intensityParameter = 'intensity';

  /// The one voice this generator writes.
  static final RhythmVoice piano = RhythmVoice(
    id: 'piano',
    displayName: 'Piano',
    isDrums: false,
    preferredChannel: 1,
  );

  static const VoicingEngine _engine = VoicingEngine();

  @override
  String get id => 'comping';

  @override
  String get displayName => 'Comping';

  @override
  List<RhythmVoice> get voices => <RhythmVoice>[piano];

  @override
  List<RhythmParameterSpec> get parameters => <RhythmParameterSpec>[
    RhythmParameterSpec(
      id: intensityParameter,
      displayName: 'Intensity',
      kind: RhythmParameterKind.integer,
      defaultValue: 50,
      minimum: 0,
      maximum: 100,
    ),
  ];

  @override
  Rhythm get rhythm => Rhythm(
    id: id,
    displayName: displayName,
    timeSignature: TimeSignature.fourFour,
    voices: voices,
    parameters: parameters,
  );

  /// The meters the corpus covers (§4.6).
  Set<TimeSignature> get supportedMeters => cells.meters;

  @override
  GeneratedPart generate(GenerationContext context) {
    final meter = context.timeSignature;
    final empty = SizedPhrase(
      channel: piano.preferredChannel!,
      beatRange: context.beatRange,
      timeSignature: meter,
    );
    if (context.beatRange.isEmpty || context.chords.isEmpty) {
      return GeneratedPart(<RhythmVoice, SizedPhrase>{piano: empty});
    }
    if (!cells.meters.contains(meter)) {
      // §4.6: a meter with no cells comps nothing rather than playing 4/4 over
      // it.
      return GeneratedPart(
        <RhythmVoice, SizedPhrase>{piano: empty},
        problems: <String>['no comping cells for $meter'],
      );
    }

    final intensity = context
        .intParameter(intensityParameter, 50)
        .clamp(0, 100);
    final beatsPerBar = meter.upper.toDouble();
    final barCount = (context.beatRange.length / beatsPerBar).ceil();

    final placements = _placeCells(
      context: context,
      intensity: intensity,
      barCount: barCount,
      beatsPerBar: beatsPerBar,
    );
    if (placements.isEmpty) {
      return GeneratedPart(
        <RhythmVoice, SizedPhrase>{piano: empty},
        problems: <String>['no comping cell fits this part'],
      );
    }

    final problems = <String>[];
    final notes = _voiceOnsets(
      context: context,
      placements: placements,
      beatsPerBar: beatsPerBar,
      problems: problems,
    );

    final phrase = SizedPhrase(
      channel: piano.preferredChannel!,
      beatRange: context.beatRange,
      timeSignature: meter,
      notes: notes,
    );
    return GeneratedPart(<RhythmVoice, SizedPhrase>{
      piano: PostProcessing.apply(
        phrase,
        context,
        range: PitchRange.piano,
        intensity: 0.75 + (intensity / 100) * 0.5,
        // A comper is the loosest voice in the band — looser than the bass,
        // much looser than the drums.
        humanizeTiming: 0.02,
      ),
    }, problems: problems);
  }

  /// Walk the part, choosing a cell at a time (§3).
  List<_Placement> _placeCells({
    required GenerationContext context,
    required int intensity,
    required int barCount,
    required double beatsPerBar,
  }) {
    final placements = <_Placement>[];
    final lastUsedAt = <String, int>{};
    final random = Random(context.randomSeed);
    var bar = 0;

    while (bar < barCount) {
      final room = barCount - bar;
      var candidates = cells.candidates(
        meter: context.timeSignature,
        intensity: intensity,
        barsAvailable: room,
      );
      if (candidates.isEmpty) {
        break;
      }
      // §3.3 — a cell whose onsets fall in a bar with no chord at all has
      // nothing to play.
      candidates = candidates
          .where((cell) => _hasChords(context, bar, cell.bars, beatsPerBar))
          .toList();
      if (candidates.isEmpty) {
        bar += 1;
        continue;
      }

      // §6 — the first bar of a section states the downbeat; a cell that
      // covers the last bar leaves space. Coverage, not the cell's starting
      // bar: a two-bar cell beginning one bar from the end still plays the
      // last bar, and must leave it air.
      final isFirstBar = bar == 0;
      var preferred = candidates;
      if (isFirstBar && context.isFirstPart) {
        final stating = candidates
            .where((cell) => cell.statesDownbeat)
            .toList();
        if (stating.isNotEmpty) {
          preferred = stating;
        }
      } else if (context.isLastPart) {
        final spacious = candidates
            .where(
              (cell) => bar + cell.bars < barCount || cell.leavesSpaceAtTheEnd,
            )
            .toList();
        if (spacious.isNotEmpty) {
          preferred = spacious;
        }
      }

      final chosen = _choose(preferred, lastUsedAt, placements.length, random);
      lastUsedAt[chosen.id] = placements.length;
      placements.add(_Placement(chosen, bar));
      bar += chosen.bars;
    }
    return placements;
  }

  /// Freshness gates, then a seeded draw ranks (§3.4).
  ///
  /// The same rule as the drums and the bass tiler: a comper who plays one
  /// two-bar figure eight times is the loop sound the whole design is against.
  /// Unlike the tiler there is no score to rank by — one rhythm is not better
  /// than another — so within the fresh pool the seeded random decides, which
  /// keeps the result reproducible (§6.2).
  CompingCell _choose(
    List<CompingCell> candidates,
    Map<String, int> lastUsedAt,
    int placed,
    Random random,
  ) {
    final fresh = candidates.where((cell) {
      final used = lastUsedAt[cell.id];
      return used == null || placed - used > reuseWindow;
    }).toList();
    final pool = fresh.isEmpty ? candidates : fresh;
    return pool[random.nextInt(pool.length)];
  }

  /// Whether any chord sounds in the bars a cell would cover.
  bool _hasChords(
    GenerationContext context,
    int bar,
    int bars,
    double beatsPerBar,
  ) {
    final start = bar * beatsPerBar;
    final end = (bar + bars) * beatsPerBar;
    return context.chords.any(
      (chord) => chord.startBeat < end && chord.endBeat > start,
    );
  }

  /// Turn placed onsets into notes, asking the voicing engine for each (§5).
  ///
  /// The onsets are resolved to chords first and voiced as one **sequence**,
  /// not one at a time. Voicing chord by chord is greedy from wherever the
  /// first one happened to sit, and that seed decides everything after it —
  /// a plain `Dm7 G7 Cmaj7 A7` then needs a voice to move four semitones,
  /// which is over the cap of `voicings.md` §6.7. `voiceSequence` searches the
  /// seeds and does not.
  List<NoteEvent> _voiceOnsets({
    required GenerationContext context,
    required List<_Placement> placements,
    required double beatsPerBar,
    required List<String> problems,
  }) {
    // What each onset states, in time order.
    final onsets = <({double at, CellOnset onset, ExtChordSymbol chord})>[];
    for (final placement in placements) {
      final origin = placement.bar * beatsPerBar;
      for (final onset in placement.cell.onsets) {
        final at = origin + onset.beat;
        if (at >= context.beatRange.end) {
          continue;
        }
        final chord = _chordFor(context, at, beatsPerBar, placement.cell);
        if (chord == null || chord.isNoChord) {
          continue;
        }
        onsets.add((at: at, onset: onset, chord: chord));
      }
    }
    if (onsets.isEmpty) {
      return const <NoteEvent>[];
    }

    // §5 — a comper does not re-voice a chord they are holding; they hit it
    // again. So the sequence to voice is the *changes*, and every onset in
    // between points at the same voicing.
    final sequence = <ExtChordSymbol>[];
    final voicingOf = <int>[];
    for (final entry in onsets) {
      if (sequence.isEmpty || sequence.last != entry.chord) {
        sequence.add(entry.chord);
      }
      voicingOf.add(sequence.length - 1);
    }

    final choices = _engine.voiceSequence(sequence);
    final unvoiceable = <String>{};
    final notes = <NoteEvent>[];
    for (var i = 0; i < onsets.length; i++) {
      final choice = choices[voicingOf[i]];
      if (choice == null) {
        if (unvoiceable.add(onsets[i].chord.format())) {
          problems.add('no voicing for ${onsets[i].chord.format()}');
        }
        continue;
      }
      final at = onsets[i].at;
      final held = _lengthAt(onsets[i].onset, at, context);
      for (final pitch in choice.voicing.pitches) {
        notes.add(
          NoteEvent(
            pitch: pitch,
            positionInBeats: at,
            beatDuration: held,
            velocity: (40 + onsets[i].onset.accent * 70).round().clamp(1, 127),
          ),
        );
      }
    }
    return notes;
  }

  /// The chord an onset states, honouring anticipation (§4).
  ///
  /// An onset within an eighth before a change takes the *new* chord. That is
  /// the single most characteristic thing a comper does, and doing it here
  /// rather than in the cell is what lets one cell work over any harmony.
  ExtChordSymbol? _chordFor(
    GenerationContext context,
    double at,
    double beatsPerBar,
    CompingCell cell,
  ) {
    // Half a quarter note, expressed in this meter's beats. `0.5` on its own
    // is an eighth only where the beat *is* a quarter: in 6/8 the beat is an
    // eighth already, so half of one is a sixteenth and the comper reached
    // half as far ahead as it meant to.
    final anticipation = 0.5 / context.timeSignature.beatDurationInQuarters;
    if (!cell.isPedal) {
      final ahead = context.chordAt(at + anticipation);
      final here = context.chordAt(at);
      if (ahead != null &&
          here != null &&
          ahead.chord != here.chord &&
          ahead.startBeat > at &&
          ahead.startBeat <= at + anticipation) {
        return ahead.chord;
      }
    }
    return context.chordAt(at)?.chord;
  }

  /// How long a hit is held, cut at the part's end.
  ///
  /// A cell's own duration is the intent; the part's end is the limit. Note
  /// that a held note is *not* cut at the next chord change: the cells are
  /// built so that only an anticipation crosses one (§7.3), and an
  /// anticipation is already stating the chord it crosses into.
  double _lengthAt(CellOnset onset, double at, GenerationContext context) {
    final remaining = context.beatRange.end - at;
    final held = onset.durationBeats < remaining
        ? onset.durationBeats
        : remaining;
    return held <= 0 ? 0.05 : held;
  }
}

class _Placement {
  const _Placement(this.cell, this.bar);
  final CompingCell cell;
  final int bar;
}
