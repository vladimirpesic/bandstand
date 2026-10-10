import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bandstand/io/library/manifest.dart';
import 'package:bandstand/io/atomic_write.dart';

/// What the cache says about one entry: on disk and flagged saved, on disk
/// as a session download, or not on disk at all.
enum CachePresence {
  /// Nothing usable at the entry's mirrored path.
  absent,

  /// Downloaded this run, discarded when the app closes unless kept.
  session,

  /// Downloaded and flagged to stay.
  saved,
}

/// An incremental checksum over a download's plaintext bytes. The cache
/// feeds it as it writes; `finish` returns the value the manifest recorded.
/// MEGA's implementation is the chunked MAC (§3 of
/// `docs/rules/mega-library.md`); the interface stays backend-blind.
abstract class ByteChecksum {
  /// Feed the next plaintext bytes through.
  void add(List<int> bytes);

  /// The final value, in the manifest's string form.
  String finish();
}

/// A download opened for streaming: the plaintext and its checksum.
class MirrorDownload {
  /// Create the handle.
  const MirrorDownload({
    required this.bytes,
    required this.checksum,
    this.contentLength,
  });

  /// The decrypted bytes. Consumed or cancelled by whoever opened them.
  final Stream<List<int>> bytes;

  /// The checksum fed the same bytes on the way through.
  final ByteChecksum checksum;

  /// How many bytes the body will deliver, when the source said so.
  final int? contentLength;
}

/// A download that arrived but did not match what the folder link says it
/// is.
class ChecksumMismatchException implements Exception {
  /// Create the exception.
  const ChecksumMismatchException(this.name, this.expected, this.actual);

  /// The file's name.
  final String name;

  /// The checksum the folder link recorded.
  final String expected;

  /// The checksum of the bytes that arrived.
  final String actual;

  @override
  String toString() =>
      '$name arrived with checksum $actual, but the folder link says '
      '$expected; nothing was kept';
}

/// A download the user stopped.
class DownloadCancelledException implements Exception {
  /// Create the exception.
  const DownloadCancelledException();

  @override
  String toString() => 'the download was stopped';
}

/// One file under `volumes/` that no manifest entry claims.
class CacheOrphan {
  /// Create the record.
  const CacheOrphan({required this.path, required this.sizeBytes});

  /// The path relative to the cache root, `volumes/…`.
  final String path;

  /// Its size, for the "this will free X MB" sentence.
  final int sizeBytes;
}

/// What a reconciliation pass found and did (§5 of
/// `docs/rules/mega-library.md`).
class ReconcileReport {
  /// Create the report.
  const ReconcileReport({
    required this.moved,
    required this.droppedFlags,
    required this.adoptedAsSession,
    required this.deletedParts,
    required this.orphans,
    required this.deletedOrphans,
  });

  /// Entries whose mirrored path changed because the MEGA side moved or
  /// renamed them; the file travelled with the flag, not behind a
  /// re-download.
  final List<String> moved;

  /// Flags whose file was gone — deleted outside the app, or a rename that
  /// never completed — and are therefore no longer claimed.
  final List<String> droppedFlags;

  /// Files that landed on disk without a flag — a crash between the rename
  /// and the flag write — adopted as session downloads, the conservative
  /// choice.
  final List<String> adoptedAsSession;

  /// Stray `.part` files deleted outright; they were never files.
  final int deletedParts;

  /// Files under `volumes/` that no manifest entry claims. Left alone
  /// unless the caller asked for the sweep.
  final List<CacheOrphan> orphans;

  /// How many of those were deleted by this pass.
  final int deletedOrphans;

  /// Whether there is anything a person should be told about.
  bool get isQuiet =>
      moved.isEmpty &&
      droppedFlags.isEmpty &&
      adoptedAsSession.isEmpty &&
      deletedParts == 0 &&
      orphans.isEmpty;
}

/// Bytes on disk, split the way the keep/discard question asks for them.
class CacheStats {
  /// Create the stats.
  const CacheStats({
    required this.savedCount,
    required this.sessionCount,
    required this.savedBytes,
    required this.sessionBytes,
  });

  /// How many saved files are on disk.
  final int savedCount;

  /// How many session files are on disk.
  final int sessionCount;

  /// Bytes the saved files take.
  final int savedBytes;

  /// Bytes the session files take.
  final int sessionBytes;

  /// Everything on disk.
  int get totalBytes => savedBytes + sessionBytes;

  /// Everything on disk, as a count.
  int get totalCount => savedCount + sessionCount;
}

