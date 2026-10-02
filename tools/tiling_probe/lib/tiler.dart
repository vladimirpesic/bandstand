import 'harmony.dart';
import 'phrase.dart';

/// A target progression: one chord per bar, 4/4.
class Progression {
  Progression(this.name, List<String> chordsPerBar)
    : bars = <Chord>[for (final symbol in chordsPerBar) Chord.parse(symbol)];

  /// Display name.
  final String name;

  /// One chord per bar.
  final List<Chord> bars;

  /// Number of bars.
  int get barCount => bars.length;

  /// The root profile of `count` bars starting at `start`.
  RootProfile profileAt(int start, int count) => RootProfile.of(<ChordSpan>[
    for (var i = 0; i < count; i++)
      ChordSpan((i * 4).toDouble(), 4, bars[start + i]),
  ]);

  /// This progression repeated `times` times, end to end.
  Progression repeated(int times) => Progression('$name ×$times', <String>[
    for (var i = 0; i < times; i++)
      for (final chord in bars) chord.toString(),
  ]);
}

/// Lowest and highest pitch a double bass will play.
const int lowestBassPitch = 28; // E1
const int highestBassPitch = 55; // G3

/// The middle of the register, used to pull the line back when nothing else
/// distinguishes two octaves.
const int _registerCentre = 41;

/// One placed phrase.
class Placement {
  const Placement({
    required this.phrase,
    required this.startBar,
    required this.transposition,
    required this.score,
    required this.joinInterval,
  });

  /// The source phrase.
  final BassPhrase phrase;

  /// Bar it starts at, within the target progression.
  final int startBar;

  /// Semitones the phrase was moved by, including octave choice.
  final int transposition;

  /// Its total score, for the report.
  final double score;

  /// Semitones between the previous placement's last note and this one's first,
  /// or null for the first placement.
  final int? joinInterval;

  /// One past the last bar.
  int get endBar => startBar + phrase.lengthBars;

  /// The notes, transposed and moved to their place in the progression.
  List<BassNote> notes() => <BassNote>[
    for (final note in phrase.notes) note.placed(transposition, startBar * 4.0),
  ];
}

/// A completed tiling.
class Tiling {
  const Tiling(this.placements);

  /// Placements in bar order.
  final List<Placement> placements;

  /// Every note of the line, in time order.
  List<BassNote> notes() => <BassNote>[
    for (final placement in placements) ...placement.notes(),
  ];

  /// Mean placement score.
  double get meanScore => placements.isEmpty
      ? 0
      : placements.map((p) => p.score).reduce((a, b) => a + b) /
            placements.length;

  /// The largest interval at any join, in semitones.
  int get widestJoin => placements
      .map((p) => p.joinInterval ?? 0)
      .fold(0, (a, b) => b.abs() > a ? b.abs() : a);
}

/// Thrown when the corpus cannot cover the progression.
class TilingFailure implements Exception {
  TilingFailure(this.bar, this.profile);

  /// The bar the tiler got stuck at.
  final int bar;

  /// The profile it could not match.
  final String profile;

  @override
  String toString() =>
      'no phrase in the corpus matches bar ${bar + 1} ($profile). '
      'The probe reports this rather than inventing a fallback — see '
      'docs/rules/corpus-tiling.md §6.';
}

/// Scores and tiles source phrases over a progression.
///
/// Rules: `docs/rules/corpus-tiling.md` §4–§6.
class Tiler {
  Tiler(this.corpus, {this.reuseWindow = 6});

  /// The source phrases.
  final List<BassPhrase> corpus;

  /// How many placements back a phrase is still considered "recently used".
  final int reuseWindow;

  static const double _harmonyWeight = 1;
  static const double _joinWeight = 2;
  static const double _registerWeight = 0.5;

  /// Harmonic fit of a phrase at a transposition (§4.1).
  ///
  /// Invariant under transposition by construction, which is the point: it
  /// scores the corpus, not the placement.
  static double harmonicFit(BassPhrase phrase, int transposition) {
    var total = 0.0;
    for (final note in phrase.notes) {
      final chord = phrase.chordAt(note.beat).transposed(transposition % 12);
      final pitch = note.pitch + transposition;
      final strong = note.beat % 2 == 0;
      if (chord.isChordTone(pitch)) {
        total += 1.0;
      } else if (chord.isScaleTone(pitch)) {
        total += strong ? 0.55 : 0.9;
      } else {
        total += strong ? 0.1 : 0.8;
      }
    }
    return total / phrase.notes.length;
  }

  /// Join quality for an interval in semitones (§4.2).
  static double joinScore(int? interval) {
    if (interval == null) {
      return 1;
    }
    final distance = interval.abs();
    if (distance == 0) {
      return 0.35;
    }
    if (distance <= 2) {
      return 1.0;
    }
    if (distance <= 5) {
      return 0.85;
    }
    if (distance <= 7) {
      return 0.6;
    }
    if (distance <= 12) {
      return 0.3;
    }
    return 0.05;
  }

