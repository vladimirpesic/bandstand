import 'dart:async';
import 'dart:io';

import 'package:bandstand/io/library/library_settings.dart';
import 'package:bandstand/io/library/manifest.dart';
import 'package:bandstand/io/library/mirror_cache.dart';
import 'package:bandstand/io/json_support.dart';
import 'package:bandstand/io/mega/mega_base64.dart';
import 'package:bandstand/io/mega/mega_client.dart';
import 'package:bandstand/io/mega/mega_crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Everything the library needs from the platform, assembled once in
/// `main()` and injected, so the controller and every test run against the
/// same real parts (`docs/rules/mega-library.md` §8).
class LibraryServices {
  /// Create the bundle. The API gateway defaults to MEGA and points at a
  /// local server in tests; one [httpClient] serves the whole stack.
  LibraryServices({
    required this.settingsFile,
    required this.defaultCacheRoot,
    http.Client? httpClient,
    Uri? megaApiBaseUri,
    this.megaRetryDelay = const Duration(seconds: 2),
  }) : httpClient = httpClient ?? http.Client(),
       _megaApiBaseUri = megaApiBaseUri ?? megaApiGateway;

  /// Build the real bundle from the platform's directories.
  static Future<LibraryServices> create() async {
    final support = await getApplicationSupportDirectory();
    final home = Directory('${support.path}/bandstand');
    await home.create(recursive: true);
    return LibraryServices(
      settingsFile: File(
        '${home.path}${Platform.pathSeparator}'
        '${LibrarySettings.fileName}',
      ),
      defaultCacheRoot: await _defaultCacheRootIn(home),
    );
  }

  /// The mirror's default home, renamed in from its 0012-era
  /// `aebersold-cache` spelling when this is the first run since — the
  /// downloaded bytes follow the name (§5.4: no silent data loss, not
  /// even by rename). A rename that cannot happen keeps using the old
  /// folder rather than re-downloading a library.
  static Future<Directory> _defaultCacheRootIn(Directory home) async {
    final root = Directory(
      '${home.path}${Platform.pathSeparator}library-cache',
    );
    if (await root.exists()) {
      return root;
    }
    final legacy = Directory(
      '${home.path}${Platform.pathSeparator}aebersold-cache',
    );
    if (!await legacy.exists()) {
      return root;
    }
    try {
      return await legacy.rename(root.path);
    } on FileSystemException {
      return legacy;
    }
  }

  /// Where the settings live — the folder link included, never anywhere
  /// more public than the app's own support directory (§7).
  final File settingsFile;

  /// The mirror's home when the user has not pointed it elsewhere.
  final Directory defaultCacheRoot;

  /// The one HTTP client the MEGA client and its downloads share.
  final http.Client httpClient;

  final Uri _megaApiBaseUri;

  /// How long the MEGA client waits between `-3` retries. Zero in tests,
  /// seconds in the app.
  final Duration megaRetryDelay;

  MegaFolderClient? _mega;
  String? _megaLinkText;

  /// The settings as they are on disk right now.
  ///
  /// Corrupt settings are the one condition worth failing loudly here —
  /// silently replacing them could throw away the pasted link and the
  /// cache root, which is exactly the §5.4 kind of loss.
  LibrarySettings _settings() => LibrarySettings.load(settingsFile);

  /// The settings, for the controller's use.
  LibrarySettings get settings => _settings();

  /// The cache root the settings ask for.
  Directory cacheRootFor(LibrarySettings settings) {
    final override = settings.cacheRootOverride;
    return override == null || override.trim().isEmpty
        ? defaultCacheRoot
        : Directory(override);
  }

  /// A cache over the root the settings ask for.
  MirrorCache cacheFor(LibrarySettings settings) =>
      MirrorCache(cacheRootFor(settings));

