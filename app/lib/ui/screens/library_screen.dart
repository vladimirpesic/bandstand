import 'dart:io';

import 'package:bandstand/io/library/manifest.dart';
import 'package:bandstand/io/library/mirror_cache.dart';
import 'package:bandstand/state/library.dart';
import 'package:bandstand/ui/screens/library_search_screen.dart';
import 'package:bandstand/ui/screens/player_screen.dart';
import 'package:bandstand/ui/screens/reader_screen.dart';
import 'package:bandstand/ui/widgets/centered_note.dart';
import 'package:bandstand/ui/widgets/volume_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The library: the folder tree, the mirrored cache, one screen
/// per phase, and the volume screen each of them opens onto — the player
/// for a track, the reader for the book (ADR 0012).
class LibraryScreen extends ConsumerWidget {
  /// Create the screen.
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phase = ref.watch(libraryProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: <Widget>[
          switch (phase) {
            LibraryReady() => const _AppBarActions(),
            _ => const SizedBox.shrink(),
          },
        ],
      ),
      body: switch (phase) {
        LibraryStarting() => const CenteredNote(
          icon: Icons.library_music,
          message: 'Opening the library…',
        ),
        LibraryNeedsLink() => _LinkCard(phase: phase),
        LibraryLoading() => const CenteredNote(
          icon: Icons.cloud_download,
          message: 'Reading the library from MEGA…',
        ),
        LibraryReady() => _VolumesList(phase: phase),
        LibraryError() => _ErrorCard(phase: phase),
      },
    );
  }
}

class _AppBarActions extends ConsumerWidget {
  const _AppBarActions();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phase = ref.watch(libraryProvider) as LibraryReady;
    return Row(
      children: <Widget>[
        if (phase.syncing)
          const Padding(
            padding: EdgeInsets.only(right: 12),
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        IconButton(
          tooltip: 'Search the library',
          onPressed: () =>
              showSearch(context: context, delegate: LibrarySearchScreen()),
          icon: const Icon(Icons.search),
        ),
        IconButton(
          tooltip: 'Sync with MEGA',
          onPressed: phase.syncing
              ? null
              : () => ref.read(libraryProvider.notifier).refresh(),
          icon: const Icon(Icons.sync),
        ),
        IconButton(
          tooltip: 'Library settings',
          onPressed: () => _openSettingsDialog(context, ref),
          icon: const Icon(Icons.settings_outlined),
        ),
      ],
    );
  }
}

Future<void> _openSettingsDialog(BuildContext context, WidgetRef ref) async {
  await showDialog<void>(
    context: context,
    builder: (context) => const _LibrarySettingsDialog(),
  );
}

/// First run — or a link that stopped working. One paste, one button:
/// the public folder link is the whole credential (§7 of the rule).
class _LinkCard extends ConsumerStatefulWidget {
  const _LinkCard({required this.phase});

  final LibraryNeedsLink phase;

  @override
  ConsumerState<_LinkCard> createState() => _LinkCardState();
}

