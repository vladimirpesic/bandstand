import 'dart:io';

import 'package:bandstand/io/library/library_settings.dart';
import 'package:bandstand/io/library/manifest.dart';
import 'package:bandstand/io/library/mirror_cache.dart';
import 'package:bandstand/io/library/setlists.dart';
import 'package:bandstand/state/library.dart';
import 'package:bandstand/state/setlists.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

Future<Directory> tempHome() async {
  final home = await Directory.systemTemp.createTemp('setlists-state-test');
  addTearDown(() async {
    try {
      await home.delete(recursive: true);
    } on FileSystemException {
      // Not the test's point.
    }
  });
  return home;
}

/// A live container over a temp home: real file, real controller — the
/// same parts the app runs, minus any MEGA.
ProviderContainer containerFor(Directory home) {
  final container = ProviderContainer(
    overrides: [
      libraryServicesProvider.overrideWithValue(
        LibraryServices(
          settingsFile: File(
            '${home.path}${Platform.pathSeparator}'
            '${LibrarySettings.fileName}',
          ),
          defaultCacheRoot: Directory(
            '${home.path}${Platform.pathSeparator}cache',
          ),
          httpClient: http.Client(),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  // A listener holds the provider alive, so the load runs once.
  container.listen(setlistsProvider, (_, _) {}, fireImmediately: true);
  return container;
}

void main() {
  test(
    'create persists: a fresh container over the same file sees it',
    () async {
      final home = await tempHome();
      final first = containerFor(home);
      final problem = await first
          .read(setlistsProvider.notifier)
          .create('Gig Saturday');
      expect(problem, isNull);

      final second = containerFor(home);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        second.read(setlistsProvider).setlists.map((s) => s.name),
        <String>['Gig Saturday'],
      );
    },
  );

  test('create can carry a first member; duplicates are refused', () async {
    final home = await tempHome();
    final container = containerFor(home);
    final controller = container.read(setlistsProvider.notifier);
    expect(await controller.create('Practice', entryId: 'a'), isNull);

    final setlist = container.read(setlistsProvider).setlists.single;
    expect(setlist.entryIds, <String>['a']);

    expect(
      await controller.addEntry(setlist.id, 'a'),
      '"Practice" already has that tune.',
    );
    expect(container.read(setlistsProvider).setlists.single.entryIds, <String>[
      'a',
    ]);
    expect(await controller.addEntry(setlist.id, 'b'), isNull);
    expect(container.read(setlistsProvider).setlists.single.entryIds, <String>[
      'a',
      'b',
    ]);
  });

  test('rename keeps members and refuses a taken name', () async {
    final home = await tempHome();
    final container = containerFor(home);
    final controller = container.read(setlistsProvider.notifier);
    await controller.create('One', entryId: 'a');
    await controller.create('Two', entryId: 'b');
    final one = container
        .read(setlistsProvider)
        .setlists
        .firstWhere((s) => s.name == 'One');

    expect(await controller.rename(one.id, '  First Set '), isNull);
    expect(container.read(setlistsProvider).byId(one.id)!.name, 'First Set');
    expect(container.read(setlistsProvider).byId(one.id)!.entryIds, <String>[
      'a',
    ]);
    expect(await controller.rename(one.id, 'two'), isNotNull);
    expect(container.read(setlistsProvider).byId(one.id)!.name, 'First Set');
  });

  test(
    'delete removes the list and keeps the rest; removal takes a member out',
    () async {
      final home = await tempHome();
      final container = containerFor(home);
      final controller = container.read(setlistsProvider.notifier);
      await controller.create('One', entryId: 'a');
      await controller.create('Two', entryId: 'b');
      final state = container.read(setlistsProvider);
      final one = state.setlists.firstWhere((s) => s.name == 'One');
      final two = state.setlists.firstWhere((s) => s.name == 'Two');

      await controller.removeEntry(two.id, 'b');
      expect(container.read(setlistsProvider).byId(two.id)!.entryIds, isEmpty);

      await controller.delete(one.id);
      expect(
        container.read(setlistsProvider).setlists.map((s) => s.name),
        <String>['Two'],
      );
    },
  );

  test('a file that cannot be read freezes every change', () async {
    final home = await tempHome();
    final file = File(
      '${home.path}${Platform.pathSeparator}${Setlists.fileName}',
    );
    await file.writeAsString('corrupt');
    final container = containerFor(home);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(container.read(setlistsProvider).isWritable, isFalse);
    expect(
      await container.read(setlistsProvider.notifier).create('Nope'),
      isNotNull,
    );
    // The corrupt file was never overwritten.
    expect(await file.readAsString(), 'corrupt');
  });

  test('Favorites is every saved track, in library order', () {
    LibraryEntry entry(String id, String name) => LibraryEntry(
      id: id,
      name: name,
      kind: LibraryEntryKind.ofName(name),
      sizeBytes: 10,
      checksum: '',
      modifiedUtc: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
    final v1 = LibraryVolume(
      id: 'v1',
      name: '001_first',
      entries: <LibraryEntry>[
        entry('t1', '001_a.wav'),
        entry('t2', '002_b.wav'),
        entry('b1', 'book.pdf'),
      ],
    );
    final v2 = LibraryVolume(
      id: 'v2',
      name: '002_second',
      entries: <LibraryEntry>[entry('t3', '001_c.wav')],
    );
    final manifest = LibraryManifest(
      rootId: 'root',
      rootName: 'root',
      generatedUtc: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      volumes: <LibraryVolume>[v1, v2],
    );
    final phase = LibraryReady(
      manifest: manifest,
      presence: <String, CachePresence>{
        't1': CachePresence.saved,
        't2': CachePresence.session,
        'b1': CachePresence.saved,
        't3': CachePresence.saved,
      },
      downloads: const <String, DownloadState>{},
      stats: const CacheStats(
        savedCount: 3,
        sessionCount: 1,
        savedBytes: 30,
        sessionBytes: 10,
      ),
    );

    // The session track and the book are out; saved tracks stay in
    // volume order, track order — and cannot repeat.
    expect(favoritesOf(phase).map((pair) => pair.$2.id), <String>['t1', 't3']);
  });
}
