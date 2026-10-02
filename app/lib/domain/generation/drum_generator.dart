import 'dart:math';

import '../harmony/time_signature.dart';
import '../phrase/note_event.dart';
import '../phrase/phrase.dart';
import '../song/rhythm.dart';
import 'drum_patterns.dart';
import 'generation_context.dart';
import 'music_generator.dart';
import 'post_processing.dart';

/// The General MIDI percussion channel.
const int drumChannel = 9;

/// Pattern-based drums, the first generator of §6.5.
///
/// Rules: `docs/rules/drum-generation.md`. Pure and seeded: the same song makes
/// the same drums, and editing bar 30 does not change bar 2.
class DrumGenerator implements MusicGenerator {
  /// Create a generator over a pattern set.
  DrumGenerator(this.patterns);

  /// The patterns it chooses from.
  final DrumPatternSet patterns;

  /// The intensity parameter's id.
  static const String intensityParameter = 'intensity';

  /// The fill parameter's id.
  static const String fillParameter = 'fills';

  /// How often fills land, in bars.
  static const String fillEveryParameter = 'fillEvery';

  /// The one voice this generator writes.
  static final RhythmVoice drums = RhythmVoice(
    id: 'drums',
    displayName: 'Drums',
    isDrums: true,
    preferredChannel: drumChannel,
  );

  @override
  String get id => 'drums';

  @override
  String get displayName => 'Drums';

