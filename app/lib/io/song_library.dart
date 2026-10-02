import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:bandstand/domain/generation/bass/bass_corpus_codec.dart';
import 'package:bandstand/domain/song/playlist.dart';
import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/domain/song/song_library_model.dart';
import 'package:path_provider/path_provider.dart';

import 'json_support.dart';
import 'playlist_json.dart';
import 'song_json.dart';
import 'uuid.dart';

/// How many past versions of a song are kept.
const int backupsPerSong = 12;

/// How long a backup is kept, unless it is the newest.
const Duration backupMaxAge = Duration(days: 90);

/// The library folder's name inside the user's music directory.
const String libraryFolderName = 'Bandstand';

/// Extension of a song file.
const String songExtension = '.song.json';

/// Extension of a playlist file.
const String playlistExtension = '.playlist.json';

/// Thrown when the library folder itself cannot be opened.
///
/// Distinct from a song that will not read: this is "there is nowhere to keep
/// anything", and the library screen says so rather than showing an empty list.
class SongLibraryUnavailable implements Exception {
  /// Create the exception.
  const SongLibraryUnavailable(this.reason);

  /// Why the folder could not be opened.
  final String reason;

  @override
  String toString() => 'The library folder could not be opened: $reason';
}

/// Thrown when the library is asked to write while in reading mode.
class ReadOnlyLibraryException implements Exception {
  /// Create the exception.
  const ReadOnlyLibraryException(this.what);

  /// What was attempted.
  final String what;

  @override
  String toString() =>
      'The library is read-only in reading mode; cannot $what.';
}

/// A song that could not be read, and what happened next.
class LoadFailure {
  /// Create a failure report.
  const LoadFailure(this.id, this.reason, {this.recoveredFromBackup});

  /// Which song.
  final String id;

  /// Why the file would not read.
  final String reason;

  /// The backup that was used instead, or null if nothing worked.
  final String? recoveredFromBackup;

  /// Whether the song was recovered.
  bool get recovered => recoveredFromBackup != null;

  @override
  String toString() => recovered
      ? '$id: $reason — recovered from $recoveredFromBackup'
      : '$id: $reason — not recovered';
}

/// What a library scan found.
class LibraryScan {
  /// Create a scan result.
  LibraryScan({
    required List<SongSummary> songs,
    required List<LoadFailure> failures,
  }) : songs = List<SongSummary>.unmodifiable(songs),
       failures = List<LoadFailure>.unmodifiable(failures);

  /// The songs that could be read.
  final List<SongSummary> songs;

  /// The songs that could not, and what was done about it.
  final List<LoadFailure> failures;

  /// Whether everything read cleanly.
  bool get isClean => failures.isEmpty;
}

/// A song recovered from the journal after a crash.
class JournalRecovery {
  /// Create a recovery offer.
  const JournalRecovery(this.song, this.journalModified, this.savedModified);

  /// The song as the journal has it.
  final Song song;

  /// When the journal was written.
  final DateTime journalModified;

  /// When the saved song was last written, or null if it was never saved.
  final DateTime? savedModified;

  @override
  String toString() => 'unsaved changes to "${song.title}"';
}

/// The song and playlist library on disk (§5.1, §5.4).
///
/// Rules: `docs/rules/library-data-safety.md`. Every write is atomic, every
/// overwrite is backed up, every load falls back to a backup rather than
/// showing an empty library.
class SongLibrary {
  /// Create a library rooted at [root].
  SongLibrary(this.root, {this.readOnly = false});

  /// Open the library in the user's music folder, creating it if needed.
  ///
  /// `~/Music/Bandstand` on Linux and macOS, the platform's documents folder
  /// elsewhere. The folder is user-visible on purpose (§5.1).
  static Future<SongLibrary> openDefault({bool readOnly = false}) async {
    final base = await _defaultRoot();
    final library = SongLibrary(
      Directory('${base.path}${Platform.pathSeparator}$libraryFolderName'),
      readOnly: readOnly,
    );
    await library.ensureLayout();
    return library;
  }