/// The local mirror of the MEGA library: one root, one copy of every file,
/// `docs/rules/mega-library.md` §§2–6 in code.
///
/// Progress as a download goes: bytes written so far, and the total when it
/// is known.
typedef DownloadProgress = void Function(int received, int? total);

/// How a download's bytes are opened: the MEGA client in the app, anything
/// with the same shape in tests.
typedef DownloadSource = Future<MirrorDownload> Function();

class MirrorCache {
  /// Create the cache over [rootDirectory].
  MirrorCache(this.rootDirectory);

  /// The cache root: `manifest.json`, `cache-state.json`, `volumes/`.
  final Directory rootDirectory;

  /// Where the manifest lives.
  File get manifestFile => _fileInRoot('manifest.json');

  /// Where the saved/session flags live.
  File get stateFile => _fileInRoot('cache-state.json');

  /// The mirrored tree.
  Directory get volumesDirectory =>
      Directory('${rootDirectory.path}${Platform.pathSeparator}volumes');

  final Map<String, _ActiveDownload> _activeDownloads =
      <String, _ActiveDownload>{};

  File _fileInRoot(String name) =>
      File('${rootDirectory.path}${Platform.pathSeparator}$name');

  /// Create the layout if it is not there.
  Future<void> ensureLayout() async {
    await rootDirectory.create(recursive: true);
    await volumesDirectory.create(recursive: true);
  }

  /// The manifest's text, or null when there is none.
  ///
  /// Corrupt JSON is the caller's problem — this layer hands over the bytes
  /// it found so the failure can be named where the schema is known.
  Future<String?> loadManifestText() async {
    try {
      return await manifestFile.readAsString();
    } on FileSystemException {
      return null;
    }
  }

  /// Write the manifest atomically (§5.4's discipline, by way of the same
  /// helper the token file uses).
  Future<void> saveManifestText(String text) async {
    await rootDirectory.create(recursive: true);
    await writeAtomically(manifestFile, text);
  }

  /// The entry's file in the mirror. Validated: a name from the manifest
  /// can never walk out of the tree (§5.4 — the library only opens paths it
  /// would have generated itself).
  File entryFile(LibraryVolume volume, LibraryEntry entry) => File(
    '${rootDirectory.path}${Platform.pathSeparator}volumes'
    '${Platform.pathSeparator}${_checkedSegment(volume.name)}'
    '${Platform.pathSeparator}${_checkedSegment(entry.name)}',
  );

  /// Where [entry] should be, relative to the root, with `/` separators —
  /// the form the flags file keeps, stable across platforms.
  String relativePathOf(LibraryVolume volume, LibraryEntry entry) =>
      'volumes/${_checkedSegment(volume.name)}/${_checkedSegment(entry.name)}';

  /// Whether the entry is on disk, and as what.
  ///
  /// Existence plus a size match against the manifest — the cheap check
  /// (§5). The checksum is paid once, at download time. A file that is there but
  /// carries no flag counts as a session download; reconciliation adopts it
  /// properly.
  Future<CachePresence> presence(
    LibraryVolume volume,
    LibraryEntry entry,
  ) async {
    final file = entryFile(volume, entry);
    if (!file.existsSync() || file.lengthSync() != entry.sizeBytes) {
      return CachePresence.absent;
    }
    final flags = await _loadFlags();
    return flags[entry.id]?.saved ?? false
        ? CachePresence.saved
        : CachePresence.session;
  }

  /// Presence for the whole manifest in one pass: the flags file is read
  /// once, and every row's answer is ready before the first frame that
  /// shows the library.
  Future<Map<String, CachePresence>> presenceOfAll(
    LibraryManifest manifest,
  ) async {
    final flags = await _loadFlags();
    return <String, CachePresence>{
      for (final volume in manifest.allVolumes)
        for (final entry in volume.entries)
          entry.id:
              entryFile(volume, entry).existsSync() &&
                  entryFile(volume, entry).lengthSync() == entry.sizeBytes
              ? (flags[entry.id]?.saved ?? false
                    ? CachePresence.saved
                    : CachePresence.session)
              : CachePresence.absent,
    };
  }

