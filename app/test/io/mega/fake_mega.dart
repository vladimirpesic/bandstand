import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bandstand/io/mega/mega_base64.dart';
import 'package:bandstand/io/mega/mega_crypto.dart';

/// A local MEGA that speaks the real protocol (`docs/rules/mega-library.md`
/// §8): real node wrapping, real attribute blobs, real CTR ciphertext, real
/// chunk MACs — over real sockets. What the app asserts against this server
/// is what MEGA itself will have to honor.
class FakeMega {
  FakeMega._(
    this.rootHandle,
    this._rootKey,
    this.rootName,
    this._volumes,
    this._files,
    this._rootFiles, {
    this.wrapperName,
    this.wrapperKey,
  });

  /// Build a library from `{volumeName: {fileName: bytes}}`, with
  /// deterministic keys so a test's tree is reproducible run to run.
  /// [rootFiles], when set, places files beside the volumes — the tuning
  /// notes and the handbook shape. [wrapper], when set, nests the whole
  /// tree one folder deeper — the shape a link to a folder *containing*
  /// the library produces.
  factory FakeMega({
    String rootName = 'jamey_aebersold',
    String? wrapper,
    Map<String, Map<String, Uint8List>> tree = const {},
    Map<String, Uint8List> rootFiles = const {},
  }) {
    var seed = 1;
    Uint8List key16() {
      final key = Uint8List.fromList(
        List<int>.generate(16, (i) => 0x11 * seed + i * 7),
      );
      seed++;
      return key;
    }

    final rootKey = key16();
    final volumes = <_FakeVolume>[];
    final files = <String, _FakeFile>{};
    var volumeIndex = 0;
    var fileIndex = 0;
    for (final volumeName in tree.keys) {
      final volumeKey = key16();
      final volumeFiles = <_FakeFile>[];
      for (final entry in tree[volumeName]!.entries) {
        final aesKey = key16();
        final nonce = Uint8List.fromList(
          List<int>.generate(8, (i) => 0x5a + i + fileIndex),
        );
        final mac = MegaChunkMac(aesKey, nonce)..add(entry.value);
        final file = _FakeFile(
          handle: 'f${fileIndex++}000000000000000',
          name: entry.key,
          plaintext: entry.value,
          key: MegaFileKey.merge(aesKey, nonce, mac.condense()),
        );
        volumeFiles.add(file);
        files[file.handle] = file;
      }
      volumes.add(
        _FakeVolume(
          handle: 'd${volumeIndex++}000000000000000',
          name: volumeName,
          key: volumeKey,
          files: volumeFiles,
        ),
      );
    }
    final rootFolderFiles = <_FakeFile>[];
    for (final rootFile in rootFiles.entries) {
      final aesKey = key16();
      final nonce = Uint8List.fromList(
        List<int>.generate(8, (i) => 0x5a + i + fileIndex),
      );
      final mac = MegaChunkMac(aesKey, nonce)..add(rootFile.value);
      final file = _FakeFile(
        handle: 'f${fileIndex++}000000000000000',
        name: rootFile.key,
        plaintext: rootFile.value,
        key: MegaFileKey.merge(aesKey, nonce, mac.condense()),
      );
      rootFolderFiles.add(file);
      files[file.handle] = file;
    }
    return FakeMega._(
      'r0000000000000000',
      rootKey,
      rootName,
      volumes,
      files,
      rootFolderFiles,
      wrapperName: wrapper,
      wrapperKey: wrapper == null ? null : key16(),
    );
  }

  /// The root folder's handle.
  final String rootHandle;

  final Uint8List _rootKey;

  /// The root folder's decrypted name.
  final String rootName;

  final String? wrapperName;
  final Uint8List? wrapperKey;

  final List<_FakeVolume> _volumes;
  final Map<String, _FakeFile> _files;

  /// The files that hang directly beside the volumes, under the library's
  /// own root.
  final List<_FakeFile> _rootFiles;

  HttpServer? _server;

  /// How many `f` calls to refuse with `-3` before serving the tree —
  /// MEGA's congestion answer, retried by the client.
  int refuseTreeTimes = 0;

  /// When set, this node's download is answered `-9`: gone.
  String? deadHandle;

  /// When set, byte downloads answer HTTP 509 with a reset time — the
  /// free-tier transfer quota (§3).
  bool bandwidthLimited = false;

