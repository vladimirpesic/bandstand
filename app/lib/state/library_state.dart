import 'dart:async';
import 'dart:io';

import 'package:bandstand/domain/command/command.dart';
import 'package:bandstand/domain/command/undo_stack.dart';
import 'package:bandstand/domain/song/playlist.dart';
import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/domain/song/song_library_model.dart';
import 'package:bandstand/io/importers/ireal_import.dart';
import 'package:bandstand/io/importers/musicxml_import.dart';
import 'package:bandstand/io/importers/text_import.dart';
import 'package:bandstand/io/song_library.dart';
import 'package:bandstand/io/uuid.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The library on disk, opened once for the life of the app.
final songLibraryProvider = FutureProvider<SongLibrary>((ref) async {
  return SongLibrary.openDefault();
});

/// Every song's headline facts, plus anything that would not read.
///
/// Invalidated by [LibraryController] whenever the library changes, which is
/// what makes the list refresh without anybody wiring up a callback.
final libraryScanProvider = FutureProvider<LibraryScan>((ref) async {
  final library = await ref.watch(songLibraryProvider.future);
  return library.scan();
});

/// Unsaved edits found in the crash journal at startup (§5.4).
///
/// Read once when the library opens. `LibraryController.restore` and
/// `discardRecovery` invalidate it, so acting on one makes it disappear.
final pendingRecoveriesProvider = FutureProvider<List<JournalRecovery>>((
  ref,
) async {
  final library = await ref.watch(songLibraryProvider.future);
  return library.pendingRecoveries();
});

/// Every playlist.
final playlistsProvider = FutureProvider<List<Playlist>>((ref) async {
  final library = await ref.watch(songLibraryProvider.future);
  return library.loadPlaylists();
});

/// What the library screen is showing: the search box, the sort, the tag.
class LibraryView {
  /// Create a view state.
  const LibraryView({
    this.query = '',
    this.sortOrder = SongSortOrder.title,
    this.tag,
  });

  /// What is typed in the search box.
  final String query;

  /// How the list is ordered.
  final SongSortOrder sortOrder;

  /// The tag being filtered on, or null for all songs.
  final String? tag;

  /// Whether anything is filtering the list.
  bool get isFiltered => query.trim().isNotEmpty || tag != null;

  /// Apply this view to a scan's songs.
  List<SongSummary> apply(Iterable<SongSummary> songs) {
    final selected = songs.where(
      (song) => song.matches(query) && (tag == null || song.tags.contains(tag)),
    );
    return sortOrder.apply(selected);
  }

  /// A copy with some fields replaced.
  LibraryView copyWith({
    String? query,
    SongSortOrder? sortOrder,
    String? tag,
    bool clearTag = false,
  }) => LibraryView(
    query: query ?? this.query,
    sortOrder: sortOrder ?? this.sortOrder,
    tag: clearTag ? null : (tag ?? this.tag),
  );
}

/// Drives the library screen's search, sort and filter.
class LibraryViewController extends Notifier<LibraryView> {
  @override
  LibraryView build() => const LibraryView();

  /// Set the search box's contents.
  void search(String query) => state = state.copyWith(query: query);

  /// Change the sort.
  void sortBy(SongSortOrder order) => state = state.copyWith(sortOrder: order);

  /// Filter on a tag, or clear the filter by passing null.
  void filterByTag(String? tag) => state = tag == null
      ? state.copyWith(clearTag: true)
      : state.copyWith(tag: tag);

  /// Clear the search box and the tag.
  void clearFilters() => state = LibraryView(sortOrder: state.sortOrder);
}

/// The library screen's search, sort and filter.
final libraryViewProvider =
    NotifierProvider<LibraryViewController, LibraryView>(
      LibraryViewController.new,
    );

/// Creating, duplicating and deleting songs.
///
/// Every method writes through the library and then invalidates the scan, so
/// the list is never told to refresh by hand.
class LibraryController {
  /// Create a controller.
  const LibraryController(this._ref);

  final Ref _ref;

  Future<SongLibrary> get _library => _ref.read(songLibraryProvider.future);

  /// Write a new, empty song and return it.
  Future<Song> createSong({String title = 'Untitled'}) async {
    final library = await _library;
    final song = Song.blank(id: newUuid(), title: title);
    await library.saveSong(song);
    _ref.invalidate(libraryScanProvider);
    return song;
  }

  /// Save a song and refresh the list.
  Future<void> save(Song song) async {
    final library = await _library;
    await library.saveSong(song);
    _ref.invalidate(libraryScanProvider);
  }