  /// Download [entry] into the mirror, §3 end to end: stream the plaintext
  /// to `.part`, checksum it on the way through, verify, rename, flag.
  ///
  /// [saved] decides the flag the file lands with; promoting later is a
  /// flag write ([markSaved]), never a second copy.
  Future<void> download(
    LibraryVolume volume,
    LibraryEntry entry, {
    required bool saved,
    required DownloadSource open,
    DownloadProgress? onProgress,
  }) async {
    if (_activeDownloads.containsKey(entry.id)) {
      throw StateError('${entry.name} is already downloading');
    }
    final target = entryFile(volume, entry);
    final part = File('${target.path}.part');
    await target.parent.create(recursive: true);

    final sink = part.openWrite();
    var received = 0;
    final done = Completer<void>();
    final active = _ActiveDownload(done);
    _activeDownloads[entry.id] = active;
    try {
      final download = await open();
      final checksum = download.checksum;
      final declared = download.contentLength;
      final total = declared ?? (entry.sizeBytes > 0 ? entry.sizeBytes : null);
      final subscription = download.bytes.listen(
        (chunk) {
          received += chunk.length;
          checksum.add(chunk);
          sink.add(chunk);
          onProgress?.call(received, total);
        },
        onError: (Object error) {
          if (!done.isCompleted) {
            done.completeError(error);
          }
        },
        onDone: () {
          if (!done.isCompleted) {
            done.complete();
          }
        },
        cancelOnError: true,
      );
      active.subscription = subscription;
      if (active.cancelled) {
        // Stopped between the open and the first chunk.
        await subscription.cancel();
        throw const DownloadCancelledException();
      }
      await done.future;
      await sink.flush();
      await sink.close();
      final actual = checksum.finish();
      if (entry.checksum.isNotEmpty &&
          actual.toLowerCase() != entry.checksum.toLowerCase()) {
        throw ChecksumMismatchException(entry.name, entry.checksum, actual);
      }
      await part.rename(target.path);
      await _recordFlag(entry, relativePathOf(volume, entry), saved: saved);
    } on Object {
      await _discardPart(sink, part);
      rethrow;
    } finally {
      _activeDownloads.remove(entry.id);
    }
  }

  /// Stop the entry's download, if one is going. Safe when it is not.
  void cancel(String entryId) {
    final active = _activeDownloads[entryId];
    if (active == null || active.cancelled) {
      return;
    }
    active.cancelled = true;
    active.subscription?.cancel();
    if (!active.done.isCompleted) {
      active.done.completeError(const DownloadCancelledException());
    }
  }

  /// Whether a download for [entryId] is in flight.
  bool isDownloading(String entryId) => _activeDownloads.containsKey(entryId);

  /// Flag the entry as saved: it stays when the app closes.
  Future<void> markSaved(LibraryVolume volume, LibraryEntry entry) =>
      _recordFlag(entry, relativePathOf(volume, entry), saved: true);

  /// Flag the entry as session: the closing prompt offers to discard it.
  Future<void> markSession(LibraryVolume volume, LibraryEntry entry) =>
      _recordFlag(entry, relativePathOf(volume, entry), saved: false);

  /// Delete the entry's file and its flag. Explicit, so it takes saved
  /// files too — this is the "remove from device" button, not data loss.
  Future<void> remove(LibraryVolume volume, LibraryEntry entry) async {
    final file = entryFile(volume, entry);
    if (file.existsSync()) {
      await file.delete();
    }
    final flags = await _loadFlags();
    if (flags.remove(entry.id) != null) {
      await _saveFlags(flags);
    }
  }

