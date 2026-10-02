import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bandstand/io/bank_download.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// A loopback server standing in for one mirror.
///
/// Real HTTP over the loopback interface, not a mock client: the whole point
/// of these tests is the code that talks Range headers, streams chunks and
/// survives broken connections, and none of that exists inside a fake.
class _Mirror {
  _Mirror(this._server);

  final HttpServer _server;

  /// How many requests reached this mirror.
  int requests = 0;

  /// The `Range` header of each request, in order; null entries asked for the
  /// whole file.
  final List<String?> ranges = <String?>[];

  /// The address the downloader should be pointed at.
  Uri get uri => Uri.parse('http://127.0.0.1:${_server.port}/FluidR3_GM.sf2');

  static Future<_Mirror> start(
    FutureOr<void> Function(_Mirror mirror, HttpRequest request) handler,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final mirror = _Mirror(server);
    server.listen((request) async {
      mirror.requests++;
      mirror.ranges.add(request.headers.value(HttpHeaders.rangeHeader));
      try {
        await handler(mirror, request);
      } on Object {
        // A test severing the connection mid-flight lands here; the client
        // side is where the assertion lives.
      }
    }, onError: (Object _) {});
    return mirror;
  }

  Future<void> close() => _server.close(force: true);
}

/// A handler that just serves [bytes], honouring ranges or not.
///
/// Writing in small pieces rather than one `add` keeps the client's chunk
/// boundaries frequent, which is what the cancellation tests need.
FutureOr<void> Function(_Mirror, HttpRequest) _servesBytes(
  Uint8List bytes, {
  bool honorRange = false,
}) => (mirror, request) async {
  final range = request.headers.value(HttpHeaders.rangeHeader);
  if (honorRange && range != null) {
    final start = int.parse(range.substring(6, range.length - 1));
    final slice = Uint8List.sublistView(bytes, start);
    request.response.statusCode = HttpStatus.partialContent;
    request.response.contentLength = slice.length;
    request.response.add(slice);
    await request.response.close();
    return;
  }
  request.response.contentLength = bytes.length;
  const piece = 64 * 1024;
  for (var offset = 0; offset < bytes.length; offset += piece) {
    final end = offset + piece > bytes.length ? bytes.length : offset + piece;
    request.response.add(Uint8List.sublistView(bytes, offset, end));
  }
  await request.response.close();
};

/// A handler that refuses with [status] and no body.
FutureOr<void> Function(_Mirror, HttpRequest) _failsWith(int status) =>
    (mirror, request) async {
      request.response.statusCode = status;
      await request.response.close();
    };

/// Deterministic stand-in bytes for a bank. Three megabytes, so the progress
/// throttle (once per megabyte) has something to report.
final Uint8List _bankBytes = () {
  final bytes = Uint8List(3 * 1024 * 1024);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = (i * 31 + i ~/ 251) & 0xff;
  }
  return bytes;
}();

/// The same bytes, altered — right length, wrong content.
final Uint8List _wrongBytes = () {
  final bytes = Uint8List.fromList(_bankBytes);
  for (var i = 0; i < bytes.length; i += 4099) {
    bytes[i] = (bytes[i] + 1) & 0xff;
  }
  return bytes;
}();

