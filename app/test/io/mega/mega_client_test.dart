import 'dart:typed_data';

import 'package:bandstand/io/mega/mega_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'fake_mega.dart';

Uint8List pattern(int size, int offset) =>
    Uint8List.fromList(List<int>.generate(size, (i) => (offset + i) % 251));

void main() {
  late FakeMega mega;
  late MegaFolderClient client;

  setUp(() async {
    mega = await FakeMega(
      tree: <String, Map<String, Uint8List>>{
        '001_how_to_play': <String, Uint8List>{
          '001_track_a.wav': pattern(70000, 0),
          '002_track_b.wav': pattern(200000, 3),
          'book.pdf': pattern(500, 7),
        },
        '002_nothing_but_the_blues': <String, Uint8List>{
          '001_minor_blues.mp3': pattern(131072 + 7, 11),
          'book.pdf': pattern(0, 0),
        },
      },
    ).start();
    client = MegaFolderClient(
      MegaFolderLink.parse(mega.linkText),
      httpClient: http.Client(),
      apiBaseUri: mega.apiBaseUri,
      retryDelay: Duration.zero,
    );
  });

  tearDown(() => mega.close());

  test('links parse in both public forms, and refuse the rest', () {
    final modern = MegaFolderLink.parse(
      'https://mega.nz/folder/AbCdEf0h#AAAAAAAAAAAAAAAAAAAAAA',
    );
    expect(modern.handle, 'AbCdEf0h');
    expect(modern.key, hasLength(16));
    final legacy = MegaFolderLink.parse(
      'https://mega.nz/#F!XyZ01234!AAAAAAAAAAAAAAAAAAAAAA',
    );
    expect(legacy.handle, 'XyZ01234');
    expect(
      () => MegaFolderLink.parse('https://mega.nz/fm/AbCdEf0h'),
      throwsA(
        isA<MegaLinkException>().having(
          (e) => e.message,
          'message',
          contains('private'),
        ),
      ),
    );
    expect(
      () => MegaFolderLink.parse('hello'),
      throwsA(isA<MegaLinkException>()),
    );
  });

  test('the tree arrives decrypted: names, sizes, times, parents', () async {
    final tree = await client.fetchNodes();
    final nodes = tree.nodes;
    // The shape real MEGA serves: the link handle never appears in the
    // tree — the folder's own handle is what the children hang under, and
    // the link's key unwraps either way.
    expect(nodes.where((n) => n.handle == mega.rootHandle), isEmpty);
    expect(tree.rootHandle, mega.internalRootHandle);
    final volumes = nodes.where((node) => node.isFolder).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    expect(volumes, hasLength(2));
    expect(volumes[0].name, '001_how_to_play');
    expect(volumes[0].parentHandle, tree.rootHandle);
    final files = nodes.where((node) => !node.isFolder).toList();
    expect(files, hasLength(5));
    final track = files.firstWhere((n) => n.name == '002_track_b.wav');
    expect(track.sizeBytes, 200000);
    expect(track.parentHandle, volumes[0].handle);
    expect(track.fileKey, isNotNull);
    expect(track.modifiedUtc.year, 2023);
  });

  test('the with-root shape parses too', () async {
    mega.includeRootNode = true;
    final tree = await client.fetchNodes();
    expect(tree.rootHandle, mega.rootHandle);
    final root = tree.nodes.singleWhere(
      (node) => node.handle == mega.rootHandle,
    );
    expect(root.isFolder, isTrue);
    expect(root.name, 'jamey_aebersold');
    expect(
      tree.nodes.where((n) => n.isFolder && n.parentHandle == tree.rootHandle),
      hasLength(2),
    );
  });

  test("a download decrypts and its meta-MAC condenses to the key's", () async {
    final nodes = (await client.fetchNodes()).nodes;
    final track = nodes.firstWhere((n) => n.name == '002_track_b.wav');
    final download = await client.openFile(track.handle);
    final received = <int>[];
    await for (final chunk in download.plaintext) {
      received.addAll(chunk);
      download.mac.add(chunk);
    }
    expect(received, pattern(200000, 3));
    expect(download.mac.condense(), download.key.metaMac);
  });

  test('an empty file downloads as an empty stream', () async {
    final nodes = (await client.fetchNodes()).nodes;
    final empty = nodes.firstWhere((n) => !n.isFolder && n.sizeBytes == 0);
    final download = await client.openFile(empty.handle);
    expect(download.sizeBytes, 0);
    expect(await download.plaintext.isEmpty, isTrue);
    expect(download.mac.condense(), download.key.metaMac);
  });

  test('corrupted ciphertext condenses to a wrong meta-MAC', () async {
    mega.corruptDownloads = true;
    final nodes = (await client.fetchNodes()).nodes;
    final track = nodes.firstWhere((n) => n.name == '001_track_a.wav');
    final download = await client.openFile(track.handle);
    await for (final chunk in download.plaintext) {
      download.mac.add(chunk);
    }
    expect(download.mac.condense(), isNot(download.key.metaMac));
  });

  test('a stale key cannot unwrap the tree', () async {
    final stale = MegaFolderClient(
      MegaFolderLink.parse(mega.staleLinkText),
      httpClient: http.Client(),
      apiBaseUri: mega.apiBaseUri,
      retryDelay: Duration.zero,
    );
    await expectLater(
      stale.fetchNodes(),
      throwsA(
        isA<MegaApiException>().having((e) => e.code, 'code', anyOf(-14, -9)),
      ),
    );
  });

  test("another folder's handle is not ours to read", () async {
    final elsewhere = MegaFolderClient(
      MegaFolderLink.parse(
        'https://mega.nz/folder/notOurFolder00000#${mega.linkText.split('#')[1]}',
      ),
      httpClient: http.Client(),
      apiBaseUri: mega.apiBaseUri,
    );
    await expectLater(
      elsewhere.fetchNodes(),
      throwsA(isA<MegaApiException>().having((e) => e.code, 'code', -9)),
    );
  });

  test('-3 congestion is retried, not reported', () async {
    mega.refuseTreeTimes = 1;
    final nodes = (await client.fetchNodes()).nodes;
    expect(nodes, isNotEmpty);
  });

  test("a dead node's download says gone, in words", () async {
    final nodes = (await client.fetchNodes()).nodes;
    final track = nodes.firstWhere((n) => n.name == '001_track_a.wav');
    mega.deadHandle = track.handle;
    await expectLater(
      client.openFile(track.handle),
      throwsA(
        isA<MegaApiException>().having(
          (e) => e.message,
          'message',
          contains('gone'),
        ),
      ),
    );
  });

  test('the transfer quota throttle says try again later', () async {
    final nodes = (await client.fetchNodes()).nodes;
    final track = nodes.firstWhere((n) => n.name == '001_track_a.wav');
    mega.bandwidthLimited = true;
    await expectLater(
      client.openFile(track.handle),
      throwsA(
        isA<MegaApiException>().having(
          (e) => e.message,
          'message',
          contains('quota'),
        ),
      ),
    );
  });
}