  /// Bring flags, disk and manifest back into line, §5.
  ///
  /// Runs off node handles, so a rename or move on the MEGA side is a
  /// move of the local file, not a mystery re-download. [deleteOrphans]
  /// decides whether files no manifest entry claims are deleted or merely
  /// reported — the sweep is the user's call, never the startup's.
  Future<ReconcileReport> reconcile(
    LibraryManifest manifest, {
    required bool deleteOrphans,
  }) async {
    final flags = await _loadFlags();
    final expected = <String, String>{};
    final byPath = <String, (LibraryVolume, LibraryEntry)>{};
    final sizes = <String, int>{};
    for (final volume in manifest.allVolumes) {
      for (final entry in volume.entries) {
        final path = relativePathOf(volume, entry);
        expected[entry.id] = path;
        byPath[path] = (volume, entry);
        sizes[entry.id] = entry.sizeBytes;
      }
    }

    // Stray `.part` files: never files, deleted outright.
    var deletedParts = 0;
    if (volumesDirectory.existsSync()) {
      await for (final entity in volumesDirectory.list(recursive: true)) {
        if (entity is File && entity.path.endsWith('.part')) {
          await entity.delete();
          deletedParts++;
        }
      }
    }

    final onDisk = <String, File>{};
    if (volumesDirectory.existsSync()) {
      await for (final entity in volumesDirectory.list(recursive: true)) {
        if (entity is File &&
            !entity.path.endsWith('.part') &&
            !entity.path.endsWith('.tmp')) {
          onDisk[_relativeToRoot(entity)] = entity;
        }
      }
    }

    // Flags for entries the manifest still knows: move with the entry, or
    // drop when the file they claim is not usable.
    final moved = <String>[];
    final dropped = <String>[];
    for (final id in flags.keys.toList()) {
      final flag = flags[id]!;
      final path = expected[id];
      if (path == null) {
        // The entry left the tree on the MEGA side. Its flag goes; the
        // file it pointed at is the orphan pass's business.
        flags.remove(id);
        dropped.add(id);
        continue;
      }
      final current = File(
        '${rootDirectory.path}${Platform.pathSeparator}'
        '${flag.path.replaceAll('/', Platform.pathSeparator)}',
      );
      final target = File(
        '${rootDirectory.path}${Platform.pathSeparator}'
        '${path.replaceAll('/', Platform.pathSeparator)}',
      );
      final fileThere =
          current.existsSync() && current.lengthSync() == sizes[id];
      final targetThere =
          target.existsSync() && target.lengthSync() == sizes[id];
      if (flag.path == path && fileThere) {
        continue;
      }
      if (!fileThere && targetThere) {
        // Already at the right place under the right name; the flag was
        // the stale half. Keep the file, fix the flag.
        flags[id] = _Flag(path: path, saved: flag.saved);
        continue;
      }
      if (fileThere && !targetThere) {
        await target.parent.create(recursive: true);
        await current.rename(target.path);
        flags[id] = _Flag(path: path, saved: flag.saved);
        moved.add(path);
        continue;
      }
      // Neither place holds a usable file: the flag claims bytes that are
      // not there. Drop it; the download can happen again.
      flags.remove(id);
      dropped.add(id);
    }

    // Files on disk the manifest expects but no flag covers: adopt as
    // session, the conservative choice (§5).
    final adopted = <String>[];
    for (final path in onDisk.keys) {
      final pair = byPath[path];
      if (pair == null) {
        continue;
      }
      final entry = pair.$2;
      final file = onDisk[path]!;
      if (file.lengthSync() == entry.sizeBytes &&
          !flags.containsKey(entry.id)) {
        flags[entry.id] = _Flag(path: path, saved: false);
        adopted.add(path);
      } else if (file.lengthSync() != entry.sizeBytes &&
          !flags.containsKey(entry.id)) {
        // A file with the right name but the wrong size claims the path;
        // it is not the download. Remove it so a future download can land.
        await file.delete();
        dropped.add(entry.id);
      }
    }

    // Orphans: on disk, claimed by no manifest path. A path the move pass
    // above emptied is not an orphan — it is a file that just travelled.
    final orphans = <CacheOrphan>[];
    var deletedOrphans = 0;
    for (final path in onDisk.keys) {
      if (byPath.containsKey(path)) {
        continue;
      }
      final file = onDisk[path]!;
      if (!file.existsSync()) {
        continue;
      }
      final size = file.lengthSync();
      if (deleteOrphans) {
        await file.delete();
        deletedOrphans++;
      } else {
        orphans.add(CacheOrphan(path: path, sizeBytes: size));
      }
    }

    await _pruneEmptyDirectories();
    await _saveFlags(flags);
    return ReconcileReport(
      moved: moved,
      droppedFlags: dropped,
      adoptedAsSession: adopted,
      deletedParts: deletedParts,
      orphans: orphans,
      deletedOrphans: deletedOrphans,
    );
  }

  /// Bytes on disk, split saved against session.
  Future<CacheStats> stats(LibraryManifest manifest) async {
    final flags = await _loadFlags();
    var savedCount = 0;
    var sessionCount = 0;
    var savedBytes = 0;
    var sessionBytes = 0;
    for (final volume in manifest.allVolumes) {
      for (final entry in volume.entries) {
        final file = entryFile(volume, entry);
        if (!file.existsSync() || file.lengthSync() != entry.sizeBytes) {
          continue;
        }
        if (flags[entry.id]?.saved ?? false) {
          savedCount++;
          savedBytes += entry.sizeBytes;
        } else {
          sessionCount++;
          sessionBytes += entry.sizeBytes;
        }
      }
    }
    return CacheStats(
      savedCount: savedCount,
      sessionCount: sessionCount,
      savedBytes: savedBytes,
      sessionBytes: sessionBytes,
    );
  }

