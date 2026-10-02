import 'package:bandstand/diagnostics/startup_report.dart';
import 'package:bandstand/domain/song/song_library_model.dart';
import 'package:bandstand/io/song_library.dart';
import 'package:bandstand/state/library_state.dart';
import 'package:bandstand/ui/screens/song_details_screen.dart';
import 'package:bandstand/ui/theme/bandstand_theme.dart';
import 'package:bandstand/ui/widgets/bank_download_banner.dart';
import 'package:bandstand/ui/widgets/import_dialog.dart';
import 'package:bandstand/ui/widgets/recovery_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The screen you use most (§8.2): search, filter, sort, open.
class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scan = ref.watch(libraryScanProvider);
    final view = ref.watch(libraryViewProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Library'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Import from iReal Pro',
            onPressed: () => ImportDialog.show(context),
            icon: const Icon(Icons.download_outlined),
          ),
          IconButton(
            tooltip: 'Rescan the library folder',
            onPressed: () => ref.invalidate(libraryScanProvider),
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _createSong(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('New song'),
      ),
      body: scan.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => LibraryErrorView(message: '$error'),
        data: (result) => _LibraryList(scan: result, view: view),
      ),
    );
  }

  Future<void> _createSong(BuildContext context, WidgetRef ref) async {
    final song = await ref.read(libraryControllerProvider).createSong();
    if (!context.mounted) {
      return;
    }
    ref.read(songEditorProvider.notifier).open(song);
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const SongDetailsScreen()));
  }
}

/// Shown when the library folder itself cannot be opened.
///
/// §5.4: never silently show an empty library. "There is nowhere to keep
/// anything" and "there is nothing here yet" look identical if this is a blank
/// list, and they need completely different responses from the user.
class LibraryErrorView extends StatelessWidget {
  /// Create the error view.
  const LibraryErrorView({required this.message, super.key});

  /// What went wrong, as the exception described it.

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.folder_off_outlined, size: 48, color: scheme.error),
            const SizedBox(height: 16),
            Text(
              'The library folder could not be opened.',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _LibraryList extends ConsumerWidget {
  const _LibraryList({required this.scan, required this.view});

  final LibraryScan scan;
  final LibraryView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // §3's cold-start budget ends here: the library is visible once this frame
    // has actually been painted, not when `build` returns. Does nothing unless
    // the environment asks for a report.
    if (StartupReport.wanted) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => StartupReport.libraryVisible(),
      );
    }

    final songs = view.apply(scan.songs);
    final tags = <String>{for (final song in scan.songs) ...song.tags}.toList()
      ..sort();

    return Column(
      children: <Widget>[
        _SearchBar(view: view),
        const RecoveryBanner(),
        const BankDownloadBanner(),
        if (tags.isNotEmpty) _TagFilter(tags: tags, selected: view.tag),
        if (scan.failures.isNotEmpty) _FailureBanner(failures: scan.failures),
        Expanded(
          child: songs.isEmpty
              ? _EmptyLibrary(
                  filtered: view.isFiltered,
                  total: scan.songs.length,
                )
              : ListView.separated(
                  itemCount: songs.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) =>
                      _SongRow(summary: songs[index]),
                ),
        ),
        _LibraryFooter(shown: songs.length, total: scan.songs.length),
      ],
    );
  }
}

class _SearchBar extends ConsumerStatefulWidget {
  const _SearchBar({required this.view});

  final LibraryView view;

  @override
  ConsumerState<_SearchBar> createState() => _SearchBarState();
}