  /// The MEGA client for the link the settings hold. One client per link:
  /// its file-key cache is what lets a download open without re-fetching
  /// the tree (§8 — two commands, no third).
  MegaFolderClient megaFor(LibrarySettings settings) {
    final linkText = settings.megaFolderLink.trim();
    final cached = _mega;
    if (cached != null && _megaLinkText == linkText) {
      return cached;
    }
    final client = MegaFolderClient(
      MegaFolderLink.parse(linkText),
      httpClient: httpClient,
      apiBaseUri: _megaApiBaseUri,
      retryDelay: megaRetryDelay,
    );
    _mega = client;
    _megaLinkText = linkText;
    return client;
  }
}

/// What the library screen is showing, top to bottom. One sealed family so
/// the switch in the UI is exhaustive — a new phase is a compile error
/// everywhere it matters, never a silent blank.
sealed class LibraryPhase {
  const LibraryPhase();
}

/// Nothing has happened yet: the cached authorization and settings are
/// still being read.
class LibraryStarting extends LibraryPhase {
  const LibraryStarting();
}

/// No folder link yet — the first run, or the last one was forgotten.
/// [problem] is what to tell the user; empty when this is simply fresh.
class LibraryNeedsLink extends LibraryPhase {
  /// Create the phase.
  const LibraryNeedsLink({this.problem = ''});

  /// What went wrong, if anything.
  final String problem;
}

/// The first manifest is still arriving — from the disk cache or MEGA.
class LibraryLoading extends LibraryPhase {
  /// Create the phase.
  const LibraryLoading({this.fromCache = false});

  /// Whether this load is the disk's copy, which is instant, and is about
  /// to be followed by a sync.
  final bool fromCache;
}

/// The library is usable. Everything the screen shows is in here.
class LibraryReady extends LibraryPhase {
  /// Create the phase.
  const LibraryReady({
    required this.manifest,
    required this.presence,
    required this.downloads,
    required this.stats,
    this.syncing = false,
    this.notice = '',
  });

  /// The manifest, cached or fresh.
  final LibraryManifest manifest;

  /// Entry id → on-disk state, one lookup per row.
  final Map<String, CachePresence> presence;

  /// Entry id → the download in flight or the one that just failed.
  final Map<String, DownloadState> downloads;

  /// Bytes on disk, split the way the closing question asks.
  final CacheStats stats;

  /// Whether a manifest sync is running.
  final bool syncing;

  /// Something worth one line under the app bar, cleared by the next
  /// successful sync.
  final String notice;

  /// This phase with some fields replaced.
  LibraryReady copyWith({
    Map<String, CachePresence>? presence,
    Map<String, DownloadState>? downloads,
    CacheStats? stats,
    bool? syncing,
    String? notice,
  }) => LibraryReady(
    manifest: manifest,
    presence: presence ?? this.presence,
    downloads: downloads ?? this.downloads,
    stats: stats ?? this.stats,
    syncing: syncing ?? this.syncing,
    notice: notice ?? this.notice,
  );
}

/// The library cannot be reached and nothing is cached. [lastManifest] is
/// the copy still browsable, if there is one.
class LibraryError extends LibraryPhase {
  /// Create the phase.
  const LibraryError({required this.message, this.lastManifest});

  /// What went wrong, in words.
  final String message;

  /// The manifest from before the failure, when there was one.
  final LibraryManifest? lastManifest;
}

/// A download as the row needs it: going, or gone wrong.
sealed class DownloadState {
  const DownloadState();
}

/// Bytes are moving.
class Downloading extends DownloadState {
  /// Create the state.
  const Downloading(this.received, this.total);

  /// Bytes written so far.
  final int received;

  /// Total bytes when known.
  final int? total;
}

/// The last attempt failed; the message is the row's tooltip.
class DownloadFailed extends DownloadState {
  /// Create the state.
  const DownloadFailed(this.message);

  /// Why it failed.
  final String message;
}