  /// How well a transposed phrase sits in the instrument's register (§4.3).
  static double registerScore(BassPhrase phrase, int transposition) {
    final low = phrase.lowestPitch + transposition;
    final high = phrase.highestPitch + transposition;
    if (low < lowestBassPitch || high > highestBassPitch) {
      return 0;
    }
    final centre = (low + high) / 2;
    final drift = (centre - _registerCentre).abs();
    return (1 - drift / 12).clamp(0.0, 1.0);
  }

  /// Every octave of `phrase` at `pitchClassShift` that keeps it in range.
  static List<int> _octaveChoices(BassPhrase phrase, int pitchClassShift) {
    final choices = <int>[];
    for (var octave = -3; octave <= 3; octave++) {
      final transposition = pitchClassShift + octave * 12;
      if (phrase.lowestPitch + transposition >= lowestBassPitch &&
          phrase.highestPitch + transposition <= highestBassPitch) {
        choices.add(transposition);
      }
    }
    return choices;
  }

  /// Candidate placements of `phrase` at `bar`, or an empty list.
  List<Placement> candidatesAt(
    Progression progression,
    BassPhrase phrase,
    int bar,
    int? previousPitch,
  ) {
    if (bar + phrase.lengthBars > progression.barCount) {
      return const <Placement>[];
    }
    if (!phrase.startsOnRoot || !phrase.endsOnChordTone) {
      return const <Placement>[];
    }
    if (progression.profileAt(bar, phrase.lengthBars) != phrase.rootProfile) {
      return const <Placement>[];
    }

    final shift =
        (progression.bars[bar].rootPitchClass -
            phrase.firstRootPitchClass +
            12) %
        12;
    final placements = <Placement>[];
    for (final transposition in _octaveChoices(phrase, shift)) {
      final firstPitch = phrase.firstNote.pitch + transposition;
      final join = previousPitch == null ? null : firstPitch - previousPitch;
      final score =
          _harmonyWeight * harmonicFit(phrase, transposition) +
          _joinWeight * joinScore(join) +
          _registerWeight * registerScore(phrase, transposition);
      placements.add(
        Placement(
          phrase: phrase,
          startBar: bar,
          transposition: transposition,
          score: score / (_harmonyWeight + _joinWeight + _registerWeight),
          joinInterval: join,
        ),
      );
    }
    return placements;
  }

  /// Tile `progression` (§6).
  ///
  /// Longest phrase first; among equal lengths, least recently used first, then
  /// highest scoring.
  Tiling tile(Progression progression) {
    final placements = <Placement>[];
    final lastUsedAt = <String, int>{};
    var bar = 0;
    int? previousPitch;

    while (bar < progression.barCount) {
      final candidates = <Placement>[
        for (final phrase in corpus)
          ...candidatesAt(progression, phrase, bar, previousPitch),
      ];
      if (candidates.isEmpty) {
        throw TilingFailure(bar, _describeFrom(progression, bar));
      }

      // Longest first — but *without repetition*, which is the half of the
      // rule that matters. Take the longest length that still has a phrase
      // nobody has heard recently; only if every length is stale does the
      // tiler fall back to reusing the longest.
      final lengths =
          candidates.map((p) => p.phrase.lengthBars).toSet().toList()
            ..sort((a, b) => b.compareTo(a));

      bool isFresh(Placement placement) {
        final used = lastUsedAt[placement.phrase.name];
        return used == null || placements.length - used > reuseWindow;
      }

      var pool = <Placement>[];
      for (final length in lengths) {
        final atLength = candidates
            .where((p) => p.phrase.lengthBars == length)
            .toList();
        final fresh = atLength.where(isFresh).toList();
        if (fresh.isNotEmpty) {
          pool = fresh;
          break;
        }
      }
      if (pool.isEmpty) {
        pool = candidates
            .where((p) => p.phrase.lengthBars == lengths.first)
            .toList();
      }

      // Freshness is a *gate*, not a ranking: the pool already excludes what
      // was heard recently, so within it the best-sounding placement wins.
      // Ranking by freshness first would happily choose an octave-and-a-half
      // jump over a step, which is the one thing the join score exists to
      // prevent.
      pool.sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        if (byScore != 0) {
          return byScore;
        }
        final aUsed = lastUsedAt[a.phrase.name] ?? -1000;
        final bUsed = lastUsedAt[b.phrase.name] ?? -1000;
        return aUsed.compareTo(bUsed);
      });

      // Among the acceptable phrases, take the best-scoring octave of the one
      // the sort put first.
      final chosenName = pool.first.phrase.name;
      final chosen = pool
          .where((p) => p.phrase.name == chosenName)
          .reduce((a, b) => b.score > a.score ? b : a);

      placements.add(chosen);
      lastUsedAt[chosenName] = placements.length;
      previousPitch = chosen.phrase.lastNote.pitch + chosen.transposition;
      bar = chosen.endBar;
    }

    return Tiling(placements);
  }

  static String _describeFrom(Progression progression, int bar) {
    final end = (bar + 4).clamp(0, progression.barCount);
    return progression.bars.sublist(bar, end).join(' | ');
  }
}
