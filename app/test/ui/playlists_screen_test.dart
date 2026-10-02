import 'dart:io';

import 'package:bandstand/domain/song/playlist.dart';
import 'package:bandstand/io/song_library.dart';
import 'package:bandstand/state/library_state.dart';
import 'package:bandstand/ui/screens/playlists_screen.dart';
import 'package:bandstand/ui/theme/bandstand_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Deleting a set asks first, and reordering keeps rows attached to their
/// songs.
///
/// The library is an in-memory fake: `testWidgets` runs in a fake-async zone
/// where futures backed by real file I/O never complete.
void main() {
  late Directory root;
  late _MemoryLibrary library;

  setUp(() {
    root = Directory.systemTemp.createTempSync('bandstand-playlists-test');
    library = _MemoryLibrary(root);
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  Playlist setOf(String name, List<PlaylistEntry> entries) =>
      Playlist(id: name.toLowerCase(), name: name, entries: entries);

  Widget harness() => ProviderScope(
    overrides: [songLibraryProvider.overrideWith((ref) async => library)],
    child: MaterialApp(
      theme: BandstandTheme.dark(),
      home: const PlaylistsScreen(),
    ),
  );

  testWidgets('deleting a set asks, and cancelling keeps it', (tester) async {
    library.playlists = <Playlist>[
      setOf('Friday', <PlaylistEntry>[PlaylistEntry(songId: 'a')]),
    ];
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    // The name shows in the list and the detail pane.
    expect(find.text('Friday'), findsWidgets);

    await tester.tap(find.byTooltip('Delete this set'));
    await tester.pumpAndSettle();
    expect(find.text('Delete set "Friday"?'), findsOneWidget);
    expect(library.deleted, isFalse);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Delete set "Friday"?'), findsNothing);
    expect(find.text('Friday'), findsWidgets);
    expect(library.deleted, isFalse);
  });

  testWidgets('confirming the dialog deletes the set', (tester) async {
    library.playlists = <Playlist>[
      setOf('Friday', <PlaylistEntry>[PlaylistEntry(songId: 'a')]),
    ];
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Delete this set'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(library.deleted, isTrue);
    expect(
      find.text('No sets yet. Start one with the button below.'),
      findsOneWidget,
    );
  });

  testWidgets('rows are keyed by their entry, not their position', (
    tester,
  ) async {
    final first = PlaylistEntry(songId: 'a');
    final second = PlaylistEntry(songId: 'b');
    library.playlists = <Playlist>[
      setOf('Friday', <PlaylistEntry>[first, second]),
    ];
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.byKey(ObjectKey(first)), findsOneWidget);
    expect(find.byKey(ObjectKey(second)), findsOneWidget);
  });
}

/// The disk pieces the screen touches, in memory: deleting flips the list the
/// next read sees, with no file I/O to stall the fake-async zone.
class _MemoryLibrary extends SongLibrary {
  _MemoryLibrary(super.root);

  List<Playlist> playlists = <Playlist>[];
  bool deleted = false;

  @override
  Future<List<Playlist>> loadPlaylists() async =>
      deleted ? <Playlist>[] : playlists;

  @override
  Future<void> deletePlaylist(String id) async {
    deleted = true;
  }
}