class _SearchBarState extends ConsumerState<_SearchBar> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.view.query,
  );

  @override
  void didUpdateWidget(_SearchBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Clearing the search from elsewhere (the "show all" chip after a dead-end
    // search) changes the query under the field; keep the two in step without
    // fighting the user's cursor while they type.
    if (widget.view.query != _controller.text) {
      _controller.value = TextEditingValue(
        text: widget.view.query,
        selection: TextSelection.collapsed(offset: widget.view.query.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.read(libraryViewProvider.notifier);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: TextField(
              controller: _controller,
              onChanged: controller.search,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search title, composer, tag',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: widget.view.query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        tooltip: 'Clear',
                        onPressed: () {
                          _controller.clear();
                          controller.search('');
                        },
                      ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          DropdownButton<SongSortOrder>(
            value: widget.view.sortOrder,
            underline: const SizedBox.shrink(),
            onChanged: (order) {
              if (order != null) {
                controller.sortBy(order);
              }
            },
            items: <DropdownMenuItem<SongSortOrder>>[
              for (final order in SongSortOrder.values)
                DropdownMenuItem<SongSortOrder>(
                  value: order,
                  child: Text(order.label),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TagFilter extends ConsumerWidget {
  const _TagFilter({required this.tags, required this.selected});

  final List<String> tags;
  final String? selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(libraryViewProvider.notifier);
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: <Widget>[
          for (final tag in tags)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text(tag),
                selected: selected == tag,
                onSelected: (isSelected) =>
                    controller.filterByTag(isSelected ? tag : null),
              ),
            ),
        ],
      ),
    );
  }
}

class _FailureBanner extends StatelessWidget {
  const _FailureBanner({required this.failures});

  final List<LoadFailure> failures;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final recovered = failures.where((f) => f.recovered).length;
    final lost = failures.length - recovered;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: lost > 0 ? scheme.errorContainer : scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            lost > 0
                ? '$lost song${lost == 1 ? '' : 's'} could not be read'
                : '$recovered song${recovered == 1 ? '' : 's'} recovered from '
                      'a backup',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: lost > 0
                  ? scheme.onErrorContainer
                  : scheme.onTertiaryContainer,
            ),
          ),
          const SizedBox(height: 4),
          for (final failure in failures.take(5))
            Text(
              '$failure',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: lost > 0
                    ? scheme.onErrorContainer
                    : scheme.onTertiaryContainer,
              ),
            ),
        ],
      ),
    );
  }
}

class _SongRow extends ConsumerWidget {
  const _SongRow({required this.summary});

  final SongSummary summary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return ListTile(
      title: Text(summary.title, style: theme.textTheme.titleMedium),
      subtitle: Text(
        <String>[
          if (summary.composer.isNotEmpty) summary.composer,
          '${summary.barCount} bars',
          summary.keyName,
          '${summary.tempo} bpm',
        ].join('  ·  '),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final tag in summary.tags.take(3))
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Chip(
                label: Text(tag),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
              ),
            ),
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (action) => _act(context, ref, action),
            itemBuilder: (context) => const <PopupMenuEntry<String>>[
              PopupMenuItem<String>(
                value: 'duplicate',
                child: Text('Duplicate'),
              ),
              PopupMenuItem<String>(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
      onTap: () => _open(context, ref),
    );
  }

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    final song = await ref.read(libraryControllerProvider).load(summary.id);
    if (!context.mounted) {
      return;
    }
    ref.read(songEditorProvider.notifier).open(song);
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const SongDetailsScreen()));
  }

  Future<void> _act(BuildContext context, WidgetRef ref, String action) async {
    final controller = ref.read(libraryControllerProvider);
    switch (action) {
      case 'duplicate':
        await controller.duplicate(summary.id);
      case 'delete':
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Delete "${summary.title}"?'),
            content: const Text(
              'The song is removed from the library. Its backups are kept, so '
              'this is recoverable.',
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
          await controller.delete(summary.id);
        }
    }
  }
}

class _EmptyLibrary extends ConsumerWidget {
  const _EmptyLibrary({required this.filtered, required this.total});

  final bool filtered;
  final int total;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              filtered ? Icons.search_off : Icons.library_music_outlined,
              size: 48,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              filtered
                  ? 'Nothing here matches.'
                  : 'The library is empty. Start a tune with the button below.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (filtered) ...<Widget>[
              const SizedBox(height: 12),
              TextButton(
                onPressed: () =>
                    ref.read(libraryViewProvider.notifier).clearFilters(),
                child: Text('Show all $total'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LibraryFooter extends StatelessWidget {
  const _LibraryFooter({required this.shown, required this.total});

  final int shown;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Text(
        shown == total ? '$total songs' : '$shown of $total songs',
        style: theme.textTheme.bodySmall
            ?.merge(BandstandTheme.numeric)
            .copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }
}
