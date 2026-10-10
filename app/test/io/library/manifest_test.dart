import 'dart:typed_data';

import 'package:bandstand/io/library/manifest.dart';
import 'package:bandstand/io/json_support.dart';
import 'package:bandstand/io/mega/mega_base64.dart';
import 'package:bandstand/io/mega/mega_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../mega/fake_mega.dart';

void main() {
  test('the manifest is the decrypted tree, in canonical order', () async {
    final mega = await FakeMega(
      tree: <String, Map<String, Uint8List>>{
        '002_nothing_but_the_blues': <String, Uint8List>{
          '002_second.mp3': Uint8List(10),
        },
        '001_how_to_play': <String, Uint8List>{
          '002_b_track.wav': Uint8List(20),
          '001_a_track.wav': Uint8List(30),
          'book.pdf': Uint8List(5),
          'notes.txt': Uint8List(3),
        },
      },
    ).start();
    addTearDown(mega.close);

    final client = MegaFolderClient(
      MegaFolderLink.parse(mega.linkText),
      httpClient: http.Client(),
      apiBaseUri: mega.apiBaseUri,
      retryDelay: Duration.zero,
    );
    final manifest = await LibraryManifest.fetch(client);

    expect(manifest.rootId, mega.internalRootHandle);
    expect(manifest.rootName, 'jamey_aebersold');
    expect(manifest.volumes, hasLength(2));
    final first = manifest.volumes[0];
    expect(first.name, '001_how_to_play');
    expect(first.volumeNumber, 1);
    expect(first.displayName, 'How To Play');
    expect(first.entries.map((e) => e.name), <String>[
      '001_a_track.wav',
      '002_b_track.wav',
      'book.pdf',
      'notes.txt',
    ]);
    expect(first.tracks, hasLength(2));
    final track = first.entries.first;
    expect(track.trackNumber, 1);
    expect(track.kind, LibraryEntryKind.track);
    // The checksum a download is verified against: the file's meta-MAC,
    // base64 — never empty for a real tree.
    expect(track.checksum, isNotEmpty);
    expect(track.checksum, hasLength(11));
    expect(first.book?.kind, LibraryEntryKind.book);
    expect(
      first.entries.lastWhere((e) => e.name == 'notes.txt').kind,
      LibraryEntryKind.other,
    );
    expect(manifest.allEntries, hasLength(5));
    expect(manifest.entryById(track.id)?.$2.name, '001_a_track.wav');
  });

  test(
    'a link to a folder wrapping the library still finds the volumes',
    () async {
      final mega = await FakeMega(
        wrapper: 'jamey_aebersold',
        tree: <String, Map<String, Uint8List>>{
          '001_how_to_play': <String, Uint8List>{
            '001_a_track.wav': Uint8List(30),
            'book.pdf': Uint8List(5),
          },
          '002_nothing_but_the_blues': <String, Uint8List>{
            '001_minor_blues.mp3': Uint8List(20),
          },
        },
      ).start();
      addTearDown(mega.close);

      final client = MegaFolderClient(
        MegaFolderLink.parse(mega.linkText),
        httpClient: http.Client(),
        apiBaseUri: mega.apiBaseUri,
        retryDelay: Duration.zero,
      );
      final manifest = await LibraryManifest.fetch(client);
      expect(manifest.volumes, hasLength(2));
      expect(manifest.volumes[0].name, '001_how_to_play');
      expect(manifest.volumes[0].entries, hasLength(2));
      // The wrapper's decrypted name is the library's.
      expect(manifest.rootName, 'jamey_aebersold');
      expect(manifest.allEntries, hasLength(3));
    },
  );

  test('the codec round-trips, byte for byte', () {
    final entry = LibraryEntry(
      id: 'f1000000000000000',
      name: '001_a_track.wav',
      kind: LibraryEntryKind.track,
      sizeBytes: 30,
      checksum: 'kEyVaLuE000A',
      modifiedUtc: DateTime.utc(2023, 11, 14, 22, 13, 20),
    );
    final volume = LibraryVolume(
      id: 'd0000000000000000',
      name: '001_how_to_play',
      entries: <LibraryEntry>[entry],
    );
    final manifest = LibraryManifest(
      rootId: 'r0000000000000000',
      rootName: 'jamey_aebersold',
      generatedUtc: DateTime.utc(2026, 10, 9),
      volumes: <LibraryVolume>[volume],
    );
    final decoded = LibraryManifestCodec.decode(
      LibraryManifestCodec.encode(manifest),
    );
    expect(decoded, manifest);
  });

  test('a malformed manifest fails naming the field', () {
    expect(
      () => LibraryManifestCodec.decode(
        '{"rootId":"r","rootName":"n","generated":"2026-01-01T00:00:00Z",'
        '"volumes":[{"id":"d","name":"v","entries":[{"id":"f","name":"x",'
        '"kind":"track","size":1,"md5":"abc","modified":"2026-01-01"}]}]}',
      ),
      throwsA(
        isA<SongFormatException>().having(
          (e) => e.field,
          'field',
          'entries[].checksum',
        ),
      ),
    );
    expect(
      () => LibraryManifestCodec.decode('not json'),
      throwsA(isA<SongFormatException>()),
    );
  });

  test('display names keep roman numerals upright', () {
    expect(canonicalDisplayName('003_ii_v7_i'), 'II V7 I');
    expect(canonicalDisplayName('007_blues_in_bb'), 'Blues In Bb');
  });

  test('the meta-MAC of a known buffer is what the manifest records', () {
    // 11 characters: the base64 of eight bytes, MEGA's unpadded dialect.
    final mac = Uint8List.fromList(List<int>.generate(8, (i) => 0x40 + i));
    final text = megaBase64Encode(mac);
    expect(text, hasLength(11));
    expect(megaBase64Decode(text), mac);
  });

  test('files beside the volumes ride along as the root files', () async {
    final mega = await FakeMega(
      rootFiles: <String, Uint8List>{
        'tuning_notes.mp3': Uint8List(12),
        'jazz_handbook.pdf': Uint8List(9),
      },
      tree: <String, Map<String, Uint8List>>{
        '001_how_to_play': <String, Uint8List>{
          '001_a_track.wav': Uint8List(30),
        },
      },
    ).start();
    addTearDown(mega.close);

    final client = MegaFolderClient(
      MegaFolderLink.parse(mega.linkText),
      httpClient: http.Client(),
      apiBaseUri: mega.apiBaseUri,
      retryDelay: Duration.zero,
    );
    final manifest = await LibraryManifest.fetch(client);

    expect(manifest.rootFiles, hasLength(2));
    // Canonical order: sorted by name, the handbook before the tuning
    // notes.
    expect(manifest.rootFiles.map((e) => e.name), <String>[
      'jazz_handbook.pdf',
      'tuning_notes.mp3',
    ]);
    expect(manifest.rootVolume.id, manifest.rootId);
    expect(manifest.rootVolume.name, manifest.rootName);
    expect(manifest.rootVolume.book?.name, 'jazz_handbook.pdf');
    expect(manifest.rootVolume.tracks.map((e) => e.name), <String>[
      'tuning_notes.mp3',
    ]);
    expect(manifest.allEntries, hasLength(3));
    expect(
      manifest.entryById(manifest.rootFiles.first.id)?.$1.id,
      manifest.rootId,
    );
  });

  test('root files round-trip, and a manifest from before them has none', () {
    final rootFile = LibraryEntry(
      id: 'f2000000000000000',
      name: 'tuning_notes.mp3',
      kind: LibraryEntryKind.track,
      sizeBytes: 12,
      checksum: 'kEyVaLuE000B',
      modifiedUtc: DateTime.utc(2023, 11, 14, 22, 13, 20),
    );
    final manifest = LibraryManifest(
      rootId: 'r0000000000000000',
      rootName: 'jamey_aebersold',
      generatedUtc: DateTime.utc(2026, 10, 9),
      volumes: const <LibraryVolume>[],
      rootFiles: <LibraryEntry>[rootFile],
    );
    expect(
      LibraryManifestCodec.decode(LibraryManifestCodec.encode(manifest)),
      manifest,
    );

    // A cached manifest written before root files existed still opens.
    final legacy = LibraryManifestCodec.decode(
      '{"rootId":"r","rootName":"n","generated":"2026-01-01T00:00:00Z",'
      '"volumes":[]}',
    );
    expect(legacy.rootFiles, isEmpty);
    expect(legacy.rootVolume.entries, isEmpty);
  });
}
