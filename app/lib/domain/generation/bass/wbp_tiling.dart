import '../../harmony/ext_chord_symbol.dart';
import 'bass_corpus.dart';
import '../chord_tones.dart';
import 'root_profile.dart';
import 'wbp_scorer.dart';
import 'wbp_source.dart';

/// The progression to tile: one chord per bar.
///
/// A walking line is scored a bar at a time, so a chord that changes mid-bar is
/// resolved to the chord on the downbeat before tiling starts. That is a real
/// simplification and it is the corpus's shape, not a shortcut: every phrase in
/// the corpus carries one chord per bar (`docs/format/bass-corpus.md`), so a
/// half-bar change has nothing to match against.
class BassProgression {
  /// Create a progression.
  ///
  /// Throws [ArgumentError] on an empty progression.
  BassProgression(Iterable<ExtChordSymbol> bars)
    : bars = List<ExtChordSymbol>.unmodifiable(bars) {
    if (this.bars.isEmpty) {
      throw ArgumentError.value(bars, 'bars', 'a progression needs a bar');
    }
  }

  /// One chord per bar.
  final List<ExtChordSymbol> bars;

  /// How many bars.
  int get barCount => bars.length;

  /// The root profile of `count` bars from `start`.
  RootProfile profileAt(int start, int count) =>
      RootProfile.ofChords(bars.sublist(start, start + count));

  /// The root pitch class at `bar`.
  int rootAt(int bar) => bars[bar].root.pitchClass;
}

/// One placed phrase, or one bar the corpus could not cover.
class Placement {
  /// Create a placement of a source phrase.
  const Placement({
    required this.source,
    required this.startBar,
    required this.transposition,
    required this.score,
  }) : fallbackNotes = null;

  /// Create a fallback bar, played when nothing in the corpus matches (§11).
  const Placement.fallback({
    required this.startBar,
    required List<BassNoteSpec> notes,
  }) : source = null,
       transposition = 0,
       score = null,
       fallbackNotes = notes;

  /// The source phrase, or null for a fallback bar.
  final WbpSource? source;

  /// Bar it starts at, within the progression.
  final int startBar;

  /// Semitones the phrase was moved by, octave included.
  final int transposition;

  /// How it scored, or null for a fallback.
  final PlacementScore? score;

  /// The notes of a fallback bar, already at pitch.
  final List<BassNoteSpec>? fallbackNotes;

  /// Whether this is a gap the corpus did not cover.
  bool get isFallback => source == null;

  /// How many bars it covers.
  int get lengthBars => source?.lengthBars ?? 1;

  /// One past the last bar.
  int get endBar => startBar + lengthBars;

  /// What it is called in a tiling report.
  String get name => source?.name ?? 'root-and-fifth (no match)';

  /// The notes, transposed and moved to their place in the progression.
  List<BassNoteSpec> notesAt(double beatsPerBar) {
    final fallback = fallbackNotes;
    final origin = startBar * beatsPerBar;
    if (fallback != null) {
      return <BassNoteSpec>[
        for (final note in fallback)
          BassNoteSpec(
            beat: note.beat + origin,
            pitch: note.pitch,
            durationBeats: note.durationBeats,
            velocity: note.velocity,
          ),
      ];
    }
    return <BassNoteSpec>[
      for (final note in source!.notes)
        BassNoteSpec(
          beat: note.beat + origin,
          pitch: note.pitch + transposition,
          durationBeats: note.durationBeats,
          velocity: note.velocity,
        ),
    ];
  }

  /// The final pitch, after transposition.
  int get lastPitch => fallbackNotes != null
      ? fallbackNotes!.last.pitch
      : source!.lastNote.pitch + transposition;

  /// The pitch before the final one, or null when there is only one note.
  int? get penultimatePitch {
    final notes = fallbackNotes ?? source!.notes;
    if (notes.length < 2) {
      return null;
    }
    final pitch = notes[notes.length - 2].pitch;
    return fallbackNotes != null ? pitch : pitch + transposition;
  }

  /// Where the next phrase joins from.
  JoinApproach get approach =>
      JoinApproach(lastPitch: lastPitch, previousPitch: penultimatePitch);
}

/// A finished tiling.
class Tiling {
  /// Create a tiling.
  Tiling(List<Placement> placements, List<String> gaps)
    : placements = List<Placement>.unmodifiable(placements),
      gaps = List<String>.unmodifiable(gaps);

  /// Placements in bar order.
  final List<Placement> placements;

