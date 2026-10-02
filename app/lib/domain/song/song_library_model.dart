import 'song.dart';

/// A song's headline facts, without its chart.
///
/// The library screen shows hundreds of these and opens one. Loading every
/// chart to draw a list would make the screen slow for no reason, and §3 gives
/// cold start to library visible a one-second target.
class SongSummary implements Comparable<SongSummary> {
  /// Create a summary.
  const SongSummary({
    required this.id,
    required this.title,
    required this.composer,
    required this.tempo,
    required this.keyName,
    required this.barCount,
    required this.tags,
    required this.modifiedAt,
  });

  /// Summarise a loaded song.
  factory SongSummary.of(Song song) => SongSummary(
    id: song.id,
    title: song.title,
    composer: song.composer,
    tempo: song.tempo,
    keyName: song.key.toString(),
    barCount: song.leadSheet.barCount,
    tags: song.tags,
    modifiedAt: song.modifiedAt,
  );

  /// The song's id, and its file name in the library.
  final String id;

  /// What the tune is called.
  final String title;

  /// Who wrote it.
  final String composer;

  /// Tempo in beats per minute.
  final int tempo;

  /// The key, as written.
  final String keyName;

  /// How many bars are on the page.
  final int barCount;

  /// The song's tags.
  final Set<String> tags;

  /// When it was last changed.
  final DateTime modifiedAt;

  /// Whether this song matches a search box's contents.
  ///
  /// Case-insensitive, matching title, composer and tags, and requiring every
  /// whitespace-separated word to match something — so `blue monk` finds
  /// Monk's Blue Monk and not every blues in the library.
  bool matches(String query) {
    final words = query.toLowerCase().split(RegExp(r'\s+'))
      ..removeWhere((word) => word.isEmpty);
    if (words.isEmpty) {
      return true;
    }
    final haystack =
        '${title.toLowerCase()} ${composer.toLowerCase()} '
        '${tags.map((t) => t.toLowerCase()).join(' ')} '
        '${keyName.toLowerCase()}';
    return words.every(haystack.contains);
  }

  @override
  int compareTo(SongSummary other) {
    final byTitle = title.toLowerCase().compareTo(other.title.toLowerCase());
    return byTitle != 0 ? byTitle : id.compareTo(other.id);
  }

  @override
  String toString() => '$title — $composer';

  @override
  bool operator ==(Object other) =>
      other is SongSummary &&
      other.id == id &&
      other.title == title &&
      other.composer == composer &&
      other.tempo == tempo &&
      other.keyName == keyName &&
      other.barCount == barCount &&
      other.modifiedAt == modifiedAt &&
      other.tags.length == tags.length &&
      other.tags.containsAll(tags);

  @override
  int get hashCode => Object.hash(
    id,
    title,
    composer,
    tempo,
    keyName,
    barCount,
    modifiedAt,
    Object.hashAllUnordered(tags),
  );
}

/// How the library screen orders its list.
enum SongSortOrder {
  /// A to Z by title.
  title('Title'),

  /// A to Z by composer, then title.
  composer('Composer'),

  /// Most recently changed first.
  recentlyModified('Recently changed'),

  /// Slowest to fastest.
  tempo('Tempo');

  const SongSortOrder(this.label);

  /// What the sort menu calls it.
  final String label;

  /// Sort [summaries] by this order. Returns a new list.
  List<SongSummary> apply(Iterable<SongSummary> summaries) {
    final sorted = summaries.toList();
    switch (this) {
      case SongSortOrder.title:
        sorted.sort();
      case SongSortOrder.composer:
        sorted.sort((a, b) {
          final byComposer = a.composer.toLowerCase().compareTo(
            b.composer.toLowerCase(),
          );
          return byComposer != 0 ? byComposer : a.compareTo(b);
        });
      case SongSortOrder.recentlyModified:
        sorted.sort((a, b) {
          final byDate = b.modifiedAt.compareTo(a.modifiedAt);
          return byDate != 0 ? byDate : a.compareTo(b);
        });
      case SongSortOrder.tempo:
        sorted.sort((a, b) {
          final byTempo = a.tempo.compareTo(b.tempo);
          return byTempo != 0 ? byTempo : a.compareTo(b);
        });
    }
    return sorted;
  }
}
