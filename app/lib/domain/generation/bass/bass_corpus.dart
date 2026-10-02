import 'root_profile.dart';
import 'wbp_source.dart';

/// A corpus of walking-bass source phrases, indexed for the tiler.
///
/// `docs/rules/corpus-tiling.md` §3 matches on an exact root profile, so the
/// index is a map from profile to the phrases that carry it. Building it costs
/// one pass at load and turns every lookup during tiling into a hash — which
/// matters because §3 of the plan gives the whole pipeline 100 ms and the tiler
/// asks this question once per bar per candidate length.
class BassCorpus {
  /// Index a set of phrases.
  ///
  /// Throws [ArgumentError] if two phrases share a name: the reuse window of §6
  /// tracks phrases by name, so duplicates would be heard as one phrase and
  /// silently defeat the freshness rule.
  factory BassCorpus({
    required String name,
    required Iterable<WbpSource> phrases,
    BassRange range = const BassRange(),
  }) {
    final list = List<WbpSource>.unmodifiable(phrases);
    final byProfile = <RootProfile, List<WbpSource>>{};
    final seen = <String>{};
    final lengths = <int>{};
    for (final phrase in list) {
      if (!seen.add(phrase.name)) {
        throw ArgumentError.value(
          phrase.name,
          'phrases',
          'two phrases share this name',
        );
      }
      byProfile
          .putIfAbsent(phrase.rootProfile, () => <WbpSource>[])
          .add(phrase);
      lengths.add(phrase.lengthBars);
    }
    return BassCorpus._(
      name,
      list,
      range,
      Map<RootProfile, List<WbpSource>>.unmodifiable(
        <RootProfile, List<WbpSource>>{
          for (final entry in byProfile.entries)
            entry.key: List<WbpSource>.unmodifiable(entry.value),
        },
      ),
      List<int>.unmodifiable(lengths.toList()..sort((a, b) => b.compareTo(a))),
    );
  }

  const BassCorpus._(
    this.name,
    this.phrases,
    this.range,
    this._byProfile,
    this.lengthsLongestFirst,
  );

  /// An empty corpus, which every tiling over it will report as a gap.
  factory BassCorpus.empty() =>
      BassCorpus(name: 'empty', phrases: const <WbpSource>[]);

  /// Identifies the corpus in reports and in the tiling log.
  final String name;

  /// Every phrase, in the order the file listed them.
  final List<WbpSource> phrases;

  /// The instrument range the phrases were built against.
  final BassRange range;

  final Map<RootProfile, List<WbpSource>> _byProfile;

  /// The phrase lengths present, in bars, longest first. The tiler walks these
  /// rather than guessing at a range (§6.2).
  final List<int> lengthsLongestFirst;

  /// How many phrases.
  int get length => phrases.length;

  /// Whether there is nothing to tile with.
  bool get isEmpty => phrases.isEmpty;

  /// The distinct root profiles covered.
  Iterable<RootProfile> get profiles => _byProfile.keys;

  /// The phrases matching `profile` exactly, playable at `tempo`, that can
  /// reach `destinationRoot`.
  ///
  /// Three filters, all of them cheap and all of them applied before any
  /// scoring: the profile match of §3, the tempo band of §9, and the
  /// transposibility map of §8. A phrase that fails any of them could not have
  /// been placed, and scoring it to find that out is work done for nothing.
  List<WbpSource> candidatesFor(
    RootProfile profile, {
    required int destinationRoot,
    required int tempo,
  }) {
    final matches = _byProfile[profile];
    if (matches == null) {
      return const <WbpSource>[];
    }
    return <WbpSource>[
      for (final phrase in matches)
        if (phrase.isPlayable &&
            phrase.tempoRange.admits(tempo) &&
            phrase.canReach(destinationRoot))
          phrase,
    ];
  }

  /// Every phrase that fails the §5 constraints, and so can never be placed.
  ///
  /// Dead weight that looks like coverage. The corpus test asserts this is
  /// empty; the importer reports it so a bad take is caught at import rather
  /// than discovered as a hole in the tiling months later.
  List<WbpSource> get unplayable => <WbpSource>[
    for (final phrase in phrases)
      if (!phrase.isPlayable) phrase,
  ];

  @override
  String toString() =>
      '$name (${phrases.length} phrases, '
      '${_byProfile.length} profiles)';
}