  /// Bars the corpus did not cover, described for the arranger screen.
  final List<String> gaps;

  /// Every note of the line, in time order.
  List<BassNoteSpec> notes(double beatsPerBar) => <BassNoteSpec>[
    for (final placement in placements) ...placement.notesAt(beatsPerBar),
  ];

  /// Mean placement score, ignoring fallback bars — which have no score, and
  /// would otherwise let a tiling full of gaps look good.
  double get meanScore {
    final scored = placements
        .where((placement) => placement.score != null)
        .toList();
    if (scored.isEmpty) {
      return 0;
    }
    return scored
            .map((placement) => placement.score!.total)
            .reduce((a, b) => a + b) /
        scored.length;
  }

  /// The widest interval at any join, in semitones.
  int get widestJoin => placements
      .map((placement) => placement.score?.joinInterval ?? 0)
      .fold(
        0,
        (widest, interval) => interval.abs() > widest ? interval.abs() : widest,
      );

  /// How many bars fell back to root-and-fifth.
  int get fallbackBars =>
      placements.where((placement) => placement.isFallback).length;

  /// How many distinct source phrases were used. The blunt measure of whether a
  /// line repeats audibly, and the one M0.5 finding 1 was caught by.
  int get distinctPhrases =>
      placements.map((placement) => placement.name).toSet().length;

  /// The share of the line that is a phrase heard before, weighted (§11).
  ///
  /// §10 of the plan asks for a line that "does not repeat audibly over 3
  /// choruses". That is a property of the whole tiling, not of any placement
  /// in it, and no amount of placement scoring will notice it: when the form
  /// repeats, the best phrase at bar 1 is still the best phrase at bar 33.
  double get repetitionPenalty {
    if (placements.isEmpty) {
      return 0;
    }
    final repeated = 1 - distinctPhrases / placements.length;
    return repeated * _repetitionWeight;
  }

  /// How much a repeat costs against a smoother seam.
  ///
  /// Tunable by ear like the scorer's weights (§4), and the same kind of
  /// judgement — at this value a line that reuses every phrase gives up about
  /// as much as a join dropping from a step to a small leap.
  static const double _repetitionWeight = 0.2;

  /// How good the tiling is as a whole: smoothness less repetition.
  ///
  /// This, not [meanScore], is what the generator compares two tilings on.
  /// Ranking on mean score alone picks the *more* repetitive line — measured,
  /// not supposed: over three choruses of an AABA the smooth tiler scored 0.931
  /// using ten phrases where the varied one scored 0.915 using eighteen.
  double get quality => meanScore - repetitionPenalty;
}

/// How a tiler breaks the tie between equally-long candidates (§11).
enum TilingStrategy {
  /// Freshness gates, score ranks. Smoother, and the probe's rule.
  longestFirst,

  /// Freshness gates, then least-recently-used ranks and score breaks ties.
  /// More variety, at the cost of some smoothness.
  maximumDistanceBetweenReuses,
}

/// Chooses a covering of a progression from scored candidate phrases.
///
/// Rules: `docs/rules/corpus-tiling.md` §6 and §11.
class WbpTiler {
  /// Create a tiler.
  WbpTiler({
    required this.corpus,
    required this.tempo,
    this.reuseWindow = 6,
    this.strategy = TilingStrategy.longestFirst,
    this.seed = 0,
  }) : _scorer = WbpScorer(tempo: tempo, range: corpus.range);

  /// The source phrases.
  final BassCorpus corpus;

  /// The song's tempo, which the scorer uses to sharpen wide joins (§9).
  final int tempo;

  /// How many placements back a phrase counts as recently heard.
  final int reuseWindow;

  /// How ties between equally-long candidates are broken.
  final TilingStrategy strategy;

  /// The §6.2 seed: the only randomness in an otherwise deterministic tiler.
  ///
  /// Zero (the default) ranks on score alone, which is what the offline probe
  /// measured; the generator passes its context's seed so that a reroll picks
  /// a different line of the same quality instead of the same line again.
  final int seed;

  final WbpScorer _scorer;