  @override
  List<RhythmVoice> get voices => <RhythmVoice>[drums];

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
    RhythmParameterSpec(
      id: fillParameter,
      displayName: 'Fills',
      kind: RhythmParameterKind.toggle,
      defaultValue: true,
    ),
    RhythmParameterSpec(
      id: fillEveryParameter,
      displayName: 'Fill every',
      kind: RhythmParameterKind.integer,
      defaultValue: 8,
      minimum: 2,
      maximum: 32,
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

  /// The meters this generator has patterns for (§4.6).
  Set<TimeSignature> get supportedMeters => patterns.meters;

  @override
  GeneratedPart generate(GenerationContext context) {
    final meter = context.timeSignature;
    final empty = SizedPhrase(
      channel: drumChannel,
      beatRange: context.beatRange,
      timeSignature: meter,
      isDrums: true,
    );
    if (context.beatRange.isEmpty) {
      return GeneratedPart(<RhythmVoice, SizedPhrase>{drums: empty});
    }
    // §4.6: a meter with no patterns generates nothing rather than playing 4/4
    // over it.
    if (!patterns.meters.contains(meter)) {
      return GeneratedPart(
        <RhythmVoice, SizedPhrase>{drums: empty},
        problems: <String>['no drum patterns for $meter'],
      );
    }

    final intensity = context.intParameter(intensityParameter, 50);
    final fillsOn = context.boolParameter(fillParameter, fallback: true);
    final fillEvery = context.intParameter(fillEveryParameter, 8).clamp(2, 32);
    final barCount = (context.beatRange.length / meter.upper).ceil();

    PatternRole roleAt(int bar) {
      final isLastBar = bar == barCount - 1;
      if (isLastBar && context.isLastPart) {
        return PatternRole.ending;
      }
      if (fillsOn && (isLastBar || (bar + 1) % fillEvery == 0)) {
        return PatternRole.fill;
      }
      return PatternRole.groove;
    }

    int barsUntilSomethingSpecial(int from) {
      for (var bar = from; bar < barCount; bar++) {
        if (roleAt(bar) != PatternRole.groove) {
          return bar - from;
        }
      }
      return barCount - from;
    }

    final notes = <NoteEvent>[];
    final problems = <String>[];
    final recentlyUsed = <String, int>{};
    var bar = 0;

    while (bar < barCount) {
      final role = roleAt(bar);
      var candidates = patterns.candidates(meter, role, intensity);
      if (candidates.isEmpty && role != PatternRole.groove) {
        // No fill or ending for this meter: play the groove rather than a gap.
        candidates = patterns.candidates(meter, PatternRole.groove, intensity);
      }
      if (role == PatternRole.groove && candidates.isNotEmpty) {
        // A two-bar groove must not step over the bar a fill or an ending is
        // due in — which is exactly what it did before this check existed.
        final room = barsUntilSomethingSpecial(bar).clamp(1, barCount);
        final fitting = candidates.where((p) => p.bars <= room).toList();
        if (fitting.isEmpty) {
          // No groove short enough. Every shipped meter has a one-bar groove
          // so this is unreachable today, and if a future kit ever has only
          // long grooves the shortest one *will* step over the fill — so it
          // is said out loud rather than played silently over the top.
          final shortest = candidates.reduce(
            (a, b) => a.bars <= b.bars ? a : b,
          );
          problems.add(
            'bar ${bar + 1}: the shortest $meter groove is '
            '${shortest.bars} bars and only $room fit before the next fill, '
            'so it plays over it',
          );
          candidates = <DrumPattern>[shortest];
        } else {
          candidates = fitting;
        }
      }
      if (candidates.isEmpty) {
        // The meter has patterns, but none for this bar's role or the groove
        // behind it. Breaking here would leave the rest of the part silent
        // with no word said about it — the loop sound §6 is against, in
        // another costume.
        break;
      }

      final pattern = _choose(
        candidates,
        recentlyUsed,
        bar,
        context.randomSeed,
      );
      recentlyUsed[pattern.id] = bar;

      // A pattern longer than the bars left is truncated by the sized phrase.
      notes.addAll(
        _renderPattern(
          pattern: pattern,
          atBeat: bar * meter.upper.toDouble(),
          context: context,
          bar: bar,
          intensity: intensity,
        ),
      );
      bar += pattern.bars;
    }

    if (bar < barCount) {
      problems.add(
        'no drum pattern covers bars ${bar + 1}–$barCount of this part',
      );
    }

    final phrase = SizedPhrase(
      channel: drumChannel,
      beatRange: context.beatRange,
      timeSignature: meter,
      isDrums: true,
      notes: notes,
    );

    return GeneratedPart(<RhythmVoice, SizedPhrase>{
      drums: PostProcessing.apply(
        phrase,
        context,
        intensity: _intensityScale(intensity, context),
        // Drums are the pulse: humanising them as much as a melody line makes
        // the whole band sound unsteady.
        humanizeTiming: 0.008,
      ),
    }, problems: problems);
  }

  /// Freshness gates, score ranks — the rule the bass tiler uses too
  /// (`docs/rules/corpus-tiling.md` §6).
  DrumPattern _choose(
    List<DrumPattern> candidates,
    Map<String, int> recentlyUsed,
    int bar,
    int seed,
  ) {
    if (candidates.length == 1) {
      return candidates.first;
    }
    const window = 3;
    final fresh = candidates
        .where((p) => bar - (recentlyUsed[p.id] ?? -1000) > window)
        .toList();
    final pool = fresh.isEmpty ? candidates : fresh;
    final random = Random(seed ^ (bar * 2654435761));
    return pool[random.nextInt(pool.length)];
  }

  List<NoteEvent> _renderPattern({
    required DrumPattern pattern,
    required double atBeat,
    required GenerationContext context,
    required int bar,
    required int intensity,
  }) {
    // One generator per bar, so a change in bar 30 does not reroll bar 2.
    //
    // The pattern is mixed in by a hash of its id computed here rather than by
    // `String.hashCode`. The Dart VM's string hash is stable across runs,
    // isolates and AOT today — a seeded take really does come back the same
    // after a restart — but nothing in the language promises that across SDK
    // versions or platforms, and a "reroll" that quietly happened on upgrade
    // would be very hard to recognise as a bug. This is eight lines and fixed
    // for good.
    final random = Random(
      context.randomSeed ^ (bar * 40503) ^ _patternSeed(pattern.id),
    );
    final notes = <NoteEvent>[];

    for (final hit in pattern.hits) {
      if (!hit.isCertain && random.nextDouble() > hit.chance) {
        continue;
      }
      final key = patterns.keyFor(hit.instrument);
      if (key == null) {
        continue;
      }
      final position = atBeat + hit.beat;
      if (!context.beatRange.contains(position)) {
        continue;
      }
      final weight = _beatWeight(hit.beat, context.timeSignature);
      final velocity = (hit.velocity * weight).round().clamp(1, 127);
      notes.add(
        NoteEvent(
          pitch: key,
          positionInBeats: position,
          // A drum hit's length does not change what is heard — the sample
          // plays to its end — but a length of zero would be a note that never
          // stops, so it gets a short, definite one.
          beatDuration: 0.25,
          velocity: velocity,
          clientProperties: <String, Object>{
            'pattern': pattern.id,
            if (pattern.role != PatternRole.groove) 'role': pattern.role.name,
          },
        ),
      );
    }
    return notes;
  }

  /// Beat 1 heaviest, then 3, then 2 and 4, then the offbeats
  /// (`docs/rules/drum-generation.md` §4).
  static double _beatWeight(double beat, TimeSignature meter) {
    final inBar = beat % meter.upper;
    final onBeat = (inBar - inBar.roundToDouble()).abs() < 0.05;
    if (!onBeat) {
      return 0.88;
    }
    final index = inBar.round() % meter.upper;
    if (index == 0) {
      return 1.0;
    }
    if (meter.upper == 4 && index == 2) {
      return 0.96;
    }
    return 0.92;
  }

  /// The part's intensity, plus the density arc across the song (§6.6).
  ///
  /// The head quieter, the middle building, the last chorus back down — a shape
  /// rather than a level, which is what stops a long form flattening out.
  static double _intensityScale(int intensity, GenerationContext context) {
    final base = 0.6 + intensity / 100 * 0.6;
    if (context.partCount <= 2) {
      return base;
    }
    // A gentle arch: quietest at the ends, fullest in the middle.
    final position = context.positionInSong;
    final arc = 1.0 - (position - 0.5).abs() * 2;
    return base * (0.88 + arc * 0.18);
  }
}

/// A stable hash of a pattern id: FNV-1a over its code units.
///
/// Written out rather than taken from `String.hashCode`, which carries no
/// cross-version guarantee. See the note at its call site.
int _patternSeed(String id) {
  var hash = 0x811c9dc5;
  for (final unit in id.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}
