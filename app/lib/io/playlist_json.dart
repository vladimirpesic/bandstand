import 'dart:convert';

import 'package:bandstand/domain/harmony/key_signature.dart';
import 'package:bandstand/domain/song/playlist.dart';

import 'json_support.dart';

/// The schema version this build writes.
const int playlistSchemaVersion = 1;

/// One step of a playlist migration.
typedef PlaylistMigration = Map<String, Object?> Function(
  Map<String, Object?> json,
);

/// The playlist migrations this build knows, keyed by the version they migrate
/// *from*.
const Map<int, PlaylistMigration> playlistMigrations =
    <int, PlaylistMigration>{};

/// Reading and writing `.playlist.json` (§5.1).
///
/// Schema in `docs/format/song-schema.md`. Every field of an entry except the
/// song id is an override, and none of it is ever written back to a song.
abstract final class PlaylistJson {
  /// Encode [playlist] as pretty-printed JSON.
  static String encode(Playlist playlist) =>
      const JsonEncoder.withIndent('  ').convert(toJson(playlist));

  /// Decode a playlist from a `.playlist.json` file.
  ///
  /// Throws [SongFormatException] if the file is malformed or from a newer
  /// schema.
  static Playlist decode(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error) {
      throw SongFormatException('not valid JSON: ${error.message}');
    }
    return fromJson(readObject(decoded, 'playlist'));
  }

  /// Turn a playlist into the JSON structure the file holds.
  static Map<String, Object?> toJson(Playlist playlist) => <String, Object?>{
    'schemaVersion': playlistSchemaVersion,
    'id': playlist.id,
    'name': playlist.name,
    if (playlist.note.isNotEmpty) 'note': playlist.note,
    'createdAt': playlist.createdAt.toIso8601String(),
    'modifiedAt': playlist.modifiedAt.toIso8601String(),
    'entries': <Map<String, Object?>>[
      for (final entry in playlist.entries)
        <String, Object?>{
          'songId': entry.songId,
          if (entry.tempoOverride != null) 'tempo': entry.tempoOverride,
          if (entry.transposeOverride != null)
            'transpose': entry.transposeOverride,
          if (entry.keyOverride != null) 'key': entry.keyOverride.toString(),
          if (entry.chorusCount != null) 'choruses': entry.chorusCount,
          if (entry.note.isNotEmpty) 'note': entry.note,
        },
    ],
  };

  /// Build a playlist from the JSON structure the file holds.
  ///
  /// Throws [SongFormatException] if the file is malformed or from a newer
  /// schema.
  static Playlist fromJson(Map<String, Object?> raw) {
    final json = _migrate(raw);
    return Playlist(
      id: readNonEmptyString(json['id'], 'id'),
      name: readNonEmptyString(json['name'], 'name'),
      note: json['note'] == null ? '' : readString(json['note'], 'note'),
      createdAt: json['createdAt'] == null
          ? null
          : readTimestamp(json['createdAt'], 'createdAt'),
      modifiedAt: json['modifiedAt'] == null
          ? null
          : readTimestamp(json['modifiedAt'], 'modifiedAt'),
      entries: <PlaylistEntry>[
        for (final entry in readList(
          json['entries'] ?? const <Object?>[],
          'entries',
        ))
          _entryFromJson(readObject(entry, 'entries')),
      ],
    );
  }

  static PlaylistEntry _entryFromJson(Map<String, Object?> json) {
    final keyText = json['key'];
    KeySignature? key;
    if (keyText != null) {
      key = KeySignature.tryParse(readString(keyText, 'entry.key'));
      if (key == null) {
        throw SongFormatException(
          '"$keyText" is not a key',
          field: 'entry.key',
        );
      }
    }
    return PlaylistEntry(
      songId: readNonEmptyString(json['songId'], 'entry.songId'),
      tempoOverride: json['tempo'] == null
          ? null
          : readInt(json['tempo'], 'entry.tempo'),
      transposeOverride: json['transpose'] == null
          ? null
          : readInt(json['transpose'], 'entry.transpose'),
      keyOverride: key,
      chorusCount: json['choruses'] == null
          ? null
          : readInt(json['choruses'], 'entry.choruses'),
      note: json['note'] == null ? '' : readString(json['note'], 'entry.note'),
    );
  }

  static Map<String, Object?> _migrate(Map<String, Object?> json) {
    final version = json['schemaVersion'];
    if (version == null) {
      throw const SongFormatException(
        'no schemaVersion, so this is not a Bandstand playlist',
      );
    }
    var current = readInt(version, 'schemaVersion');
    if (current > playlistSchemaVersion) {
      throw SongFormatException(
        'this playlist is schema version $current and this build understands '
        '$playlistSchemaVersion',
      );
    }
    if (current < 1) {
      throw SongFormatException(
        'schema version $current is not a version',
        field: 'schemaVersion',
      );
    }
    var result = json;
    while (current < playlistSchemaVersion) {
      final step = playlistMigrations[current];
      if (step == null) {
        throw SongFormatException(
          'no way to read a version $current playlist into version '
          '$playlistSchemaVersion',
        );
      }
      result = <String, Object?>{...step(result), 'schemaVersion': ++current};
    }
    return result;
  }
}