  static Future<Directory> _defaultRoot() async {
    if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
      final music = await getApplicationDocumentsDirectory();
      final home =
          Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
      if (home != null) {
        final candidate = Directory('$home${Platform.pathSeparator}Music');
        if (candidate.existsSync()) {
          return candidate;
        }
      }
      return music;
    }
    return getApplicationDocumentsDirectory();
  }

  /// The library folder.
  final Directory root;

  /// Whether writing is forbidden — reading mode on stage (§5.4).
  final bool readOnly;

  /// Where songs live.
  Directory get songsDirectory => _sub('songs');

  /// Where playlists live.
  Directory get playlistsDirectory => _sub('playlists');

  /// Where past versions live.
  Directory get backupsDirectory => _sub('.backups');

  /// Where in-progress edits live.
  Directory get journalDirectory => _sub('.journal');

  /// Where phrase corpora live (§6.4).
  Directory get corporaDirectory => _sub(_corporaDirectoryName);

  /// The corpora directory's name, which is also how [importArchive]
  /// recognises a corpus inside an archive.
  static const String _corporaDirectoryName = 'corpora';

  /// Where soundbanks live.
  Directory get soundbanksDirectory => _sub('soundbanks');

  /// Where bounced audio lives.
  Directory get rendersDirectory => _sub('renders');

  Directory _sub(String name) =>
      Directory('${root.path}${Platform.pathSeparator}$name');

  /// Create the folders the library needs.
  Future<void> ensureLayout() async {
    for (final directory in <Directory>[
      root,
      songsDirectory,
      playlistsDirectory,
      backupsDirectory,
      journalDirectory,
      corporaDirectory,
      soundbanksDirectory,
      rendersDirectory,
    ]) {
      await directory.create(recursive: true);
    }
  }

  /// The file a song with this id lives in.
  ///
  /// Throws [ArgumentError] if the id is not one this app generated — the
  /// library never builds a path out of arbitrary text.
  File songFile(String id) {
    _checkId(id);
    return File(
      '${songsDirectory.path}${Platform.pathSeparator}$id$songExtension',
    );
  }

  /// The file a playlist with this id lives in.
  File playlistFile(String id) {
    _checkId(id);
    return File(
      '${playlistsDirectory.path}${Platform.pathSeparator}$id$playlistExtension',
    );
  }

  /// Every song's headline facts, read without building any charts.
  ///
  /// A song that will not parse is retried from its backups; whatever happens
  /// is reported in [LibraryScan.failures] rather than silently dropped.
  Future<LibraryScan> scan() async {
    final summaries = <SongSummary>[];
    final failures = <LoadFailure>[];
    if (!songsDirectory.existsSync()) {
      return LibraryScan(songs: summaries, failures: failures);
    }

    final files = songsDirectory
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith(songExtension))
        .toList();

    for (final file in files) {
      final id = _idOf(file.path, songExtension);
      if (id == null) {
        continue;
      }
      try {
        summaries.add(SongJson.decodeSummary(await file.readAsString()));
      } on Object catch (error) {
        final recovered = await _recoverSummary(id);
        if (recovered != null) {
          summaries.add(recovered.$1);
          failures.add(
            LoadFailure(
              id,
              _describe(error),
              recoveredFromBackup: recovered.$2,
            ),
          );
        } else {
          failures.add(LoadFailure(id, _describe(error)));
        }
      }
    }

    summaries.sort();
    return LibraryScan(songs: summaries, failures: failures);
  }

  /// Load a song, falling back to its newest readable backup.
  ///
  /// Throws [SongFormatException] only when neither the song nor any backup can
  /// be read.
  Future<Song> loadSong(String id) async {
    final file = songFile(id);
    if (file.existsSync()) {
      try {
        return SongJson.decode(await file.readAsString());
      } on Object catch (error) {
        final recovered = await _recoverSong(id);
        if (recovered != null) {
          return recovered.$1;
        }
        throw SongFormatException(
          'could not read "$id": ${_describe(error)}, and no backup would read '
          'either',
        );
      }
    }
    final recovered = await _recoverSong(id);
    if (recovered != null) {
      return recovered.$1;
    }
    throw SongFormatException('there is no song "$id" in the library');
  }

  /// Save a song: atomically, with a backup of what it replaces.
  ///
  /// Throws [ReadOnlyLibraryException] in reading mode.
  Future<void> saveSong(Song song) async {
    _checkWritable('save "${song.title}"');
    final file = songFile(song.id);
    await _backupIfPresent(file, song.id);
    await _writeAtomically(file, SongJson.encode(song));
    await clearJournal(song.id);
  }

  /// Delete a song. Its backups are kept — deleting is not the same as losing.
  ///
  /// Throws [ReadOnlyLibraryException] in reading mode.
  Future<void> deleteSong(String id) async {
    _checkWritable('delete "$id"');
    final file = songFile(id);
    if (file.existsSync()) {
      await _backupIfPresent(file, id);
      await file.delete();
    }
    await clearJournal(id);
  }

  /// Every playlist, sorted by name.
  Future<List<Playlist>> loadPlaylists() async {
    if (!playlistsDirectory.existsSync()) {
      return const <Playlist>[];
    }
    final playlists = <Playlist>[];
    for (final file in playlistsDirectory.listSync().whereType<File>().where(
      (file) => file.path.endsWith(playlistExtension),
    )) {
      try {
        playlists.add(PlaylistJson.decode(await file.readAsString()));
      } on Object {
        // A broken playlist must not hide the working ones; the file stays on
        // disk for the user to look at.
        continue;
      }
    }
    playlists.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    return playlists;
  }

  /// Load one playlist.
  ///
  /// Throws [SongFormatException] if it is missing or malformed.
  Future<Playlist> loadPlaylist(String id) async {
    final file = playlistFile(id);
    if (!file.existsSync()) {
      throw SongFormatException('there is no playlist "$id" in the library');
    }
    return PlaylistJson.decode(await file.readAsString());
  }

  /// Save a playlist atomically.
  ///
  /// Throws [ReadOnlyLibraryException] in reading mode.
  Future<void> savePlaylist(Playlist playlist) async {
    _checkWritable('save the set "${playlist.name}"');
    await _writeAtomically(
      playlistFile(playlist.id),
      PlaylistJson.encode(playlist),
    );
  }

  /// Delete a playlist.
  ///
  /// Throws [ReadOnlyLibraryException] in reading mode.
  Future<void> deletePlaylist(String id) async {
    _checkWritable('delete the set "$id"');
    final file = playlistFile(id);
    if (file.existsSync()) {
      await file.delete();
    }
  }

  // --- the journal ----------------------------------------------------------

  /// Write the song being edited to the journal, so a crash costs seconds.
  ///
  /// Silently does nothing in reading mode: reading mode has no edits to
  /// journal, and throwing here would turn a stage gesture into a crash.
  Future<void> writeJournal(Song song) async {
    if (readOnly) {
      return;
    }
    _checkId(song.id);
    await journalDirectory.create(recursive: true);
    await _writeAtomically(_journalFile(song.id), SongJson.encode(song));
  }

  /// Forget the journal for a song.
  Future<void> clearJournal(String id) async {
    if (readOnly) {
      return;
    }
    final file = _journalFile(id);
    if (file.existsSync()) {
      await file.delete();
    }
  }

  /// Every journalled song that is newer than what was saved.
  ///
  /// A journal that will not parse is deleted rather than offered: a crash that
  /// corrupted the journal must not also break startup.
  Future<List<JournalRecovery>> pendingRecoveries() async {
    if (!journalDirectory.existsSync()) {
      return const <JournalRecovery>[];
    }
    final recoveries = <JournalRecovery>[];
    for (final file in journalDirectory.listSync().whereType<File>().where(
      (file) => file.path.endsWith(songExtension),
    )) {
      final id = _idOf(file.path, songExtension);
      if (id == null) {
        continue;
      }
      Song journalled;
      try {
        journalled = SongJson.decode(await file.readAsString());
      } on Object {
        if (!readOnly) {
          await file.delete();
        }
        continue;
      }
      DateTime? savedAt;
      final saved = songFile(id);
      if (saved.existsSync()) {
        try {
          savedAt = SongJson.decodeSummary(await saved.readAsString())
              .modifiedAt;
        } on Object {
          savedAt = null;
        }
      }
      if (savedAt == null || journalled.modifiedAt.isAfter(savedAt)) {
        recoveries.add(
          JournalRecovery(journalled, journalled.modifiedAt, savedAt),
        );
      } else if (!readOnly) {
        await file.delete();
      }
    }
    return recoveries;
  }

  File _journalFile(String id) => File(
    '${journalDirectory.path}${Platform.pathSeparator}$id$songExtension',
  );

  // --- archive --------------------------------------------------------------

  /// Write the whole library to a zip: disaster recovery, and how you move to a
  /// new machine (§5.4).
  ///
  /// Backups, the journal and bounced audio are left out: the first two are
  /// recovery scaffolding, and the third is regenerable and large.
  Future<File> exportArchive(File target) async {
    final encoder = ZipFileEncoder()..create(target.path);
    try {
      for (final directory in <Directory>[
        songsDirectory,
        playlistsDirectory,
        corporaDirectory,
      ]) {
        if (directory.existsSync()) {
          await encoder.addDirectory(directory);
        }
      }
    } finally {
      await encoder.close();
    }
    return target;
  }

  /// Read a library archive back, returning how many songs and playlists it
  /// brought in.
  ///
  /// Existing files are kept unless [overwrite] is set: an import that silently
  /// replaced the library would be the very disaster the archive exists for.
  ///
  /// Throws [ReadOnlyLibraryException] in reading mode.
  Future<({int songs, int playlists, int corpora, int skipped})> importArchive(
    File source, {
    bool overwrite = false,
  }) async {
    _checkWritable('import "${source.path}"');
    await ensureLayout();
    final archive = ZipDecoder().decodeBytes(await source.readAsBytes());
    var songs = 0;
    var playlists = 0;
    var corpora = 0;
    var skipped = 0;

    for (final entry in archive) {
      if (!entry.isFile) {
        continue;
      }
      final segments = entry.name.split('/');
      final name = segments.last;
      final isSong = name.endsWith(songExtension);
      final isPlaylist = name.endsWith(playlistExtension);
      // Corpora are plain JSON with no distinguishing extension, so they are
      // recognised by the directory they were exported from.
      // `exportArchive` has always written them into the archive and this
      // read them back as "not a song, not a playlist" and dropped them —
      // silently, and not even counted as skipped. Exporting a library and
      // restoring it lost every phrase corpus, on the one path that exists
      // for exactly that disaster.
      final isCorpus =
          !isSong &&
          !isPlaylist &&
          name.toLowerCase().endsWith('.json') &&
          segments.length > 1 &&
          segments[segments.length - 2] == _corporaDirectoryName;
      if (!isSong && !isPlaylist && !isCorpus) {
        continue;
      }
      final content = utf8.decode(
        entry.content as List<int>,
        allowMalformed: true,
      );

      final File target;
      if (isCorpus) {
        try {
          BassCorpusCodec.decode(content);
        } on Object {
          skipped++;
          continue;
        }
        target = File('${corporaDirectory.path}${Platform.pathSeparator}$name');
      } else {
        final id = _idOf(name, isSong ? songExtension : playlistExtension);
        if (id == null) {
          skipped++;
          continue;
        }
        try {
          if (isSong) {
            SongJson.decode(content);
          } else {
            PlaylistJson.decode(content);
          }
        } on Object {
          skipped++;
          continue;
        }
        target = isSong ? songFile(id) : playlistFile(id);
      }

      if (target.existsSync() && !overwrite) {
        skipped++;
        continue;
      }
      await _writeAtomically(target, content);
      if (isSong) {
        songs++;
      } else if (isPlaylist) {
        playlists++;
      } else {
        corpora++;
      }
    }
    return (
      songs: songs,
      playlists: playlists,
      corpora: corpora,
      skipped: skipped,
    );
  }

  // --- the plumbing ---------------------------------------------------------

  /// Write [content] to [file] without ever leaving it half-written.
  Future<void> _writeAtomically(File file, String content) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    final handle = temporary.openWrite();
    handle.write(content);
    await handle.flush();
    await handle.close();
    await temporary.rename(file.path);
  }

  Future<void> _backupIfPresent(File file, String id) async {
    if (!file.existsSync()) {
      return;
    }
    final directory = Directory(
      '${backupsDirectory.path}${Platform.pathSeparator}$id',
    );
    await directory.create(recursive: true);
    final now = DateTime.now().toUtc();
    String two(int value) => value.toString().padLeft(2, '0');
    // Fixed-width down to the microsecond (L-TQ10): `toIso8601String` omits
    // the subseconds when there are none, and the prune below picks the
    // newest backup by sorting these names as text — a name that stops at
    // the second cannot stand in the right place among a second's worth.
    final subsecond = (now.millisecond * 1000 + now.microsecond)
        .toString()
        .padLeft(6, '0');
    final stamp =
        '${now.year}-${two(now.month)}-${two(now.day)}'
        'T${two(now.hour)}-${two(now.minute)}-${two(now.second)}'
        '.$subsecond';
    await file.copy(
      '${directory.path}${Platform.pathSeparator}$stamp$songExtension',
    );
    await _pruneBackups(directory);
  }

  Future<void> _pruneBackups(Directory directory) async {
    final backups =
        directory
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith(songExtension))
            .toList()
          ..sort((a, b) => b.path.compareTo(a.path));
    final now = DateTime.now();
    for (var i = 0; i < backups.length; i++) {
      // The newest is always kept, whatever its age.
      if (i == 0) {
        continue;
      }
      final tooMany = i >= backupsPerSong;
      final tooOld =
          now.difference(backups[i].statSync().modified) > backupMaxAge;
      if (tooMany || tooOld) {
        await backups[i].delete();
      }
    }
  }

  List<File> _backupsOf(String id) {
    final directory = Directory(
      '${backupsDirectory.path}${Platform.pathSeparator}$id',
    );
    if (!directory.existsSync()) {
      return const <File>[];
    }
    return directory
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith(songExtension))
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path));
  }

  Future<(Song, String)?> _recoverSong(String id) async {
    for (final backup in _backupsOf(id)) {
      try {
        return (
          SongJson.decode(await backup.readAsString()),
          backup.uri.pathSegments.last,
        );
      } on Object {
        continue;
      }
    }
    return null;
  }

  Future<(SongSummary, String)?> _recoverSummary(String id) async {
    for (final backup in _backupsOf(id)) {
      try {
        return (
          SongJson.decodeSummary(await backup.readAsString()),
          backup.uri.pathSegments.last,
        );
      } on Object {
        continue;
      }
    }
    return null;
  }

  void _checkWritable(String what) {
    if (readOnly) {
      throw ReadOnlyLibraryException(what);
    }
  }

  static void _checkId(String id) {
    if (!isUuid(id)) {
      throw ArgumentError.value(
        id,
        'id',
        'the library only opens files it named itself',
      );
    }
  }

  static String? _idOf(String path, String extension) {
    final name = path.split(Platform.pathSeparator).last.split('/').last;
    if (!name.endsWith(extension)) {
      return null;
    }
    final id = name.substring(0, name.length - extension.length);
    return isUuid(id) ? id : null;
  }

  static String _describe(Object error) =>
      error is SongFormatException ? error.message : error.toString();
}
