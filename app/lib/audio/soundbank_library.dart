import 'dart:io';

/// A soundbank on disk, offered to the user.
class SoundbankFile {
  /// Create an entry.
  const SoundbankFile({
    required this.path,
    required this.name,
    required this.sizeBytes,
    required this.isSystem,
  });

  /// Where it is.
  final String path;

  /// Its file name, without the extension.
  final String name;

  /// How big it is.
  final int sizeBytes;

  /// Whether it came from the system rather than the user's library.
  final bool isSystem;

  /// Its size, as a person would say it.
  String get sizeLabel {
    const megabyte = 1024 * 1024;
    if (sizeBytes >= megabyte) {
      return '${(sizeBytes / megabyte).toStringAsFixed(1)} MB';
    }
    return '${(sizeBytes / 1024).round()} kB';
  }

  @override
  bool operator ==(Object other) =>
      other is SoundbankFile && other.path == path;

  @override
  int get hashCode => path.hashCode;
}

/// Finds the soundbanks a machine has.
///
/// The library's own `soundbanks/` folder first, then the places a Linux box
/// keeps a General MIDI bank. §7.2 says SF2 first, and a user with no bank at
/// all should still be able to hear something without hunting.
abstract final class SoundbankLibrary {
  /// Where a system General MIDI bank tends to live.
  static const List<String> systemDirectories = <String>[
    '/usr/share/sounds/sf2',
    '/usr/share/soundfonts',
    '/usr/share/sounds/sf3',
  ];

  /// Every soundbank found, the library's own first.
  static List<SoundbankFile> scan(Directory libraryFolder) {
    final found = <String, SoundbankFile>{};

    void add(Directory directory, {required bool isSystem}) {
      if (!directory.existsSync()) {
        return;
      }
      final List<FileSystemEntity> entries;
      try {
        entries = directory.listSync();
      } on FileSystemException {
        // A directory that cannot be read — one of the system paths with
        // restrictive permissions — is skipped, not fatal. This call sat
        // outside the try below, so an unreadable *directory* aborted the
        // whole scan and took the player's own library folder with it, which
        // is the opposite of what that catch promises.
        return;
      }
      for (final entity in entries.whereType<File>()) {
        try {
          final path = entity.resolveSymbolicLinksSync();
          if (!path.toLowerCase().endsWith('.sf2')) {
            continue;
          }
          if (found.containsKey(path)) {
            continue;
          }
          final name = entity.uri.pathSegments.last;
          found[path] = SoundbankFile(
            path: path,
            // The extension filter above is case-insensitive (`.SF2`
            // passes), so the stripping has to be too — otherwise the
            // display name keeps an extension the filter said was gone.
            name: name.toLowerCase().endsWith('.sf2')
                ? name.substring(0, name.length - 4)
                : name,
            sizeBytes: entity.lengthSync(),
            isSystem: isSystem,
          );
        } on FileSystemException {
          // A broken symlink or a file that vanished mid-scan must not
          // take down the whole list: skip what cannot be stat'ed.
          continue;
        }
      }
    }

    add(libraryFolder, isSystem: false);
    for (final directory in systemDirectories) {
      add(Directory(directory), isSystem: true);
    }

    final all = found.values.toList()
      ..sort((a, b) {
        if (a.isSystem != b.isSystem) {
          return a.isSystem ? 1 : -1;
        }
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    return all;
  }
}
