import 'package:bandstand/domain/harmony/key_signature.dart';
import 'package:bandstand/domain/song/playlist.dart';
import 'package:bandstand/domain/song/song_library_model.dart';
import 'package:bandstand/state/library_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Sets, in playing order, with per-entry overrides (§8.2, §9).
class PlaylistsScreen extends ConsumerStatefulWidget {
  const PlaylistsScreen({super.key});

  @override
  ConsumerState<PlaylistsScreen> createState() => _PlaylistsScreenState();
}

class _PlaylistsScreenState extends ConsumerState<PlaylistsScreen> {
  String? _selectedId;

  @override
  Widget build(BuildContext context) {
    final playlists = ref.watch(playlistsProvider);
    final songs = ref.watch(libraryScanProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Sets')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final created = await ref
              .read(libraryControllerProvider)
              .createPlaylist();
          if (mounted) {
            setState(() => _selectedId = created.id);
          }
        },
        icon: const Icon(Icons.add),
        label: const Text('New set'),
      ),
      body: playlists.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('$error')),
        data: (all) {
          if (all.isEmpty) {
            return const Center(
              child: Text('No sets yet. Start one with the button below.'),
            );
          }
          final selected = all.firstWhere(
            (playlist) => playlist.id == _selectedId,
            orElse: () => all.first,
          );
          return LayoutBuilder(
            builder: (context, constraints) {
              final list = _PlaylistList(
                playlists: all,
                selectedId: selected.id,
                onSelect: (id) => setState(() => _selectedId = id),
              );
              final detail = _PlaylistDetail(
                playlist: selected,
                summaries: songs.value?.songs ?? const <SongSummary>[],
              );
              if (constraints.maxWidth < 720) {
                return Column(
                  children: <Widget>[
                    SizedBox(height: 96, child: list),
                    const Divider(height: 1),
                    Expanded(child: detail),
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  SizedBox(width: 280, child: list),
                  const VerticalDivider(width: 1),
                  Expanded(child: detail),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class _PlaylistList extends StatelessWidget {
  const _PlaylistList({
    required this.playlists,
    required this.selectedId,
    required this.onSelect,
  });

  final List<Playlist> playlists;
  final String selectedId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: <Widget>[
        for (final playlist in playlists)
          ListTile(
            selected: playlist.id == selectedId,
            title: Text(playlist.name),
            subtitle: Text(
              '${playlist.length} song${playlist.length == 1 ? '' : 's'}',
            ),
            onTap: () => onSelect(playlist.id),
          ),
      ],
    );
  }
}

class _PlaylistDetail extends ConsumerWidget {
  const _PlaylistDetail({required this.playlist, required this.summaries});

  final Playlist playlist;
  final List<SongSummary> summaries;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(libraryControllerProvider);
    final byId = <String, SongSummary>{
      for (final summary in summaries) summary.id: summary,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  playlist.name,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              IconButton(
                tooltip: 'Rename',
                onPressed: () => _rename(context, ref, playlist),
                icon: const Icon(Icons.edit_outlined),
              ),
              IconButton(
                tooltip: 'Delete this set',
                onPressed: () => _confirmDelete(context, ref, playlist),
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: <Widget>[
              FilledButton.tonalIcon(
                onPressed: summaries.isEmpty
                    ? null
                    : () => _addSong(context, ref, playlist, summaries),
                icon: const Icon(Icons.playlist_add),
                label: const Text('Add song'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: playlist.isEmpty
              ? const Center(child: Text('This set is empty.'))
              : ReorderableListView.builder(
                  buildDefaultDragHandles: true,
                  itemCount: playlist.entries.length,
                  onReorderItem: (from, to) => controller.savePlaylist(
                    playlist.withEntryMoved(from, to),
                  ),
                  itemBuilder: (context, index) {
                    final entry = playlist.entries[index];
                    return _EntryRow(
                      // The entry instance is stable across a reorder —
                      // withEntryMoved preserves the objects, so an identity
                      // key keeps rows attached to their song. A songId-based
                      // key would also collide when a set lists a song twice.
                      key: ObjectKey(entry),
                      index: index,
                      entry: entry,
                      summary: byId[entry.songId],
                      playlist: playlist,
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    Playlist playlist,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete set "${playlist.name}"?'),
        content: const Text(
          'The set is removed. Its songs stay in the library — deleting a '
          'set never deletes music.',
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
    if (confirmed ?? false) {
      await ref.read(libraryControllerProvider).deletePlaylist(playlist.id);
    }
  }

  Future<void> _rename(
    BuildContext context,
    WidgetRef ref,
    Playlist playlist,
  ) async {
    final controller = TextEditingController(text: playlist.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename set'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name != null && name.trim().isNotEmpty) {
      await ref
          .read(libraryControllerProvider)
          .savePlaylist(playlist.renamed(name.trim()));
    }
  }

  Future<void> _addSong(
    BuildContext context,
    WidgetRef ref,
    Playlist playlist,
    List<SongSummary> songs,
  ) async {
    final chosen = await showDialog<SongSummary>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Add a song'),
        children: <Widget>[
          for (final song in songs)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(song),
              child: Text('${song.title}  ·  ${song.keyName}'),
            ),
        ],
      ),
    );
    if (chosen != null) {
      await ref
          .read(libraryControllerProvider)
          .savePlaylist(
            playlist.withEntryAppended(PlaylistEntry(songId: chosen.id)),
          );
    }
  }
}

class _EntryRow extends ConsumerWidget {
  const _EntryRow({
    required this.index,
    required this.entry,
    required this.summary,
    required this.playlist,
    super.key,
  });

  final int index;
  final PlaylistEntry entry;
  final SongSummary? summary;
  final Playlist playlist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(libraryControllerProvider);
    final theme = Theme.of(context);
    final overrides = <String>[
      if (entry.tempoOverride != null) '${entry.tempoOverride} bpm',
      if (entry.keyOverride != null) 'in ${entry.keyOverride}',
      if (entry.transposeOverride != null)
        '${entry.transposeOverride! > 0 ? '+' : ''}${entry.transposeOverride}',
      if (entry.chorusCount != null) '×${entry.chorusCount}',
    ];

    return ListTile(
      leading: CircleAvatar(
        radius: 14,
        child: Text('${index + 1}', style: theme.textTheme.labelSmall),
      ),
      title: Text(summary?.title ?? 'Missing song (${entry.songId})'),
      subtitle: Text(
        <String>[
          if (summary != null) '${summary!.keyName}  ${summary!.tempo} bpm',
          if (overrides.isNotEmpty) 'set: ${overrides.join('  ')}',
          if (entry.note.isNotEmpty) entry.note,
        ].join('  ·  '),
        style: summary == null
            ? TextStyle(color: theme.colorScheme.error)
            : null,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          IconButton(
            tooltip: 'Set overrides',
            onPressed: () => _editOverrides(context, ref),
            icon: const Icon(Icons.tune),
          ),
          IconButton(
            tooltip: 'Remove from set',
            onPressed: () =>
                controller.savePlaylist(playlist.withEntryRemoved(index)),
            icon: const Icon(Icons.remove_circle_outline),
          ),
        ],
      ),
    );
  }

  Future<void> _editOverrides(BuildContext context, WidgetRef ref) async {
    final updated = await showDialog<PlaylistEntry>(
      context: context,
      builder: (context) => _OverridesDialog(entry: entry),
    );
    if (updated != null) {
      await ref
          .read(libraryControllerProvider)
          .savePlaylist(playlist.withEntryReplaced(index, updated));
    }
  }
}

class _OverridesDialog extends StatefulWidget {
  const _OverridesDialog({required this.entry});

  final PlaylistEntry entry;

  @override
  State<_OverridesDialog> createState() => _OverridesDialogState();
}

class _OverridesDialogState extends State<_OverridesDialog> {
  late int? _tempo = widget.entry.tempoOverride;
  late String? _key = widget.entry.keyOverride?.toString();
  late int? _choruses = widget.entry.chorusCount;
  late final TextEditingController _note = TextEditingController(
    text: widget.entry.note,
  );

  static const List<String> _keys = <String>[
    'C', 'Db', 'D', 'Eb', 'E', 'F', 'Gb', 'G', 'Ab', 'A', 'Bb', 'B', //
    'Cm', 'C#m', 'Dm', 'Ebm', 'Em', 'Fm', 'F#m', 'Gm', 'G#m', 'Am', 'Bbm', 'Bm',
  ];

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Overrides for this set'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text(
              'These apply to this set only. The song in the library is never '
              'changed.',
            ),
            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                Expanded(
                  child: Slider(
                    value: (_tempo ?? 120).toDouble(),
                    min: 40,
                    max: 320,
                    onChanged: (value) =>
                        setState(() => _tempo = value.round()),
                  ),
                ),
                SizedBox(
                  width: 96,
                  child: Text(_tempo == null ? 'song tempo' : '$_tempo bpm'),
                ),
                IconButton(
                  tooltip: 'Use the song tempo',
                  onPressed: () => setState(() => _tempo = null),
                  icon: const Icon(Icons.clear),
                ),
              ],
            ),
            DropdownButtonFormField<String?>(
              initialValue: _key,
              decoration: const InputDecoration(labelText: 'Key for this set'),
              items: <DropdownMenuItem<String?>>[
                const DropdownMenuItem<String?>(child: Text('Written key')),
                for (final key in _keys)
                  DropdownMenuItem<String?>(value: key, child: Text(key)),
              ],
              onChanged: (value) => setState(() => _key = value),
            ),
            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                const Text('Choruses'),
                const SizedBox(width: 16),
                Expanded(
                  child: Slider(
                    value: (_choruses ?? 1).toDouble(),
                    min: 1,
                    max: 12,
                    divisions: 11,
                    label: '${_choruses ?? 1}',
                    onChanged: (value) =>
                        setState(() => _choruses = value.round()),
                  ),
                ),
                SizedBox(
                  width: 40,
                  child: Text(_choruses == null ? '—' : '$_choruses'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _note,
              decoration: const InputDecoration(
                labelText: 'Note for the stand',
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            widget.entry.copyWith(
              tempoOverride: _tempo,
              clearTempo: _tempo == null,
              keyOverride: _key == null ? null : KeySignature.parse(_key!),
              clearKey: _key == null,
              chorusCount: _choruses,
              clearChoruses: _choruses == null || _choruses == 1,
              note: _note.text,
            ),
          ),
          child: const Text('Apply'),
        ),
      ],
    );
  }
}
