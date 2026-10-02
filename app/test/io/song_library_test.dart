import 'dart:io';

import 'package:bandstand/domain/generation/bass/bass_corpus.dart';
import 'package:bandstand/domain/generation/bass/bass_corpus_codec.dart';
import 'package:bandstand/domain/generation/bass/root_profile.dart';
import 'package:bandstand/domain/generation/bass/wbp_source.dart';
import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:bandstand/domain/song/chord_leadsheet.dart';
import 'package:bandstand/domain/song/lead_sheet_item.dart';
import 'package:bandstand/domain/song/playlist.dart';
import 'package:bandstand/domain/song/section.dart';
import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/domain/song/song_library_model.dart';
import 'package:bandstand/domain/song/song_structure.dart';
import 'package:bandstand/io/json_support.dart';
import 'package:bandstand/io/song_json.dart';
import 'package:bandstand/io/song_library.dart';
import 'package:bandstand/io/uuid.dart';
import 'package:flutter_test/flutter_test.dart';

import '../domain/harmony/harmony_test_support.dart';

void main() {
  installTestHarmony();

  late Directory root;
  late SongLibrary library;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('bandstand-library-test');
    library = SongLibrary(root);
    await library.ensureLayout();
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  Song makeSong({String? id, String title = 'Tune', int tempo = 120}) {
    final songId = id ?? newUuid();
    final sheet = ChordLeadSheet(
      barCount: 8,
      items: <LeadSheetItem>[
        CliSection(Section(name: 'A', startBar: 0)),
        CliChordSymbol(Position(0), ExtChordSymbol.parse('Cmaj7')),
        CliChordSymbol(Position(4), ExtChordSymbol.parse('Dm7')),
      ],
    );
    return Song(
      id: songId,
      title: title,
      leadSheet: sheet,
      structure: SongStructure.fromLeadSheet(sheet, rhythmId: 'swing'),
      tempo: tempo,
    );
  }

  group('the folder', () {
    test('is laid out as §5.1 describes', () async {
      expect(library.songsDirectory.existsSync(), isTrue);
      expect(library.playlistsDirectory.existsSync(), isTrue);
      expect(library.backupsDirectory.existsSync(), isTrue);
      expect(library.journalDirectory.existsSync(), isTrue);
      expect(library.corporaDirectory.existsSync(), isTrue);
      expect(library.soundbanksDirectory.existsSync(), isTrue);
      expect(library.rendersDirectory.existsSync(), isTrue);
    });

    test('only opens files it named itself', () {
      expect(() => library.songFile('../../etc/passwd'), throwsArgumentError);
      expect(() => library.songFile('not-a-uuid'), throwsArgumentError);
      expect(() => library.playlistFile('..'), throwsArgumentError);
      expect(library.songFile(newUuid()).path, endsWith(songExtension));
    });
  });

  group('saving and loading', () {
    test('a song round-trips through the disk', () async {
      final song = makeSong(title: 'Blue Bossa');
      await library.saveSong(song);
      final loaded = await library.loadSong(song.id);
      expect(loaded, song);
    });

    test('writes are atomic — no .tmp survives a save', () async {
      final song = makeSong();
      await library.saveSong(song);
      final strays = library.songsDirectory.listSync().where(
        (entity) => entity.path.endsWith('.tmp'),
      );
      expect(strays, isEmpty);
    });

    test('a missing song is reported, not invented', () async {
      expect(
        () => library.loadSong(newUuid()),
        throwsA(isA<SongFormatException>()),
      );
    });

    test('create, save, load and reorder 100 songs — §10 M2', () async {
      final songs = <Song>[
        for (var i = 0; i < 100; i++)
          makeSong(
            title: 'Tune ${i.toString().padLeft(3, '0')}',
            tempo: 60 + i,
          ),
      ];
      for (final song in songs) {
        await library.saveSong(song);
      }

      final scan = await library.scan();
      expect(scan.songs, hasLength(100));
      expect(scan.isClean, isTrue);

      // The scan reads headline facts only, and gets them right.
      final byId = <String, SongSummary>{
        for (final summary in scan.songs) summary.id: summary,
      };
      for (final song in songs) {
        expect(byId[song.id]!.title, song.title);
        expect(byId[song.id]!.tempo, song.tempo);
        expect(byId[song.id]!.barCount, 8);
      }

      // Reordering is a view concern, and every order is available.
      expect(SongSortOrder.title.apply(scan.songs).first.title, 'Tune 000');
      expect(SongSortOrder.tempo.apply(scan.songs).last.tempo, 159);
      expect(SongSortOrder.recentlyModified.apply(scan.songs), hasLength(100));

      // And every one of them loads in full.
      for (final song in songs) {
        expect(await library.loadSong(song.id), song);
      }
    });

    test('search matches title, composer and tags', () async {
      final summary = SongSummary.of(
        makeSong(
          title: 'Blue Monk',
        ).copyWith(composer: 'Thelonious Monk', tags: const <String>{'blues'}),
      );
      expect(summary.matches(''), isTrue);
      expect(summary.matches('monk'), isTrue);
      expect(summary.matches('blue monk'), isTrue);
      expect(summary.matches('thelonious blue'), isTrue);
      expect(summary.matches('blues'), isTrue);
      expect(summary.matches('coltrane'), isFalse);
      expect(summary.matches('blue coltrane'), isFalse);
    });
  });

  group('backups', () {
    test('the version being replaced is kept', () async {
      final song = makeSong(title: 'First');
      await library.saveSong(song);
      await library.saveSong(song.copyWith(title: 'Second'));

      final backups = Directory('${library.backupsDirectory.path}/${song.id}')
          .listSync()
          .whereType<File>()
          .toList();
      expect(backups, hasLength(1));
      expect(SongJson.decode(backups.single.readAsStringSync()).title, 'First');
      expect((await library.loadSong(song.id)).title, 'Second');
    });

    test(
      'a first save backs nothing up — there is nothing to preserve',
      () async {
        final song = makeSong();
        await library.saveSong(song);
        final directory = Directory(
          '${library.backupsDirectory.path}/${song.id}',
        );
        expect(directory.existsSync(), isFalse);
      },
    );

    test('old versions are pruned, and the newest is always kept', () async {
      final song = makeSong();
      for (var i = 0; i <= backupsPerSong + 4; i++) {
        await library.saveSong(song.copyWith(title: 'Take $i'));
      }
      final backups = Directory('${library.backupsDirectory.path}/${song.id}')
          .listSync()
          .whereType<File>()
          .toList();
      expect(backups.length, lessThanOrEqualTo(backupsPerSong));
      expect(backups, isNotEmpty);

      // The newest backup is the latest take the last save replaced — the
      // final take itself is never in a backup, because backing up happens
      // before the overwrite.
      final newest = backups..sort((a, b) => b.path.compareTo(a.path));
      expect(
        SongJson.decode(newest.first.readAsStringSync()).title,
        'Take ${backupsPerSong + 3}',
      );
    });

    test('a corrupt song is recovered from its backup, and says so', () async {
      final song = makeSong(title: 'Recoverable');
      await library.saveSong(song);
      await library.saveSong(song.copyWith(title: 'Newer'));
      library.songFile(song.id).writeAsStringSync('{ this is not json');

      final loaded = await library.loadSong(song.id);
      expect(loaded.title, 'Recoverable');

      final scan = await library.scan();
      expect(scan.songs, hasLength(1));
      expect(scan.failures, hasLength(1));
      expect(scan.failures.single.recovered, isTrue);
      expect(scan.failures.single.id, song.id);
    });

    test('a song with no readable backup is reported, not hidden', () async {
      final song = makeSong();
      await library.saveSong(song);
      library.songFile(song.id).writeAsStringSync('rubbish');
      final scan = await library.scan();
      expect(scan.songs, isEmpty);
      expect(scan.failures, hasLength(1));
      expect(scan.failures.single.recovered, isFalse);
      expect(
        () => library.loadSong(song.id),
        throwsA(isA<SongFormatException>()),
      );
    });

    test('deleting keeps the backups — deleting is not losing', () async {
      final song = makeSong();
      await library.saveSong(song);
      await library.deleteSong(song.id);
      expect(library.songFile(song.id).existsSync(), isFalse);
      expect(
        Directory('${library.backupsDirectory.path}/${song.id}').existsSync(),
        isTrue,
      );
    });
  });

  group('the journal', () {
    test('an unsaved edit is offered back after a crash', () async {
      final song = makeSong(title: 'Saved');
      await library.saveSong(song);
      await library.writeJournal(
        song.copyWith(
          title: 'Edited but not saved',
          modifiedAt: song.modifiedAt.add(const Duration(minutes: 5)),
        ),
      );

      final pending = await library.pendingRecoveries();
      expect(pending, hasLength(1));
      expect(pending.single.song.title, 'Edited but not saved');
      expect(pending.single.savedModified, isNotNull);
    });

    test('a journal older than the saved song is dropped', () async {
      // Saved first, journalled second with an *older* timestamp: the journal
      // loses to the song on disk and is removed, not offered back.
      final song = makeSong(title: 'Saved');
      await library.saveSong(song);
      await library.writeJournal(
        song.copyWith(
          title: 'An older take',
          modifiedAt: song.modifiedAt.subtract(const Duration(minutes: 5)),
        ),
      );

      expect(await library.pendingRecoveries(), isEmpty);
      expect(
        File('${library.journalDirectory.path}/${song.id}$songExtension')
            .existsSync(),
        isFalse,
      );
    });

    test('a journal for a song that was never saved is offered', () async {
      final song = makeSong(title: 'Never saved');
      await library.writeJournal(song);
      final pending = await library.pendingRecoveries();
      expect(pending, hasLength(1));
      expect(pending.single.savedModified, isNull);
    });

    test('a corrupt journal is deleted, not offered', () async {
      final id = newUuid();
      File('${library.journalDirectory.path}/$id$songExtension')
          .writeAsStringSync('half a file');
      expect(await library.pendingRecoveries(), isEmpty);
      expect(
        File('${library.journalDirectory.path}/$id$songExtension').existsSync(),
        isFalse,
      );
    });
  });

  group('playlists', () {
    test('round-trip through the disk', () async {
      final playlist = Playlist(
        id: newUuid(),
        name: 'Friday',
        entries: <PlaylistEntry>[PlaylistEntry(songId: newUuid())],
      );
      await library.savePlaylist(playlist);
      expect(await library.loadPlaylist(playlist.id), playlist);
      expect(await library.loadPlaylists(), <Playlist>[playlist]);
      await library.deletePlaylist(playlist.id);
      expect(await library.loadPlaylists(), isEmpty);
    });

    test('a broken playlist does not hide the working ones', () async {
      final good = Playlist(id: newUuid(), name: 'Good');
      await library.savePlaylist(good);
      File('${library.playlistsDirectory.path}/${newUuid()}$playlistExtension')
          .writeAsStringSync('not json');
      final loaded = await library.loadPlaylists();
      expect(loaded, <Playlist>[good]);
    });
  });

  group('reading mode is read-only — §5.4', () {
    test('every write is refused', () async {
      final song = makeSong();
      await library.saveSong(song);
      final stage = SongLibrary(root, readOnly: true);

      expect(
        () => stage.saveSong(song),
        throwsA(isA<ReadOnlyLibraryException>()),
      );
      expect(
        () => stage.deleteSong(song.id),
        throwsA(isA<ReadOnlyLibraryException>()),
      );
      expect(
        () => stage.savePlaylist(Playlist(id: newUuid(), name: 'x')),
        throwsA(isA<ReadOnlyLibraryException>()),
      );
      expect(
        () => stage.importArchive(File('${root.path}/nothing.zip')),
        throwsA(isA<ReadOnlyLibraryException>()),
      );
    });

    test('reading still works, and journalling quietly does nothing', () async {
      final song = makeSong(title: 'On stage');
      await library.saveSong(song);
      final stage = SongLibrary(root, readOnly: true);
      expect((await stage.loadSong(song.id)).title, 'On stage');
      await stage.writeJournal(song);
      expect(
        File('${stage.journalDirectory.path}/${song.id}$songExtension')
            .existsSync(),
        isFalse,
      );
    });
  });

  group('the whole-library archive — §5.4', () {
    test('a phrase corpus survives the round trip', () async {
      // §5.4's disaster-recovery path. `exportArchive` has always written the
      // corpora directory into the zip, and `importArchive` accepted only
      // songs and playlists — so every corpus was dropped on the way back in,
      // without a warning and without even being counted as skipped. Export
      // your library, restore it, and your corpora were gone.
      await library.saveSong(makeSong(title: 'One'));
      final corpus = File(
        '${library.corporaDirectory.path}${Platform.pathSeparator}'
        'my-take.json',
      );
      final source = BassCorpusCodec.encode(
        BassCorpus(
          name: 'my-take',
          phrases: <WbpSource>[
            WbpSource(
              name: 'a phrase',
              harmony: <BassChordSpan>[
                BassChordSpan(0, 4, ExtChordSymbol.parse('Dm7')),
              ],
              notes: <BassNoteSpec>[
                BassNoteSpec(beat: 0, pitch: 38, durationBeats: 1),
                BassNoteSpec(beat: 1, pitch: 41, durationBeats: 1),
              ],
            ),
          ],
        ),
      );
      corpus.writeAsStringSync(source);

      final archive = File('${root.path}/library.zip');
      await library.exportArchive(archive);

      final other = Directory.systemTemp.createTempSync('bandstand-corpora');
      addTearDown(() => other.deleteSync(recursive: true));
      final target = SongLibrary(other);
      await target.ensureLayout();

      final result = await target.importArchive(archive);
      expect(result.corpora, 1);
      expect(result.skipped, 0);

      final restored = File(
        '${target.corporaDirectory.path}${Platform.pathSeparator}'
        'my-take.json',
      );
      expect(restored.existsSync(), isTrue);
      expect(
        BassCorpusCodec.decode(restored.readAsStringSync()).phrases.single.name,
        'a phrase',
      );
    });

    test('a corrupt corpus is skipped and counted, not written', () async {
      await library.saveSong(makeSong(title: 'One'));
      File('${library.corporaDirectory.path}${Platform.pathSeparator}bad.json')
          .writeAsStringSync('{ not a corpus');

      final archive = File('${root.path}/library.zip');
      await library.exportArchive(archive);

      final other = Directory.systemTemp.createTempSync('bandstand-corpora');
      addTearDown(() => other.deleteSync(recursive: true));
      final target = SongLibrary(other);
      await target.ensureLayout();

      final result = await target.importArchive(archive);
      expect(result.corpora, 0);
      expect(result.skipped, 1);
      expect(
        File('${target.corporaDirectory.path}${Platform.pathSeparator}bad.json')
            .existsSync(),
        isFalse,
      );
    });

    test('exports and imports songs and playlists', () async {
      final songs = <Song>[
        makeSong(title: 'One'),
        makeSong(title: 'Two'),
        makeSong(title: 'Three'),
      ];
      for (final song in songs) {
        await library.saveSong(song);
      }
      final playlist = Playlist(id: newUuid(), name: 'Set');
      await library.savePlaylist(playlist);

      final archive = File('${root.path}/library.zip');
      await library.exportArchive(archive);
      expect(archive.existsSync(), isTrue);
      expect(archive.lengthSync(), greaterThan(0));

      final other = Directory.systemTemp.createTempSync('bandstand-import');
      addTearDown(() => other.deleteSync(recursive: true));
      final target = SongLibrary(other);
      await target.ensureLayout();

      final result = await target.importArchive(archive);
      expect(result.songs, 3);
      expect(result.playlists, 1);
      expect(result.skipped, 0);

      final scan = await target.scan();
      expect(scan.songs.map((s) => s.title).toList()..sort(), <String>[
        'One',
        'Three',
        'Two',
      ]);
      expect((await target.loadPlaylists()).single.name, 'Set');
    });

    test('an import does not overwrite unless told to', () async {
      final song = makeSong(title: 'Original');
      await library.saveSong(song);
      final archive = File('${root.path}/library.zip');
      await library.exportArchive(archive);

      await library.saveSong(song.copyWith(title: 'Changed since'));
      final kept = await library.importArchive(archive);
      expect(kept.songs, 0);
      expect(kept.skipped, 1);
      expect((await library.loadSong(song.id)).title, 'Changed since');

      final replaced = await library.importArchive(archive, overwrite: true);
      expect(replaced.songs, 1);
      expect((await library.loadSong(song.id)).title, 'Original');
    });

    test('a corrupt entry in an archive is skipped, not imported', () async {
      final song = makeSong();
      await library.saveSong(song);
      library.songFile(song.id).writeAsStringSync('not a song');
      final archive = File('${root.path}/library.zip');
      await library.exportArchive(archive);

      final other = Directory.systemTemp.createTempSync('bandstand-import2');
      addTearDown(() => other.deleteSync(recursive: true));
      final target = SongLibrary(other);
      await target.ensureLayout();
      final result = await target.importArchive(archive);
      expect(result.songs, 0);
      expect(result.skipped, 1);
    });
  });
}
