import 'dart:math';

import 'package:bandstand/io/library/manifest.dart';

/// One find from the library search (ADR 0012 §4): a volume whose own name
/// matched, or a track with the volume that contains it — "autumn leaves"
/// answers with every volume that has the tune, one row per find.
sealed class LibrarySearchHit {
  const LibrarySearchHit();
}

/// A volume whose name matched.
class LibraryVolumeHit extends LibrarySearchHit {
  /// Create the hit.
  const LibraryVolumeHit(this.volume);

  /// The volume that matched.
  final LibraryVolume volume;
}

/// A track that matched.
class LibraryTrackHit extends LibrarySearchHit {
  /// Create the hit.
  const LibraryTrackHit(this.volume, this.entry);

  /// The volume the track lives in.
  final LibraryVolume volume;

  /// The track.
  final LibraryEntry entry;
}

/// Every volume and track in [manifest] whose name matches [query], best
/// first — the library is disciplined, so this is the whole of search: no
/// index, no corpus, one pass over the manifest per keystroke.
///
/// A query matches when its normalised form matches the normalised name:
/// the ordinal prefix and the extension are set aside (they stay
/// searchable as words), underscores and punctuation read as spaces, and
/// letter case never matters. Matching happens in four tiers, so the
/// obvious answer outranks the generous one:
///
/// 1. the name starts with the query;
/// 2. the name contains the query as a phrase;
/// 3. every query word is contained in some name word, in any order;
/// 4. every query word is matched fuzzily by some name word — a
///    substring either way, or a typo within a bounded edit distance.
///
/// Inside a tier, the hit that accounts for more of its name's words
/// comes first (`autumnleaves` ranks `autumn_leaves` above `late_autumn`),
/// and after that the tree's own order decides: volume, then entry.
List<LibrarySearchHit> searchLibrary(LibraryManifest manifest, String query) {
  final queryText = _normalize(query);
  if (queryText.isEmpty) {
    return const <LibrarySearchHit>[];
  }
  final queryWords = queryText.split(' ');
  final ranked =
      <
        ({
          LibrarySearchHit hit,
          int tier,
          double coverage,
          int volume,
          int entry,
        })
      >[];
  for (var v = 0; v < manifest.volumes.length; v++) {
    final volume = manifest.volumes[v];
    final volumeMatch = _matchOf(
      _searchable(volume.name),
      queryText,
      queryWords,
    );
    if (volumeMatch != null) {
      ranked.add((
        hit: LibraryVolumeHit(volume),
        tier: volumeMatch.tier,
        coverage: volumeMatch.coverage,
        volume: v,
        entry: -1,
      ));
    }
    for (var e = 0; e < volume.entries.length; e++) {
      final entry = volume.entries[e];
      // The book's name is `book.pdf`, not a tune title, and stray files
      // are nobody's search target; a volume hit is where their verbs
      // live. Tracks are what the field is for.
      if (entry.kind != LibraryEntryKind.track) {
        continue;
      }
      final match = _matchOf(_searchable(entry.name), queryText, queryWords);
      if (match != null) {
        ranked.add((
          hit: LibraryTrackHit(volume, entry),
          tier: match.tier,
          coverage: match.coverage,
          volume: v,
          entry: e,
        ));
      }
    }
  }
  ranked.sort((a, b) {
    final byTier = a.tier.compareTo(b.tier);
    if (byTier != 0) {
      return byTier;
    }
    final byCoverage = b.coverage.compareTo(a.coverage);
    if (byCoverage != 0) {
      return byCoverage;
    }
    final byVolume = a.volume.compareTo(b.volume);
    if (byVolume != 0) {
      return byVolume;
    }
    return a.entry.compareTo(b.entry);
  });
  return <LibrarySearchHit>[for (final each in ranked) each.hit];
}

