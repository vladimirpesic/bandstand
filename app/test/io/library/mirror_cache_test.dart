import 'dart:async';
import 'dart:io';

import 'package:bandstand/io/library/manifest.dart';
import 'package:bandstand/io/library/mirror_cache.dart';
import 'package:flutter_test/flutter_test.dart';

LibraryEntry entry(String name, List<int> bytes, {String checksum = ''}) =>
    LibraryEntry(
      id: name,
      name: name,
      kind: LibraryEntryKind.track,
      sizeBytes: bytes.length,
      checksum: checksum,
      modifiedUtc: DateTime.utc(2026, 1, 1),
    );

LibraryVolume volume(String name, List<LibraryEntry> entries) =>
    LibraryVolume(id: name, name: name, entries: entries);

/// A checksum that spells a fixed answer — the cache verifies the
/// plumbing, the MEGA tests verify the real chain.
class _FixedChecksum implements ByteChecksum {
  _FixedChecksum(this.value);

  final String value;

  @override
  void add(List<int> bytes) {}

  @override
  String finish() => value;
}

class _Source {
  _Source(this.bytes, {this.checksumValue = 'matches-everything'});

  final List<int> bytes;
  final String checksumValue;

  Future<MirrorDownload> open() async => MirrorDownload(
    contentLength: bytes.length,
    bytes: Stream<List<int>>.fromIterable(<List<int>>[bytes]),
    checksum: _FixedChecksum(checksumValue),
  );
}

Future<Directory> tempRoot() async {
  final root = await Directory.systemTemp.createTemp('mirror-cache-test');
  addTearDown(() async {
    try {
      await root.delete(recursive: true);
    } on FileSystemException {
      // A test's own cleanup race is not its point.
    }
  });
  return root;
}

