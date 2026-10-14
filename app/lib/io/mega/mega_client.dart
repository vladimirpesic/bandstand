import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bandstand/io/mega/mega_base64.dart';
import 'package:bandstand/io/mega/mega_crypto.dart';
import 'package:http/http.dart' as http;

/// MEGA's API gateway. Injectable so the whole client runs against a local
/// server in tests (`docs/rules/mega-library.md` §8).
final Uri megaApiGateway = Uri.https('g.api.mega.co.nz', '/');

/// A pasted string that is not a usable public folder link — including the
/// private `mega.nz/fm/…` links MEGA hands out for one's own folders.
class MegaLinkException implements Exception {
  /// Create the exception.
  const MegaLinkException(this.message);

  /// What went wrong, in words.
  final String message;

  @override
  String toString() => message;
}

/// Anything the MEGA API refused, with its error code when there was one.
class MegaApiException implements Exception {
  /// Create the exception.
  const MegaApiException(this.message, {this.code = 0, this.retryAfter});

  /// MEGA's negative error code, or 0 for transport-level failures.
  final int code;

  /// How long MEGA asked to wait, when the answer was a quota throttle.
  final Duration? retryAfter;

  /// What went wrong, in words.
  final String message;

  @override
  String toString() => 'MEGA said no ($code): $message';
}

/// One public folder link: the handle names the folder, the fragment is its
/// AES-128 key — the whole credential (§7).
class MegaFolderLink {
  /// Parse from a pasted [text], in either of MEGA's public-folder forms.
  ///
  /// Throws [MegaLinkException] naming the problem — a link that parses to
  /// nothing can never list anything.
  factory MegaFolderLink.parse(String text) {
    final trimmed = text.trim();
    final fragmentIndex = trimmed.indexOf('#');
    final fragment = fragmentIndex >= 0
        ? trimmed.substring(fragmentIndex + 1)
        : '';
    final path = fragmentIndex >= 0
        ? trimmed.substring(0, fragmentIndex)
        : trimmed;

    // Legacy: `#F!<handle>!<key>`.
    var handle = '';
    var key = '';
    if (fragment.startsWith('F!')) {
      final parts = fragment.split('!');
      if (parts.length == 3 && parts[1].isNotEmpty && parts[2].isNotEmpty) {
        handle = parts[1];
        key = parts[2];
      }
    }
    // Modern: `/folder/<handle>#<key>`.
    if (handle.isEmpty) {
      final match = RegExp(r'/folder/([A-Za-z0-9_-]+)').firstMatch(path);
      if (match != null && fragment.isNotEmpty && !fragment.contains('!')) {
        handle = match.group(1)!;
        key = fragment;
      }
    }
    if (handle.isEmpty) {
      if (path.contains('mega.nz/fm/')) {
        throw const MegaLinkException(
          'that is a private MEGA link; in MEGA, open the folder\'s menu '
          'and choose "Get link" for a public one',
        );
      }
      throw const MegaLinkException(
        'that is not a MEGA public folder link; it looks like '
        'https://mega.nz/folder/…#…',
      );
    }
    Uint8List folderKey;
    try {
      folderKey = truncateTo(megaBase64Decode(key), 16);
    } on FormatException {
      throw const MegaLinkException('the link\'s key is not a folder key');
    }
    return MegaFolderLink._(handle, folderKey, key);
  }

  const MegaFolderLink._(this.handle, this.key, this._keyText);

  /// The folder's node handle.
  final String handle;

  /// The folder's 16-byte AES key, from the fragment.
  final Uint8List key;

  /// The key exactly as pasted — never logged, never shown after entry.
  final String _keyText;

  /// The link reassembled in MEGA's modern form.
  @override
  String toString() => 'https://mega.nz/folder/$handle#$_keyText';
}

/// One node of the folder's tree, everything decrypted that can be.
class MegaNode {
  /// Create the record.
  const MegaNode({
    required this.handle,
    required this.parentHandle,
    required this.isFolder,
    required this.name,
    required this.sizeBytes,
    required this.modifiedUtc,
    this.fileKey,
  });

  /// The node's handle — the id everything local reconciles by (§4).
  final String handle;

  /// The parent folder's handle; the root's is empty.
  final String parentHandle;

