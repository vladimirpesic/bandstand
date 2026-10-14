import 'package:bandstand/io/library/manifest.dart';
import 'package:bandstand/io/library/mirror_cache.dart';
import 'package:bandstand/io/library/setlists.dart';
import 'package:bandstand/state/library.dart';
import 'package:bandstand/state/setlists.dart';
import 'package:bandstand/ui/screens/library_screen.dart';
import 'package:bandstand/ui/screens/player_screen.dart';
import 'package:bandstand/ui/widgets/centered_note.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The setlists screen: the default, derived "Favorites" pinned first,
/// then the user's own lists — each with its rename pencil and delete
/// bin. A setlist is references, never copies: delete one and the
/// library is exactly as it was.
class SetlistsScreen extends ConsumerWidget {
  /// Create the screen.
  const SetlistsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final setlists = ref.watch(setlistsProvider);
    final phase = ref.watch(libraryProvider);
    final favorites = phase is LibraryReady ? favoritesOf(phase).length : 0;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Setlists'),
        actions: <Widget>[
          IconButton(
            tooltip: 'New setlist',
            onPressed: setlists.isWritable
                ? () => _NameDialog.show(
                    context,
                    title: 'New setlist',
                    confirmLabel: 'Create',
                    onConfirm: (name) =>
                        ref.read(setlistsProvider.notifier).create(name),
                  )
                : null,
            icon: const Icon(Icons.playlist_add),
          ),
        ],
      ),
      body: setlists.problem != null
          ? CenteredNote(
              icon: Icons.warning_amber_outlined,
              message:
                  'The setlists file cannot be read: ${setlists.problem} '
                  'Setlists stay read-only until it is fixed.',
            )
          : ListView(
              children: <Widget>[
                ListTile(
                  leading: const Icon(Icons.bookmark),
                  title: const Text(favoritesSetName),
                  subtitle: Text(
                    favorites == 0
                        ? 'nothing bookmarked yet'
                        : favorites == 1
                        ? '1 tune · every bookmarked track'
                        : '$favorites tunes · every bookmarked track',
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (context) =>
                          const SetlistDetailScreen.favorites(),
                    ),
                  ),
                ),
                const Divider(height: 1),
                if (setlists.setlists.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'No setlists of your own yet — the + button makes one, '
                      'and the + beside any downloaded tune fills it.',
                    ),
                  )
                else
                  for (final setlist in setlists.setlists)
                    ListTile(
                      leading: const Icon(Icons.queue_music_outlined),
                      title: Text(setlist.name),
                      subtitle: Text(
                        setlist.entryIds.isEmpty
                            ? 'empty'
                            : setlist.entryIds.length == 1
                            ? '1 tune'
                            : '${setlist.entryIds.length} tunes',
                      ),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (context) =>
                              SetlistDetailScreen(setlistId: setlist.id),
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          IconButton(
                            tooltip: 'Rename setlist',
                            onPressed: () => _NameDialog.show(
                              context,
                              title: 'Rename setlist',
                              confirmLabel: 'Rename',
                              initial: setlist.name,
                              onConfirm: (name) => ref
                                  .read(setlistsProvider.notifier)
                                  .rename(setlist.id, name),
                            ),
                            icon: const Icon(Icons.edit_outlined),
                          ),
                          IconButton(
                            tooltip: 'Delete setlist',
                            onPressed: () =>
                                _confirmDelete(context, ref, setlist),
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ],
                      ),
                    ),
              ],
            ),
    );
  }

  /// The bin asks once, and says what it does not do: the list goes,
  /// the tunes stay.
  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    Setlist setlist,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${setlist.name}"?'),
        content: const Text(
          'The setlist goes; its tunes stay in the library, '
          'exactly as they were.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(setlistsProvider.notifier).delete(setlist.id);
    }
  }
}

/// One setlist, opened: its tunes, each a play (or a fetch) and a way
/// out of the list — never a way out of the library. The default's
/// detail is the same screen with the bookmark as its membership: the
/// bin beside a Favorites tune is the bookmark, taken off.
class SetlistDetailScreen extends ConsumerWidget {
  /// Create the detail for one stored setlist.
  const SetlistDetailScreen({super.key, required this.setlistId})
    : isFavorites = false;

  /// Create the default's detail: every bookmarked track, live.
  const SetlistDetailScreen.favorites({super.key})
    : setlistId = null,
      isFavorites = true;

  /// The setlist's id; null for the derived default.
  final String? setlistId;