class _LinkCardState extends ConsumerState<_LinkCard> {
  final TextEditingController _link = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  Future<void> _use() async {
    setState(() => _busy = true);
    await ref.read(libraryProvider.notifier).linkLibrary(_link.text);
    if (mounted) {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 520),
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                'Connect the library folder',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                'In MEGA, open the jamey_aebersold folder menu and choose '
                '"Get link", then paste the link here. Bandstand reads that '
                'one folder — nothing else — and keeps the link on this '
                'device only.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 4),
              Text(
                'The link works until you revoke it in MEGA; it is never '
                'shown on this screen again.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _link,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: 'MEGA folder link',
                  border: OutlineInputBorder(),
                  helperText: 'Looks like https://mega.nz/folder/…#…',
                ),
                onSubmitted: _busy ? null : (_) => _use(),
              ),
              if (widget.phase.problem.isNotEmpty) ...<Widget>[
                const SizedBox(height: 16),
                Text(
                  widget.phase.problem,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _busy ? null : _use,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.link),
                label: const Text('Use this folder'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The library's front matter and the volumes: the root files pinned above
/// the volume tiles, one tile each, with what is on this device under it.
class _VolumesList extends ConsumerWidget {
  const _VolumesList({required this.phase});

  final LibraryReady phase;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manifest = phase.manifest;
    // The root files first, then the divider, then the volumes — a list
    // that opens on the tuning notes and the handbook before any volume.
    final rootCount = manifest.rootFiles.length;
    final itemCount =
        rootCount + manifest.volumes.length + (rootCount > 0 ? 1 : 0);
    return Column(
      children: <Widget>[
        if (phase.notice.isNotEmpty)
          Material(
            color: Theme.of(context).colorScheme.secondaryContainer,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.info_outline, size: 18),
                  const SizedBox(width: 8),
                  Expanded(child: Text(phase.notice)),
                ],
              ),
            ),
          ),
        Expanded(
          child: ListView.builder(
            itemCount: itemCount,
            itemBuilder: (context, index) {
              if (index < rootCount) {
                final entry = manifest.rootFiles[index];
                return _EntryRow(
                  volume: manifest.rootVolume,
                  entry: entry,
                  defaultSaved: entry.kind == LibraryEntryKind.book,
                );
              }
              final volumeIndex = index - rootCount;
              if (rootCount > 0 && volumeIndex == 0) {
                return const Divider(height: 1);
              }
              final volume =
                  manifest.volumes[volumeIndex - (rootCount > 0 ? 1 : 0)];
              return VolumeTile(
                phase: phase,
                volume: volume,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (context) => VolumeScreen(volumeId: volume.id),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// What the library cannot do right now, and the way out — retry, or back
/// to sign-in. The cached manifest, when there is one, stays browsable
/// above the message.
class _ErrorCard extends ConsumerWidget {
  const _ErrorCard({required this.phase});

  final LibraryError phase;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.cloud_off,
              size: 56,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(phase.message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: () => ref.read(libraryProvider.notifier).reload(),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try again'),
                ),
                if (phase.lastManifest == null)
                  OutlinedButton.icon(
                    onPressed: () =>
                        ref.read(libraryProvider.notifier).forgetLink(),
                    icon: const Icon(Icons.link_off),
                    label: const Text('Paste the link again'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One volume: its book, its tracks, and every download state between. The
/// library's own verbs — fetch, keep, remove — are all here; the player and
/// the reader open from the rows.
class VolumeScreen extends ConsumerWidget {
  /// Create the screen for the volume with this node handle.
  const VolumeScreen({super.key, required this.volumeId});

  final String volumeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phase = ref.watch(libraryProvider);
    if (phase is! LibraryReady) {
      return Scaffold(
        appBar: AppBar(),
        body: const CenteredNote(
          icon: Icons.library_music,
          message: 'The library went away; go back and reopen it.',
        ),
      );
    }
    LibraryVolume? volume;
    for (final candidate in phase.manifest.volumes) {
      if (candidate.id == volumeId) {
        volume = candidate;
        break;
      }
    }
    if (volume == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const CenteredNote(
          icon: Icons.library_music,
          message: 'This volume left the library in the last sync.',
        ),
      );
    }
    final localVolume = volume;
    final totalBytes = volume.entries.fold<int>(
      0,
      (sum, entry) => sum + entry.sizeBytes,
    );
    return Scaffold(
      appBar: AppBar(title: Text(volume.displayName)),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '${localVolume.tracks.length} tracks'
                    '${localVolume.book == null ? '' : ' · 1 book'} · '
                    '${LibraryController.describeBytes(totalBytes)} '
                    'in total',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                TextButton.icon(
                  onPressed: () => ref
                      .read(libraryProvider.notifier)
                      .downloadVolume(localVolume, saved: false),
                  icon: const Icon(Icons.download),
                  label: const Text('Download all'),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              children: <Widget>[
                if (localVolume.book != null)
                  _EntryRow(
                    volume: localVolume,
                    entry: localVolume.book!,
                    defaultSaved: true,
                  ),
                for (final entry in localVolume.tracks)
                  _EntryRow(
                    volume: localVolume,
                    entry: entry,
                    defaultSaved: false,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One book or track row: name, size, and the trailing cluster its local
/// state asks for.
class _EntryRow extends ConsumerWidget {
  const _EntryRow({
    required this.volume,
    required this.entry,
    required this.defaultSaved,
  });

  final LibraryVolume volume;
  final LibraryEntry entry;
  final bool defaultSaved;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phase = ref.watch(libraryProvider);
    final download = phase is LibraryReady ? phase.downloads[entry.id] : null;
    final presence = phase is LibraryReady
        ? phase.presence[entry.id] ?? CachePresence.absent
        : CachePresence.absent;
    final controller = ref.read(libraryProvider.notifier);
    final isBook = entry.kind == LibraryEntryKind.book;

    // A present entry is one tap from its screen — the player for a
    // track, the reader for the book; an absent one has nothing to open.
    // The trailing play button lands on the same place.
    void open() {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => isBook
              ? ReaderScreen(volumeId: volume.id)
              : PlayerScreen(volumeId: volume.id, entryId: entry.id),
        ),
      );
    }

    Widget title = Text(
      entry.displayName,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    if (download is DownloadFailed) {
      title = Tooltip(
        message: download.message,
        child: Row(
          children: <Widget>[
            Flexible(child: title),
            const SizedBox(width: 6),
            Icon(
              Icons.error_outline,
              size: 16,
              color: Theme.of(context).colorScheme.error,
            ),
          ],
        ),
      );
    }

    final Widget trailing;
    if (download is Downloading) {
      final total = download.total;
      final value = total != null && total > 0
          ? download.received / total
          : null;
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            width: 72,
            child: LinearProgressIndicator(value: value, minHeight: 4),
          ),
          IconButton(
            tooltip: 'Stop the download',
            onPressed: () => controller.cancelDownload(entry.id),
            icon: const Icon(Icons.close),
          ),
        ],
      );
    } else if (download is DownloadFailed) {
      trailing = IconButton(
        tooltip: 'Try again — ${download.message}',
        onPressed: () =>
            controller.download(volume, entry, saved: defaultSaved),
        icon: const Icon(Icons.refresh),
      );
    } else {
      switch (presence) {
        case CachePresence.absent:
          trailing = IconButton(
            tooltip: 'Download to this device',
            onPressed: () =>
                controller.download(volume, entry, saved: defaultSaved),
            icon: const Icon(Icons.download_outlined),
          );
        case CachePresence.session:
          trailing = Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              IconButton(
                tooltip: 'Play — here until the app closes, unless kept',
                onPressed: open,
                icon: const Icon(Icons.play_arrow, color: Colors.white),
              ),
              IconButton(
                tooltip: 'Keep on this device',
                onPressed: () => controller.toggleSaved(volume, entry),
                icon: const Icon(Icons.bookmark_add_outlined),
              ),
              IconButton(
                tooltip: 'Remove from this device',
                onPressed: () => controller.remove(volume, entry),
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          );
        case CachePresence.saved:
          trailing = Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              IconButton(
                tooltip: 'Play',
                onPressed: open,
                icon: const Icon(Icons.play_arrow, color: Colors.white),
              ),
              IconButton(
                tooltip: 'Kept on this device — make it a session download',
                onPressed: () => controller.toggleSaved(volume, entry),
                icon: const Icon(Icons.bookmark),
              ),
              IconButton(
                tooltip: 'Remove from this device',
                onPressed: () => controller.remove(volume, entry),
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          );
      }
    }

    return ListTile(
      leading: isBook
          ? const Icon(Icons.menu_book_outlined)
          : SizedBox(
              width: 34,
              child: Text(
                entry.trackNumber?.toString().padLeft(2, '0') ?? '··',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
      title: title,
      subtitle: Text(LibraryController.describeBytes(entry.sizeBytes)),
      trailing: trailing,
      onTap: presence == CachePresence.absent ? null : open,
    );
  }
}

/// The library's own knobs: where the mirror lives (desktop), the sweep of
/// orphaned files, and the way out of the Google account.
class _LibrarySettingsDialog extends ConsumerStatefulWidget {
  const _LibrarySettingsDialog();

  @override
  ConsumerState<_LibrarySettingsDialog> createState() =>
      _LibrarySettingsDialogState();
}

class _LibrarySettingsDialogState
    extends ConsumerState<_LibrarySettingsDialog> {
  String? _message;

  void _say(String message) {
    if (mounted) {
      setState(() => _message = message);
    }
  }

  /// The `Move` verb's honest half: a walk through the real folder tree,
  /// because a path nobody wants to type by hand is a path nobody moves
  /// to. The chosen folder must already exist; nothing is copied.
  Future<void> _move() async {
    final controller = ref.read(libraryProvider.notifier);
    final picked = await showDialog<String>(
      context: context,
      builder: (context) => _FolderPickerDialog(
        start: Directory(controller.cacheRootDescription()),
      ),
    );
    if (picked == null) {
      return;
    }
    final problem = await controller.applyCacheRootOverride(picked);
    _say(
      problem ??
          'The library now lives at '
              '${ref.read(libraryProvider.notifier).cacheRootDescription()}',
    );
  }

  /// The sweep explains itself first: what is sitting on disk that the
  /// library no longer claims, how much of it there is, and only then the
  /// delete (§5 — never at startup, and never unannounced).
  Future<void> _sweep() async {
    final controller = ref.read(libraryProvider.notifier);
    final leftovers = await controller.findOrphans();
    if (!mounted) {
      return;
    }
    if (leftovers.isEmpty) {
      _say('No leftover files — nothing to sweep.');
      return;
    }
    final bytes = leftovers.fold<int>(
      0,
      (sum, orphan) => sum + orphan.sizeBytes,
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sweep leftover files?'),
        content: Text(
          '${leftovers.length == 1 ? 'One leftover file' : '${leftovers.length} leftover files'} '
          '(${LibraryController.describeBytes(bytes)}) — copies on disk the '
          'library no longer claims, from volumes removed or renamed on the '
          'MEGA side. Safe to delete; everything the library still uses is '
          'untouched, and anything missing downloads again on demand.',
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
    if (confirmed != true) {
      return;
    }
    final deleted = await controller.sweepOrphans();
    _say(
      deleted == 0
          ? 'Nothing to sweep.'
          : 'Removed ${deleted == 1 ? '1 file' : '$deleted files'}.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final phase = ref.watch(libraryProvider);
    final stats = phase is LibraryReady ? phase.stats : null;
    final onDesktop = !Platform.isAndroid;
    final labelStyle = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return AlertDialog(
      title: const Text('Library settings'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (stats != null) ...<Widget>[
              Text('On this device', style: labelStyle),
              Text(
                '${stats.totalCount == 1 ? '1 file' : '${stats.totalCount} files'} '
                '· ${LibraryController.describeBytes(stats.totalBytes)} on disk',
              ),
              Text(
                '${stats.savedCount} kept '
                '(${LibraryController.describeBytes(stats.savedBytes)}) · '
                '${stats.sessionCount} session '
                '(${LibraryController.describeBytes(stats.sessionBytes)})',
              ),
              const SizedBox(height: 16),
            ],
            Text('Where the library lives', style: labelStyle),
            SelectableText(
              ref.read(libraryProvider.notifier).cacheRootDescription(),
            ),
            const SizedBox(height: 4),
            if (onDesktop)
              Text(
                '• The old folder is left as it was.\n'
                '• The new one starts empty — files download again on demand.',
                style: labelStyle,
              )
            else
              Text(
                "On this device the library lives in the app's own storage — "
                'there is nothing to choose.',
                style: labelStyle,
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: <Widget>[
                if (onDesktop)
                  FilledButton(onPressed: _move, child: const Text('Move…')),
                OutlinedButton(
                  onPressed: _sweep,
                  child: const Text('Sweep leftover files'),
                ),
              ],
            ),
            if (_message != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(_message!),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        TextButton(
          onPressed: () async {
            await ref.read(libraryProvider.notifier).forgetLink();
            if (context.mounted) {
              Navigator.of(context).pop();
            }
          },
          child: const Text('Forget folder link'),
        ),
      ],
    );
  }
}

/// A small, real folder browser for the `Move…` verb: walk up and down the
/// actual directory tree and pick a folder that already exists. The
/// platform pickers live behind plugins this app does not carry, and its
/// needs are modest — a list, an up button, a choice.
class _FolderPickerDialog extends StatefulWidget {
  /// Create the picker, opening it at [start].
  const _FolderPickerDialog({required this.start});

  /// The folder the walk begins in — usually where the library lives now.
  final Directory start;

  @override
  State<_FolderPickerDialog> createState() => _FolderPickerDialogState();
}

class _FolderPickerDialogState extends State<_FolderPickerDialog> {
  late Directory _current;
  List<Directory> _inside = const <Directory>[];
  String? _problem;

  @override
  void initState() {
    super.initState();
    _current = widget.start;
    _read();
  }

  void _read() {
    setState(() {
      _problem = null;
      try {
        _inside =
            _current
                .listSync(followLinks: false)
                .whereType<Directory>()
                .toList()
              ..sort((a, b) => a.path.compareTo(b.path));
      } on FileSystemException catch (error) {
        _inside = const <Directory>[];
        _problem =
            'This folder cannot be read: '
            '${error.osError?.message ?? error.message}';
      }
    });
  }

  void _enter(Directory folder) {
    _current = folder;
    _read();
  }

  /// There is no parent above the filesystem root.
  bool get _canGoUp => _current.parent.path != _current.path;

  String _name(Directory folder) =>
      folder.path.split(Platform.pathSeparator).last;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Choose a folder'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SelectableText(
              _current.path,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 320,
              child: _problem != null
                  ? Center(child: Text(_problem!))
                  : ListView(
                      children: <Widget>[
                        if (_canGoUp)
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.arrow_upward),
                            title: const Text('Up one level'),
                            onTap: () => _enter(_current.parent),
                          ),
                        if (_inside.isEmpty)
                          const ListTile(
                            dense: true,
                            enabled: false,
                            leading: Icon(Icons.folder_off_outlined),
                            title: Text('No folders inside.'),
                          ),
                        for (final folder in _inside)
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.folder_outlined),
                            title: Text(_name(folder)),
                            onTap: () => _enter(folder),
                          ),
                      ],
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
          onPressed: _problem == null
              ? () => Navigator.of(context).pop(_current.path)
              : null,
          child: const Text('Choose this folder'),
        ),
      ],
    );
  }
}