  /// Copy a song under a new id, so the original is untouched.
  Future<Song> duplicate(String id) async {
    final library = await _library;
    final original = await library.loadSong(id);
    // `duplicatedAs` rather than an enumerated constructor call: the enumerated
    // form silently dropped `writtenParts`, so duplicating a tune threw away
    // every imported melody, and it would have dropped the next field added to
    // `Song` in exactly the same silence.
    final copy = original.duplicatedAs(
      id: newUuid(),
      title: '${original.title} (copy)',
    );
    await library.saveSong(copy);
    _ref.invalidate(libraryScanProvider);
    return copy;
  }

  /// Delete a song. Its backups stay on disk.
  Future<void> delete(String id) async {
    final library = await _library;
    await library.deleteSong(id);
    _ref.invalidate(libraryScanProvider);
  }

  /// Load one song in full.
  Future<Song> load(String id) async => (await _library).loadSong(id);

  /// Write the whole library to a zip.
  Future<File> exportArchive(File target) async =>
      (await _library).exportArchive(target);

  /// Read a library archive back.
  Future<({int songs, int playlists, int corpora, int skipped})> importArchive(
    File source, {
    bool overwrite = false,
  }) async {
    final result = await (await _library).importArchive(
      source,
      overwrite: overwrite,
    );
    _ref
      ..invalidate(libraryScanProvider)
      ..invalidate(playlistsProvider);
    return result;
  }

  /// Save a playlist and refresh the list.
  Future<void> savePlaylist(Playlist playlist) async {
    await (await _library).savePlaylist(playlist);
    _ref.invalidate(playlistsProvider);
  }

  /// Delete a playlist.
  Future<void> deletePlaylist(String id) async {
    await (await _library).deletePlaylist(id);
    _ref.invalidate(playlistsProvider);
  }

  /// Read an iReal Pro URL and save every chart in it (§5.2).
  ///
  /// Returns what was brought in, so the UI can say what happened rather than
  /// leaving the user to count the library.
  Future<IRealImportResult> importIRealUrl(String url) async {
    final library = await _library;
    final parsed = IRealImporter.parseUrl(url);
    final saved = <Song>[];
    try {
      for (final imported in parsed.songs) {
        final song = imported.toSong(newUuid());
        await library.saveSong(song);
        saved.add(song);
      }
    } finally {
      _ref.invalidate(libraryScanProvider);
    }
    return IRealImportResult(
      songs: saved,
      playlistName: parsed.name,
      problems: <ImportProblem>[
        ...parsed.problems,
        for (final imported in parsed.songs) ...imported.problems,
      ],
    );
  }

  /// Import a chart pasted or typed as text (§5.2 items 2 and 3).
  ///
  /// The format is decided by the content rather than asked for: a MusicXML
  /// document announces itself, and anything else with bar lines in it is a
  /// plain text lead sheet. Making the user say which is asking them for
  /// something the computer can see.
  Future<IRealImportResult> importText(String source) async {
    final library = await _library;
    final trimmed = source.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('there is nothing to import');
    }

    final Song song;
    final List<String> problems;
    if (_looksLikeMusicXml(trimmed)) {
      final imported = MusicXmlImporter.parse(trimmed, id: newUuid());
      song = imported.song;
      problems = imported.problems;
    } else {
      final imported = TextImporter.parse(trimmed, id: newUuid());
      song = imported.song;
      problems = imported.problems;
    }

    await library.saveSong(song);
    _ref.invalidate(libraryScanProvider);
    return IRealImportResult(
      songs: <Song>[song],
      playlistName: null,
      problems: <ImportProblem>[
        for (final problem in problems) ImportProblem(problem),
      ],
    );
  }

  /// Whether a document announces itself as MusicXML.
  static bool _looksLikeMusicXml(String source) {
    final head = source.length > 512 ? source.substring(0, 512) : source;
    return head.contains('<score-partwise') ||
        head.contains('<score-timewise') ||
        head.contains('-//Recordare//DTD MusicXML');
  }

  /// Save a journalled song, so the recovery becomes the real one.
  Future<void> restoreRecovery(Song song) async {
    final library = await _library;
    await library.saveSong(song);
    _ref
      ..invalidate(libraryScanProvider)
      ..invalidate(pendingRecoveriesProvider);
  }

  /// Throw away a journalled edit.
  Future<void> discardRecovery(String songId) async {
    final library = await _library;
    await library.clearJournal(songId);
    _ref.invalidate(pendingRecoveriesProvider);
  }

  /// Create a new, empty set.
  Future<Playlist> createPlaylist({String name = 'New set'}) async {
    final playlist = Playlist(id: newUuid(), name: name);
    await savePlaylist(playlist);
    return playlist;
  }
}