/// The library, end to end: sign-in, folder choice, manifest sync,
/// downloads, keep/discard — every rule in `docs/rules/mega-library.md`
/// acting on the screen from one place.
class LibraryController extends Notifier<LibraryPhase> {
  @override
  LibraryPhase build() {
    unawaited(_bootstrap());
    return const LibraryStarting();
  }

  /// Downloads run one at a time (§3): one queue, chained futures.
  Future<void> _downloadQueue = Future<void>.value();

  /// The cache the download queue talks to; presence queries make their
  /// own, they are stateless reads.
  MirrorCache? _downloadCache;

  LibraryServices get _services => ref.read(libraryServicesProvider);

  Future<void> _bootstrap() async {
    // One turn past build(): a state assignment made while the provider is
    // still building is dropped, and the first run would sit on
    // "Opening the library…" forever.
    await Future<void>.delayed(Duration.zero);
    LibrarySettings settings;
    try {
      settings = _services.settings;
    } on SongFormatException catch (error) {
      state = LibraryError(message: error.message);
      return;
    }
    if (!settings.hasLink) {
      state = const LibraryNeedsLink();
      return;
    }
    await _loadLibrary();
  }

  /// Adopt a pasted folder link: parse it, prove it reads the tree, keep
  /// it, load the library against it. The link is stored and never shown
  /// again (§7).
  Future<void> linkLibrary(String pastedLink) async {
    final trimmed = pastedLink.trim();
    MegaFolderLink link;
    try {
      link = MegaFolderLink.parse(trimmed);
    } on MegaLinkException catch (error) {
      state = LibraryNeedsLink(problem: error.message);
      return;
    }
    final services = _services;
    final settings = services.settings.withLink(link.toString());
    // The link is proven before it is kept: a folder that does not list is
    // a link that was revoked, and the paste card is where that belongs.
    try {
      await services.megaFor(settings).fetchNodes();
    } on Object catch (error) {
      state = LibraryNeedsLink(problem: _describe(error));
      return;
    }
    await settings.saveTo(services.settingsFile);
    await _loadLibrary();
  }

  /// Forget the folder link. The library on disk stays exactly as it is
  /// (§7) — this is "stop reading that folder", not "delete my downloads".
  Future<void> forgetLink() async {
    final services = _services;
    final settings = services.settings.withLink('');
    await settings.saveTo(services.settingsFile);
    state = const LibraryNeedsLink();
  }

  /// Start from the disk's manifest (§4: the app opens against the cached
  /// copy), then sync with MEGA in the background.
  Future<void> _loadLibrary() async {
    final services = _services;
    final settings = services.settings;
    final cache = services.cacheFor(settings);
    _downloadCache = cache;
    await cache.ensureLayout();
    final text = await cache.loadManifestText();
    LibraryManifest? cached;
    if (text != null) {
      try {
        cached = LibraryManifestCodec.decode(text);
      } on SongFormatException {
        cached = null;
      }
    }
    if (cached == null) {
      state = const LibraryLoading();
      await _sync(cache, settings, previous: null);
      return;
    }
    await _publish(cache, cached, syncing: true);
    await _sync(cache, settings, previous: cached);
  }

  /// Re-fetch the manifest now. The app bar's refresh button.
  Future<void> refresh() async {
    final phase = state;
    if (phase is LibraryReady) {
      state = phase.copyWith(syncing: true);
      await _sync(
        _downloadCache ?? _services.cacheFor(_services.settings),
        _services.settings,
        previous: phase.manifest,
      );
    }
  }

  /// Try the whole load again from whatever the settings say. The error
  /// card's button.
  Future<void> reload() async {
    await _loadLibrary();
  }

  /// What a sweep would delete, counted and sized, for the settings
  /// dialog to describe before the user's hand confirms it (§5).
  Future<List<CacheOrphan>> findOrphans() async {
    final phase = state;
    if (phase is! LibraryReady) {
      return const <CacheOrphan>[];
    }
    final cache = _downloadCache ?? _services.cacheFor(_services.settings);
    final report = await cache.reconcile(phase.manifest, deleteOrphans: false);
    return report.orphans;
  }

