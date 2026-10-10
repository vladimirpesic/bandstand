import 'dart:async';

import 'package:bandstand/io/library/manifest.dart';
import 'package:bandstand/io/library/mirror_cache.dart';
import 'package:bandstand/state/library.dart';
import 'package:bandstand/state/player.dart';
import 'package:bandstand/ui/widgets/centered_note.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// The volume's book, open for reading while the player runs underneath
/// (ADR 0012, milestone 4).
///
/// The reader is a viewer over the cached `book.pdf` and nothing more: the
/// same download/keep/discard handling as every other entry, raster work in
/// pdfium off the UI thread, and deliberately no interaction with the audio
/// path — the only thing this screen does with [playerProvider] is *watch*
/// whether a track is playing, because that is what decides the wakelock.
/// The manifest, not the constructor arguments, is the truth here as
/// everywhere: a volume that leaves the library in a sync lands as a note,
/// not a crash.
class ReaderScreen extends ConsumerStatefulWidget {
  /// Create the screen for the volume whose book is to be read.
  const ReaderScreen({super.key, required this.volumeId});

  /// The volume the book belongs to.
  final String volumeId;

  @override
  ConsumerState<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends ConsumerState<ReaderScreen> {
  final PdfViewerController _viewer = PdfViewerController();

  /// The page the viewer has settled on; null until it has one.
  int? _pageNumber;

  /// The book's length; null until the document is open.
  int? _pageCount;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _applyWakelock(ref.read(playerProvider).isPlaying),
    );
  }

  @override
  void dispose() {
    // Leaving the reader must not keep the screen awake; if the player
    // screen is still underneath, its own listener has the say from here.
    unawaited(WakelockPlus.disable());
    super.dispose();
  }

  /// Reading a page while the track runs is exactly the moment the screen
  /// must not sleep — the same rule the player screen already applies.
  void _applyWakelock(bool playing) {
    unawaited(WakelockPlus.toggle(enable: playing));
  }

  LibraryVolume? _resolveVolume(LibraryReady phase) {
    final manifest = phase.manifest;
    // The library's own book resolves through the root, like its tracks
    // through the player.
    if (manifest.rootFiles.isNotEmpty && manifest.rootId == widget.volumeId) {
      return manifest.rootVolume;
    }
    for (final volume in manifest.volumes) {
      if (volume.id == widget.volumeId) {
        return volume;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(playerProvider, (_, next) => _applyWakelock(next.isPlaying));

    final phase = ref.watch(libraryProvider);
    final volume = phase is LibraryReady ? _resolveVolume(phase) : null;
    final book = volume?.book;
    final presence = phase is LibraryReady && book != null
        ? phase.presence[book.id] ?? CachePresence.absent
        : CachePresence.absent;

    final Widget body;
    if (phase is! LibraryReady) {
      body = const CenteredNote(
        icon: Icons.library_music,
        message: 'The library went away; go back and reopen it.',
      );
    } else if (volume == null) {
      body = const CenteredNote(
        icon: Icons.library_music,
        message: 'This volume left the library in the last sync.',
      );
    } else if (book == null) {
      body = const CenteredNote(
        icon: Icons.menu_book_outlined,
        message: 'This volume has no book in the library.',
      );
    } else if (presence == CachePresence.absent) {
      body = const CenteredNote(
        icon: Icons.cloud_off_outlined,
        message:
            'The book is not on this device — download it from '
            'the volume, then open it again.',
      );
    } else {
      body = PdfViewer.file(
        ref.read(libraryProvider.notifier).localFileFor(volume, book).path,
        controller: _viewer,
        params: PdfViewerParams(
          onViewerReady: (document, controller) =>
              setState(() => _pageCount = controller.pageCount),
          onPageChanged: (pageNumber) =>
              setState(() => _pageNumber = pageNumber),
          errorBannerBuilder: (context, error, stackTrace, documentRef) =>
              CenteredNote(
                icon: Icons.broken_image_outlined,
                message: 'The book could not be read: $error',
              ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(volume?.displayName ?? 'Book'),
        actions: <Widget>[
          if (_pageNumber != null && _pageCount != null)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text(
                  'page $_pageNumber of $_pageCount',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
        ],
      ),
      body: body,
    );
  }
}
