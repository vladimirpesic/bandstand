import 'dart:convert';
import 'dart:typed_data';

import 'package:bandstand/io/mega/mega_base64.dart';
import 'package:pointycastle/export.dart';

/// AES-128 for the MEGA protocol, in the three shapes it is used: raw ECB
/// (key unwrapping, the MAC chain), CBC with a zero IV (node attributes),
/// and CTR (file bytes). Verified against the reference implementation's
/// published test vectors (`test/io/mega/mega_crypto_test.dart`).
class MegaAes {
  /// Create the cipher over a 16-byte [key].
  MegaAes(Uint8List key)
    : key = Uint8List.fromList(key),
      _ecbEncrypt = ECBBlockCipher(AESEngine()),
      _ecbDecrypt = ECBBlockCipher(AESEngine()) {
    if (key.length != 16) {
      throw ArgumentError.value(key.length, 'key', 'must be 16 bytes');
    }
    _ecbEncrypt.init(true, KeyParameter(this.key));
    _ecbDecrypt.init(false, KeyParameter(this.key));
  }

  /// The 128-bit key.
  final Uint8List key;
  final ECBBlockCipher _ecbEncrypt;
  final ECBBlockCipher _ecbDecrypt;

  /// Encrypts whole 16-byte [blocks] with ECB. Returns a new buffer.
  Uint8List ecb(Uint8List blocks) => _mapBlocks(blocks, _ecbEncrypt.process);

  /// Decrypts whole 16-byte [blocks] with ECB. Returns a new buffer.
  Uint8List ecbDecrypt(Uint8List blocks) =>
      _mapBlocks(blocks, _ecbDecrypt.process);

  /// CBC-encrypts [data] (a multiple of 16) with a zero IV, no padding.
  Uint8List cbcEncrypt(Uint8List data) => _cbc(data, encrypt: true);

  /// CBC-decrypts [data] (a multiple of 16) with a zero IV, no padding.
  Uint8List cbcDecrypt(Uint8List data) => _cbc(data, encrypt: false);

  Uint8List _mapBlocks(Uint8List blocks, Uint8List Function(Uint8List) one) {
    if (blocks.length % 16 != 0) {
      throw ArgumentError.value(blocks.length, 'blocks', 'must be 16-aligned');
    }
    final out = Uint8List(blocks.length);
    for (var offset = 0; offset < blocks.length; offset += 16) {
      final block = one(Uint8List.sublistView(blocks, offset, offset + 16));
      out.setRange(offset, offset + 16, block);
    }
    return out;
  }

  Uint8List _cbc(Uint8List data, {required bool encrypt}) {
    if (data.length % 16 != 0) {
      throw ArgumentError.value(data.length, 'data', 'must be 16-aligned');
    }
    final cipher = CBCBlockCipher(AESEngine())
      ..init(
        encrypt,
        ParametersWithIV<KeyParameter>(KeyParameter(key), Uint8List(16)),
      );
    final out = Uint8List(data.length);
    for (var offset = 0; offset < data.length; offset += 16) {
      final block = cipher.process(
        Uint8List.sublistView(data, offset, offset + 16),
      );
      out.setRange(offset, offset + 16, block);
    }
    return out;
  }
}

/// AES-128-CTR over a file: the IV is the 8-byte nonce and a zeroed 8-byte
/// counter, incremented big-endian per 16-byte block — exactly Node's
/// `aes-128-ctr`, which is exactly MEGA's file stream.
class MegaCtr {
  /// Create the stream over [key] and [nonce].
  MegaCtr(Uint8List key, Uint8List nonce)
    : _cipher = SICStreamCipher(AESEngine()) {
    final iv = Uint8List(16);
    iv.setRange(0, 8, truncateTo(nonce, 8));
    _cipher.init(true, ParametersWithIV<KeyParameter>(KeyParameter(key), iv));
  }

  final SICStreamCipher _cipher;

  /// XORs [data] with the keystream from here on. Returns a new buffer;
  /// call with ciphertext for decrypt, plaintext for encrypt — CTR is its
  /// own inverse.
  Uint8List process(Uint8List data) {
    final out = Uint8List(data.length);
    _cipher.processBytes(data, 0, data.length, out, 0);
    return out;
  }
}

