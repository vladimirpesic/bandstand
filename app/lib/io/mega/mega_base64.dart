import 'dart:convert';
import 'dart:typed_data';

/// MEGA's base64 dialect: the URL-safe alphabet (`-` and `_`), no padding.
///
/// Decoding is generous the way the protocol needs it to be: the URL-safe
/// alphabet is translated back, standard-alphabet input decodes unchanged
/// (the API uses both), and padding is optional. Encoding always produces
/// the URL-safe, unpadded form MEGA's links and key fields are written in.

/// Decodes [text] (URL-safe or standard base64, padded or not).
///
/// Throws `FormatException` when the input is not base64 in either dialect —
/// a key that decodes to nothing can never decrypt anything, so it fails
/// here, loudly, instead of three layers down.
Uint8List megaBase64Decode(String text) {
  var normalized = text
      .trim()
      .replaceAll('-', '+')
      .replaceAll('_', '/')
      .replaceAll('=', '');
  final remainder = normalized.length % 4;
  if (remainder == 1) {
    throw const FormatException('not base64: a dangling single character');
  }
  final padding = switch (remainder) {
    2 || 3 => '=' * (4 - remainder),
    _ => '',
  };
  normalized += padding;
  return base64.decode(normalized);
}

/// Encodes [bytes] in MEGA's dialect: URL-safe, unpadded.
String megaBase64Encode(List<int> bytes) => base64
    .encode(bytes)
    .replaceAll('+', '-')
    .replaceAll('/', '_')
    .replaceAll('=', '');

/// The first [length] bytes of a buffer that must be exactly that long.
///
/// MEGA fields are fixed-size; a `k` that decodes to the wrong length is a
/// wrong key, not a shorter one.
Uint8List truncateTo(Uint8List bytes, int length) {
  if (bytes.length < length) {
    throw FormatException(
      'expected $length bytes, the field decoded to ${bytes.length}',
    );
  }
  return Uint8List.sublistView(bytes, 0, length);
}
