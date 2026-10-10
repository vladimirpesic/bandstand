import 'dart:convert';

import 'package:bandstand/io/json_support.dart';
import 'package:bandstand/io/mega/mega_client.dart';

/// The Unix epoch, the stand-in modified time when MEGA did not say.
final DateTime epochUtc = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

/// What a file in the library is, from its name alone.
enum LibraryEntryKind {
  /// An audio track: `.mp3` or `.wav`.
  track,

  /// A volume's `book.pdf`.
  book,

  /// Anything else the folder holds. Recorded, never fetched by the
  /// UI, so a stray file in the tree is visible rather than mysterious.
  other;

  /// The kind a file name carries, by extension.
  static LibraryEntryKind ofName(String name) {
    final extension = name.substring(name.lastIndexOf('.') + 1).toLowerCase();
    return switch (extension) {
      'mp3' || 'wav' => LibraryEntryKind.track,
      'pdf' => LibraryEntryKind.book,
      _ => LibraryEntryKind.other,
    };
  }
}

/// One file in one volume of the library, as the folder link describes it.
class LibraryEntry {
  /// Create the record.
  const LibraryEntry({
    required this.id,
    required this.name,
    required this.kind,
    required this.sizeBytes,
    required this.checksum,
    required this.modifiedUtc,
  });

  /// The track's ordinal parsed from its `NNN_` prefix, null without one.
  int? get trackNumber {
    final match = RegExp(r'^(\d+)_').firstMatch(name);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  /// The name as a person reads it: `006_blues_in_bb` → `Blues in Bb`.
  String get displayName => canonicalDisplayName(name);

  /// The node's handle — the key everything local is reconciled by (§4).
  final String id;

  /// The canonical file name, byte for byte as on MEGA.
  final String name;

  /// What the file is.
  final LibraryEntryKind kind;

  /// Size in bytes; the cheap half of the presence check (§5).
  final int sizeBytes;

  /// The file's meta-MAC, base64 — the checksum a download is verified
  /// against (§3). Empty when the tree did not carry one, which the cache
  /// reads as "not verifiable", never as "verified".
  final String checksum;

  /// When MEGA last saw the file change.
  final DateTime modifiedUtc;

  @override
  bool operator ==(Object other) =>
      other is LibraryEntry &&
      other.id == id &&
      other.name == name &&
      other.kind == kind &&
      other.sizeBytes == sizeBytes &&
      other.checksum == checksum &&
      other.modifiedUtc == modifiedUtc;

  @override
  int get hashCode =>
      Object.hash(id, name, kind, sizeBytes, checksum, modifiedUtc);

  @override
  String toString() => 'LibraryEntry($id, $name)';
}

/// One tree file as the manifest records it.
LibraryEntry _entryOfNode(MegaNode file) => LibraryEntry(
  id: file.handle,
  name: file.name,
  kind: LibraryEntryKind.ofName(file.name),
  sizeBytes: file.sizeBytes,
  checksum: file.fileKey?.metaMacBase64 ?? '',
  modifiedUtc: file.modifiedUtc,
);

/// One volume folder: tracks and its book, canonical order.
class LibraryVolume {
  /// Create the record.
  const LibraryVolume({
    required this.id,
    required this.name,
    required this.entries,
  });