void main() {
  test('a download lands verified, flagged, and present', () async {
    final cache = MirrorCache(await tempRoot());
    final bytes = List<int>.generate(100, (i) => i);
    final e = entry('001_a.wav', bytes, checksum: 'the-mac');
    final v = volume('001_how_to_play', <LibraryEntry>[e]);
    await cache.download(
      v,
      e,
      saved: true,
      open: _Source(bytes, checksumValue: 'the-mac').open,
    );
    expect(await cache.presence(v, e), CachePresence.saved);
    expect(await cache.entryFile(v, e).readAsBytes(), bytes);
    expect(cache.volumesDirectory.listSync(), isNotEmpty);
  });

  test('a session download is present as session', () async {
    final cache = MirrorCache(await tempRoot());
    final bytes = <int>[1, 2, 3];
    final e = entry('001_a.wav', bytes);
    final v = volume('001_how_to_play', <LibraryEntry>[e]);
    await cache.download(v, e, saved: false, open: _Source(bytes).open);
    expect(await cache.presence(v, e), CachePresence.session);
  });

  test('a root file downloads and counts like any volume file', () async {
    final cache = MirrorCache(await tempRoot());
    final bytes = <int>[7, 7, 7];
    final tuning = entry('tuning_notes.mp3', bytes);
    final track = entry('001_a.wav', <int>[1, 2, 3]);
    final v = volume('001_how_to_play', <LibraryEntry>[track]);
    final manifest = LibraryManifest(
      rootId: 'r0',
      rootName: 'jamey_aebersold',
      generatedUtc: DateTime.utc(2026, 10, 9),
      volumes: <LibraryVolume>[v],
      rootFiles: <LibraryEntry>[tuning],
    );
    await cache.download(
      manifest.rootVolume,
      tuning,
      saved: false,
      open: _Source(bytes).open,
    );

    expect(
      await cache.presence(manifest.rootVolume, tuning),
      CachePresence.session,
    );
    // The whole-manifest walks see it: presence, stats, the session list.
    final presence = await cache.presenceOfAll(manifest);
    expect(presence[tuning.id], CachePresence.session);
    expect(presence[track.id], CachePresence.absent);
    final stats = await cache.stats(manifest);
    expect(stats.sessionCount, 1);
    expect(stats.sessionBytes, bytes.length);
    expect(await cache.sessionEntries(manifest), hasLength(1));
    // And a sweep claims it rather than orphaning it.
    final report = await cache.reconcile(manifest, deleteOrphans: true);
    expect(report.deletedOrphans, 0);
    expect(
      await cache.presence(manifest.rootVolume, tuning),
      CachePresence.session,
    );
  });

  test('a checksum mismatch keeps nothing', () async {
    final cache = MirrorCache(await tempRoot());
    final bytes = List<int>.generate(50, (i) => 255 - i);
    final e = entry('001_a.wav', bytes, checksum: 'what-the-link-says');
    final v = volume('001_how_to_play', <LibraryEntry>[e]);
    await expectLater(
      cache.download(
        v,
        e,
        saved: true,
        open: _Source(bytes, checksumValue: 'what-arrived').open,
      ),
      throwsA(isA<ChecksumMismatchException>()),
    );
    expect(await cache.presence(v, e), CachePresence.absent);
    expect(cache.entryFile(v, e).existsSync(), isFalse);
    expect(
      cache.volumesDirectory
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.part')),
      isEmpty,
    );
  });

  test(
    'an empty checksum in the manifest is accepted as unverifiable',
    () async {
      final cache = MirrorCache(await tempRoot());
      final bytes = <int>[9, 9, 9, 9];
      final e = entry('book.pdf', bytes, checksum: '');
      final v = volume('001_how_to_play', <LibraryEntry>[e]);
      await cache.download(v, e, saved: true, open: _Source(bytes).open);
      expect(await cache.presence(v, e), CachePresence.saved);
    },
  );

  test('a stopped download keeps nothing and cancels cleanly', () async {
    final cache = MirrorCache(await tempRoot());
    final bytes = List<int>.generate(1000, (i) => i);
    final e = entry('001_a.wav', bytes);
    final v = volume('001_how_to_play', <LibraryEntry>[e]);
    final controller = StreamController<List<int>>();
    final firstProgress = Completer<void>();
    final doing = cache.download(
      v,
      e,
      saved: true,
      open: () async => MirrorDownload(
        contentLength: bytes.length,
        bytes: controller.stream,
        checksum: _FixedChecksum('whatever'),
      ),
      onProgress: (_, _) {
        if (!firstProgress.isCompleted) {
          firstProgress.complete();
        }
      },
    );
    unawaited(
      controller.addStream(Stream<List<int>>.value(bytes.sublist(0, 16))),
    );
    // Progress is proof the download is subscribed and writing; only then
    // does stopping it mean anything.
    await firstProgress.future;
    cache.cancel(e.id);
    await expectLater(doing, throwsA(isA<DownloadCancelledException>()));
    expect(await cache.presence(v, e), CachePresence.absent);
    await controller.close();
  });

  test(
    'reconciliation moves files with their ids, adopts strays, reports orphans',
    () async {
      final cache = MirrorCache(await tempRoot());
      final bytes = <int>[1, 2, 3, 4, 5];
      final e = entry('001_a.wav', bytes);
      final oldVolume = volume('001_old_name', <LibraryEntry>[e]);
      await cache.download(
        oldVolume,
        e,
        saved: true,
        open: _Source(bytes).open,
      );

      // The remote side renamed the volume: same id, new name.
      final renamed = volume('001_new_name', <LibraryEntry>[e]);
      final manifest = LibraryManifest(
        rootId: 'r',
        rootName: 'root',
        generatedUtc: DateTime.utc(2026, 1, 1),
        volumes: <LibraryVolume>[renamed],
      );
      final report = await cache.reconcile(manifest, deleteOrphans: false);
      expect(report.moved, <String>['volumes/001_new_name/001_a.wav']);
      expect(await cache.presence(renamed, e), CachePresence.saved);
      expect(
        File('${cache.rootDirectory.path}/volumes/001_old_name/001_a.wav')
            .existsSync(),
        isFalse,
      );

      // A file on disk no manifest claims: reported, kept, then swept.
      final stray = File(
        '${cache.volumesDirectory.path}/001_new_name/leftover.bin',
      );
      await stray.parent.create(recursive: true);
      await stray.writeAsBytes(<int>[7, 7, 7]);
      final withOrphan = await cache.reconcile(manifest, deleteOrphans: false);
      expect(withOrphan.orphans, hasLength(1));
      expect(stray.existsSync(), isTrue);
      final swept = await cache.reconcile(manifest, deleteOrphans: true);
      expect(swept.deletedOrphans, 1);
      expect(stray.existsSync(), isFalse);

      // A flag whose file is gone: dropped, not kept half-alive.
      File('${cache.rootDirectory.path}/volumes/001_new_name/001_a.wav')
          .deleteSync();
      final afterLoss = await cache.reconcile(manifest, deleteOrphans: false);
      expect(afterLoss.droppedFlags, <String>[e.id]);
      expect(await cache.presence(renamed, e), CachePresence.absent);
    },
  );

  test('a crash between rename and flag adopts as session', () async {
    final cache = MirrorCache(await tempRoot());
    final bytes = <int>[4, 4, 4];
    final e = entry('001_a.wav', bytes);
    final v = volume('001_how_to_play', <LibraryEntry>[e]);
    final file = cache.entryFile(v, e);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    final manifest = LibraryManifest(
      rootId: 'r',
      rootName: 'root',
      generatedUtc: DateTime.utc(2026, 1, 1),
      volumes: <LibraryVolume>[v],
    );
    final report = await cache.reconcile(manifest, deleteOrphans: false);
    expect(report.adoptedAsSession, <String>[
      'volumes/001_how_to_play/001_a.wav',
    ]);
    expect(await cache.presence(v, e), CachePresence.session);
  });

  test('stray .part files are deleted outright', () async {
    final cache = MirrorCache(await tempRoot());
    final part = File('${cache.volumesDirectory.path}/junk.part');
    await part.parent.create(recursive: true);
    await part.writeAsBytes(<int>[1]);
    final report = await cache.reconcile(
      LibraryManifest(
        rootId: 'r',
        rootName: 'root',
        generatedUtc: DateTime.utc(2026, 1, 1),
        volumes: const <LibraryVolume>[],
      ),
      deleteOrphans: false,
    );
    expect(report.deletedParts, 1);
    expect(part.existsSync(), isFalse);
  });

  test('stats split bytes the way the closing question asks', () async {
    final cache = MirrorCache(await tempRoot());
    final savedBytes = List<int>.filled(10, 1);
    final sessionBytes = List<int>.filled(20, 2);
    final savedEntry = entry('001_saved.wav', savedBytes);
    final sessionEntry = entry('002_session.wav', sessionBytes);
    final v = volume('001_how_to_play', <LibraryEntry>[
      savedEntry,
      sessionEntry,
    ]);
    await cache.download(
      v,
      savedEntry,
      saved: true,
      open: _Source(savedBytes).open,
    );
    await cache.download(
      v,
      sessionEntry,
      saved: false,
      open: _Source(sessionBytes).open,
    );
    final manifest = LibraryManifest(
      rootId: 'r',
      rootName: 'root',
      generatedUtc: DateTime.utc(2026, 1, 1),
      volumes: <LibraryVolume>[v],
    );
    final stats = await cache.stats(manifest);
    expect(stats.savedCount, 1);
    expect(stats.sessionCount, 1);
    expect(stats.savedBytes, 10);
    expect(stats.sessionBytes, 20);
    expect(stats.totalBytes, 30);
    final summary = await cache.sessionEntries(manifest);
    expect(summary, hasLength(1));
    expect(summary.first.$2.name, '002_session.wav');
  });
}
