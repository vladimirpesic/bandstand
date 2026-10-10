import 'dart:io';
import 'dart:typed_data';

import 'package:bandstand/io/library/library_settings.dart';
import 'package:bandstand/io/library/mirror_cache.dart';
import 'package:bandstand/state/library.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../io/mega/fake_mega.dart';

Uint8List pattern(int size, int offset) =>
    Uint8List.fromList(List<int>.generate(size, (i) => (offset + i) % 251));

Future<LibraryPhase> settleFor(
  ProviderContainer container,
  bool Function(LibraryPhase) wanted, [
  Duration limit = const Duration(seconds: 10),
]) async {
  // A listener holds the provider alive, so the controller's async
  // bootstrap is one run, not one run per poll.
  final subscription = container.listen(
    libraryProvider,
    (_, _) {},
    fireImmediately: true,
  );
  try {
    final deadline = DateTime.now().add(limit);
    LibraryPhase? last;
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final phase = container.read(libraryProvider);
      if (wanted(phase)) {
        return phase;
      }
      last = phase;
    }
    fail('phase never arrived; last was $last');
  } finally {
    subscription.close();
  }
}

ProviderContainer containerFor(FakeMega mega, Directory home) {
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
          megaApiBaseUri: mega.apiBaseUri,
          megaRetryDelay: Duration.zero,
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<Directory> tempHome() async {
  final home = await Directory.systemTemp.createTemp('library-state-test');
  addTearDown(() async {
    try {
      await home.delete(recursive: true);
    } on FileSystemException {
      // Not the test's point.
    }
  });
  return home;
}

void main() {
  test(
    'the first run asks for the link, and a paste loads the library',
    () async {
      final mega = await FakeMega(
        tree: <String, Map<String, Uint8List>>{
          '001_how_to_play': <String, Uint8List>{
            '001_track_a.wav': pattern(5000, 1),
            'book.pdf': pattern(300, 2),
          },
        },
      ).start();
      addTearDown(mega.close);
      final container = containerFor(mega, await tempHome());

      final phase = await settleFor(container, (p) => p is LibraryNeedsLink);
      expect(phase, isA<LibraryNeedsLink>());

      await container.read(libraryProvider.notifier).linkLibrary(mega.linkText);
      final ready =
          await settleFor(container, (p) => p is LibraryReady) as LibraryReady;
      expect(ready.manifest.volumes, hasLength(1));
      expect(ready.manifest.rootName, 'jamey_aebersold');
      expect(ready.presence.values, everyElement(CachePresence.absent));
    },
  );

  test('a bad paste explains itself on the same card', () async {
    final mega = await FakeMega().start();
    addTearDown(mega.close);
    final container = containerFor(mega, await tempHome());
    await settleFor(container, (p) => p is LibraryNeedsLink);

    await container
        .read(libraryProvider.notifier)
        .linkLibrary('https://mega.nz/fm/whatever');
    final refused = await settleFor(
      container,
      (p) => p is LibraryNeedsLink && p.problem.isNotEmpty,
    ) as LibraryNeedsLink;
    expect(refused.problem, contains('private'));

    // A revoked link is also the paste card's business.
    await container
        .read(libraryProvider.notifier)
        .linkLibrary(mega.staleLinkText);
    final stale = await settleFor(
      container,
      (p) => p is LibraryNeedsLink && p.problem.isNotEmpty && p != refused,
    ) as LibraryNeedsLink;
    expect(stale.problem, isNotEmpty);
  });

  test('a download lands, verifies against its meta-MAC, and stays', () async {
    final mega = await FakeMega(
      tree: <String, Map<String, Uint8List>>{
        '001_how_to_play': <String, Uint8List>{
          '001_track_a.wav': pattern(70000, 5),
        },
      },
    ).start();
    addTearDown(mega.close);
    final home = await tempHome();
    final container = containerFor(mega, home);
    await container.read(libraryProvider.notifier).linkLibrary(mega.linkText);
    final ready =
        await settleFor(container, (p) => p is LibraryReady) as LibraryReady;
    final volume = ready.manifest.volumes.single;
    final entry = volume.entries.single;

    final controller = container.read(libraryProvider.notifier);
    controller.download(volume, entry, saved: true);
    await settleFor(
      container,
      (p) => p is LibraryReady && p.presence[entry.id] == CachePresence.saved,
    );
    final onDisk = File(
      '${home.path}/cache/volumes/001_how_to_play/001_track_a.wav',
    );
    expect(onDisk.existsSync(), isTrue);
    expect(await onDisk.readAsBytes(), pattern(70000, 5));
  });

  test('corrupted bytes are rejected, kept as nothing, and said so', () async {
    final mega = await FakeMega(
      tree: <String, Map<String, Uint8List>>{
        '001_how_to_play': <String, Uint8List>{
          '001_track_a.wav': pattern(4000, 9),
        },
      },
    ).start();
    addTearDown(mega.close);
    final home = await tempHome();
    final container = containerFor(mega, home);
    await container.read(libraryProvider.notifier).linkLibrary(mega.linkText);
    final ready =
        await settleFor(container, (p) => p is LibraryReady) as LibraryReady;
    final volume = ready.manifest.volumes.single;
    final entry = volume.entries.single;

    mega.corruptDownloads = true;
    container
        .read(libraryProvider.notifier)
        .download(volume, entry, saved: true);
    final failed = await settleFor(
      container,
      (p) => p is LibraryReady && p.downloads[entry.id] is DownloadFailed,
    ) as LibraryReady;
    expect(
      (failed.downloads[entry.id]! as DownloadFailed).message,
      contains('checksum'),
    );
    expect(failed.presence[entry.id], CachePresence.absent);
  });

  test('a dead sync keeps the cached manifest browsable', () async {
    final mega = await FakeMega(
      tree: <String, Map<String, Uint8List>>{
        '001_how_to_play': <String, Uint8List>{
          '001_track_a.wav': pattern(100, 1),
        },
      },
    ).start();
    final home = await tempHome();
    final container = containerFor(mega, home);
    await container.read(libraryProvider.notifier).linkLibrary(mega.linkText);
    await settleFor(container, (p) => p is LibraryReady);

    await mega.close();
    final controller = container.read(libraryProvider.notifier);
    await controller.refresh();
    final notice = await settleFor(
      container,
      (p) => p is LibraryReady && p.notice.contains('Could not sync'),
    ) as LibraryReady;
    expect(notice.manifest.volumes, hasLength(1));
    expect(notice.syncing, isFalse);
  });

  test('forgetting the link keeps the library on disk', () async {
    final mega = await FakeMega(
      tree: <String, Map<String, Uint8List>>{
        '001_how_to_play': <String, Uint8List>{
          '001_track_a.wav': pattern(100, 1),
        },
      },
    ).start();
    addTearDown(mega.close);
    final home = await tempHome();
    final container = containerFor(mega, home);
    await container.read(libraryProvider.notifier).linkLibrary(mega.linkText);
    final ready =
        await settleFor(container, (p) => p is LibraryReady) as LibraryReady;
    final volume = ready.manifest.volumes.single;
    final entry = volume.entries.single;
    container
        .read(libraryProvider.notifier)
        .download(volume, entry, saved: true);
    await settleFor(
      container,
      (p) => p is LibraryReady && p.presence[entry.id] == CachePresence.saved,
    );

    await container.read(libraryProvider.notifier).forgetLink();
    await settleFor(container, (p) => p is LibraryNeedsLink);
    expect(
      File('${home.path}/cache/volumes/001_how_to_play/001_track_a.wav')
          .existsSync(),
      isTrue,
    );
  });

  test('byte sizes read the way a person does', () {
    // The library's own numbers: the tuning notes, the handbook, a track,
    // and a library's worth of them. A file is never a GB; only the
    // totals are.
    expect(LibraryController.describeBytes(512), '512 B');
    expect(LibraryController.describeBytes(2053311), '2.0 MB');
    expect(LibraryController.describeBytes(4297622), '4.1 MB');
    expect(LibraryController.describeBytes(41943040), '40.0 MB');
    expect(LibraryController.describeBytes(157286400), '150 MB');
    expect(LibraryController.describeBytes(3221225472), '3.0 GB');
  });
}
