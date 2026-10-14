import 'package:bandstand/io/library/library_search.dart';
import 'package:bandstand/io/library/mirror_cache.dart';
import 'package:bandstand/state/library.dart';
import 'package:bandstand/ui/screens/library_screen.dart';
import 'package:bandstand/ui/screens/player_screen.dart';
import 'package:bandstand/ui/widgets/add_to_setlist_sheet.dart';
import 'package:bandstand/ui/widgets/centered_note.dart';
import 'package:bandstand/ui/widgets/volume_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The library's search screen (ADR 0012 §4): one field over the whole
/// tree, results live as the query is typed. The delegate is the route's
/// chrome only; the results watch the library themselves, so a sync that
/// lands mid-search is in the next keystroke, not the next visit.
class LibrarySearchScreen extends SearchDelegate<void> {
  /// Create the search.
  LibrarySearchScreen()
    : super(
        searchFieldLabel: 'Tune or volume',
        textInputAction: TextInputAction.search,
      );

  @override
  Widget buildLeading(BuildContext context) => IconButton(
    tooltip: 'Back to the library',
    icon: AnimatedIcon(
      icon: AnimatedIcons.menu_arrow,
      progress: transitionAnimation,
    ),
    onPressed: () => close(context, null),
  );

  @override
  List<Widget> buildActions(BuildContext context) => <Widget>[
    IconButton(
      tooltip: query.isEmpty ? 'Close' : 'Clear',
      icon: const Icon(Icons.clear),
      onPressed: query.isEmpty ? () => close(context, null) : () => query = '',
    ),
  ];

  @override
  Widget buildResults(BuildContext context) =>
      _Results(delegate: this, query: query);

  @override
  Widget buildSuggestions(BuildContext context) =>
      _Results(delegate: this, query: query);
}

/// The results for one query: every matching volume and track, in the
/// order the search gives them, with the way into each.
class _Results extends ConsumerWidget {
  const _Results({required this.delegate, required this.query});

  final LibrarySearchScreen delegate;

  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phase = ref.watch(libraryProvider);
    if (phase is! LibraryReady) {
      return const CenteredNote(
        icon: Icons.library_music,
        message: 'The library went away; go back and reopen it.',
      );
    }
    if (query.trim().isEmpty) {
      return const CenteredNote(
        icon: Icons.music_note,
        message: 'Search every tune and volume in the library.',
      );
    }
    final hits = searchLibrary(phase.manifest, query);
    if (hits.isEmpty) {
      return CenteredNote(
        icon: Icons.search_off,
        message: "Nothing in the library matches '$query'.",
      );
    }
    return ListView.builder(
      itemCount: hits.length,
      itemBuilder: (context, index) => _rowFor(context, phase, hits[index]),
    );
  }

  Widget _rowFor(
    BuildContext context,
    LibraryReady phase,
    LibrarySearchHit hit,
  ) {
    switch (hit) {
      case LibraryVolumeHit():
        return VolumeTile(
          phase: phase,
          volume: hit.volume,
          onTap: () {
            delegate.close(context, null);
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (context) => VolumeScreen(volumeId: hit.volume.id),
              ),
            );
          },
        );
      case LibraryTrackHit():
        final presence = phase.presence[hit.entry.id] ?? CachePresence.absent;
        return _TrackRow(
          hit: hit,
          presence: presence,
          // A track on this device is one tap from the player; one that is
          // not goes to its volume, where the download verb lives — an
          // absent file has nothing to play.
          onTap: () {
            delegate.close(context, null);
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (context) => presence != CachePresence.absent
                    ? PlayerScreen(
                        volumeId: hit.volume.id,
                        entryId: hit.entry.id,
                      )
                    : VolumeScreen(volumeId: hit.volume.id),
              ),
            );
          },
        );
    }
  }
}

/// One track find: the tune, its number, and the volume it lives in.
/// On this device, it carries the same two verbs the library rows do —
/// the bookmark (Favorites) and the setlist `+` — so a search result
/// is a starting point, not a dead end.
class _TrackRow extends ConsumerWidget {
  const _TrackRow({
    required this.hit,
    required this.presence,
    required this.onTap,
  });

  final LibraryTrackHit hit;

  /// Whether — and how — the file is on this device; said out loud in
  /// the subtitle, because it decides where the tap goes.
  final CachePresence presence;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final volume = hit.volume;
    final number = volume.volumeNumber?.toString().padLeft(3, '0');
    final where =
        '${number == null ? '' : 'Vol $number · '}'
        '${volume.displayName}';
    final present = presence != CachePresence.absent;
    final saved = presence == CachePresence.saved;
    return ListTile(
      leading: SizedBox(
        width: 34,
        child: Text(
          hit.entry.trackNumber?.toString().padLeft(2, '0') ?? '··',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
      title: Text(
        hit.entry.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        present ? where : '$where · not on this device',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: present
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                IconButton(
                  tooltip: saved
                      ? 'In Favorites — make it a session download'
                      : 'Add to Favorites — keep on this device',
                  onPressed: () => ref
                      .read(libraryProvider.notifier)
                      .toggleSaved(hit.volume, hit.entry),
                  icon: Icon(
                    saved ? Icons.bookmark : Icons.bookmark_add_outlined,
                  ),
                ),
                IconButton(
                  tooltip: 'Add to a setlist',
                  onPressed: () => showAddToSetlistSheet(
                    context,
                    trackName: hit.entry.displayName,
                    entryId: hit.entry.id,
                  ),
                  icon: const Icon(Icons.add),
                ),
              ],
            )
          : null,
      onTap: onTap,
    );
  }
}