RecommendedBank _bank(List<Uri> mirrors) => RecommendedBank(
  fileName: 'FluidR3_GM.sf2',
  displayName: 'Test bank',
  sizeBytes: _bankBytes.length,
  sha256: sha256.convert(_bankBytes).toString(),
  mirrors: mirrors,
);

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('bandstand_bank_download');
  });

  tearDown(() async {
    if (root.existsSync()) {
      await root.delete(recursive: true);
    }
  });

  test('fetches, verifies and installs the bank whole', () async {
    final mirror = await _Mirror.start(
      (m, r) => _servesBytes(_bankBytes)(m, r),
    );
    addTearDown(mirror.close);
    final downloader = BankDownloader(
      directory: root,
      bank: _bank([mirror.uri]),
    );

    final seen = <BankDownloadProgress>[];
    final result = await downloader.download(onProgress: seen.add);

    expect(result, BankDownloadResult.downloaded);
    expect(await downloader.targetFile.readAsBytes(), _bankBytes);
    expect(
      downloader.partFile.existsSync(),
      isFalse,
      reason: 'a finished download leaves no part behind',
    );
    expect(seen.last.bytesDone, _bankBytes.length);
    expect(seen.last.bytesTotal, _bankBytes.length);
  });

  test('resumes from a kept part with a Range request', () async {
    final mirror = await _Mirror.start(
      (m, r) => _servesBytes(_bankBytes, honorRange: true)(m, r),
    );
    addTearDown(mirror.close);
    final downloader = BankDownloader(
      directory: root,
      bank: _bank([mirror.uri]),
    );
    final part = downloader.partFile;
    await part.create(recursive: true);
    await part.writeAsBytes(Uint8List.sublistView(_bankBytes, 0, 1024 * 1024));

    final result = await downloader.download();

    expect(result, BankDownloadResult.downloaded);
    expect(mirror.ranges, [
      'bytes=1048576-',
    ], reason: 'the part file is the progress; the server is sent the rest');
    expect(await downloader.targetFile.readAsBytes(), _bankBytes);
  });

  test('starts over when the server ignores the range', () async {
    final mirror = await _Mirror.start(
      (m, r) => _servesBytes(_bankBytes)(m, r),
    );
    addTearDown(mirror.close);
    final downloader = BankDownloader(
      directory: root,
      bank: _bank([mirror.uri]),
    );
    final part = downloader.partFile;
    await part.create(recursive: true);
    await part.writeAsBytes(Uint8List.sublistView(_bankBytes, 0, 1024 * 1024));

    final result = await downloader.download();

    expect(result, BankDownloadResult.downloaded);
    expect(
      mirror.ranges.first,
      startsWith('bytes='),
      reason: 'the range was asked for even though it was ignored',
    );
    expect(
      await downloader.targetFile.readAsBytes(),
      _bankBytes,
      reason: 'a 200 response is the whole file; the stale prefix is gone',
    );
  });

  test('tries the next mirror when one cannot serve the file', () async {
    final dead = await _Mirror.start(
      (m, r) => _failsWith(HttpStatus.notFound)(m, r),
    );
    final live = await _Mirror.start((m, r) => _servesBytes(_bankBytes)(m, r));
    addTearDown(dead.close);
    addTearDown(live.close);
    final downloader = BankDownloader(
      directory: root,
      bank: _bank([dead.uri, live.uri]),
    );

    final result = await downloader.download();

    expect(result, BankDownloadResult.downloaded);
    expect(dead.requests, 1);
    expect(live.requests, 1);
    expect(await downloader.targetFile.readAsBytes(), _bankBytes);
  });

  test('throws away corrupt bytes and trusts the next mirror', () async {
    final liar = await _Mirror.start((m, r) => _servesBytes(_wrongBytes)(m, r));
    final honest = await _Mirror.start(
      (m, r) => _servesBytes(_bankBytes)(m, r),
    );
    addTearDown(liar.close);
    addTearDown(honest.close);
    final downloader = BankDownloader(
      directory: root,
      bank: _bank([liar.uri, honest.uri]),
    );

    final result = await downloader.download();

    expect(result, BankDownloadResult.downloaded);
    expect(await downloader.targetFile.readAsBytes(), _bankBytes);
    expect(
      downloader.partFile.existsSync(),
      isFalse,
      reason:
          'bytes that fail the digest must not survive to poison a '
          'later resume',
    );
  });

  test('reports every mirror when none of them works', () async {
    final one = await _Mirror.start(
      (m, r) => _failsWith(HttpStatus.notFound)(m, r),
    );
    final two = await _Mirror.start((m, r) => _failsWith(503)(m, r));
    addTearDown(one.close);
    addTearDown(two.close);
    final downloader = BankDownloader(
      directory: root,
      bank: _bank([one.uri, two.uri]),
    );

    await expectLater(
      downloader.download(),
      throwsA(
        isA<BankDownloadException>().having(
          (error) => error.failures.length,
          'failures',
          2,
        ),
      ),
    );
  });

  test('keeps the fetched bytes when the connection dies mid-stream', () async {
    // Promise the whole file, deliver half, hang up.
    final dead = await _Mirror.start((mirror, request) async {
      request.response.contentLength = _bankBytes.length;
      request.response.add(
        Uint8List.sublistView(_bankBytes, 0, _bankBytes.length ~/ 2),
      );
      await request.response.close();
    });
    addTearDown(dead.close);
    final downloader = BankDownloader(directory: root, bank: _bank([dead.uri]));

    await expectLater(downloader.download(), throwsA(isA<Exception>()));
    expect(
      downloader.partFile.existsSync(),
      isTrue,
      reason: 'a network failure is not corruption; the bytes stay',
    );
    expect(
      downloader.partFile.lengthSync(),
      _bankBytes.length ~/ 2,
      reason: 'loopback delivery is ordered — exactly the half sent arrived',
    );

    // And the next attempt picks up where the bytes ran out — from a
    // different mirror, which is the whole reason the digest is pinned.
    final live = await _Mirror.start(
      (m, r) => _servesBytes(_bankBytes, honorRange: true)(m, r),
    );
    addTearDown(live.close);
    final resumed = BankDownloader(directory: root, bank: _bank([live.uri]));
    final result = await resumed.download();

    expect(result, BankDownloadResult.downloaded);
    expect(live.ranges, ['bytes=${_bankBytes.length ~/ 2}-']);
    expect(await downloader.targetFile.readAsBytes(), _bankBytes);
  });

  test('does nothing when a bank of that name is already there', () async {
    final mirror = await _Mirror.start(
      (m, r) => _servesBytes(_bankBytes)(m, r),
    );
    addTearDown(mirror.close);
    final downloader = BankDownloader(
      directory: root,
      bank: _bank([mirror.uri]),
    );
    await downloader.targetFile.create(recursive: true);
    await downloader.targetFile.writeAsBytes(_wrongBytes);

    final result = await downloader.download();

    expect(result, BankDownloadResult.alreadyPresent);
    expect(mirror.requests, 0);
    expect(
      await downloader.targetFile.readAsBytes(),
      _wrongBytes,
      reason: 'a bank the user placed by hand is theirs, whatever it is',
    );
  });

  test('renames a finished part into place without any network', () async {
    final mirror = await _Mirror.start(
      (m, r) => _servesBytes(_bankBytes)(m, r),
    );
    addTearDown(mirror.close);
    final downloader = BankDownloader(
      directory: root,
      bank: _bank([mirror.uri]),
    );
    // The crash window this covers: everything verified, process gone before
    // the rename.
    await downloader.partFile.create(recursive: true);
    await downloader.partFile.writeAsBytes(_bankBytes);

    final result = await downloader.download();

    expect(result, BankDownloadResult.downloaded);
    expect(mirror.requests, 0);
    expect(await downloader.targetFile.readAsBytes(), _bankBytes);
    expect(downloader.partFile.existsSync(), isFalse);
  });

  test('restarts from the top when the server rejects the range', () async {
    final mirror = await _Mirror.start((mirror, request) async {
      if (request.headers.value(HttpHeaders.rangeHeader) != null) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await request.response.close();
        return;
      }
      await _servesBytes(_bankBytes)(mirror, request);
    });
    addTearDown(mirror.close);
    final downloader = BankDownloader(
      directory: root,
      bank: _bank([mirror.uri]),
    );
    // A part the server considers unsatisfiable — a mirror serving different
    // bytes than the ones already fetched, say. It is within the pinned
    // size, so the client cannot know it is stale and must ask.
    await downloader.partFile.create(recursive: true);
    await downloader.partFile.writeAsBytes(
      Uint8List.sublistView(_bankBytes, 0, 1024 * 1024),
    );

    final result = await downloader.download();

    expect(result, BankDownloadResult.downloaded);
    expect(mirror.ranges, [
      startsWith('bytes='),
      isNull,
    ], reason: 'the 416 costs the stale part one extra request, no more');
    expect(await downloader.targetFile.readAsBytes(), _bankBytes);
  });

  test('drops a part longer than the bank without asking anyone', () async {
    final mirror = await _Mirror.start(
      (m, r) => _servesBytes(_bankBytes)(m, r),
    );
    addTearDown(mirror.close);
    final downloader = BankDownloader(
      directory: root,
      bank: _bank([mirror.uri]),
    );
    await downloader.partFile.create(recursive: true);
    await downloader.partFile.writeAsBytes(Uint8List(_bankBytes.length + 1024));

    final result = await downloader.download();

    expect(result, BankDownloadResult.downloaded);
    expect(
      mirror.ranges,
      [isNull],
      reason:
          'a part longer than the bank cannot be a prefix of it, and '
          'the client can tell that on its own',
    );
    expect(await downloader.targetFile.readAsBytes(), _bankBytes);
  });

  test('cancellation keeps the part and installs nothing', () async {
    final mirror = await _Mirror.start(
      (m, r) => _servesBytes(_bankBytes)(m, r),
    );
    addTearDown(mirror.close);
    final downloader = BankDownloader(
      directory: root,
      bank: _bank([mirror.uri]),
    );

    var cancelled = false;
    final result = await downloader.download(
      onProgress: (_) => cancelled = true,
      isCancelled: () => cancelled,
    );

    expect(result, BankDownloadResult.cancelled);
    expect(downloader.targetFile.existsSync(), isFalse);
    expect(
      downloader.partFile.existsSync(),
      isTrue,
      reason: 'pausing is what the part file is for',
    );
  });

  test('the declined choice survives and fails soft', () async {
    expect(await RecommendedBankChoice.isDeclined(root), isFalse);

    await RecommendedBankChoice.markDeclined(root);
    expect(await RecommendedBankChoice.isDeclined(root), isTrue);
    expect(
      RecommendedBankChoice.fileFor(root).readAsStringSync(),
      contains('"declined": true'),
    );
    expect(
      RecommendedBankChoice.fileFor(root).parent
          .listSync()
          .whereType<File>()
          .map((file) => file.uri.pathSegments.last),
      everyElement(isNot(endsWith('.tmp'))),
      reason: 'the staging name must not be left behind',
    );

    // An unreadable or corrupt choice asks again rather than nag-proofing.
    final elsewhere = await Directory.systemTemp.createTemp('bandstand_choice');
    addTearDown(() => elsewhere.delete(recursive: true));
    final corrupt = RecommendedBankChoice.fileFor(elsewhere);
    await corrupt.create(recursive: true);
    await corrupt.writeAsString('{nope');
    expect(await RecommendedBankChoice.isDeclined(elsewhere), isFalse);
  });
}
