import 'dart:convert';

import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:bandstand/domain/song/chord_leadsheet.dart';
import 'package:bandstand/domain/song/lead_sheet_item.dart';
import 'package:bandstand/domain/song/mixer_settings.dart';
import 'package:bandstand/domain/song/section.dart';
import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/domain/song/song_library_model.dart';
import 'package:bandstand/domain/song/song_part.dart';
import 'package:bandstand/domain/song/song_structure.dart';
import 'package:bandstand/domain/song/written_part.dart';

import 'json_support.dart';

/// The schema version this build writes.
///
/// 2 adds `writtenParts` (`docs/rules/written-parts.md`). The field is optional
/// and a version 1 file reads without it, so the bump is not needed to *read*
/// old songs — it is needed so an older build **refuses** a new file instead of
/// reading it, dropping the part it does not know about, and writing the loss
/// back to disk on the next save.
const int songSchemaVersion = 2;

/// One step of a migration: a file at version `n` becomes a file at `n + 1`.
typedef SongMigration = Map<String, Object?> Function(
  Map<String, Object?> json,
);

/// The migrations this build knows, keyed by the version they migrate *from*.
///
/// The machinery was here and tested from version 1, before there was anything
/// to migrate, because retrofitting migrations onto a library of real songs is
/// how libraries get corrupted.
const Map<int, SongMigration> songMigrations = <int, SongMigration>{
  // 1 → 2 adds `writtenParts`, and a version 1 song has none. Nothing to do:
  // the decoder reads a missing `writtenParts` as an empty list, which is what
  // a chords-only tune has. Present rather than absent because the chain
  // refuses a version it has no step for, and "nothing changes" is a step.
  1: _identity,
};

Map<String, Object?> _identity(Map<String, Object?> json) => json;

/// Reading and writing `.song.json` (§5.1).
///
/// Schema in `docs/format/song-schema.md`. Every field is read by name; nothing
/// here uses reflection, so adding a field is a deliberate act with a migration
/// attached.
abstract final class SongJson {
  /// Encode [song] as pretty-printed JSON, ready to write to disk.
  static String encode(Song song) =>
      const JsonEncoder.withIndent('  ').convert(toJson(song));