  /// Whether this node is a folder.
  final bool isFolder;

  /// The decrypted canonical name.
  final String name;

  /// Size in bytes; 0 for folders.
  final int sizeBytes;

  /// When MEGA last saw the node change.
  final DateTime modifiedUtc;

  /// The file's split key; null for folders.
  final MegaFileKey? fileKey;
}

/// A file's download, opened and streaming: the plaintext, and the MAC
/// chain fed from the same bytes.
class MegaFileDownload {
  /// Create the handle.
  const MegaFileDownload({
    required this.sizeBytes,
    required this.plaintext,
    required this.key,
    required this.mac,
  });

  /// The file's size, as the `g` answer declared.
  final int sizeBytes;

  /// The decrypted bytes. Consumed or cancelled by whoever opened it.
  final Stream<List<int>> plaintext;

  /// The file's key — the meta-MAC's source of truth.
  final MegaFileKey key;

  /// The MAC chain, fed the plaintext as it is consumed (§3).
  final MegaChunkMac mac;
}

/// The folder's tree as one fetch brought it: the root's handle and every
/// node below it, decrypted.
///
/// The root handle is not always the link's: MEGA folder links can carry a
/// public alias handle that names the folder but never appears in the tree
/// — the real root is then the parent the top-level nodes hang under.
/// [MegaFolderLink.key] unwraps either way; the tree says which it is.
class MegaTree {
  /// Create the tree.
  const MegaTree({required this.rootHandle, required this.nodes});

  /// The folder root's node handle.
  final String rootHandle;

  /// Every node of the tree, the root included when the answer carried it.
  final List<MegaNode> nodes;
}

/// The anonymous, read-only MEGA folder client — two commands, §8: `f` for
/// the tree, `g` plus one ranged GET for a file's decrypted bytes.
class MegaFolderClient {
  /// Create the client over [link].
  MegaFolderClient(
    this.link, {
    http.Client? httpClient,
    Uri? apiBaseUri,
    this.retryDelay = const Duration(seconds: 2),
  }) : _httpClient = httpClient ?? http.Client(),
       _apiBaseUri = apiBaseUri ?? megaApiGateway;

  /// The folder link this client reads.
  final MegaFolderLink link;

  /// How long to wait between `-3` retries. Zero in tests, seconds in the
  /// app.
  final Duration retryDelay;

  final http.Client _httpClient;
  final Uri _apiBaseUri;

  static const int _maxRetries = 4;
  static const int _httpOk = 200;
  static const int _httpBandwidth = 509;

  final Map<String, MegaFileKey> _fileKeys = <String, MegaFileKey>{};

