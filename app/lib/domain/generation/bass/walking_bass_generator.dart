import '../../harmony/ext_chord_symbol.dart';
import '../../harmony/time_signature.dart';
import '../../phrase/note_event.dart';
import '../../phrase/phrase.dart';
import '../../song/rhythm.dart';
import '../generation_context.dart';
import '../music_generator.dart';
import '../post_processing.dart';
import 'bass_corpus.dart';
import 'wbp_tiling.dart';

/// Walking bass by corpus tiling — the second generator of §6.5 and the whole
/// of M6.
///
/// Rules: `docs/rules/corpus-tiling.md`. Pure and seeded like every generator
/// (§6.2): the same song and seed give the same line, which is what makes
/// "reroll" a button rather than a lottery.
class WalkingBassGenerator implements MusicGenerator {
  /// Create a generator over a corpus.
  WalkingBassGenerator(this.corpus, {this.reuseWindow = 6});

  /// The source phrases it tiles.
  final BassCorpus corpus;

  /// How many placements back a phrase counts as recently heard (§6).
  final int reuseWindow;

  /// The one voice this generator writes.
  static final RhythmVoice bass = RhythmVoice(
    id: 'bass',
    displayName: 'Bass',
    isDrums: false,
    preferredChannel: 0,
  );

  /// How loud, 0–100.
  static const String intensityParameter = 'intensity';

  @override
  String get id => 'walking-bass';

  @override
  String get displayName => 'Walking bass';

  @override
  List<RhythmVoice> get voices => <RhythmVoice>[bass];

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

  @override
  GeneratedPart generate(GenerationContext context) {
    final meter = context.timeSignature;
    final empty = SizedPhrase(
      channel: bass.preferredChannel!,
      beatRange: context.beatRange,
      timeSignature: meter,
    );
    if (context.beatRange.isEmpty || context.chords.isEmpty) {
      return GeneratedPart(<RhythmVoice, SizedPhrase>{bass: empty});
    }
    if (corpus.isEmpty) {
      return GeneratedPart(
        <RhythmVoice, SizedPhrase>{bass: empty},
        problems: <String>['the bass corpus is empty'],
      );
    }

    // The grid below is one meter for the whole part, which is sound
    // because `song_generator.dart` asserts a part never spans a meter
    // change: a part plays one section, a section carries one meter. The
    // bass generator leans on that upstream invariant rather than
    // re-asserting it here (L-B2) — if the domain ever grows per-bar
    // meters, the assert there and this grid change together.
    final beatsPerBar = meter.upper.toDouble();
    final barCount = (context.beatRange.length / beatsPerBar).ceil();
    final progression = BassProgression(
      _barChords(context, beatsPerBar, barCount),
    );

    // §11 — run both tilers and keep the better line. Cheap, because §10 means
    // the second run is mostly cache hits, and worth it because the two make
    // opposite trades and which one wins depends on the form. Both see the
    // context's seed (§6.2), so a reroll re-ranks both tilers and the better
    // line of the pair is a new one.
    final tilings = <Tiling>[
      for (final strategy in TilingStrategy.values)
        WbpTiler(
          corpus: corpus,
          tempo: context.tempo,
          reuseWindow: reuseWindow,
          strategy: strategy,
          seed: context.randomSeed,
        ).tile(progression, beatsPerBar: beatsPerBar),
    ];
    final best = tilings.reduce(_better);

    // §4.1 — `N.C.` is not a chord and is never played. Every other generator
    // checks it; the bass walked straight through, tiling a real line over
    // bars the chart says are silent (or falling back to root-and-fifth on
    // whatever `N.C.` resolved to).
    //
    // Filtered after tiling rather than before: the tiler wants a chord in
    // every bar so that the phrases either side of the gap still join to each
    // other, and dropping the bar from the progression would move every bar
    // after it.
    final silent = <int>{
      for (var bar = 0; bar < progression.bars.length; bar++)
        if (progression.bars[bar].isNoChord) bar,
    };
    final notes = <NoteEvent>[
      for (final note in best.notes(beatsPerBar))
        if (silent.isEmpty ||
            !silent.contains((note.beat / beatsPerBar).floor()))
          NoteEvent(
            pitch: note.pitch,
            positionInBeats: note.beat,
            beatDuration: note.durationBeats,
            velocity: note.velocity,
          ),
    ];

    final phrase = SizedPhrase(
      channel: bass.preferredChannel!,
      beatRange: context.beatRange,
      timeSignature: meter,
      notes: notes,
    );

    return GeneratedPart(<RhythmVoice, SizedPhrase>{
      bass: PostProcessing.apply(
        phrase,
        context,
        // The tiler already keeps every note in range (§8), so this clamp
        // never fires on a well-formed corpus. It is here because a corpus
        // declaring a wider instrument than the double bass would otherwise
        // hand the sampler notes it has no samples for.
        range: PitchRange(corpus.range.lowest, corpus.range.highest),
        // One note at a time, which is what a bass plays. It also cleans up
        // the overlap a phrase's final note makes with the next phrase's
        // first when the durations run long.
        monophonic: true,
        intensity: _intensityScale(context),
        // A bass player pushes and drags more than a drummer does, and less
        // than a horn player. This is the value the drums use, doubled.
        humanizeTiming: 0.016,
      ),
    }, problems: best.gaps);
  }

  /// One chord per bar, which is the shape the corpus is written in.
  ///
  /// The bars sit on the section's meter grid: a part never spans a meter
  /// change (asserted upstream, in `song_generator.dart`), so the uniform
  /// grid `generate` builds from `meter.upper` matches every bar it covers
  /// (L-B2).
  ///
  /// A chord that changes mid-bar resolves to whatever is sounding on the
  /// downbeat: every phrase in the corpus carries one chord per bar
  /// (`docs/format/bass-corpus.md`), so a half-bar change has nothing to match
  /// against. The chord it loses is not silently dropped — the bar it lands in
  /// still scores against the downbeat chord, and a corpus that wanted to cover
  /// two-chord bars would need phrases written that way.
  List<ExtChordSymbol> _barChords(
    GenerationContext context,
    double beatsPerBar,
    int barCount,
  ) {
    final first = context.chords.first.chord;
    return <ExtChordSymbol>[
      for (var bar = 0; bar < barCount; bar++)
        context.chordAt(bar * beatsPerBar)?.chord ?? first,
    ];
  }

  /// Higher quality wins; a tie goes to the tiling with the narrower widest
  /// join, because that is the one whose worst moment is less audible.
  static Tiling _better(Tiling a, Tiling b) {
    // A tiling with fewer gaps is better whatever it scores: a gap is a bar of
    // root-and-fifth, and no amount of smoothness elsewhere makes up for it.
    if (a.fallbackBars != b.fallbackBars) {
      return a.fallbackBars < b.fallbackBars ? a : b;
    }
    // Quality, not mean score. Comparing mean score alone chooses the tiling
    // that repeats — see Tiling.quality.
    final byQuality = b.quality.compareTo(a.quality);
    if (byQuality != 0) {
      return byQuality < 0 ? a : b;
    }
    return a.widestJoin <= b.widestJoin ? a : b;
  }

  /// Intensity as a velocity scale, and a density arc across the song (§6.6).
  double _intensityScale(GenerationContext context) {
    final intensity = context
        .intParameter(intensityParameter, 50)
        .clamp(0, 100);
    return 0.75 + (intensity / 100) * 0.5;
  }
}
