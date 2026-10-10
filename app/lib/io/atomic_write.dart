import 'dart:io';

/// Writes [text] to [file] through `<file>.tmp` and a rename, §5.4's
/// discipline: a reader sees the old file or the new one, never a half of
/// either. Shared by the manifest, the cache state, the settings and the
/// MEGA client's link store alike.
Future<void> writeAtomically(File file, String text) async {
  final temporary = File('${file.path}.tmp');
  final sink = temporary.openWrite();
  try {
    sink.write(text);
    await sink.flush();
  } finally {
    await sink.close();
  }
  await temporary.rename(file.path);
}