  /// When set, served ciphertext has its first byte flipped — the
  /// corrupted-transfer case the meta-MAC exists to catch.
  bool corruptDownloads = false;

  /// Whether the `f` answer includes the link's own node. Real MEGA
  /// usually lists the folder's children directly, the link handle only
  /// as their parent — that is the default here; the with-root shape is
  /// the variant some share setups produce.
  bool includeRootNode = false;

  static final Uint8List _wrongKey = Uint8List.fromList(
    List<int>.generate(16, (i) => 0x77 + i),
  );

  /// A link with a key that fits nothing — for the stale-link paths.
  String get staleLinkText =>
      'https://mega.nz/folder/$rootHandle#${megaBase64Encode(_wrongKey)}';

  /// The public folder link a user would paste.
  String get linkText =>
      'https://mega.nz/folder/$rootHandle#${megaBase64Encode(_rootKey)}';

  /// The API gateway's base URI: the server's root.
  Uri get apiBaseUri => Uri.parse('http://127.0.0.1:${_server!.port}/');

  /// The file node's plaintext, for asserting downloads against.
  Uint8List plaintextOf(String handle) => _files[handle]!.plaintext;

  /// The folder's node handle when the `f` answer omits the root — the
  /// link handle then aliases a folder whose own handle is this.
  String get internalRootHandle => 'q7y0000000000000';