  /// The volume's ordinal parsed from its `NNN_` prefix, null without one.
  int? get volumeNumber {
    final match = RegExp(r'^(\d+)_').firstMatch(name);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  /// The name as a person reads it: `001_how_to_play_and_improvise_jazz`
  /// → `How To Play And Improvise Jazz`.
  String get displayName => canonicalDisplayName(name);

  /// The volume folder's node handle.
  final String id;

  /// The canonical folder name.
  final String name;

  /// The files inside, sorted by name — which the tree's zero-padded
  /// discipline makes the track order.
  final List<LibraryEntry> entries;

  /// The tracks, in order.
  Iterable<LibraryEntry> get tracks =>
      entries.where((entry) => entry.kind == LibraryEntryKind.track);

  /// The volume's book, when there is one.
  LibraryEntry? get book {
    for (final entry in entries) {
      if (entry.kind == LibraryEntryKind.book) {
        return entry;
      }
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is LibraryVolume &&
      other.id == id &&
      other.name == name &&
      _listEquals(other.entries, entries);

  @override
  int get hashCode => Object.hash(id, name, Object.hashAll(entries));

  @override
  String toString() => 'LibraryVolume($id, $name, ${entries.length} entries)';
}

/// The folder tree as of one sync: the truth everything local reconciles
/// against (§4 of `docs/rules/mega-library.md`).
class LibraryManifest {
  /// Create the manifest.
  const LibraryManifest({
    required this.rootId,
    required this.rootName,
    required this.generatedUtc,
    required this.volumes,
    this.rootFiles = const <LibraryEntry>[],
  });

  /// Fetch the link's whole tree in one call: the root folder's volume
  /// folders, and each one's files — the only network the manifest ever
  /// needs (§8).
  ///
  /// The volume level is found, not assumed: the link may name the library
  /// folder itself, or a folder wrapping it — the volumes are the first
  /// level of folders whose children include files.
  static Future<LibraryManifest> fetch(MegaFolderClient mega) async {
    final tree = await mega.fetchNodes();
    MegaNode? root;
    String? libraryName;
    final byParent = <String, List<MegaNode>>{};
    for (final node in tree.nodes) {
      if (node.handle == tree.rootHandle && node.isFolder) {
        root = node;
        continue;
      }
      byParent.putIfAbsent(node.parentHandle, () => []).add(node);
    }
    if (byParent[tree.rootHandle] == null &&
        root == null &&
        tree.nodes.isEmpty) {
      throw const MegaApiException(
        'the folder is gone or the link was revoked',
        code: -9,
      );
    }
    List<MegaNode> childrenOf(String handle) =>
        byParent[handle] ?? const <MegaNode>[];
    List<MegaNode> foldersUnder(String handle) =>
        childrenOf(handle).where((node) => node.isFolder).toList();
    // A volume is a folder whose children are files, and nothing else: the
    // levels above it — a link to a folder wrapping the library, stray
    // files beside the volumes — are descended through.
    bool isVolume(MegaNode folder) {
      final children = childrenOf(folder.handle);
      return children.isNotEmpty && children.every((node) => !node.isFolder);
    }

    var level = foldersUnder(tree.rootHandle);
    while (level.isNotEmpty && !level.any(isVolume)) {
      // A single folder on the way down names the library; deeper
      // nesting flattens.
      if (level.length == 1 && libraryName == null) {
        libraryName = level.single.name;
      }
      level = <MegaNode>[
        for (final folder in level) ...foldersUnder(folder.handle),
      ];
    }
    if (level.isEmpty) {
      throw const MegaApiException('the folder holds no volumes', code: -9);
    }
    level.sort((a, b) => a.name.compareTo(b.name));
    final folders = level;
    // Files that live beside the volumes — the tuning notes and the
    // handbook at the library's own root — are the library's front matter:
    // they ride along as the manifest's root files rather than being
    // descended past.
    final volumeParents = <String>{
      for (final folder in folders) folder.parentHandle,
    };
    final rootFiles = <MegaNode>[
      for (final node in tree.nodes)
        if (!node.isFolder && volumeParents.contains(node.parentHandle)) node,
    ]..sort((a, b) => a.name.compareTo(b.name));
    final volumes = <LibraryVolume>[];
    for (final folder in folders) {
      final files =
          (byParent[folder.handle] ?? const <MegaNode>[])
              .where((node) => !node.isFolder)
              .toList()
            ..sort((a, b) => a.name.compareTo(b.name));
      volumes.add(
        LibraryVolume(
          id: folder.handle,
          name: folder.name,
          entries: <LibraryEntry>[for (final file in files) _entryOfNode(file)],
        ),
      );
    }
    return LibraryManifest(
      rootId: tree.rootHandle,
      rootName: root?.name ?? libraryName ?? 'jamey_aebersold',
      generatedUtc: DateTime.now().toUtc(),
      volumes: volumes,
      rootFiles: <LibraryEntry>[
        for (final file in rootFiles) _entryOfNode(file),
      ],
    );
  }

  /// The `jamey_aebersold` folder's node handle.
  final String rootId;

  /// Its name.
  final String rootName;

  /// When this snapshot was taken.
  final DateTime generatedUtc;

  /// The volumes, in canonical order.
  final List<LibraryVolume> volumes;

  /// The files that live beside the volumes — the library's own front
  /// matter, shown at the top of the library rather than inside a volume.
  final List<LibraryEntry> rootFiles;

  /// [rootFiles] as the rest of the app sees a folder's contents: one
  /// volume-shaped view of the library's root, so a download, a presence
  /// check or a player open needs no special case at the root.
  LibraryVolume get rootVolume =>
      LibraryVolume(id: rootId, name: rootName, entries: rootFiles);

  /// Every volume-shaped view of the tree, the root's first — the walk the
  /// cache makes of a whole manifest.
  Iterable<LibraryVolume> get allVolumes sync* {
    if (rootFiles.isNotEmpty) {
      yield rootVolume;
    }
    yield* volumes;
  }

  /// The entry with [entryId], and its volume — the root volume for a root
  /// file — when the manifest has them.
  (LibraryVolume, LibraryEntry)? entryById(String entryId) {
    for (final volume in allVolumes) {
      for (final entry in volume.entries) {
        if (entry.id == entryId) {
          return (volume, entry);
        }
      }
    }
    return null;
  }

  /// Every entry: the root files, then every volume's.
  Iterable<LibraryEntry> get allEntries sync* {
    yield* rootFiles;
    for (final volume in volumes) {
      yield* volume.entries;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is LibraryManifest &&
      other.rootId == rootId &&
      other.rootName == rootName &&
      other.generatedUtc == generatedUtc &&
      _listEquals(other.rootFiles, rootFiles) &&
      _listEquals(other.volumes, volumes);

  @override
  int get hashCode => Object.hash(
    rootId,
    rootName,
    generatedUtc,
    Object.hashAll(rootFiles),
    Object.hashAll(volumes),
  );

  @override
  String toString() =>
      'LibraryManifest($rootId, ${volumes.length} volumes, '
      '${rootFiles.length} root files, $generatedUtc)';
}

/// Reads and writes `manifest.json` (§4 of `docs/rules/mega-library.md`).
///
/// A malformed file fails naming the field, per this layer's convention —
/// the caller turns that into "refresh the manifest", not into a crash.
abstract final class LibraryManifestCodec {
  /// Serialize [manifest], indented so a curious user can read it.
  static String encode(LibraryManifest manifest) {
    return const JsonEncoder.withIndent('  ').convert(_toJson(manifest));
  }

  /// Parse the file's text.
  static LibraryManifest decode(String text) {
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (error) {
      throw SongFormatException('the manifest is not JSON: ${error.message}');
    }
    return fromJson(decoded);
  }

  /// Build from decoded JSON, failing with the field's name.
  static LibraryManifest fromJson(Object? json) {
    final object = readObject(json, 'manifest');
    final volumes = <LibraryVolume>[];
    for (final volumeJson in readList(object['volumes'], 'manifest.volumes')) {
      final volume = readObject(volumeJson, 'manifest.volumes[]');
      final entries = <LibraryEntry>[
        for (final entryJson in readList(
          volume['entries'],
          'volumes[].entries',
        ))
          _entryFromJson(entryJson, 'entries[]'),
      ];
      volumes.add(
        LibraryVolume(
          id: readNonEmptyString(volume['id'], 'volumes[].id'),
          name: readNonEmptyString(volume['name'], 'volumes[].name'),
          entries: entries,
        ),
      );
    }
    // Root files arrived after the rest of the schema: a manifest written
    // before them simply has none.
    final rootFilesJson = object['rootFiles'];
    final rootFiles = <LibraryEntry>[
      if (rootFilesJson != null)
        for (final entryJson in readList(rootFilesJson, 'manifest.rootFiles'))
          _entryFromJson(entryJson, 'rootFiles[]'),
    ];
    return LibraryManifest(
      rootId: readNonEmptyString(object['rootId'], 'manifest.rootId'),
      rootName: readNonEmptyString(object['rootName'], 'manifest.rootName'),
      generatedUtc: readTimestamp(object['generated'], 'manifest.generated'),
      volumes: volumes,
      rootFiles: rootFiles,
    );
  }

  static Map<String, Object?> _toJson(LibraryManifest manifest) =>
      <String, Object?>{
        'rootId': manifest.rootId,
        'rootName': manifest.rootName,
        'generated': manifest.generatedUtc.toIso8601String(),
        'volumes': <Object?>[
          for (final volume in manifest.volumes)
            <String, Object?>{
              'id': volume.id,
              'name': volume.name,
              'entries': <Object?>[
                for (final entry in volume.entries) _entryToJson(entry),
              ],
            },
        ],
        'rootFiles': <Object?>[
          for (final entry in manifest.rootFiles) _entryToJson(entry),
        ],
      };

  static Map<String, Object?> _entryToJson(LibraryEntry entry) =>
      <String, Object?>{
        'id': entry.id,
        'name': entry.name,
        'kind': entry.kind.name,
        'size': entry.sizeBytes,
        'checksum': entry.checksum,
        'modified': entry.modifiedUtc.toIso8601String(),
      };

  static LibraryEntry _entryFromJson(Object? json, String field) {
    final entry = readObject(json, field);
    return LibraryEntry(
      id: readNonEmptyString(entry['id'], '$field.id'),
      name: readNonEmptyString(entry['name'], '$field.name'),
      kind: readEnum(entry['kind'], LibraryEntryKind.values, '$field.kind'),
      sizeBytes: readInt(entry['size'], '$field.size'),
      checksum: readString(entry['checksum'], '$field.checksum'),
      modifiedUtc: readTimestamp(entry['modified'], '$field.modified'),
    );
  }
}

bool _listEquals<T>(List<T> a, List<T> b) {
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

/// The canonical name a person reads: strip the `NNN_` prefix, underscores
/// become spaces, first letter of each word up — and a word whose letters
/// are a roman numeral goes all the way up, because `ii_v7_i` is the
/// library's own way of writing "II–V7–I" and re-lowercasing it would be a
/// step backwards.
String canonicalDisplayName(String canonicalName) {
  final withoutPrefix = canonicalName.replaceFirst(RegExp(r'^\d+_'), '');
  final spaced = withoutPrefix
      .replaceAll('_', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (spaced.isEmpty) {
    return canonicalName;
  }
  return spaced
      .split(' ')
      .map(
        (word) =>
            _isRomanNumeral(word) ? word.toUpperCase() : _capitalize(word),
      )
      .join(' ');
}

const Set<String> _romanNumerals = <String>{
  'i',
  'ii',
  'iii',
  'iv',
  'v',
  'vi',
  'vii',
  'viii',
  'ix',
  'x',
};

bool _isRomanNumeral(String word) {
  final letters = word.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
  return letters.isNotEmpty && _romanNumerals.contains(letters);
}

String _capitalize(String word) =>
    word.isEmpty ? word : word[0].toUpperCase() + word.substring(1);
