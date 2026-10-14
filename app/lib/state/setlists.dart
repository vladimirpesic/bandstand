import 'dart:async';
import 'dart:io';

import 'package:bandstand/io/json_support.dart';
import 'package:bandstand/io/library/manifest.dart';
import 'package:bandstand/io/library/mirror_cache.dart';
import 'package:bandstand/io/library/setlists.dart';
import 'package:bandstand/state/library.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The user's setlists: [Setlists] loaded from the support directory,
/// every change written straight back, and every change answering a
/// dialog with the problem when it cannot happen — null means it did.
///
/// "Favorites" lives here only as a derivation of the library: see
/// [favoritesOf].
class SetlistsController extends Notifier<Setlists> {
  @override
  Setlists build() {
    _loading = _load();
    unawaited(_loading);
    return const Setlists();
  }

  /// The file's first answer, so a change made before it arrives waits
  /// for it rather than writing over a file nobody has read.
  Future<void>? _loading;

  File get _file => ref.read(libraryServicesProvider).setlistsFile;

  Future<void> _load() async {
    // One turn past build(): a state assignment made while the provider
    // is still building is dropped — the same dance as the library's.
    await Future<void>.delayed(Duration.zero);
    try {
      state = Setlists.load(_file);
    } on JsonFormatException catch (error) {
      state = Setlists(problem: error.message);
    }
  }

  /// Why [candidate] cannot be a setlist name right now; null when it
  /// can. For dialogs, live as the field is typed.
  String? nameProblem(String candidate, {String? exceptId}) =>
      state.problemWithName(candidate, exceptId: exceptId);

  /// Wait for the file, then say why a change cannot happen — null
  /// when it can.
  Future<String?> _guard() async {
    await _loading;
    final problem = state.problem;
    return problem == null
        ? null
        : 'The setlists file cannot be read: $problem';
  }

  Future<String?> _save() async {
    try {
      await state.saveTo(_file);
      return null;
    } on FileSystemException catch (error) {
      return 'Could not save the setlists: ${error.message}';
    }
  }

  /// Make a setlist, with [entryId]'s track as its first member when the
  /// add-to-setlist sheet is where the name came from.
  Future<String?> create(String name, {String? entryId}) async {
    final blocked = await _guard();
    if (blocked != null) {
      return blocked;
    }
    final trimmed = name.trim();
    final problem = state.problemWithName(trimmed);
    if (problem != null) {
      return problem;
    }
    var created = Setlist.named(trimmed);
    if (entryId != null) {
      created = created.withEntryAdded(entryId);
    }
    state = state.withSetlist(created);
    return _save();
  }

  /// Rename one setlist. The id, and every member, stays.
  Future<String?> rename(String setlistId, String name) async {
    final blocked = await _guard();
    if (blocked != null) {
      return blocked;
    }
    final setlist = state.byId(setlistId);
    if (setlist == null) {
      return 'That setlist is already gone.';
    }
    final trimmed = name.trim();
    final problem = state.problemWithName(trimmed, exceptId: setlistId);
    if (problem != null) {
      return problem;
    }
    state = state.withSetlist(
      Setlist(id: setlistId, name: trimmed, entryIds: setlist.entryIds),
    );
    return _save();
  }

  /// Delete one setlist — the list, never the tracks it points at.
  Future<void> delete(String setlistId) async {
    await _loading;
    if (!state.isWritable) {
      return;
    }
    state = state.withoutSetlist(setlistId);
    await _save();
  }

  /// Add a track to a setlist. A duplicate is refused, not merged.
  Future<String?> addEntry(String setlistId, String entryId) async {
    final blocked = await _guard();
    if (blocked != null) {
      return blocked;
    }
    final setlist = state.byId(setlistId);
    if (setlist == null) {
      return 'That setlist is already gone.';
    }
    if (setlist.contains(entryId)) {
      return '"${setlist.name}" already has that tune.';
    }
    state = state.withSetlist(setlist.withEntryAdded(entryId));
    return _save();
  }

  /// Take a track out of a setlist — the list loses a reference, the
  /// library keeps the file.
  Future<void> removeEntry(String setlistId, String entryId) async {
    await _loading;
    if (!state.isWritable) {
      return;
    }
    final setlist = state.byId(setlistId);
    if (setlist == null) {
      return;
    }
    state = state.withSetlist(setlist.withEntryRemoved(entryId));
    await _save();
  }
}

/// "Favorites" is not a stored setlist; it is every bookmarked track,
/// live — the saved flag the bookmark toggles is the membership, so the
/// two can never disagree and one tune can never appear twice. Library
/// order: volumes as the manifest lists them, tracks as the volume does.
List<(LibraryVolume, LibraryEntry)> favoritesOf(LibraryReady phase) =>
    <(LibraryVolume, LibraryEntry)>[
      for (final volume in phase.manifest.allVolumes)
        for (final entry in volume.entries)
          if (entry.kind == LibraryEntryKind.track &&
              phase.presence[entry.id] == CachePresence.saved)
            (volume, entry),
    ];

/// The setlists' state.
final setlistsProvider = NotifierProvider<SetlistsController, Setlists>(
  SetlistsController.new,
);