/// MEGA's chunked MAC over a file's plaintext: the integrity half of the
/// protocol (`docs/rules/mega-library.md` §3).
///
/// The chain starts from the nonce doubled to 16 bytes; every 16-byte block
/// is XORed in and encrypted with ECB; at each chunk boundary (128 KiB,
/// then growing by 128 KiB a step up to 1 MiB) the running value is pushed
/// and the chain restarts from the nonce. The file's meta-MAC is the
/// sequence folded: XOR-and-encrypt over all chunk MACs, then the 16 result
/// bytes folded to 8.
class MegaChunkMac {
  /// Create the chain over [key] and [nonce].
  MegaChunkMac(Uint8List key, Uint8List nonce)
    : _aes = MegaAes(key),
      _nonce = Uint8List.fromList(truncateTo(nonce, 8)) {
    _mac = Uint8List(16);
    _mac.setRange(0, 8, _nonce);
    _mac.setRange(8, 16, _nonce);
  }

  static const int _firstChunk = 131072; // 2^17
  static const int _chunkStep = 131072;
  static const int _chunkCap = 1048576; // 2^20

  final MegaAes _aes;
  final Uint8List _nonce;
  final List<Uint8List> _chunkMacs = <Uint8List>[];
  late Uint8List _mac;
  Uint8List _pending = Uint8List(0);
  int _pos = 0;
  int _posNext = _firstChunk;
  int _increment = _firstChunk;

  /// Feeds plaintext through the chain. Any chunking of the calls is
  /// irrelevant — only the bytes and their order matter: a partial block
  /// at the end of one call is held back and completed by the next, the
  /// way the protocol's own 16-byte framing does it.
  void add(List<int> plaintext) {
    var data = plaintext;
    if (_pending.isNotEmpty) {
      final needed = 16 - _pending.length;
      if (data.length < needed) {
        _pending = Uint8List.fromList(<int>[..._pending, ...data]);
        return;
      }
      _pending = Uint8List.fromList(<int>[
        ..._pending,
        ...data.sublist(0, needed),
      ]);
      _block(_pending);
      _pending = Uint8List(0);
      data = data.sublist(needed);
    }
    final fullBlocks = (data.length ~/ 16) * 16;
    for (var start = 0; start < fullBlocks; start += 16) {
      _blockAt(data, start);
    }
    if (fullBlocks < data.length) {
      _pending = Uint8List.fromList(data.sublist(fullBlocks));
    }
  }

  void _block(List<int> bytes) {
    for (var j = 0; j < 16; j++) {
      _mac[j] ^= bytes[j];
    }
    _mac = _aes.ecb(_mac);
    _boundary();
  }

  void _blockAt(List<int> bytes, int offset) {
    for (var j = 0; j < 16; j++) {
      _mac[j] ^= bytes[offset + j];
    }
    _mac = _aes.ecb(_mac);
    _boundary();
  }

  void _boundary() {
    _pos += 16;
    if (_pos < _posNext) {
      return;
    }
    _chunkMacs.add(Uint8List.fromList(_mac));
    _mac = Uint8List(16);
    _mac.setRange(0, 8, _nonce);
    _mac.setRange(8, 16, _nonce);
    if (_increment < _chunkCap) {
      _increment += _chunkStep;
    }
    _posNext += _increment;
  }

  /// The running chain value, for diagnostics.
  Uint8List get debugMac => Uint8List.fromList(_mac);

  /// How many complete chunk MACs the chain has pushed, for diagnostics.
  int get debugChunkCount => _chunkMacs.length;

  /// Folds everything fed so far into the 8-byte meta-MAC. The chain is
  /// spent afterwards.
  Uint8List condense() {
    if (_pending.isNotEmpty) {
      // The stream's last block, zero-padded — the framing the protocol's
      // own flush produces.
      for (var j = 0; j < _pending.length; j++) {
        _mac[j] ^= _pending[j];
      }
      _mac = _aes.ecb(_mac);
      _boundary();
      _pending = Uint8List(0);
    }
    final macs = List<Uint8List>.of(_chunkMacs)..add(Uint8List.fromList(_mac));
    var folded = Uint8List(16);
    for (final mac in macs) {
      for (var j = 0; j < 16; j++) {
        folded[j] ^= mac[j];
      }
      folded = _aes.ecb(folded);
    }
    final meta = Uint8List(8);
    for (var i = 0; i < 4; i++) {
      meta[i] = folded[i] ^ folded[4 + i];
      meta[4 + i] = folded[8 + i] ^ folded[12 + i];
    }
    return meta;
  }
}