  /// Delete the orphans the manifest does not claim. The settings dialog's
  /// sweep, run by the user's hand — never at startup (§5).
  Future<int> sweepOrphans() async {
    final phase = state;
    if (phase is! LibraryReady) {
      return 0;
    }
    final cache = _downloadCache ?? _services.cacheFor(_services.settings);
    final report = await cache.reconcile(phase.manifest, deleteOrphans: true);
    await _publish(cache, phase.manifest, syncing: phase.syncing);
    return report.deletedOrphans;
  }

  Future<void> _sync(
    MirrorCache cache,
    LibrarySettings settings, {
    required LibraryManifest? previous,
  }) async {
    try {
      final manifest = await LibraryManifest.fetch(_services.megaFor(settings));
      await cache.saveManifestText(LibraryManifestCodec.encode(manifest));
      await _publish(cache, manifest, syncing: false);
    } on Object catch (error) {
      final message = _describe(error);
      final phase = state;
      if (phase is LibraryReady) {
        state = phase.copyWith(
          syncing: false,
          notice:
              'Could not sync with MEGA — showing the saved library. '
              '($message)',
        );
      } else {
        state = LibraryError(message: message, lastManifest: previous);
      }
    }
  }

  /// Reconcile, then put manifest, presence and stats into one Ready phase.
  Future<void> _publish(
    MirrorCache cache,
    LibraryManifest manifest, {
    required bool syncing,
  }) async {
    final report = await cache.reconcile(manifest, deleteOrphans: false);
    final presence = await cache.presenceOfAll(manifest);
    final stats = await cache.stats(manifest);
    final carried = state is LibraryReady
        ? (state as LibraryReady).downloads
        : const <String, DownloadState>{};
    state = LibraryReady(
      manifest: manifest,
      presence: presence,
      downloads: carried,
      stats: stats,
      syncing: syncing,
      notice: _noticeOf(report),
    );
  }

  /// Queue a download; one at a time, presence refreshed when it lands.
  void download(
    LibraryVolume volume,
    LibraryEntry entry, {
    required bool saved,
  }) {
    _downloadQueue = _downloadQueue.then(
      (_) => _downloadOne(volume, entry, saved),
    );
  }

  /// Queue every missing entry of a volume — the volume screen's
  /// "download" button.
  void downloadVolume(LibraryVolume volume, {required bool saved}) {
    final phase = state;
    if (phase is! LibraryReady) {
      return;
    }
    for (final entry in volume.entries) {
      final running = phase.downloads[entry.id];
      final here = phase.presence[entry.id] ?? CachePresence.absent;
      if (here == CachePresence.absent && running is! Downloading) {
        download(volume, entry, saved: saved);
      }
    }
  }

  /// Stop the entry's download. Safe when none is going.
  void cancelDownload(String entryId) => _downloadCache?.cancel(entryId);

  Future<void> _downloadOne(
    LibraryVolume volume,
    LibraryEntry entry,
    bool saved,
  ) async {
    final cache = _downloadCache ??= _services.cacheFor(_services.settings);
    _setDownload(entry.id, Downloading(0, _totalOf(entry, null)));
    var lastEmit = DateTime.now();
    try {
      final mega = _services.megaFor(_services.settings);
      await cache.download(
        volume,
        entry,
        saved: saved,
        open: () async {
          final file = await mega.openFile(entry.id);
          return MirrorDownload(
            contentLength: file.sizeBytes,
            bytes: file.plaintext,
            checksum: _MetaMacChecksum(file.mac),
          );
        },
        onProgress: (received, total) {
          final now = DateTime.now();
          final finished = total != null && received >= total;
          if (!finished &&
              now.difference(lastEmit) < const Duration(milliseconds: 200)) {
            return;
          }
          lastEmit = now;
          _setDownload(entry.id, Downloading(received, total));
        },
      );
      _clearDownload(entry.id);
      await _refreshEntry(cache, volume, entry);
    } on DownloadCancelledException {
      _clearDownload(entry.id);
    } on Object catch (error) {
      _setDownload(entry.id, DownloadFailed(_describe(error)));
    }
  }