  /// Decode a song from the contents of a `.song.json` file.
  ///
  /// Throws [SongFormatException] if the file is malformed, from a newer
  /// schema, or missing a migration step.
  static Song decode(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error) {
      throw SongFormatException('not valid JSON: ${error.message}');
    }
    return fromJson(readObject(decoded, 'song'));
  }

  /// Turn a song into the JSON structure the file holds.
  static Map<String, Object?> toJson(Song song) => <String, Object?>{
    'schemaVersion': songSchemaVersion,
    'id': song.id,
    'title': song.title,
    if (song.composer.isNotEmpty) 'composer': song.composer,
    'tempo': song.tempo,
    'key': song.key.toString(),
    if (song.tags.isNotEmpty) 'tags': song.tags.toList(),
    if (song.meta.isNotEmpty) 'meta': song.meta,
    'createdAt': song.createdAt.toIso8601String(),
    'modifiedAt': song.modifiedAt.toIso8601String(),
    'leadSheet': _leadSheetToJson(song.leadSheet),
    'structure': _structureToJson(song.structure),
    if (song.mixer.channels.isNotEmpty || song.mixer.masterVolume != 0.8)
      'mixer': _mixerToJson(song.mixer),
    // Omitted entirely for the overwhelming majority of tunes, which are chords
    // and nothing else. A song file is meant to be readable.
    if (song.writtenParts.isNotEmpty)
      'writtenParts': <Object?>[
        for (final part in song.writtenParts) _writtenPartToJson(part),
      ],
  };

  /// Build a song from the JSON structure the file holds.
  ///
  /// Throws [SongFormatException] if the file is malformed or from a newer
  /// schema.
  static Song fromJson(Map<String, Object?> raw) {
    final json = applyMigrationChain(raw, songMigrations, songSchemaVersion);
    final leadSheet = _leadSheetFromJson(
      readObject(json['leadSheet'], 'leadSheet'),
    );
    final structureJson = json['structure'];
    return Song(
      id: readNonEmptyString(json['id'], 'id'),
      title: readNonEmptyString(json['title'], 'title'),
      composer: json['composer'] == null
          ? ''
          : readString(json['composer'], 'composer'),
      leadSheet: leadSheet,
      structure: structureJson == null
          ? SongStructure.empty()
          : _structureFromJson(readObject(structureJson, 'structure')),
      tempo: json['tempo'] == null ? 120 : readInt(json['tempo'], 'tempo'),
      key: json['key'] == null
          ? KeySignature.cMajor()
          : _keyFromJson(readString(json['key'], 'key')),
      mixer: json['mixer'] == null
          ? MixerSettings.empty()
          : _mixerFromJson(readObject(json['mixer'], 'mixer')),
      tags: json['tags'] == null
          ? const <String>{}
          : readStringList(json['tags'], 'tags').toSet(),
      meta: json['meta'] == null
          ? const <String, String>{}
          : readStringMap(json['meta'], 'meta'),
      writtenParts: json['writtenParts'] == null
          ? const <WrittenPart>[]
          : <WrittenPart>[
              for (final entry in readList(
                json['writtenParts'],
                'writtenParts',
              ))
                _writtenPartFromJson(readObject(entry, 'writtenParts entry')),
            ],
      createdAt: json['createdAt'] == null
          ? null
          : readTimestamp(json['createdAt'], 'createdAt'),
      modifiedAt: json['modifiedAt'] == null
          ? null
          : readTimestamp(json['modifiedAt'], 'modifiedAt'),
    );
  }

  /// Read only a song's headline fields, without building its chart.
  ///
  /// The library screen shows hundreds of these and opens one; parsing every
  /// chord of every song to draw a list is the difference between the
  /// one-second cold start §3 asks for and a spinner.
  ///
  /// Throws [SongFormatException] if the file is malformed or from a newer
  /// schema.
  static SongSummary summaryFromJson(Map<String, Object?> raw) {
    final json = applyMigrationChain(raw, songMigrations, songSchemaVersion);
    final leadSheet = readObject(json['leadSheet'], 'leadSheet');
    return SongSummary(
      id: readNonEmptyString(json['id'], 'id'),
      title: readNonEmptyString(json['title'], 'title'),
      composer: json['composer'] == null
          ? ''
          : readString(json['composer'], 'composer'),
      tempo: json['tempo'] == null ? 120 : readInt(json['tempo'], 'tempo'),
      keyName: json['key'] == null ? 'C' : readString(json['key'], 'key'),
      barCount: readInt(leadSheet['barCount'], 'leadSheet.barCount'),
      tags: json['tags'] == null
          ? const <String>{}
          : readStringList(json['tags'], 'tags').toSet(),
      modifiedAt: json['modifiedAt'] == null
          ? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
          : readTimestamp(json['modifiedAt'], 'modifiedAt'),
    );
  }

  /// Read only a song's headline fields from the file's contents.
  ///
  /// Throws [SongFormatException] if the file is malformed.
  static SongSummary decodeSummary(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error) {
      throw SongFormatException('not valid JSON: ${error.message}');
    }
    return summaryFromJson(readObject(decoded, 'song'));
  }

  /// Walk [json] from its own schema version up to [targetVersion].
  ///
  /// A file from a newer build is refused rather than guessed at, and a missing
  /// step names both versions. Public because it is worth testing on its own.
  static Map<String, Object?> applyMigrationChain(
    Map<String, Object?> json,
    Map<int, SongMigration> migrations,
    int targetVersion,
  ) {
    final version = json['schemaVersion'];
    if (version == null) {
      throw const SongFormatException(
        'no schemaVersion, so this is not a Bandstand file',
      );
    }
    var current = readInt(version, 'schemaVersion');
    if (current > targetVersion) {
      throw SongFormatException(
        'this file is schema version $current and this build understands '
        '$targetVersion — update Bandstand rather than risk the library',
      );
    }
    if (current < 1) {
      throw SongFormatException(
        'schema version $current is not a version',
        field: 'schemaVersion',
      );
    }
    var result = json;
    while (current < targetVersion) {
      final step = migrations[current];
      if (step == null) {
        throw SongFormatException(
          'no way to read a version $current file into version $targetVersion',
        );
      }
      result = step(result);
      current++;
      result = <String, Object?>{...result, 'schemaVersion': current};
    }
    return result;
  }

  // --- written parts --------------------------------------------------------

  /// Notes are written as a flat list of numbers rather than a list of objects.
  ///
  /// A head is a few hundred notes and an object apiece would be a few hundred
  /// lines of `{"bar": 3, "beat": 1.5, ...}` in a file a person is meant to be
  /// able to open and read. Five numbers in a fixed order — bar, beat, key,
  /// duration, velocity — fit on one line and are still obvious.
  static Map<String, Object?> _writtenPartToJson(WrittenPart part) =>
      <String, Object?>{
        'id': part.id,
        'displayName': part.displayName,
        'program': part.program,
        'muted': part.muted,
        'notes': <Object?>[
          for (final note in part.notes)
            <Object?>[
              note.bar,
              note.beat,
              note.key,
              note.durationBeats,
              note.velocity,
            ],
        ],
      };

  static WrittenPart _writtenPartFromJson(Map<String, Object?> json) {
    try {
      final notes = <WrittenNote>[];
      for (final entry in readList(json['notes'], 'notes')) {
        final fields = readList(entry, 'note');
        if (fields.length != 5) {
          throw SongFormatException(
            'a note needs five numbers — bar, beat, key, duration, velocity — '
            'and this one has ${fields.length}',
            field: 'notes',
          );
        }
        notes.add(
          WrittenNote(
            bar: readInt(fields[0], 'note bar'),
            beat: readDouble(fields[1], 'note beat'),
            key: readInt(fields[2], 'note key'),
            durationBeats: readDouble(fields[3], 'note duration'),
            velocity: readInt(fields[4], 'note velocity'),
          ),
        );
      }
      return WrittenPart(
        id: readNonEmptyString(json['id'], 'id'),
        displayName: readNonEmptyString(json['displayName'], 'displayName'),
        notes: notes,
        program: json['program'] == null
            ? 73
            : readInt(json['program'], 'program'),
        muted: json['muted'] == null ? true : readBool(json['muted'], 'muted'),
      );
    } on ArgumentError catch (error) {
      throw SongFormatException('${error.message}', field: 'writtenParts');
    }
  }

  // --- lead sheet -----------------------------------------------------------

  static Map<String, Object?> _leadSheetToJson(ChordLeadSheet sheet) =>
      <String, Object?>{
        'barCount': sheet.barCount,
        if (sheet.pickupBeats != 0) 'pickupBeats': sheet.pickupBeats,
        'items': <Map<String, Object?>>[
          for (final item in sheet.items) _itemToJson(item),
        ],
      };

  static ChordLeadSheet _leadSheetFromJson(Map<String, Object?> json) =>
      ChordLeadSheet(
        barCount: readInt(json['barCount'], 'leadSheet.barCount'),
        pickupBeats: json['pickupBeats'] == null
            ? 0
            : readDouble(json['pickupBeats'], 'leadSheet.pickupBeats'),
        items: <LeadSheetItem>[
          for (final entry in readList(
            json['items'] ?? const <Object?>[],
            'leadSheet.items',
          ))
            _itemFromJson(readObject(entry, 'leadSheet.items')),
        ],
      );

  static Map<String, Object?> _itemToJson(LeadSheetItem item) => switch (item) {
    CliChordSymbol(:final position, :final chord) => <String, Object?>{
      'kind': 'chord',
      'bar': position.bar,
      'beat': position.beat,
      'symbol': chord.format(),
      if (!chord.rendering.isPlain || chord.isNoChord)
        'rendering': _renderingToJson(chord.rendering),
      if (chord.scale != null) 'scale': _scaleToJson(chord.scale!),
    },
    CliSection(:final section) => <String, Object?>{
      'kind': 'section',
      'bar': section.startBar,
      'name': section.name,
      if (section.timeSignature != TimeSignature.fourFour)
        'timeSignature': section.timeSignature.toString(),
    },
    CliRepeat(:final position, :final isStart, :final playCount) =>
      <String, Object?>{
        'kind': 'repeat',
        'bar': position.bar,
        'start': isStart,
        if (!isStart && playCount != 2) 'playCount': playCount,
      },
    CliEnding(:final position, :final passNumbers, :final barCount) =>
      <String, Object?>{
        'kind': 'ending',
        'bar': position.bar,
        'passes': passNumbers.toList(),
        if (barCount != 1) 'barCount': barCount,
      },
    CliNavigation(:final position, :final mark) => <String, Object?>{
      'kind': 'navigation',
      'bar': position.bar,
      'mark': mark.name,
    },
    CliAnnotation(:final position, :final text) => <String, Object?>{
      'kind': 'annotation',
      'bar': position.bar,
      'beat': position.beat,
      'text': text,
    },
  };

  static LeadSheetItem _itemFromJson(Map<String, Object?> json) {
    final kind = readString(json['kind'], 'item.kind');
    final bar = readInt(json['bar'], 'item.bar');
    double beat() =>
        json['beat'] == null ? 0 : readDouble(json['beat'], 'item.beat');

    switch (kind) {
      case 'chord':
        final symbol = readNonEmptyString(json['symbol'], 'item.symbol');
        final parsed = ExtChordSymbol.tryParse(symbol);
        if (parsed == null) {
          throw SongFormatException(
            '"$symbol" is not a chord symbol',
            field: 'item.symbol',
          );
        }
        final rendering = json['rendering'] == null
            ? ChordRenderingInfo.plain
            : _renderingFromJson(
                readObject(json['rendering'], 'item.rendering'),
              );
        final scale = json['scale'] == null
            ? null
            : _scaleFromJson(readObject(json['scale'], 'item.scale'));
        return CliChordSymbol(
          Position(bar, beat()),
          ExtChordSymbol.from(
            parsed.plain,
            rendering: parsed.isNoChord
                ? ChordRenderingInfo.silence
                : rendering,
            scale: scale,
          ),
        );
      case 'section':
        return CliSection(
          Section(
            name: readNonEmptyString(json['name'], 'item.name'),
            startBar: bar,
            timeSignature: json['timeSignature'] == null
                ? TimeSignature.fourFour
                : TimeSignature.parse(
                    readString(json['timeSignature'], 'item.timeSignature'),
                  ),
          ),
        );
      case 'repeat':
        final isStart = readBool(json['start'], 'item.start');
        return CliRepeat(
          Position(bar),
          isStart: isStart,
          playCount: json['playCount'] == null
              ? 2
              : readInt(json['playCount'], 'item.playCount'),
        );
      case 'ending':
        return CliEnding(
          Position(bar),
          <int>{
            for (final pass in readList(json['passes'], 'item.passes'))
              readInt(pass, 'item.passes'),
          },
          barCount: json['barCount'] == null
              ? 1
              : readInt(json['barCount'], 'item.barCount'),
        );
      case 'navigation':
        return CliNavigation(
          Position(bar),
          readEnum(json['mark'], NavigationMark.values, 'item.mark'),
        );
      case 'annotation':
        return CliAnnotation(
          Position(bar, beat()),
          readNonEmptyString(json['text'], 'item.text'),
        );
      default:
        throw SongFormatException(
          'unknown item kind "$kind"',
          field: 'item.kind',
        );
    }
  }

  static Map<String, Object?> _renderingToJson(ChordRenderingInfo info) =>
      <String, Object?>{
        if (info.accent != ChordAccent.none) 'accent': info.accent.name,
        if (info.playStyle != ChordPlayStyle.normal)
          'playStyle': info.playStyle.name,
        if (info.anticipation != ChordAnticipation.none)
          'anticipation': info.anticipation.name,
        if (info.pedalBass) 'pedalBass': true,
        if (info.noChord) 'noChord': true,
      };

  static ChordRenderingInfo _renderingFromJson(Map<String, Object?> json) =>
      ChordRenderingInfo(
        accent: json['accent'] == null
            ? ChordAccent.none
            : readEnum(json['accent'], ChordAccent.values, 'rendering.accent'),
        playStyle: json['playStyle'] == null
            ? ChordPlayStyle.normal
            : readEnum(
                json['playStyle'],
                ChordPlayStyle.values,
                'rendering.playStyle',
              ),
        anticipation: json['anticipation'] == null
            ? ChordAnticipation.none
            : readEnum(
                json['anticipation'],
                ChordAnticipation.values,
                'rendering.anticipation',
              ),
        pedalBass: json['pedalBass'] == null
            ? false
            : readBool(json['pedalBass'], 'rendering.pedalBass'),
        noChord: json['noChord'] == null
            ? false
            : readBool(json['noChord'], 'rendering.noChord'),
      );

  static Map<String, Object?> _scaleToJson(StandardScaleInstance instance) =>
      <String, Object?>{
        'name': instance.scale.name,
        'root': instance.root.toString(),
      };

  /// A scale hint is never worth losing a chart over: an unknown scale name or
  /// an unreadable root is dropped rather than failing the load.
  static StandardScaleInstance? _scaleFromJson(Map<String, Object?> json) {
    if (!Harmony.isInstalled) {
      return null;
    }
    final scale = Harmony.scales.byName(readString(json['name'], 'scale.name'));
    final root = PitchSpelling.tryParse(readString(json['root'], 'scale.root'));
    if (scale == null || root == null) {
      return null;
    }
    return StandardScaleInstance(scale, root);
  }

  static KeySignature _keyFromJson(String text) {
    final key = KeySignature.tryParse(text);
    if (key == null) {
      throw SongFormatException('"$text" is not a key', field: 'key');
    }
    return key;
  }

  // --- structure ------------------------------------------------------------

  static Map<String, Object?> _structureToJson(SongStructure structure) =>
      <String, Object?>{
        'parts': <Map<String, Object?>>[
          for (final part in structure.songParts)
            <String, Object?>{
              'section': part.parentSectionName,
              'barCount': part.barCount,
              'rhythmId': part.rhythmId,
              if (part.name != null) 'name': part.name,
              if (part.parameterValues.isNotEmpty)
                'parameters': part.parameterValues,
            },
        ],
      };

  static SongStructure _structureFromJson(Map<String, Object?> json) =>
      SongStructure(<SongPart>[
        for (final entry in readList(
          json['parts'] ?? const <Object?>[],
          'structure.parts',
        ))
          _partFromJson(readObject(entry, 'structure.parts')),
      ]);

  static SongPart _partFromJson(Map<String, Object?> json) => SongPart(
    parentSectionName: readNonEmptyString(json['section'], 'part.section'),
    startBar: 0,
    barCount: readInt(json['barCount'], 'part.barCount'),
    rhythmId: readNonEmptyString(json['rhythmId'], 'part.rhythmId'),
    name: json['name'] == null ? null : readString(json['name'], 'part.name'),
    parameterValues: json['parameters'] == null
        ? const <String, Object>{}
        : _parametersFromJson(
            readObject(json['parameters'], 'part.parameters'),
          ),
  );

  static Map<String, Object> _parametersFromJson(Map<String, Object?> json) =>
      <String, Object>{
        for (final entry in json.entries)
          if (entry.value case final Object value) entry.key: value,
      };

  // --- mixer ----------------------------------------------------------------

  static Map<String, Object?> _mixerToJson(MixerSettings mixer) =>
      <String, Object?>{
        'masterVolume': mixer.masterVolume,
        'channels': <Map<String, Object?>>[
          for (final channel in mixer.channels.values)
            <String, Object?>{
              'voiceId': channel.voiceId,
              'volume': channel.volume,
              if (channel.pan != 0) 'pan': channel.pan,
              if (channel.muted) 'muted': true,
              if (channel.soloed) 'soloed': true,
              if (channel.midiBank != 0) 'midiBank': channel.midiBank,
              if (channel.midiProgram != 0) 'midiProgram': channel.midiProgram,
              if (channel.transpose != 0) 'transpose': channel.transpose,
            },
        ],
      };

  static MixerSettings _mixerFromJson(Map<String, Object?> json) =>
      MixerSettings(
        masterVolume: json['masterVolume'] == null
            ? 0.8
            : readDouble(json['masterVolume'], 'mixer.masterVolume'),
        channels: <ChannelSettings>[
          for (final entry in readList(
            json['channels'] ?? const <Object?>[],
            'mixer.channels',
          ))
            _channelFromJson(readObject(entry, 'mixer.channels')),
        ],
      );

  static ChannelSettings _channelFromJson(Map<String, Object?> json) =>
      ChannelSettings(
        voiceId: readNonEmptyString(json['voiceId'], 'channel.voiceId'),
        volume: json['volume'] == null
            ? 0.8
            : readDouble(json['volume'], 'channel.volume'),
        pan: json['pan'] == null ? 0 : readDouble(json['pan'], 'channel.pan'),
        muted: json['muted'] == null
            ? false
            : readBool(json['muted'], 'channel.muted'),
        soloed: json['soloed'] == null
            ? false
            : readBool(json['soloed'], 'channel.soloed'),
        midiBank: json['midiBank'] == null
            ? 0
            : readInt(json['midiBank'], 'channel.midiBank'),
        midiProgram: json['midiProgram'] == null
            ? 0
            : readInt(json['midiProgram'], 'channel.midiProgram'),
        transpose: json['transpose'] == null
            ? 0
            : readInt(json['transpose'], 'channel.transpose'),
      );
}