/// One name as the matcher sees it: the phrase its tiers 1 and 2 read, and
/// the word list its tiers 3 and 4 read — with the ordinal kept as a word
/// so `054` and `11` find things, while the tune's name starts clean.
({String text, List<String> words}) _searchable(String canonicalName) {
  final prefix = RegExp(r'^(\d+)_').firstMatch(canonicalName);
  final ordinal = prefix?.group(1);
  final rest = prefix == null
      ? canonicalName
      : canonicalName.substring(prefix.end);
  final text = _normalize(rest.replaceFirst(RegExp(r'\.[^.]+$'), ''));
  return (
    text: text,
    words: <String>[
      ?ordinal,
      ...text.isEmpty ? const <String>[] : text.split(' '),
    ],
  );
}

/// Lowercase, and every run of anything that is not a letter or a digit
/// reads as one space — underscores, dashes, apostrophes, dots alike.
String _normalize(String name) =>
    name.toLowerCase().replaceAll(RegExp(r'[^0-9a-z]+'), ' ').trim();

/// The tier [queryText]/[queryWords] matches [target] in, and how much of
/// the target's words the query accounts for — null for no match. The
/// phrase tiers are the whole name by definition, so only the fuzzy tier
/// earns less than full coverage.
({int tier, double coverage})? _matchOf(
  ({String text, List<String> words}) target,
  String queryText,
  List<String> queryWords,
) {
  if (target.text.startsWith(queryText)) {
    return (tier: 0, coverage: 1);
  }
  if (target.text.contains(queryText)) {
    return (tier: 1, coverage: 1);
  }
  if (queryWords.every(
    (queryWord) => target.words.any((word) => word.contains(queryWord)),
  )) {
    return (tier: 2, coverage: 1);
  }
  if (queryWords.every(
    (queryWord) =>
        target.words.any((word) => _fuzzyWordMatches(queryWord, word)),
  )) {
    return (tier: 3, coverage: _coverageOf(target.words, queryWords));
  }
  return null;
}

/// The share of [words] the query speaks to — how much of the name the
/// match explains. Only words long enough to mean something count; a name
/// with none of them is all explanation and nothing to explain.
double _coverageOf(List<String> words, List<String> queryWords) {
  var countable = 0;
  var spokenTo = 0;
  for (final word in words) {
    if (word.length < 3) {
      continue;
    }
    countable++;
    if (queryWords.any((queryWord) => _fuzzyWordMatches(queryWord, word))) {
      spokenTo++;
    }
  }
  return countable == 0 ? 1 : spokenTo / countable;
}

/// Whether [queryWord] is [word] misspelled: contained in it either way,
/// or a substitution, insertion or deletion away (two, for words long
/// enough to carry it). Three guards keep the tier honest: short words do
/// not fuzz at all — `in` would match everything — a run-together query
/// only swallows words of some length, and digit words never fuzz —
/// `011` drifting to `001` finds another track, not a spelling of this
/// one.
bool _fuzzyWordMatches(String queryWord, String word) {
  if (word.contains(queryWord)) {
    return true;
  }
  if (word.length >= 3 && queryWord.contains(word)) {
    return true;
  }
  if (queryWord.length < 3 || word.length < 3) {
    return false;
  }
  final digitsOnly = RegExp(r'^\d+$');
  if (digitsOnly.hasMatch(queryWord) && digitsOnly.hasMatch(word)) {
    return false;
  }
  return _withinEditDistance(queryWord, word, queryWord.length <= 4 ? 1 : 2);
}

/// The Levenshtein distance between [a] and [b], as a yes/no against
/// [limit] — two rows and an early out when a row is already past it.
/// Words here are tune-title words: short, and few of them.
bool _withinEditDistance(String a, String b, int limit) {
  if ((a.length - b.length).abs() > limit) {
    return false;
  }
  var previous = List<int>.generate(b.length + 1, (j) => j);
  for (var i = 1; i <= a.length; i++) {
    final current = List<int>.filled(b.length + 1, 0)..[0] = i;
    var rowMinimum = i;
    for (var j = 1; j <= b.length; j++) {
      final substitution =
          previous[j - 1] +
          (a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1);
      current[j] = min(substitution, min(previous[j] + 1, current[j - 1] + 1));
      if (current[j] < rowMinimum) {
        rowMinimum = current[j];
      }
    }
    if (rowMinimum > limit) {
      return false;
    }
    previous = current;
  }
  return previous[b.length] <= limit;
}