  /// Starts serving.
  Future<FakeMega> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_handle);
    _server = server;
    return this;
  }

  /// Stops serving.
  Future<void> close() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.method == 'POST' && request.uri.path == '/cs') {
        await _handleApi(request);
        return;
      }
      if (request.method == 'GET' && request.uri.path.startsWith('/files/')) {
        await _handleDownload(request);
        return;
      }
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    } on Object {
      try {
        await request.response.close();
      } on Object {
        // Already gone — a test tearing the server down mid-request.
      }
    }
  }

  Future<void> _handleApi(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final Object? decoded = jsonDecode(body);
    if (decoded is! List || decoded.isEmpty || decoded.first is! Map) {
      await _answer(request, <Object?>[-2]);
      return;
    }
    final command = decoded.first as Map<String, Object?>;
    // The folder context: an anonymous `cs` call names the folder whose
    // contents it may see. Anything else is somebody else's folder.
    if (request.uri.queryParameters['n'] != rootHandle) {
      await _answer(request, <Object?>[-9]);
      return;
    }
    if (refuseTreeTimes > 0) {
      refuseTreeTimes--;
      await _answer(request, <Object?>[-3]);
      return;
    }
    switch (command['a']) {
      case 'f':
        await _answer(request, <Object?>[
          <String, Object?>{'f': _treeJson()},
        ]);
      case 'g':
        final handle = command['n'];
        if (handle is! String ||
            !_files.containsKey(handle) ||
            handle == deadHandle) {
          await _answer(request, <Object?>[-9]);
          return;
        }
        final file = _files[handle]!;
        await _answer(request, <Object?>[
          <String, Object?>{
            'g': 'http://127.0.0.1:${_server!.port}/files/${file.handle}',
            's': file.plaintext.length,
            'at': encryptNodeAttributes(<String, Object?>{
              'n': file.name,
            }, file.key.mergedBytesForFake()),
          },
        ]);
      default:
        await _answer(request, <Object?>[-2]);
    }
  }

  List<Map<String, Object?>> _treeJson() {
    final rootAes = MegaAes(_rootKey);
    final nodes = <Map<String, Object?>>[
      if (includeRootNode)
        <String, Object?>{
          'h': rootHandle,
          'p': 'ownerVault',
          't': 1,
          'a': encryptNodeAttributes(<String, Object?>{
            'n': rootName,
          }, _rootKey),
          'k': '$rootHandle:${megaBase64Encode(rootAes.ecb(_rootKey))}',
          'ts': 1700000000,
        },
    ];
    // The rootless shape real MEGA serves: the link handle never appears;
    // the children hang under the folder's own handle instead.
    final treeRoot = includeRootNode ? rootHandle : internalRootHandle;
    // A wrapper folder, when the tree models a link to a folder holding
    // the library: the volumes hang under it, it hangs under the root.
    final wrapped = wrapperName != null && wrapperKey != null;
    final volumesParent = wrapped ? 'w0000000000000000' : treeRoot;
    if (wrapped) {
      nodes.add(<String, Object?>{
        'h': volumesParent,
        'p': treeRoot,
        't': 1,
        'a': encryptNodeAttributes(<String, Object?>{
          'n': wrapperName!,
        }, wrapperKey!),
        'k':
            '$volumesParent:'
            '${megaBase64Encode(rootAes.ecb(wrapperKey!))}',
        'ts': 1700000050,
      });
    }
    for (final volume in _volumes) {
      nodes.add(<String, Object?>{
        'h': volume.handle,
        'p': volumesParent,
        't': 1,
        'a': encryptNodeAttributes(<String, Object?>{
          'n': volume.name,
        }, volume.key),
        'k':
            '${volume.handle}:'
            '${megaBase64Encode(rootAes.ecb(volume.key))}',
        'ts': 1700000100,
      });
      for (final file in volume.files) {
        final merged = file.key.mergedBytesForFake();
        nodes.add(<String, Object?>{
          'h': file.handle,
          'p': volume.handle,
          't': 0,
          'a': encryptNodeAttributes(<String, Object?>{'n': file.name}, merged),
          'k':
              '${file.handle}:'
              '${megaBase64Encode(MegaAes(volume.key).ecb(merged))}',
          's': file.plaintext.length,
          'ts': 1700000200,
        });
      }
    }
    // The files beside the volumes — wrapped with the key of the folder
    // that holds them, exactly as a volume's files are.
    final wrappedRoot = wrapperName != null && wrapperKey != null;
    final rootParentKey = wrappedRoot ? wrapperKey! : _rootKey;
    for (final file in _rootFiles) {
      final merged = file.key.mergedBytesForFake();
      nodes.add(<String, Object?>{
        'h': file.handle,
        'p': volumesParent,
        't': 0,
        'a': encryptNodeAttributes(<String, Object?>{'n': file.name}, merged),
        'k':
            '${file.handle}:'
            '${megaBase64Encode(MegaAes(rootParentKey).ecb(merged))}',
        's': file.plaintext.length,
        'ts': 1700000300,
      });
    }
    return nodes;
  }

  Future<void> _handleDownload(HttpRequest request) async {
    final rest = request.uri.path.substring('/files/'.length);
    final handle = rest.split('/').first;
    final file = _files[handle];
    if (file == null) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    if (bandwidthLimited) {
      request.response.statusCode = 509;
      request.response.headers.set('x-mega-time-left', '3600');
      await request.response.close();
      return;
    }
    var bytes = file.ciphertextForFake();
    if (corruptDownloads && bytes.isNotEmpty) {
      bytes = Uint8List.fromList(bytes);
      bytes[0] ^= 0xff;
    }
    // The `/start-end` suffix a ranged download asks with: serve it, so
    // the URL shape the client builds is exercised.
    final match = RegExp(r'^/(\d+)-(\d+)$')
        .firstMatch(rest.substring(handle.length));
    if (match != null) {
      bytes = bytes.sublist(
        int.parse(match.group(1)!),
        int.parse(match.group(2)!) + 1,
      );
    }
    request.response.headers.contentLength = bytes.length;
    request.response.add(bytes);
    await request.response.close();
  }

  Future<void> _answer(HttpRequest request, Object? body) async {
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }
}

class _FakeVolume {
  _FakeVolume({
    required this.handle,
    required this.name,
    required this.key,
    required this.files,
  });

  final String handle;
  final String name;
  final Uint8List key;
  final List<_FakeFile> files;
}

class _FakeFile {
  _FakeFile({
    required this.handle,
    required this.name,
    required this.plaintext,
    required this.key,
  });

  final String handle;
  final String name;
  final Uint8List plaintext;
  final MegaFileKey key;

  Uint8List? _ciphertext;

  Uint8List ciphertextForFake() =>
      _ciphertext ??= key.ctr.process(Uint8List.fromList(plaintext));
}

extension on MegaFileKey {
  Uint8List mergedBytesForFake() {
    final merged = Uint8List(32);
    merged.setRange(16, 24, nonce);
    merged.setRange(24, 32, metaMac);
    for (var i = 0; i < 16; i++) {
      merged[i] = aesKey[i] ^ merged[16 + i];
    }
    return merged;
  }
}