/// A file node's unwrapped 32-byte key, split the way the protocol uses it:
/// the AES-128 key (stored XOR-merged with the second half), the 8-byte
/// nonce for CTR and the MAC chain, and the 8-byte meta-MAC the uploader
/// baked in — the value a download's chain must condense to (§3).
class MegaFileKey {
  /// Create from the 32-byte merged form the node listing carries after
  /// ECB unwrapping.
  MegaFileKey(Uint8List merged)
    : nonce = Uint8List.sublistView(merged, 16, 24),
      metaMac = Uint8List.sublistView(merged, 24, 32) {
    if (merged.length != 32) {
      throw ArgumentError.value(merged.length, 'merged', 'must be 32 bytes');
    }
    final aesKey = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      aesKey[i] = merged[i] ^ merged[16 + i];
    }
    this.aesKey = aesKey;
  }

  /// The merged form: `merge(aes, nonce, mac)` is
  /// `aes ⊕ (nonce ‖ mac) ‖ nonce ‖ mac` — what the upload side writes and
  /// what the tests build nodes with.
  factory MegaFileKey.merge(
    Uint8List aesKey,
    Uint8List nonce,
    Uint8List metaMac,
  ) {
    final merged = Uint8List(32);
    merged.setRange(16, 24, truncateTo(nonce, 8));
    merged.setRange(24, 32, truncateTo(metaMac, 8));
    for (var i = 0; i < 16; i++) {
      merged[i] = aesKey[i] ^ merged[16 + i];
    }
    return MegaFileKey(merged);
  }

  /// The AES-128 key, un-merged from the stored form.
  late final Uint8List aesKey;

  /// The CTR and MAC nonce.
  final Uint8List nonce;

  /// The expected meta-MAC.
  final Uint8List metaMac;

  /// The meta-MAC the way the manifest records it.
  String get metaMacBase64 => megaBase64Encode(metaMac);

  /// A fresh CTR stream for this file.
  MegaCtr get ctr => MegaCtr(aesKey, nonce);

  /// A fresh MAC chain for this file.
  MegaChunkMac get mac => MegaChunkMac(aesKey, nonce);

  /// The cipher this file's attributes were encrypted with.
  MegaAes get attributeCipher => MegaAes(aesKey);
}

/// The AES-128-ECB unwrapping of a node key: 16 bytes for a folder (its own
/// key), 32 for a file (the merged key + nonce + meta-MAC), wrapped with
/// the parent folder's — or the share root's — key.
Uint8List unwrapNodeKey(String wrappedBase64, MegaAes wrapper) {
  final wrapped = megaBase64Decode(wrappedBase64);
  if (wrapped.isEmpty || wrapped.length % 16 != 0 || wrapped.length > 32) {
    throw const FormatException('a node key is 16 or 32 bytes, no more');
  }
  return wrapper.ecbDecrypt(wrapped);
}

/// The AES key a node's attributes were encrypted with: folders hand their
/// 16 bytes over directly; files' merged keys must be un-merged first.
Uint8List attributeKeyOf(Uint8List nodeKey) {
  if (nodeKey.length == 16) {
    return nodeKey;
  }
  if (nodeKey.length == 32) {
    final key = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      key[i] = nodeKey[i] ^ nodeKey[16 + i];
    }
    return key;
  }
  throw const FormatException('a node key is 16 or 32 bytes');
}

/// Decrypts a node's `at` attribute blob. Returns null when the key is
/// wrong or the blob is not MEGA's `MEGA{…}` JSON — the caller is trying
/// candidate keys, and a null is one more candidate rejected.
Map<String, Object?>? decryptNodeAttributes(
  String atBase64,
  Uint8List nodeKey,
) {
  Uint8List blob;
  try {
    blob = megaBase64Decode(atBase64);
  } on FormatException {
    return null;
  }
  if (blob.isEmpty || blob.length % 16 != 0) {
    return null;
  }
  final plain = MegaAes(attributeKeyOf(nodeKey)).cbcDecrypt(blob);
  var end = plain.indexOf(0);
  if (end < 0) {
    end = plain.length;
  }
  final text = utf8.decode(plain.sublist(0, end), allowMalformed: true);
  if (!text.startsWith('MEGA{')) {
    return null;
  }
  Object? decoded;
  try {
    decoded = jsonDecode(text.substring(4));
  } on FormatException {
    return null;
  }
  return decoded is Map<String, Object?> ? decoded : null;
}

/// Encrypts [attributes] into a node's `at` blob — the upload side of the
/// same format, used by the test server that has to produce real nodes.
String encryptNodeAttributes(
  Map<String, Object?> attributes,
  Uint8List nodeKey,
) {
  final text = 'MEGA${jsonEncode(attributes)}';
  final bytes = utf8.encode(text);
  final padded = Uint8List((bytes.length + 1 + 15) & ~15);
  padded.setAll(0, bytes);
  final blob = MegaAes(attributeKeyOf(nodeKey)).cbcEncrypt(padded);
  return megaBase64Encode(blob);
}