  /// Fetches and decrypts the folder's whole tree, root included when the
  /// answer carries it, children following by parent handle. Every file's
  /// key is cached by handle for [openFile].
  Future<MegaTree> fetchNodes() async {
    final response = await _command(<String, Object?>{
      'a': 'f',
      'c': 1,
      'r': 1,
    });
    final rawNodes = response['f'];
    if (rawNodes is! List) {
      throw const MegaApiException('the node tree is not a list', code: -2);
    }
    final raw = <Map<String, Object?>>[
      for (final entry in rawNodes)
        if (entry is Map<String, Object?>) entry,
    ];
    if (raw.isEmpty) {
      throw const MegaApiException(
        'the folder is gone or the link was revoked',
        code: -9,
      );
    }
    // Whose tree this is: either the link's own node rides along, or the
    // top-level nodes hang under a handle the tree never names — the
    // folder's real node handle, which a public link handle can alias.
    final handles = <String>{
      for (final node in raw)
        if (node['h'] is String) node['h']! as String,
    };
    var rootHandle = link.handle;
    if (!handles.contains(rootHandle)) {
      final outsideParents = <String>{
        for (final node in raw)
          if (node['p'] is String &&
              (node['p']! as String).isNotEmpty &&
              !handles.contains(node['p']))
            node['p']! as String,
      };
      if (outsideParents.contains(link.handle)) {
        rootHandle = link.handle;
      } else if (outsideParents.isNotEmpty) {
        rootHandle = outsideParents.first;
      } else {
        throw const MegaApiException(
          'the folder is gone or the link was revoked',
          code: -9,
        );
      }
    }

    // One key per node, resolved parents-first. A node's key may be
    // wrapped with its parent folder's key, or — the shape MEGA's folder
    // links actually serve — with the link's master key directly; the
    // parent's is tried first, the link's always after it, and the
    // attributes decrypting is the proof the unwrapping was right.
    final folderKeys = <String, Uint8List>{rootHandle: link.key};
    final resolved = <String, MegaNode>{};
    var pending = List<Map<String, Object?>>.of(raw);
    while (pending.isNotEmpty) {
      final deferred = <Map<String, Object?>>[];
      for (final node in pending) {
        final handle = node['h'];
        if (handle is! String) {
          continue;
        }
        final parentHandle = (node['p'] as String?) ?? rootHandle;
        final parentKey = folderKeys[parentHandle];
        var wrappers = <Uint8List>[
          if (parentKey != null && !_sameBytes(parentKey, link.key)) parentKey,
          link.key,
        ];
        var attempt = _tryResolveNode(node, wrappers);
        if (attempt == null && parentKey != null) {
          // A deeper ancestor's key can be the wrapper a nested share
          // chose; every known folder key is a legitimate candidate when
          // the attributes check is the referee.
          wrappers = folderKeys.values.toList(growable: false);
          attempt = _tryResolveNode(node, wrappers);
        }
        if (attempt == null) {
          if (parentKey == null) {
            // The parent's key is still coming; this node may be wrapped
            // with it, and another pass costs nothing.
            deferred.add(node);
            continue;
          }
          throw MegaApiException(
            'the folder\'s key does not fit node $handle; the link is stale',
            code: -14,
          );
        }
        final resolvedNode = attempt.$1;
        final resolvedKey = attempt.$2;
        resolved[handle] = resolvedNode;
        if (resolvedNode.isFolder) {
          folderKeys.putIfAbsent(handle, () => Uint8List.fromList(resolvedKey));
        } else {
          _fileKeys[handle] = resolvedNode.fileKey!;
        }
      }
      if (deferred.length == pending.length) {
        throw const MegaApiException(
          'the node tree has a node whose parent never arrived',
          code: -3,
        );
      }
      pending = deferred;
    }
    return MegaTree(
      rootHandle: rootHandle,
      nodes: resolved.values.toList(growable: false),
    );
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  /// The node, and its unwrapped key — the folder key when it is a folder,
  /// the merged file key when it is a file.
  (MegaNode, Uint8List)? _tryResolveNode(
    Map<String, Object?> raw,
    List<Uint8List> wrapperKeys,
  ) {
    final handle = raw['h'] as String;
    final isFolder = raw['t'] == 1;
    final at = raw['a'];
    final kField = raw['k'];
    if (kField is! String || kField.isEmpty) {
      return null;
    }
    final alternatives = <String>[
      for (final alternative in kField.split('/')) alternative.split(':').last,
    ];
    for (final wrapperKey in wrapperKeys) {
      final wrapper = MegaAes(wrapperKey);
      for (final wrapped in alternatives) {
        Uint8List unwrapped;
        try {
          unwrapped = unwrapNodeKey(wrapped, wrapper);
        } on FormatException {
          continue;
        }
        if (isFolder ? unwrapped.length != 16 : unwrapped.length != 32) {
          continue;
        }
        Map<String, Object?>? attributes;
        if (at is String) {
          attributes = decryptNodeAttributes(at, unwrapped);
          if (attributes == null) {
            continue;
          }
        }
        final name = attributes?['n'];
        final size = raw['s'];
        final ts = raw['ts'];
        return (
          MegaNode(
            handle: handle,
            parentHandle: (raw['p'] as String?) ?? '',
            isFolder: isFolder,
            name: name is String && name.isNotEmpty ? name : handle,
            sizeBytes: size is int
                ? size
                : size is String
                ? int.tryParse(size) ?? 0
                : 0,
            modifiedUtc: ts is int
                ? DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: true)
                : DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
            fileKey: isFolder ? null : MegaFileKey(unwrapped),
          ),
          unwrapped,
        );
      }
    }
    return null;
  }

