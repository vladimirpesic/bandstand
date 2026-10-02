import 'dart:math';

/// A random identifier for a song or a playlist.
///
/// Version 4 UUIDs, from `Random.secure`. Twenty lines against a dependency is
/// the trade §15 asks for; there is nothing here worth owning someone else's
/// package for.
String newUuid([Random? random]) {
  final source = random ?? _secure;
  final bytes = List<int>.generate(16, (_) => source.nextInt(256));
  // Version 4, variant 1, as RFC 4122 requires.
  bytes[6] = (bytes[6] & 0x0F) | 0x40;
  bytes[8] = (bytes[8] & 0x3F) | 0x80;

  final hex = StringBuffer();
  for (var i = 0; i < bytes.length; i++) {
    if (i == 4 || i == 6 || i == 8 || i == 10) {
      hex.write('-');
    }
    hex.write(bytes[i].toRadixString(16).padLeft(2, '0'));
  }
  return hex.toString();
}

/// Whether [text] looks like a UUID this app wrote.
///
/// Used to keep the library from opening files whose names it did not choose —
/// a stray `.song.json` in the folder is fine, a path traversal is not.
bool isUuid(String text) => _uuidPattern.hasMatch(text);

final Random _secure = Random.secure();

final RegExp _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);