  /// Promote a session file to saved, or demote a saved one to session.
  Future<void> toggleSaved(LibraryVolume volume, LibraryEntry entry) async {
    final cache = _downloadCache ?? _services.cacheFor(_services.settings);
    final here = await cache.presence(volume, entry);
    if (here == CachePresence.saved) {
      await cache.markSession(volume, entry);
    } else if (here == CachePresence.session) {
      await cache.markSaved(volume, entry);
    }
    await _refreshEntry(cache, volume, entry);
  }

  /// Delete the entry's file from the device.
  Future<void> remove(LibraryVolume volume, LibraryEntry entry) async {
    final cache = _downloadCache ?? _services.cacheFor(_services.settings);
    await cache.remove(volume, entry);
    _clearDownload(entry.id);
    await _refreshEntry(cache, volume, entry);
  }

  /// What the closing question is about: how many session files, how many
  /// bytes (§6).
  Future<({int count, int bytes})> sessionSummary() async {
    final phase = state;
    if (phase is! LibraryReady) {
      return (count: 0, bytes: 0);
    }
    final cache = _downloadCache ?? _services.cacheFor(_services.settings);
    final entries = await cache.sessionEntries(phase.manifest);
    return (
      count: entries.length,
      bytes: entries.fold<int>(0, (sum, pair) => sum + pair.$2.sizeBytes),
    );
  }

  /// The "keep" half of the closing question: every session file flagged
  /// saved (§6).
  Future<void> keepAllSessionFiles() async {
    final phase = state;
    if (phase is LibraryReady) {
      final cache = _downloadCache ?? _services.cacheFor(_services.settings);
      await cache.keepAllSessions(phase.manifest);
      await _publish(cache, phase.manifest, syncing: phase.syncing);
    }
  }

  /// The "discard" half: every session file deleted (§6).
  Future<void> discardAllSessionFiles() async {
    final phase = state;
    if (phase is LibraryReady) {
      final cache = _downloadCache ?? _services.cacheFor(_services.settings);
      await cache.discardAllSessions(phase.manifest);
      await _publish(cache, phase.manifest, syncing: phase.syncing);
    }
  }

  /// Point the mirror somewhere else — the desktop's answer to an 11 GB
  /// library on a small disk. The old mirror is left exactly where it was;
  /// nothing moves, the new root starts empty (§2: one root at a time).
  /// Returns the problem, or null when the new root is in force.
  Future<String?> applyCacheRootOverride(String? rawPath) async {
    if (Platform.isAndroid) {
      return 'On Android the library lives in the app\u2019s own storage; '
          'there is nothing to choose.';
    }
    final trimmed = rawPath?.trim() ?? '';
    final override = trimmed.isEmpty ? null : trimmed;
    if (override != null &&
        FileSystemEntity.typeSync(override) != FileSystemEntityType.directory) {
      return '\u201c$override\u201d is not a folder that exists.';
    }
    final services = _services;
    final settings = services.settings.withCacheRootOverride(override);
    await settings.saveTo(services.settingsFile);
    await _loadLibrary();
    return null;
  }

  /// Where the mirror currently lives, for the settings dialog to show.
  String cacheRootDescription() =>
      _services.cacheRootFor(_services.settings).path;

  /// Where a downloaded entry lives on disk — the path the player loads.
  ///
  /// The mirrored-path mapping is the cache's rule (§5 of the library
  /// rule), so it is asked for through here rather than re-derived beside
  /// every call site.
  File localFileFor(LibraryVolume volume, LibraryEntry entry) =>
      (_downloadCache ?? _services.cacheFor(_services.settings)).entryFile(
        volume,
        entry,
      );