  /// Whether this is "Favorites".
  final bool isFavorites;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final setlists = ref.watch(setlistsProvider);
    final phase = ref.watch(libraryProvider);
    final setlist = setlistId == null ? null : setlists.byId(setlistId!);
    final ready = phase is LibraryReady;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          isFavorites ? favoritesSetName : setlist?.name ?? 'Setlist',
        ),
      ),
      body: !isFavorites && setlist == null
          ? const CenteredNote(
              icon: Icons.queue_music_outlined,
              message: 'This setlist is already gone.',
            )
          : !ready
          ? const CenteredNote(
              icon: Icons.library_music,
              message: 'The library went away; go back and reopen it.',
            )
          : _body(context, phase, setlist),
    );
  }

  Widget _body(BuildContext context, LibraryReady phase, Setlist? setlist) {
    if (isFavorites) {
      final members = favoritesOf(phase);
      if (members.isEmpty) {
        return const CenteredNote(
          icon: Icons.bookmark_add_outlined,
          message:
              'Nothing bookmarked yet — the bookmark beside a downloaded '
              'tune puts it here, and keeps it on this device.',
        );
      }
      return ListView(
        children: <Widget>[
          for (final (volume, entry) in members)
            _TuneRow(
              volume: volume,
              entry: entry,
              presence: CachePresence.saved,
              removeTooltip:
                  'Remove from Favorites — back to a session download',
              onRemove: (ref) =>
                  ref.read(libraryProvider.notifier).toggleSaved(volume, entry),
            ),
        ],
      );
    }
    final members = <(LibraryVolume, LibraryEntry)>[];
    for (final id in setlist!.entryIds) {
      for (final volume in phase.manifest.allVolumes) {
        for (final entry in volume.entries) {
          if (entry.id == id) {
            members.add((volume, entry));
          }
        }
      }
    }
    if (members.isEmpty) {
      return const CenteredNote(
        icon: Icons.queue_music_outlined,
        message:
            'This setlist is empty — the + beside a downloaded tune '
            'adds it here.',
      );
    }
    return ListView(
      children: <Widget>[
        for (final (volume, entry) in members)
          _TuneRow(
            volume: volume,
            entry: entry,
            presence: phase.presence[entry.id] ?? CachePresence.absent,
            removeTooltip: 'Remove from this setlist',
            onRemove: (ref) => ref
                .read(setlistsProvider.notifier)
                .removeEntry(setlist.id, entry.id),
          ),
      ],
    );
  }
}

/// One field, one answer: making a setlist and renaming one are the
/// same dialog — the name, the rule check against everything else, and
/// a problem that stays on the field until it is fixed.
class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.title,
    required this.confirmLabel,
    required this.onConfirm,
    this.initial = '',
  });

  /// Shows the dialog; [onConfirm] returns the problem, or null when
  /// the name was taken and the change is done.
  static Future<void> show(
    BuildContext context, {
    required String title,
    required String confirmLabel,
    required Future<String?> Function(String name) onConfirm,
    String initial = '',
  }) => showDialog<void>(
    context: context,
    builder: (context) => _NameDialog(
      title: title,
      confirmLabel: confirmLabel,
      onConfirm: onConfirm,
      initial: initial,
    ),
  );

  final String title;
  final String confirmLabel;
  final Future<String?> Function(String name) onConfirm;
  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initial,
  );
  String? _problem;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    final problem = await widget.onConfirm(_name.text);
    if (!mounted) {
      return;
    }
    if (problem == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _busy = false;
      _problem = problem;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _name,
        enabled: !_busy,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: _busy ? null : (_) => _confirm(),
        decoration: InputDecoration(
          labelText: 'Setlist name',
          errorText: _problem,
          border: const OutlineInputBorder(),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _confirm,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// One tune in a setlist: where it lives, the way into it — the player
/// when it is on this device, the fetch when it is not — and the bin,
/// which takes the tune out of the list and leaves the library alone.
class _TuneRow extends ConsumerWidget {
  const _TuneRow({
    required this.volume,
    required this.entry,
    required this.presence,
    required this.removeTooltip,
    required this.onRemove,
  });

  final LibraryVolume volume;
  final LibraryEntry entry;
  final CachePresence presence;
  final String removeTooltip;
  final void Function(WidgetRef ref) onRemove;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final present = presence != CachePresence.absent;
    final number = volume.volumeNumber?.toString().padLeft(3, '0');
    final where =
        '${number == null ? '' : 'Vol $number · '}${volume.displayName}';
    return ListTile(
      leading: SizedBox(
        width: 34,
        child: Text(
          entry.trackNumber?.toString().padLeft(2, '0') ?? '··',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
      title: Text(
        entry.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        present ? where : '$where · not on this device',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      // A tune on this device is one tap from the player; one that is
      // not goes to its volume, where the download verb lives.
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => present
              ? PlayerScreen(volumeId: volume.id, entryId: entry.id)
              : VolumeScreen(volumeId: volume.id),
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (present)
            IconButton(
              tooltip: 'Play',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) =>
                      PlayerScreen(volumeId: volume.id, entryId: entry.id),
                ),
              ),
              icon: const Icon(Icons.play_arrow, color: Colors.white),
            )
          else
            IconButton(
              tooltip: 'Download to this device',
              onPressed: () => ref
                  .read(libraryProvider.notifier)
                  .download(volume, entry, saved: false),
              icon: const Icon(Icons.download_outlined),
            ),
          IconButton(
            tooltip: removeTooltip,
            onPressed: () => onRemove(ref),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    );
  }
}