  /// Opens the file node's byte stream: one `g` command for the download
  /// URL, one ranged GET for the ciphertext, CTR-decrypted on the way out
  /// (§3). The MAC chain comes with it — the caller feeds it the same bytes
  /// it writes, and the meta-MAC it condenses to is checked against
  /// [MegaFileKey.metaMac] by the cache.
  Future<MegaFileDownload> openFile(String nodeHandle) async {
    final response = await _command(<String, Object?>{
      'a': 'g',
      'g': 1,
      'ssl': 2,
      'n': nodeHandle,
    });
    final url = response['g'];
    final size = response['s'];
    if (url is! String || !url.startsWith('http') || size is! int) {
      throw const MegaApiException(
        'the download answer has no usable URL or size',
        code: -3,
      );
    }
    final key = _fileKeys[nodeHandle];
    if (key == null) {
      throw StateError(
        'node $nodeHandle was never in a fetched tree; fetchNodes() first',
      );
    }
    final mac = key.mac;
    final ctr = key.ctr;
    if (size == 0) {
      return MegaFileDownload(
        sizeBytes: 0,
        plaintext: const Stream<List<int>>.empty(),
        key: key,
        mac: mac,
      );
    }
    final request = http.Request('GET', Uri.parse('$url/0-${size - 1}'));
    final responseStream = await _httpClient.send(request);
    if (responseStream.statusCode == _httpBandwidth) {
      await responseStream.stream.drain<void>();
      final wait = responseStream.headers['x-mega-time-left'];
      throw MegaApiException(
        'MEGA\'s transfer quota for this network is used up'
        '${wait == null ? '' : '; it resets in $wait seconds'}',
        code: -17,
      );
    }
    if (responseStream.statusCode != _httpOk) {
      await responseStream.stream.drain<void>();
      throw MegaApiException(
        'the download server answered HTTP ${responseStream.statusCode}',
        code: 0,
      );
    }
    return MegaFileDownload(
      sizeBytes: size,
      plaintext: responseStream.stream.map(
        (chunk) => ctr.process(Uint8List.fromList(chunk)),
      ),
      key: key,
      mac: mac,
    );
  }

  /// One API round trip: POST the single-command array, unwrap the answer
  /// array, retry `-3` (overload) with backoff, map every other negative
  /// code to words.
  Future<Map<String, Object?>> _command(Map<String, Object?> command) async {
    var attempt = 0;
    while (true) {
      final uri = _apiBaseUri.resolve('cs?n=${link.handle}');
      final response = await _httpClient.post(
        uri,
        body: jsonEncode(<Object?>[command]),
      );
      if (response.statusCode == _httpBandwidth) {
        throw const MegaApiException(
          'MEGA\'s transfer quota for this network is used up; try again '
          'later',
          code: -17,
        );
      }
      if (response.statusCode != _httpOk) {
        throw MegaApiException(
          'the API gateway answered HTTP ${response.statusCode}',
          code: 0,
        );
      }
      Object? decoded;
      try {
        decoded = jsonDecode(response.body);
      } on FormatException {
        throw const MegaApiException('the answer is not JSON', code: 0);
      }
      if (decoded is! List || decoded.isEmpty) {
        throw const MegaApiException('the answer is empty', code: 0);
      }
      final answer = decoded.first;
      if (answer is int && answer < 0) {
        if (answer == -3 && attempt < _maxRetries) {
          attempt++;
          await Future<void>.delayed(retryDelay * attempt);
          continue;
        }
        throw MegaApiException(_describeCode(answer), code: answer);
      }
      if (answer is Map<String, Object?>) {
        return answer;
      }
      throw const MegaApiException('the answer is not an object', code: 0);
    }
  }

  static String _describeCode(int code) => switch (code) {
    -1 => 'an internal MEGA error',
    -2 => 'the request was not understood',
    -3 => 'MEGA is congested; try again',
    -4 => 'too many requests; wait a moment',
    -9 => 'the folder is gone or the link was revoked',
    -11 => 'the link does not allow reading',
    -16 => 'the account behind the link was blocked',
    -17 || -24 =>
      'MEGA\'s transfer quota for this network is used up; try '
          'again later',
    -18 => 'the resource is temporarily unavailable; try again later',
    _ => 'error $code',
  };
}