  Future<void> _refreshEntry(
    MirrorCache cache,
    LibraryVolume volume,
    LibraryEntry entry,
  ) async {
    final phase = state;
    if (phase is! LibraryReady) {
      return;
    }
    final presence = Map<String, CachePresence>.of(phase.presence);
    presence[entry.id] = await cache.presence(volume, entry);
    state = phase.copyWith(
      presence: presence,
      stats: await cache.stats(phase.manifest),
    );
  }

  void _setDownload(String entryId, DownloadState value) {
    final phase = state;
    if (phase is! LibraryReady) {
      return;
    }
    final downloads = Map<String, DownloadState>.of(phase.downloads);
    downloads[entryId] = value;
    state = phase.copyWith(downloads: downloads);
  }

  void _clearDownload(String entryId) {
    final phase = state;
    if (phase is! LibraryReady) {
      return;
    }
    final downloads = Map<String, DownloadState>.of(phase.downloads);
    downloads.remove(entryId);
    state = phase.copyWith(downloads: downloads);
  }

  int? _totalOf(LibraryEntry entry, int? declared) =>
      declared ?? (entry.sizeBytes > 0 ? entry.sizeBytes : null);

  static String _noticeOf(ReconcileReport report) {
    if (report.isQuiet) {
      return '';
    }
    final parts = <String>[];
    if (report.moved.isNotEmpty) {
      parts.add(
        '${report.moved.length} file(s) followed the MEGA side '
        'to a new place',
      );
    }
    if (report.droppedFlags.isNotEmpty) {
      parts.add(
        '${report.droppedFlags.length} download(s) were not on '
        'disk any more and will need fetching again',
      );
    }
    if (report.adoptedAsSession.isNotEmpty) {
      parts.add(
        '${report.adoptedAsSession.length} file(s) recovered from '
        'an interrupted run, flagged session',
      );
    }
    if (report.deletedParts > 0) {
      parts.add('${report.deletedParts} partial download(s) cleaned up');
    }
    if (report.orphans.isNotEmpty) {
      final bytes = report.orphans.fold<int>(0, (sum, o) => sum + o.sizeBytes);
      parts.add(
        '${report.orphans.length} file(s) from an older library '
        'are taking ${describeBytes(bytes)} — the sweep in Settings '
        'removes them',
      );
    }
    return parts.join('; ');
  }

  /// Bytes the way a person reads them on a store shelf.
  static String describeBytes(int bytes) {
    const unit = 1024;
    const names = <String>['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var name = 0;
    while (value >= unit && name < names.length - 1) {
      value /= unit;
      name++;
    }
    return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${names[name]}';
  }

  static String _describe(Object error) => switch (error) {
    MegaApiException error => error.message,
    MegaLinkException error => error.message,
    ChecksumMismatchException error => error.toString(),
    SocketException error => 'the network said no: ${error.message}',
    HttpException error => 'the transfer broke: ${error.message}',
    TimeoutException error => 'the network was too slow: ${error.message}',
    FileSystemException error => 'the disk said no: ${error.message}',
    _ => error.toString(),
  };
}

/// A download's checksum: the MEGA chunk-MAC chain, finished as the
/// base64 meta-MAC the manifest records.
class _MetaMacChecksum implements ByteChecksum {
  const _MetaMacChecksum(this._mac);

  final MegaChunkMac _mac;

  @override
  void add(List<int> bytes) => _mac.add(bytes);

  @override
  String finish() => megaBase64Encode(_mac.condense());
}

/// The services, assembled in `main()` and overridden into the scope; every
/// test builds its own against temp directories and local servers.
final libraryServicesProvider = Provider<LibraryServices>((ref) {
  throw StateError(
    'LibraryServices must be created in main() and overridden into the '
    'scope',
  );
});

/// The library's state.
final libraryProvider = NotifierProvider<LibraryController, LibraryPhase>(
  LibraryController.new,
);