  /// The entries on disk as session downloads — what closing the app puts
  /// up for the keep-or-discard question (§6).
  Future<List<(LibraryVolume, LibraryEntry)>> sessionEntries(
    LibraryManifest manifest,
  ) async {
    final flags = await _loadFlags();
    return <(LibraryVolume, LibraryEntry)>[
      for (final volume in manifest.allVolumes)
        for (final entry in volume.entries)
          if (entryFile(volume, entry).existsSync() &&
              entryFile(volume, entry).lengthSync() == entry.sizeBytes &&
              !(flags[entry.id]?.saved ?? false))
            (volume, entry),
    ];
  }

  /// Flag every session file saved — the "keep" half of the closing
  /// question, one flag write per file, no copies (§6).
  Future<void> keepAllSessions(LibraryManifest manifest) async {
    for (final (volume, entry) in await sessionEntries(manifest)) {
      await markSaved(volume, entry);
    }
  }

  /// Delete every session file — the "discard" half (§6).
  Future<void> discardAllSessions(LibraryManifest manifest) async {
    for (final (volume, entry) in await sessionEntries(manifest)) {
      await remove(volume, entry);
    }
    await _pruneEmptyDirectories();
  }

  String _relativeToRoot(FileSystemEntity entity) {
    final prefix = '${rootDirectory.path}${Platform.pathSeparator}'.length;
    return entity.path
        .substring(prefix)
        .replaceAll(Platform.pathSeparator, '/');
  }

  Future<void> _pruneEmptyDirectories() async {
    if (!volumesDirectory.existsSync()) {
      return;
    }
    final directories =
        volumesDirectory
            .listSync(recursive: true, followLinks: false)
            .whereType<Directory>()
            .toList()
          ..sort((a, b) => b.path.length.compareTo(a.path.length));
    for (final directory in directories) {
      if (directory.listSync().isEmpty) {
        directory.deleteSync();
      }
    }
  }

  Future<Map<String, _Flag>> _loadFlags() async {
    if (!stateFile.existsSync()) {
      return <String, _Flag>{};
    }
    try {
      final decoded = jsonDecode(await stateFile.readAsString());
      if (decoded is! Map<String, Object?>) {
        return <String, _Flag>{};
      }
      final files = decoded['files'];
      if (files is! Map<String, Object?>) {
        return <String, _Flag>{};
      }
      return <String, _Flag>{
        for (final entry in files.entries)
          if (entry.value is Map<String, Object?>)
            entry.key: _Flag.fromJson(entry.value! as Map<String, Object?>),
      };
    } on FormatException {
      // An unreadable flags file costs the flags, not the files: every
      // byte on disk is adopted back as a session download by the next
      // reconcile, so nothing is lost and nothing is lied about.
      return <String, _Flag>{};
    } on FileSystemException {
      return <String, _Flag>{};
    }
  }

  Future<void> _saveFlags(Map<String, _Flag> flags) async {
    await rootDirectory.create(recursive: true);
    await writeAtomically(
      stateFile,
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'files': <String, Object?>{
          for (final entry in flags.entries) entry.key: entry.value.toJson(),
        },
      }),
    );
  }

  Future<void> _recordFlag(
    LibraryEntry entry,
    String path, {
    required bool saved,
  }) async {
    final flags = await _loadFlags();
    flags[entry.id] = _Flag(path: path, saved: saved);
    await _saveFlags(flags);
  }

  Future<void> _discardPart(IOSink sink, File part) async {
    try {
      await sink.close();
    } on FileSystemException {
      // The sink never made it to life; the delete below is the cleanup
      // that matters.
    }
    if (part.existsSync()) {
      await part.delete();
    }
  }

  static String _checkedSegment(String name) {
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.startsWith('.') ||
        name.contains('/') ||
        name.contains('\\')) {
      throw ArgumentError.value(name, 'name', 'not a canonical library name');
    }
    return name;
  }
}

/// One entry's flag: saved or session, and the path it was recorded against.
class _Flag {
  const _Flag({required this.path, required this.saved});

  factory _Flag.fromJson(Map<String, Object?> json) => _Flag(
    path: json['path'] is String ? json['path']! as String : '',
    saved: json['saved'] is bool ? json['saved']! as bool : false,
  );

  final String path;
  final bool saved;

  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'saved': saved,
  };
}

/// A download in flight, reachable by entry id for cancellation.
class _ActiveDownload {
  _ActiveDownload(this.done);

  final Completer<void> done;
  StreamSubscription<List<int>>? subscription;
  bool cancelled = false;
}