/// What an iReal Pro import brought in.
class IRealImportResult {
  /// Create a result.
  IRealImportResult({
    required List<Song> songs,
    required this.playlistName,
    required List<ImportProblem> problems,
  }) : songs = List<Song>.unmodifiable(songs),
       problems = List<ImportProblem>.unmodifiable(problems);

  /// The charts that were saved.
  final List<Song> songs;

  /// The name the URL gave its playlist, if any.
  final String? playlistName;

  /// Everything the importer could not read, across every chart.
  final List<ImportProblem> problems;

  /// Whether every chart read cleanly.
  bool get isClean => problems.isEmpty;
}

/// Creating, duplicating and deleting songs and playlists.
final libraryControllerProvider = Provider<LibraryController>(
  LibraryController.new,
);

/// The song being edited, with its undo history (§4.4).
///
/// The UI never mutates a song: it runs a [Command] through here, and the
/// history is exact because the model is immutable.
class SongEditor extends Notifier<Song?> {
  /// How often an unsaved song is written to the crash journal.
  ///
  /// Five seconds is the most work a crash can cost, and the write is a few
  /// kilobytes to a temporary file plus a rename — far too cheap to be worth
  /// tuning (§5.4).
  static const Duration journalInterval = Duration(seconds: 5);

  UndoStack<Song>? _stack;
  Timer? _journalTimer;

  @override
  Song? build() {
    ref.onDispose(_stopJournalling);
    return null;
  }

  /// Whether there is anything to undo.
  bool get canUndo => _stack?.canUndo ?? false;

  /// Whether there is anything to redo.
  bool get canRedo => _stack?.canRedo ?? false;

  /// What the next undo would reverse.
  String? get undoLabel => _stack?.undoLabel;

  /// What the next redo would repeat.
  String? get redoLabel => _stack?.redoLabel;

  /// Whether the song has changes that are not on disk.
  ///
  /// Compared against the snapshot taken at [open] or [save] rather than a
  /// flag flipped by edits, so undoing back to the saved state reads clean.
  bool get isDirty => state != _saved;
  Song? _saved;

  /// Start editing [song], forgetting any previous history.
  void open(Song song) {
    _stack = UndoStack<Song>(song);
    _saved = song;
    state = song;
    _startJournalling();
  }

  /// Stop editing.
  void close() {
    _stopJournalling();
    _stack = null;
    _saved = null;
    state = null;
  }

  void _startJournalling() {
    _journalTimer?.cancel();
    // The future is deliberately not awaited — a periodic timer has nowhere to
    // await it — which is exactly why [journal] must not throw.
    _journalTimer = Timer.periodic(
      journalInterval,
      (_) => unawaited(journal()),
    );
  }

  void _stopJournalling() {
    _journalTimer?.cancel();
    _journalTimer = null;
  }

  /// Run an edit.
  void run(Command<Song> command) {
    final stack = _stack;
    if (stack == null) {
      return;
    }
    final before = stack.value;
    final after = stack.run(command);
    if (!identical(after, before)) {
      state = after;
    }
  }

  /// Undo one edit.
  void undo() {
    final stack = _stack;
    if (stack == null || !stack.canUndo) {
      return;
    }
    state = stack.undo();
  }

  /// Redo one edit.
  void redo() {
    final stack = _stack;
    if (stack == null || !stack.canRedo) {
      return;
    }
    state = stack.redo();
  }

  /// Save the song and mark it clean.
  Future<void> save() async {
    final song = state;
    if (song == null) {
      return;
    }
    await ref.read(libraryControllerProvider).save(song);
    _saved = song;
  }

  /// Whether the journal timer is running. Tests only.
  @visibleForTesting
  bool get isJournalling => _journalTimer?.isActive ?? false;

  /// Write the current state to the crash journal.
  Future<void> journal() async {
    final song = state;
    if (song == null || !isDirty) {
      return;
    }
    try {
      final library = await ref.read(songLibraryProvider.future);
      await library.writeJournal(song);
      _lastJournalError = null;
    } on Object catch (error) {
      // §5.4 makes the journal best effort, and [_startJournalling] discards
      // the future this returns — so anything thrown here becomes an unhandled
      // async error with nobody to catch it. The folder really can go away
      // underneath the app: a removable drive unmounted, a sync client moving
      // it. Losing a crash journal is a small harm; taking the app down on
      // stage because of it is not.
      //
      // Recorded rather than swallowed, so the failure is visible to a test
      // and available to the UI.
      _lastJournalError = error.toString();
    }
  }

  /// Why the last journal write failed, or null if it worked.
  ///
  /// Cleared by the next write that succeeds.
  String? get lastJournalError => _lastJournalError;
  String? _lastJournalError;
}

/// The song being edited, with its undo history.
final songEditorProvider = NotifierProvider<SongEditor, Song?>(SongEditor.new);
