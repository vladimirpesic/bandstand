import 'dart:io';

import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:bandstand/domain/song/chord_leadsheet.dart';
import 'package:bandstand/domain/song/lead_sheet_item.dart';
import 'package:bandstand/domain/song/playlist.dart';
import 'package:bandstand/domain/song/section.dart';
import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/domain/song/song_commands.dart';
import 'package:bandstand/domain/song/song_library_model.dart';
import 'package:bandstand/domain/song/song_structure.dart';
import 'package:bandstand/domain/song/written_part.dart';
import 'package:bandstand/io/song_library.dart';
import 'package:bandstand/io/uuid.dart';
import 'package:bandstand/state/library_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../domain/harmony/harmony_test_support.dart';

/// What the controller and the editor do to the disk.
///
/// Plain `test`, not `testWidgets`: real file I/O and a fake-async zone do not
/// mix, and none of this needs a widget tree. The screens' own behaviour is
/// covered by `test/ui/library_screen_test.dart`.
void main() {
  installTestHarmony();

  late Directory root;
  late SongLibrary library;
  late ProviderContainer container;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('bandstand-controller-test');
    library = SongLibrary(root);
    await library.ensureLayout();
    container = ProviderContainer(
      overrides: [songLibraryProvider.overrideWith((ref) async => library)],
    );
  });

  tearDown(() {
    container.dispose();
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  LibraryController controller() => container.read(libraryControllerProvider);

  Future<List<SongSummary>> songs() async =>
      (await container.read(libraryScanProvider.future)).songs;

  /// A tune with a written melody on it.
  ///
  /// The melody is not decoration: every song built here goes through the
  /// library's save, load, duplicate and archive paths, and a song with no
  /// written parts cannot tell whether those paths carry them. `duplicate()`
  /// dropped written parts for exactly as long as this helper left them out.
  Song tune(String title) {
    final sheet = ChordLeadSheet(
      barCount: 8,
      items: <LeadSheetItem>[
        CliSection(Section(name: 'A', startBar: 0)),
        CliChordSymbol(Position(0), ExtChordSymbol.parse('Cmaj7')),
      ],
    );
    return Song(
      id: newUuid(),
      title: title,
      leadSheet: sheet,
      structure: SongStructure.fromLeadSheet(sheet, rhythmId: 'swing'),
      writtenParts: <WrittenPart>[
        WrittenPart(
          id: 'melody',
          displayName: 'Melody',
          notes: <WrittenNote>[
            WrittenNote(bar: 0, beat: 0, key: 72, durationBeats: 2),
            WrittenNote(bar: 1, beat: 2, key: 74, durationBeats: 1),
          ],
        ),
      ],
    );
  }

  group('creating and removing songs', () {
    test('a new song is written and appears in the scan', () async {
      final created = await controller().createSong(title: 'Fresh');
      expect(library.songFile(created.id).existsSync(), isTrue);
      expect((await songs()).map((s) => s.title), contains('Fresh'));
    });

    test('the scan refreshes without anybody asking it to', () async {
      expect(await songs(), isEmpty);
      await controller().createSong(title: 'One');
      expect(await songs(), hasLength(1));
      await controller().createSong(title: 'Two');
      expect(await songs(), hasLength(2));
    });

    test(
      'duplicating leaves the original alone and renames the copy',
      () async {
        final original = tune('Original');
        await controller().save(original);
        final copy = await controller().duplicate(original.id);

        expect(copy.id, isNot(original.id));
        expect(copy.title, 'Original (copy)');
        expect(copy.leadSheet, original.leadSheet);
        expect((await library.loadSong(original.id)).title, 'Original');
        expect(await songs(), hasLength(2));
      },
    );

    test('a duplicate carries every field but the id and the title', () async {
      // The copy used to be built by naming each field, and `writtenParts` was
      // not among them: duplicating a tune with an imported melody produced a
      // melody-less copy and said nothing. Asserting the whole song rather
      // than a field list means the next field added to `Song` is covered
      // here without anyone remembering to add it.
      final original = tune('Original');
      await controller().save(original);
      final copy = await controller().duplicate(original.id);

      expect(copy.writtenParts, original.writtenParts);
      expect(copy.writtenParts, isNotEmpty);
      expect(
        copy.copyWith(
          id: original.id,
          title: original.title,
          createdAt: original.createdAt,
          modifiedAt: original.modifiedAt,
        ),
        original,
      );
    });

    test('a duplicate survives the round trip to disk', () async {
      // The copy is saved by `duplicate()` itself, so a field that the copy
      // carries but the codec drops would still lose the melody.
      final original = tune('Original');
      await controller().save(original);
      final copy = await controller().duplicate(original.id);
      expect(await library.loadSong(copy.id), copy);
    });

    test('deleting removes it from the list but keeps the backups', () async {
      final song = tune('Doomed');
      await controller().save(song);
      await controller().delete(song.id);

      expect(await songs(), isEmpty);
      expect(library.songFile(song.id).existsSync(), isFalse);
      expect(
        Directory('${library.backupsDirectory.path}/${song.id}').existsSync(),
        isTrue,
      );
    });

    test('loading brings back exactly what was saved', () async {
      final song = tune('Round trip');
      await controller().save(song);
      expect(await controller().load(song.id), song);
    });
  });

  group('the song editor', () {
    test(
      'runs commands and tracks whether there is anything to undo',
      () async {
        final editor = container.read(songEditorProvider.notifier);
        final song = tune('Editable');
        editor.open(song);

        expect(container.read(songEditorProvider), song);
        expect(editor.canUndo, isFalse);
        expect(editor.isDirty, isFalse);

        editor.run(SongCommands.setTempo(200));
        expect(container.read(songEditorProvider)!.tempo, 200);
        expect(editor.canUndo, isTrue);
        expect(editor.isDirty, isTrue);
        expect(editor.undoLabel, 'Set tempo');

        editor.undo();
        expect(container.read(songEditorProvider)!.tempo, song.tempo);
        expect(editor.canRedo, isTrue);

        editor.redo();
        expect(container.read(songEditorProvider)!.tempo, 200);
      },
    );

    test('an edit to a song nobody opened does nothing', () {
      final editor = container.read(songEditorProvider.notifier)
        ..run(SongCommands.setTempo(200))
        ..undo()
        ..redo();
      expect(container.read(songEditorProvider), isNull);
      expect(editor.canUndo, isFalse);
    });

    test('saving writes the edited song and marks it clean', () async {
      final editor = container.read(songEditorProvider.notifier);
      final song = tune('To save');
      await controller().save(song);
      editor
        ..open(song)
        ..run(SongCommands.setTitle('Renamed'))
        ..run(SongCommands.setTempo(96));
      expect(editor.isDirty, isTrue);

      await editor.save();
      expect(editor.isDirty, isFalse);

      final reloaded = await library.loadSong(song.id);
      expect(reloaded.title, 'Renamed');
      expect(reloaded.tempo, 96);
      expect((await songs()).single.title, 'Renamed');
    });

    test('closing forgets the song and its history', () {
      final editor = container.read(songEditorProvider.notifier)
        ..open(tune('Open'))
        ..run(SongCommands.setTempo(200))
        ..close();
      expect(container.read(songEditorProvider), isNull);
      expect(editor.canUndo, isFalse);
      expect(editor.isDirty, isFalse);
    });

    test(
      'opening a second song does not inherit the first one history',
      () async {
        final editor = container.read(songEditorProvider.notifier)
          ..open(tune('First'))
          ..run(SongCommands.setTempo(200))
          ..open(tune('Second'));
        expect(editor.canUndo, isFalse);
        expect(container.read(songEditorProvider)!.title, 'Second');
      },
    );

    test('undo and redo track the dirty flag against the saved song', () {
      final editor = container.read(songEditorProvider.notifier);
      editor
        ..open(tune('Dirty check'))
        ..run(SongCommands.setTempo(200));
      expect(editor.isDirty, isTrue);

      editor.undo();
      expect(editor.isDirty, isFalse);

      editor.redo();
      expect(editor.isDirty, isTrue);
    });

    test(
      'the journal captures an unsaved edit and survives a reopen',
      () async {
        final editor = container.read(songEditorProvider.notifier);
        final song = tune('Journalled');
        await controller().save(song);
        editor
          ..open(song)
          ..run(SongCommands.setTitle('Edited, never saved'));
        await editor.journal();

        final pending = await library.pendingRecoveries();
        expect(pending, hasLength(1));
        expect(pending.single.song.title, 'Edited, never saved');
        expect((await library.loadSong(song.id)).title, 'Journalled');
      },
    );

    test(
      'a clean song is not journalled — there is nothing to recover',
      () async {
        final song = tune('Clean');
        await controller().save(song);
        container.read(songEditorProvider.notifier).open(song);
        await container.read(songEditorProvider.notifier).journal();
        expect(await library.pendingRecoveries(), isEmpty);
      },
    );

    test('saving clears the journal', () async {
      final editor = container.read(songEditorProvider.notifier);
      final song = tune('Journalled then saved');
      await controller().save(song);
      editor
        ..open(song)
        ..run(SongCommands.setTempo(180));
      await editor.journal();
      expect(await library.pendingRecoveries(), hasLength(1));

      await editor.save();
      expect(await library.pendingRecoveries(), isEmpty);
    });
  });

  group('crash recovery', () {
    test('the editor journals on a timer while a song is dirty', () async {
      final editor = container.read(songEditorProvider.notifier);
      final song = tune('Ticking');
      await controller().save(song);

      editor.open(song);
      expect(editor.isJournalling, isTrue);
      editor.run(SongCommands.setTempo(180));

      // Rather than wait five seconds, drive the same call the timer makes.
      await editor.journal();
      final pending = await container.read(pendingRecoveriesProvider.future);
      expect(pending, hasLength(1));
      expect(pending.single.song.tempo, 180);

      editor.close();
      expect(editor.isJournalling, isFalse);
    });

    test('a journal that cannot be written does not take the app down', () async {
      // §5.4 makes the journal best effort, and the timer that drives it
      // discards the future it returns — so anything thrown here would land as
      // an unhandled async error with no one to catch it. The library folder
      // really can go away underneath the app: a removable drive unmounted, a
      // sync client moving it, or, in the integration suite, a temp directory
      // deleted by a tearDown while a previous test's timer is still alive.
      final editor = container.read(songEditorProvider.notifier);
      final song = tune('Doomed');
      await controller().save(song);
      editor
        ..open(song)
        ..run(SongCommands.setTitle('Edited, never saved'));

      // A plain file where the journal directory belongs, so creating it
      // fails. Deleting the folder is not enough — `writeJournal` recreates it,
      // which is the right behaviour and was worth finding out by testing it.
      library.journalDirectory.deleteSync(recursive: true);
      File(library.journalDirectory.path).writeAsStringSync('in the way');

      await expectLater(editor.journal(), completes);
      expect(
        editor.lastJournalError,
        isNotNull,
        reason: 'the failure is recorded rather than swallowed',
      );
    });

    test('a journal that succeeds clears an earlier failure', () async {
      final editor = container.read(songEditorProvider.notifier);
      final song = tune('Recovering');
      await controller().save(song);
      editor
        ..open(song)
        ..run(SongCommands.setTempo(180));

      library.journalDirectory.deleteSync(recursive: true);
      final blocker = File(library.journalDirectory.path)
        ..writeAsStringSync('in the way');
      await editor.journal();
      expect(editor.lastJournalError, isNotNull);

      blocker.deleteSync();
      await editor.journal();
      expect(editor.lastJournalError, isNull);
      expect(await library.pendingRecoveries(), hasLength(1));
    });

    test('restoring makes the journalled version the real one', () async {
      final editor = container.read(songEditorProvider.notifier);
      final song = tune('Interrupted');
      await controller().save(song);
      editor
        ..open(song)
        ..run(SongCommands.setTitle('Rescued'));
      await editor.journal();

      final pending = await container.read(pendingRecoveriesProvider.future);
      await controller().restoreRecovery(pending.single.song);

      expect((await library.loadSong(song.id)).title, 'Rescued');
      expect(await container.read(pendingRecoveriesProvider.future), isEmpty);
      expect((await songs()).single.title, 'Rescued');
    });

    test('discarding leaves the saved song alone', () async {
      final editor = container.read(songEditorProvider.notifier);
      final song = tune('Keep the saved one');
      await controller().save(song);
      editor
        ..open(song)
        ..run(SongCommands.setTitle('Throw this away'));
      await editor.journal();

      await controller().discardRecovery(song.id);
      expect(await container.read(pendingRecoveriesProvider.future), isEmpty);
      expect((await library.loadSong(song.id)).title, 'Keep the saved one');
    });

    test('nothing to recover is the ordinary case', () async {
      await controller().save(tune('Saved and quiet'));
      expect(await container.read(pendingRecoveriesProvider.future), isEmpty);
    });
  });

  group('playlists', () {
    test('creating one shows up in the list', () async {
      final created = await controller().createPlaylist(name: 'Friday');
      final all = await container.read(playlistsProvider.future);
      expect(all.single.id, created.id);
      expect(all.single.name, 'Friday');
    });

    test('saving and deleting refresh the list', () async {
      final playlist = await controller().createPlaylist(name: 'Set one');
      await controller().savePlaylist(
        playlist.withEntryAppended(PlaylistEntry(songId: newUuid())),
      );
      expect((await container.read(playlistsProvider.future)).single.length, 1);

      await controller().deletePlaylist(playlist.id);
      expect(await container.read(playlistsProvider.future), isEmpty);
    });
  });

  group('the whole-library archive', () {
    test('exports and imports through the controller', () async {
      await controller().save(tune('One'));
      await controller().save(tune('Two'));
      await controller().createPlaylist(name: 'Set');

      final archive = File('${root.path}/library.zip');
      await controller().exportArchive(archive);
      expect(archive.existsSync(), isTrue);

      final elsewhere = Directory.systemTemp.createTempSync(
        'bandstand-controller-import',
      );
      addTearDown(() => elsewhere.deleteSync(recursive: true));
      final target = SongLibrary(elsewhere);
      await target.ensureLayout();
      final other = ProviderContainer(
        overrides: [songLibraryProvider.overrideWith((ref) async => target)],
      );
      addTearDown(other.dispose);

      final result = await other
          .read(libraryControllerProvider)
          .importArchive(archive);
      expect(result.songs, 2);
      expect(result.playlists, 1);
      expect(
        (await other.read(libraryScanProvider.future)).songs,
        hasLength(2),
      );
    });
  });

  group('the library view', () {
    test('search, sort and tag filter compose', () {
      final view = container.read(libraryViewProvider.notifier);
      final all = <SongSummary>[
        SongSummary(
          id: 'a',
          title: 'Blue Monk',
          composer: 'Monk',
          tempo: 100,
          keyName: 'Bb',
          barCount: 12,
          tags: const <String>{'blues'},
          modifiedAt: DateTime.utc(2026),
        ),
        SongSummary(
          id: 'b',
          title: 'Autumn Leaves',
          composer: 'Kosma',
          tempo: 140,
          keyName: 'Gm',
          barCount: 32,
          tags: const <String>{'standard'},
          modifiedAt: DateTime.utc(2026, 2),
        ),
      ];

      expect(container.read(libraryViewProvider).apply(all), hasLength(2));

      view.search('monk');
      expect(
        container.read(libraryViewProvider).apply(all).single.title,
        'Blue Monk',
      );

      view
        ..search('')
        ..filterByTag('standard');
      expect(
        container.read(libraryViewProvider).apply(all).single.title,
        'Autumn Leaves',
      );
      expect(container.read(libraryViewProvider).isFiltered, isTrue);

      view.clearFilters();
      expect(container.read(libraryViewProvider).apply(all), hasLength(2));
      expect(container.read(libraryViewProvider).isFiltered, isFalse);

      view.sortBy(SongSortOrder.tempo);
      expect(
        container.read(libraryViewProvider).apply(all).first.title,
        'Blue Monk',
      );
    });
  });

  group('importing', () {
    test('a failed import still refreshes the scan', () async {
      // The library that loses the second save. Real I/O failure injection
      // (a read-only directory) depends on the user the tests run as; a
      // subclass is exact about which call fails.
      final flaky = _FailSecondSaveLibrary(root);
      final flakyContainer = ProviderContainer(
        overrides: [songLibraryProvider.overrideWith((ref) async => flaky)],
      );
      addTearDown(flakyContainer.dispose);

      // Read the scan first so the provider caches it. The regression this
      // guards is the refresh being skipped on the failure path, which would
      // leave this cache stale.
      expect(
        (await flakyContainer.read(libraryScanProvider.future)).songs,
        isEmpty,
      );

      const url =
          'irealbook://One=A B=Swing=C=n=|C |'
          '===Two=C D=Swing=F=n=|F |';
      await expectLater(
        flakyContainer.read(libraryControllerProvider).importIRealUrl(url),
        throwsA(isA<FileSystemException>()),
      );

      // The first song reached disk before the second save failed; the scan
      // must show it rather than the stale pre-import cache.
      final titles = (await flakyContainer.read(libraryScanProvider.future))
          .songs
          .map((s) => s.title);
      expect(titles, <String>['One']);
    });
  });
}

/// Saves the first song, then fails — standing in for a disk that fills up
/// halfway through a multi-tune import.
class _FailSecondSaveLibrary extends SongLibrary {
  _FailSecondSaveLibrary(super.root);

  int _saves = 0;

  @override
  Future<void> saveSong(Song song) async {
    _saves += 1;
    if (_saves == 2) {
      throw const FileSystemException('no space left on device');
    }
    await super.saveSong(song);
  }
}
