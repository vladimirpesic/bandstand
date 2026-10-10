import 'dart:convert';
import 'dart:io';

import 'package:bandstand/io/atomic_write.dart';
import 'package:bandstand/io/json_support.dart';

/// The library's persisted choices, one JSON file in the app's
/// support directory: the MEGA folder link — the whole credential, §7 of
/// `docs/rules/mega-library.md` — and, on the desktop, where a cache of
/// this size wants a big disk, where the mirror lives.
class LibrarySettings {
  /// Create a settings value.
  const LibrarySettings({this.megaFolderLink = '', this.cacheRootOverride});

  /// The file's name inside the support directory.
  static const String fileName = 'library-settings.json';

  /// The 0012-era spelling of it, still read as a fallback so that a
  /// rename never costs the pasted link.
  static const String legacyFileName = 'aebersold-settings.json';

  /// Parse the file, or throw naming what is wrong.
  ///
  /// A missing file is not an error — it is the first run, and the
  /// defaults are the answer. A file still under the 0012-era name is
  /// parsed, written under the new one, and only then unlinked — the
  /// pasted link survives the rename (§5.4: no silent data loss).
  static LibrarySettings load(File file) {
    String text;
    File? legacy;
    try {
      text = file.readAsStringSync();
    } on FileSystemException {
      legacy = File(
        '${file.parent.path}${Platform.pathSeparator}$legacyFileName',
      );
      try {
        text = legacy.readAsStringSync();
      } on FileSystemException {
        return const LibrarySettings();
      }
    }
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const SongFormatException(
        'the library settings are not JSON; delete the file to start over',
      );
    }
    final object = readObject(decoded, 'settings');
    final link = object['megaFolderLink'];
    final override = object['cacheRootOverride'];
    if (legacy != null) {
      _carryAcross(legacy, file, text);
    }
    return LibrarySettings(
      megaFolderLink: link is String ? link : '',
      cacheRootOverride: override is String && override.trim().isNotEmpty
          ? override
          : null,
    );
  }

  /// Move a legacy file's bytes under the new name through a `.tmp` and a
  /// rename — the same discipline as every write here — and unlink the
  /// old name only once the new one answers. An unlink that fails leaves
  /// residue, not loss: the new file is the one read from now on.
  static void _carryAcross(File legacy, File file, String text) {
    file.parent.createSync(recursive: true);
    final temporary = File('${file.path}.tmp');
    temporary.writeAsStringSync(text, flush: true);
    temporary.renameSync(file.path);
    try {
      legacy.deleteSync();
    } on FileSystemException {
      // Residue, not loss.
    }
  }

  /// Whether a folder link has been pasted.
  bool get hasLink => megaFolderLink.trim().isNotEmpty;

  /// The pasted public folder link, exactly as it was given.
  final String megaFolderLink;

  /// Where the mirror lives when it is not in the default place. Desktop
  /// only: Android keeps the cache in the app's private storage, and no
  /// override is offered there.
  final String? cacheRootOverride;

  /// A copy with the folder link replaced.
  LibrarySettings withLink(String link) => LibrarySettings(
    megaFolderLink: link,
    cacheRootOverride: cacheRootOverride,
  );

  /// A copy with the cache root override replaced.
  LibrarySettings withCacheRootOverride(String? override) => LibrarySettings(
    megaFolderLink: megaFolderLink,
    cacheRootOverride: override,
  );

  /// Write to [file], atomically, indented.
  Future<void> saveTo(File file) async {
    await file.parent.create(recursive: true);
    await writeAtomically(
      file,
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'megaFolderLink': megaFolderLink,
        'cacheRootOverride': cacheRootOverride,
      }),
    );
  }
}