  /// Tile `progression`.
  ///
  /// Never throws on a gap: §11 requires a shippable generator, so an
  /// uncoverable bar becomes a root-and-fifth bar and a line in [Tiling.gaps].
  Tiling tile(BassProgression progression, {double beatsPerBar = 4}) {
    final placements = <Placement>[];
    final gaps = <String>[];
    final lastUsedAt = <String, int>{};
    var bar = 0;
    JoinApproach? approach;

    while (bar < progression.barCount) {
      final chosen = _bestAt(
        progression,
        bar,
        approach,
        placements.length,
        lastUsedAt,
      );
      if (chosen == null) {
        final fallback = _fallbackBar(progression, bar, beatsPerBar);
        placements.add(fallback);
        gaps.add(
          'bar ${bar + 1} (${progression.bars[bar].format()}): no phrase in '
          '"${corpus.name}" matches',
        );
        approach = fallback.approach;
        bar += 1;
        continue;
      }
      placements.add(chosen);
      lastUsedAt[chosen.name] = placements.length;
      approach = chosen.approach;
      bar = chosen.endBar;
    }

    return Tiling(placements, gaps);
  }

  /// The best placement at `bar`, or null when nothing in the corpus matches.
  Placement? _bestAt(
    BassProgression progression,
    int bar,
    JoinApproach? approach,
    int placedSoFar,
    Map<String, int> lastUsedAt,
  ) {
    // §6.1 — every candidate at every length that still fits.
    final byLength = <int, List<Placement>>{};
    for (final length in corpus.lengthsLongestFirst) {
      if (bar + length > progression.barCount) {
        continue;
      }
      final candidates = _candidates(progression, bar, length, approach);
      if (candidates.isNotEmpty) {
        byLength[length] = candidates;
      }
    }
    if (byLength.isEmpty) {
      return null;
    }

    bool isFresh(Placement placement) {
      final used = lastUsedAt[placement.name];
      // §6.2 — fresh means nobody has heard it in the last [reuseWindow]
      // placements: a use `reuseWindow` placements back is at the edge of the
      // window and may be heard again.
      return used == null || placedSoFar - used >= reuseWindow;
    }

    // §6.2 — the longest length that still has something nobody has heard
    // recently. A long phrase heard four times in three choruses is a worse
    // failure than a seam, which is what M0.5 finding 1 established.
    var pool = <Placement>[];
    for (final length in corpus.lengthsLongestFirst) {
      final atLength = byLength[length];
      if (atLength == null) {
        continue;
      }
      final fresh = atLength.where(isFresh).toList();
      if (fresh.isNotEmpty) {
        pool = fresh;
        break;
      }
    }
    if (pool.isEmpty) {
      // §6.3 — everything is stale, so reuse the longest rather than stall.
      for (final length in corpus.lengthsLongestFirst) {
        final atLength = byLength[length];
        if (atLength != null) {
          pool = atLength;
          break;
        }
      }
    }

    _rank(pool, lastUsedAt);
    // Among the acceptable phrases, take the best-scoring octave of the one the
    // ranking put first.
    final chosenName = pool.first.name;
    return pool
        .where((placement) => placement.name == chosenName)
        .reduce((a, b) => b.score!.total > a.score!.total ? b : a);
  }

  /// Order a pool according to the strategy (§11).
  void _rank(List<Placement> pool, Map<String, int> lastUsedAt) {
    int lastUse(Placement placement) => lastUsedAt[placement.name] ?? -1000;
    // The §6.2 seed enters here. Without the nudge the tiler is fully
    // deterministic and a reroll with a fresh seed returns a byte-identical
    // line. The nudge is a stable hash of (seed, phrase, bar) in ±0.02 —
    // small against the gaps the score tables produce, large enough to
    // reorder near-ties.
    double total(Placement placement) =>
        placement.score!.total + _jitter(placement);
    switch (strategy) {
      case TilingStrategy.longestFirst:
        // §6.4 — freshness is a gate, not a ranking. Sorting by recency first
        // will cheerfully choose an octave-and-a-half jump over a step, which
        // is exactly what the join score exists to prevent (M0.5 finding 2).
        pool.sort((a, b) {
          final byScore = total(b).compareTo(total(a));
          return byScore != 0 ? byScore : lastUse(a).compareTo(lastUse(b));
        });
      case TilingStrategy.maximumDistanceBetweenReuses:
        pool.sort((a, b) {
          final byAge = lastUse(a).compareTo(lastUse(b));
          return byAge != 0 ? byAge : total(b).compareTo(total(a));
        });
    }
  }

