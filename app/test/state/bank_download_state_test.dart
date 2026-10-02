import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bandstand/io/bank_download.dart';
import 'package:bandstand/io/song_library.dart';
import 'package:bandstand/state/bank_download_state.dart';
import 'package:bandstand/state/library_state.dart';
import 'package:bandstand/state/playback_state.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Deterministic bytes standing in for a bank, with the digest a real one
/// would have.
final Uint8List _bytes = () {
  final bytes = Uint8List(2 * 1024 * 1024);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = (i * 17 + 3) & 0xff;
  }
  return bytes;
}();

RecommendedBank _bank(Uri mirror) => RecommendedBank(
  fileName: 'FluidR3_GM.sf2',
  displayName: 'Test bank',
  sizeBytes: _bytes.length,
  sha256: sha256.convert(_bytes).toString(),
  mirrors: <Uri>[mirror],
);

/// A loopback server serving [_bytes], so the controller is exercised over
/// real HTTP against the real downloader — this layer's only job is what it
/// does with the results.
Future<Uri> _serving() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    request.response.contentLength = _bytes.length;
    request.response.add(_bytes);
    await request.response.close();
  });
  addTearDown(() => server.close(force: true));
  return Uri.parse('http://127.0.0.1:${server.port}/FluidR3_GM.sf2');
}

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('bandstand_bank_state');
    await SongLibrary(root).ensureLayout();
  });

  tearDown(() async {
    if (root.existsSync()) {
      await root.delete(recursive: true);
    }
  });

  ProviderContainer makeContainer(List<Uri> mirrors) {
    final bank = _bank(mirrors.first);
    final container = ProviderContainer(
      overrides: [
        songLibraryProvider.overrideWith((ref) async => SongLibrary(root)),
        bankDownloaderProvider.overrideWith(
          (ref) =>
              (directory) => BankDownloader(directory: directory, bank: bank),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test(
    'a successful download lands in the state, on disk and in the list',
    () async {
      final mirror = await _serving();
      final container = makeContainer(<Uri>[mirror]);

      // Watched before the download, so the assertion below proves the
      // invalidation rather than a first read.
      final before = await container.read(soundbanksProvider.future);
      expect(before.where((bank) => bank.path.contains(root.path)), isEmpty);

      await container.read(bankDownloadProvider.notifier).start();

      final state = container.read(bankDownloadProvider);
      expect(state.phase, BankDownloadPhase.done);
      expect(state.errorMessage, isNull);

      final target = File(
        '${root.path}${Platform.pathSeparator}soundbanks'
        '${Platform.pathSeparator}FluidR3_GM.sf2',
      );
      expect(target.existsSync(), isTrue);
      expect(await target.readAsBytes(), _bytes);

      final after = await container.read(soundbanksProvider.future);
      expect(
        after.where((bank) => bank.path == target.path),
        isNotEmpty,
        reason: 'the picker must see the bank the app itself just placed',
      );
    },
  );

  test('a pause returns to idle, keeping what was fetched', () async {
    // Serve the first chunk, then stall: the download is running, and the
    // bytes are on disk, but it will never finish on its own.
    final stall = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      if (!stall.isCompleted) {
        stall.complete();
      }
      await server.close(force: true);
    });
    server.listen((request) async {
      request.response.contentLength = _bytes.length;
      request.response.add(Uint8List.sublistView(_bytes, 0, 64 * 1024));
      await request.response.flush();
      await stall.future;
      await request.response.close();
    });

    final container = makeContainer(<Uri>[
      Uri.parse('http://127.0.0.1:${server.port}/FluidR3_GM.sf2'),
    ]);
    final controller = container.read(bankDownloadProvider.notifier);
    final running = controller.start();

    while (container.read(bankDownloadProvider).phase !=
        BankDownloadPhase.downloading) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    controller.cancel();
    await running;

    final state = container.read(bankDownloadProvider);
    expect(state.phase, BankDownloadPhase.idle);
    final part = File(
      '${root.path}${Platform.pathSeparator}soundbanks'
      '${Platform.pathSeparator}FluidR3_GM.sf2.part',
    );
    expect(part.existsSync(), isTrue);
    expect(part.lengthSync(), greaterThanOrEqualTo(64 * 1024));
    expect(
      File(
        '${root.path}${Platform.pathSeparator}soundbanks'
        '${Platform.pathSeparator}FluidR3_GM.sf2',
      ).existsSync(),
      isFalse,
    );
  });

  test('a part left by an earlier run starts out as resumable', () async {
    final mirror = await _serving();
    final container = makeContainer(<Uri>[mirror]);

    // A previous run of the app died after 64 KiB of the bank.
    final part = File(
      '${root.path}${Platform.pathSeparator}soundbanks'
      '${Platform.pathSeparator}FluidR3_GM.sf2.part',
    );
    await part.writeAsBytes(Uint8List.sublistView(_bytes, 0, 64 * 1024));

    // Reading the provider builds it; the announcement of the part is
    // async, so give it a moment to land.
    var waited = 0;
    while (!container.read(bankDownloadProvider).isPartial && waited < 5000) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      waited += 10;
    }

    final state = container.read(bankDownloadProvider);
    expect(state.phase, BankDownloadPhase.idle);
    expect(state.bytesDone, 64 * 1024);
    expect(
      state.isPartial,
      isTrue,
      reason: 'the idle controls must offer "resume", not a fresh download',
    );
  });

  test(
    'a failure is reported in the state, not thrown at the caller',
    () async {
      // Port 1 refuses connections immediately; nothing is listening there.
      final container = makeContainer(<Uri>[
        Uri.parse('http://127.0.0.1:1/FluidR3_GM.sf2'),
      ]);

      await container.read(bankDownloadProvider.notifier).start();

      final state = container.read(bankDownloadProvider);
      expect(state.phase, BankDownloadPhase.failed);
      expect(state.errorMessage, contains('could not be downloaded'));
    },
  );
}
