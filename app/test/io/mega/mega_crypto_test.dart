import 'dart:typed_data';

import 'package:bandstand/io/mega/mega_base64.dart';
import 'package:bandstand/io/mega/mega_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// The reference implementation's test buffer: `byte[i] = i % 255`.
Uint8List testBuffer(int size) =>
    Uint8List.fromList(List<int>.generate(size, (i) => i % 255));

String hexOf(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// The published vector from the reference implementation's verify test:
/// this exact key, this exact 151511-byte buffer, this exact meta-MAC. If
/// this file fails, the whole client would be decrypting garbage — which
/// is why it is first in the suite.
const String vectorKeyBase64 = 'AAAAAAAAAABnFCfbJFwAxwAAAAAAAAAAZxQn2yRcAMc';
const String vectorMetaMacHex = '671427db245c00c7';
const int vectorSize = 151511;

void main() {
  test('the base64 dialect round-trips both alphabets', () {
    final bytes = Uint8List.fromList(List<int>.generate(33, (i) => i * 7));
    final encoded = megaBase64Encode(bytes);
    expect(encoded, contains('-'));
    expect(encoded, isNot(contains('=')));
    expect(megaBase64Decode(encoded), bytes);
    // The API's standard alphabet decodes too.
    expect(
      megaBase64Decode(encoded.replaceAll('-', '+').replaceAll('_', '/')),
      bytes,
    );
    expect(() => megaBase64Decode('not base64!!'), throwsFormatException);
  });

  test('the MAC chain reproduces the published meta-MAC vector', () {
    final key = megaBase64Decode(vectorKeyBase64);
    final fileKey = MegaFileKey(key);
    // The vector's key carries the expected MAC in its last eight bytes —
    // that is the structure a download verifies against.
    expect(hexOf(fileKey.metaMac), vectorMetaMacHex);

    final whole = testBuffer(vectorSize);
    final mac = fileKey.mac;
    mac.add(whole.sublist(0, 50000));
    mac.add(whole.sublist(50000, 100000));
    mac.add(whole.sublist(100000));
    expect(hexOf(mac.condense()), vectorMetaMacHex);
  });

  test('the MAC chain is independent of how the bytes are chunked', () {
    final key = MegaFileKey(megaBase64Decode(vectorKeyBase64));
    final whole = testBuffer(vectorSize);
    final fedInOne = key.mac..add(whole);
    final acrossBoundary = MegaChunkMac(key.aesKey, key.nonce)
      ..add(whole.sublist(0, 131060))
      ..add(whole.sublist(131060, 131080))
      ..add(whole.sublist(131080));
    expect(hexOf(fedInOne.condense()), vectorMetaMacHex);
    expect(hexOf(acrossBoundary.condense()), vectorMetaMacHex);
  });

  test('the MAC chain folds a many-chunk file', () {
    // 128 KiB + 256 KiB + a partial chunk: every growth step of the chunk
    // schedule is exercised.
    final key = MegaFileKey(megaBase64Decode(vectorKeyBase64));
    final reference = MegaChunkMac(key.aesKey, key.nonce);
    final bytes = testBuffer(131072 + 262144 + 1000);
    final split = MegaChunkMac(key.aesKey, key.nonce)
      ..add(bytes.sublist(0, 131072))
      ..add(bytes.sublist(131072));
    reference.add(bytes);
    expect(split.condense(), reference.condense());
  });

  test('the MAC chain handles the empty file', () {
    final key = MegaFileKey(megaBase64Decode(vectorKeyBase64));
    expect(key.mac.condense(), hasLength(8));
  });

  test('CTR keystream matches ECB-encrypted counter blocks', () {
    // Two independent paths through the AES: the stream cipher XORing
    // plaintext, and the block cipher encrypting nonce‖counter by hand.
    final keyBytes = testBuffer(16);
    final nonce = testBuffer(8);
    final ctr = MegaCtr(keyBytes, nonce);
    final aes = MegaAes(keyBytes);
    final plaintext = testBuffer(1000); // not 16-aligned on purpose
    final encrypted = ctr.process(plaintext);
    // Decrypting again with a fresh stream gives the plaintext back.
    expect(MegaCtr(keyBytes, nonce).process(encrypted), plaintext);
    // And the first 16 bytes equal AES(nonce ‖ big-endian 0).
    final counter = Uint8List(16);
    counter.setRange(0, 8, nonce);
    final keystream = aes.ecb(counter);
    for (var i = 0; i < 16; i++) {
      expect(encrypted[i], plaintext[i] ^ keystream[i]);
    }
    // Block 2 (offset 32) uses counter 2 in the low half.
    final counter2 = Uint8List(16);
    counter2.setRange(0, 8, nonce);
    counter2[15] = 2;
    final keystream2 = aes.ecb(counter2);
    for (var i = 0; i < 16; i++) {
      expect(encrypted[32 + i], plaintext[32 + i] ^ keystream2[i]);
    }
  });

  test('node keys unwrap and file keys merge', () {
    final wrapper = testBuffer(16);
    final aes = MegaAes(wrapper);
    final fileKey = MegaFileKey.merge(
      testBuffer(16),
      testBuffer(8),
      testBuffer(8),
    );
    final wrapped = aes.ecb(fileKey.mergedBytesForTest());
    expect(
      unwrapNodeKey(megaBase64Encode(wrapped), aes),
      fileKey.mergedBytesForTest(),
    );

    final folderKey = testBuffer(16);
    final wrappedFolder = aes.ecb(folderKey);
    expect(unwrapNodeKey(megaBase64Encode(wrappedFolder), aes), folderKey);
  });

  test('attributes encrypt and decrypt, and reject wrong keys', () {
    final folderKey = testBuffer(16);
    final at = encryptNodeAttributes(<String, Object?>{
      'n': '001_how_to_play_and_improvise_jazz',
    }, folderKey);
    final decoded = decryptNodeAttributes(at, folderKey);
    expect(decoded?['n'], '001_how_to_play_and_improvise_jazz');
    final wrongKey = Uint8List.fromList(List<int>.generate(16, (i) => 200 + i));
    expect(decryptNodeAttributes(at, wrongKey), isNull);
  });
}

extension on MegaFileKey {
  Uint8List mergedBytesForTest() {
    final merged = Uint8List(32);
    merged.setRange(16, 24, nonce);
    merged.setRange(24, 32, metaMac);
    for (var i = 0; i < 16; i++) {
      merged[i] = aesKey[i] ^ merged[16 + i];
    }
    return merged;
  }
}