  /// The seeded nudge for [placement], ±0.02, or zero when no seed was given.
  ///
  /// Hashed by hand rather than through [Object.hash] because String's hash
  /// code is randomised per isolate: the same seed must give the same line on
  /// every run, not just within one.
  double _jitter(Placement placement) {
    if (seed == 0) {
      return 0;
    }
    var hash = seed & 0x7fffffff;
    for (final unit in placement.name.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    hash = (hash * 31 + placement.startBar) & 0x7fffffff;
    return (hash % 2001 - 1000) * 0.00002;
  }

  /// Every scored placement of a phrase of `length` bars at `bar`.
  List<Placement> _candidates(
    BassProgression progression,
    int bar,
    int length,
    JoinApproach? approach,
  ) {
    final profile = progression.profileAt(bar, length);
    final destinationRoot = progression.rootAt(bar);
    final sources = corpus.candidatesFor(
      profile,
      destinationRoot: destinationRoot,
      tempo: tempo,
    );
    final placements = <Placement>[];
    for (final source in sources) {
      Placement? best;
      for (final transposition in source.transpositionsTo(destinationRoot)) {
        final score = _scorer.score(source, transposition, approach);
        if (best == null || score.total > best.score!.total) {
          best = Placement(
            source: source,
            startBar: bar,
            transposition: transposition,
            score: score,
          );
        }
      }
      // §5 constraint 4 — a phrase whose *best* octave still makes a bad seam
      // is rejected rather than placed. M0.5 finding 4: without this, a phrase
      // with one reachable octave forces its seam on the line wherever it
      // lands, because there was nothing else to choose.
      if (best != null && WbpScorer.isAcceptableSeam(best.score!)) {
        placements.add(best);
      }
    }
    return placements;
  }

  /// A root-and-fifth bar, for a chord the corpus does not cover (§11).
  ///
  /// Deliberately dull. It has to be recognisable as a gap when you hear it, so
  /// that the honest fix — adding a phrase to the corpus — is the one that gets
  /// made. Dressing it up would hide exactly the information the corpus needs.
  Placement _fallbackBar(
    BassProgression progression,
    int bar,
    double beatsPerBar,
  ) {
    final chord = progression.bars[bar];
    final colour = ChordTones.of(chord);
    final root = _inRange(chord.root.pitchClass);
    // The perfect fifth if the chord has one, otherwise the chord tone nearest
    // to where a fifth would be: a diminished chord's "fifth" is a tritone,
    // and playing a perfect fifth over it would be worse than dull.
    //
    // Nearest, not first. `firstWhere` returned the lowest non-root chord
    // tone, which for a diminished or half-diminished chord is the *minor
    // third* — so the deliberately dull root-and-fifth bar outlined a minor
    // triad over a diminished sonority, which is not dull, it is wrong.
    final rootClass = chord.root.pitchClass;
    final perfect = (rootClass + 7) % 12;
    final fifthClass = colour.chordTones.contains(perfect)
        ? perfect
        : colour.chordTones
                  .where((pitchClass) => pitchClass != rootClass)
                  .fold<int?>(null, (best, pitchClass) {
                    if (best == null) {
                      return pitchClass;
                    }
                    // Distance above the root, so the comparison is about where
                    // the tone sits in the chord rather than about pitch-class
                    // arithmetic wrapping through zero.
                    final above = (pitchClass - rootClass + 12) % 12;
                    final bestAbove = (best - rootClass + 12) % 12;
                    return (above - 7).abs() < (bestAbove - 7).abs()
                        ? pitchClass
                        : best;
                  }) ??
              perfect;
    var fifth = root + ((fifthClass - root % 12 + 12) % 12);
    // Wrap by octaves until it fits: one correction is not enough when the
    // corpus declares a range narrower than twelve semitones.
    while (fifth > corpus.range.highest) {
      fifth -= 12;
    }
    // A degenerate custom range may admit no octave of the fifth at all; a
    // clamp at least keeps the note on the instrument.
    fifth = fifth.clamp(corpus.range.lowest, corpus.range.highest);
    final beats = beatsPerBar.round();
    return Placement.fallback(
      startBar: bar,
      notes: <BassNoteSpec>[
        for (var beat = 0; beat < beats; beat++)
          BassNoteSpec(
            beat: beat.toDouble(),
            pitch: beat.isEven ? root : fifth,
            velocity: beat == 0 ? 94 : 82,
          ),
      ],
    );
  }

  /// The octave of `pitchClass` nearest the middle of the instrument's range.
  int _inRange(int pitchClass) {
    var pitch =
        corpus.range.lowest +
        ((pitchClass - corpus.range.lowest) % 12 + 12) % 12;
    while (pitch + 12 <= corpus.range.centre + 6) {
      pitch += 12;
    }
    return pitch.clamp(corpus.range.lowest, corpus.range.highest);
  }
}
