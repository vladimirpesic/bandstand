import 'dart:convert';

import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:bandstand/domain/song/chord_leadsheet.dart';
import 'package:bandstand/domain/song/lead_sheet_item.dart';
import 'package:bandstand/domain/song/mixer_settings.dart';
import 'package:bandstand/domain/song/playlist.dart';
import 'package:bandstand/domain/song/section.dart';
import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/domain/song/song_part.dart';
import 'package:bandstand/domain/song/song_structure.dart';
import 'package:bandstand/io/json_support.dart';
import 'package:bandstand/io/playlist_json.dart';
import 'package:bandstand/io/song_json.dart';
import 'package:flutter_test/flutter_test.dart';

import '../domain/harmony/harmony_test_support.dart';

void main() {
  installTestHarmony();

  Song fullSong() {
    final sheet = ChordLeadSheet(
      barCount: 16,
      pickupBeats: 2,
      items: <LeadSheetItem>[
        CliSection(Section(name: 'A', startBar: 0)),
        CliSection(
          Section(
            name: 'B',
            startBar: 8,
            timeSignature: TimeSignature.threeFour,
          ),
        ),
        CliRepeat(Position(0), isStart: true),
        CliRepeat(Position(7), isStart: false, playCount: 3),
        CliEnding(Position(6), <int>{1, 2}, barCount: 2),
        CliNavigation(Position(15), NavigationMark.daCapoAlCoda),
        CliNavigation(Position(8), NavigationMark.coda),
        CliNavigation(Position(4), NavigationMark.toCoda),
        CliAnnotation(Position(2, 1.5), 'solo break'),
        CliChordSymbol(Position(0), ExtChordSymbol.parse('Cmaj7')),
        CliChordSymbol(
          Position(0, 2),
          ExtChordSymbol.parse('A7').withRendering(
            const ChordRenderingInfo(
              accent: ChordAccent.strong,
              playStyle: ChordPlayStyle.hold,
              anticipation: ChordAnticipation.eighth,
              pedalBass: true,
            ),
          ),
        ),
        CliChordSymbol(Position(4), ExtChordSymbol.noChord()),
        CliChordSymbol(
          Position(8),
          ExtChordSymbol.parse('Eb13b9#11').withScale(
            StandardScaleInstance(
              Harmony.scales.byName('Altered')!,
              PitchSpelling.parse('Eb'),
            ),
          ),
        ),
      ],
    );
    return Song(
      id: 'a-song',
      title: 'Everything At Once',
      composer: 'A. Tester',
      leadSheet: sheet,
      structure: SongStructure(<SongPart>[
        SongPart(
          parentSectionName: 'A',
          startBar: 0,
          barCount: 8,
          rhythmId: 'swing',
          name: 'A (head)',
          parameterValues: const <String, Object>{
            'intensity': 70,
            'variation': 'B',
            'fill': true,
          },
        ),
        SongPart(
          parentSectionName: 'B',
          startBar: 0,
          barCount: 8,
          rhythmId: 'swing',
        ),
      ]),
      tempo: 176,
      key: KeySignature.parse('Bb'),
      mixer: MixerSettings(
        masterVolume: 0.7,
        channels: <ChannelSettings>[
          ChannelSettings(
            voiceId: 'bass',
            volume: 0.9,
            pan: -0.2,
            midiProgram: 32,
            transpose: -12,
          ),
          ChannelSettings(voiceId: 'drums', muted: true),
        ],
      ),
      tags: const <String>{'session', 'up'},
      meta: const <String, String>{'source': 'test'},
      createdAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
      modifiedAt: DateTime.utc(2026, 2, 3, 4, 5, 6),
    );
  }

  group('round trips', () {
    test('a song survives encode and decode unchanged', () {
      final song = fullSong();
      expect(SongJson.decode(SongJson.encode(song)), song);
    });

    test('a minimal song survives too', () {
      final song = Song.blank(id: 'blank');
      expect(SongJson.decode(SongJson.encode(song)), song);
    });

    test('every item kind survives', () {
      final song = fullSong();
      final round = SongJson.decode(SongJson.encode(song));
      expect(round.leadSheet.items.length, song.leadSheet.items.length);
      for (var i = 0; i < song.leadSheet.items.length; i++) {
        expect(
          round.leadSheet.items[i],
          song.leadSheet.items[i],
          reason: 'item $i',
        );
      }
    });

    test('rendering information and scale hints survive', () {
      final round = SongJson.decode(SongJson.encode(fullSong()));
      final accented = round.leadSheet.chordItems.firstWhere(
        (c) => c.chord.format() == 'A7',
      );
      expect(accented.chord.rendering.accent, ChordAccent.strong);
      expect(accented.chord.rendering.playStyle, ChordPlayStyle.hold);
      expect(accented.chord.rendering.anticipation, ChordAnticipation.eighth);
      expect(accented.chord.rendering.pedalBass, isTrue);

      final altered = round.leadSheet.chordItems.firstWhere(
        (c) => c.chord.format().startsWith('Eb13'),
      );
      expect(altered.chord.scale!.scale.name, 'Altered');
      expect(altered.chord.scale!.root.toString(), 'Eb');
    });

    test('N.C. survives as N.C.', () {
      final round = SongJson.decode(SongJson.encode(fullSong()));
      expect(round.leadSheet.chordItems.any((c) => c.chord.isNoChord), isTrue);
    });

    test('a playlist survives encode and decode unchanged', () {
      final playlist = Playlist(
        id: 'friday',
        name: 'Friday',
        note: 'two sets',
        entries: <PlaylistEntry>[
          PlaylistEntry(songId: 'a'),
          PlaylistEntry(
            songId: 'b',
            tempoOverride: 200,
            transposeOverride: -3,
            keyOverride: KeySignature.parse('Ab'),
            chorusCount: 4,
            note: 'vocal in 2',
          ),
        ],
        createdAt: DateTime.utc(2026),
        modifiedAt: DateTime.utc(2026, 6),
      );
      expect(PlaylistJson.decode(PlaylistJson.encode(playlist)), playlist);
    });
  });

  group('what the file looks like', () {
    test('defaults are left out, so a diff shows what changed', () {
      final json = jsonDecode(
        SongJson.encode(Song.blank(id: 'blank')),
      ) as Map<String, Object?>;
      expect(json.containsKey('composer'), isFalse);
      expect(json.containsKey('tags'), isFalse);
      expect(json.containsKey('meta'), isFalse);
      expect(json.containsKey('mixer'), isFalse);
      final sheet = json['leadSheet']! as Map<String, Object?>;
      expect(sheet.containsKey('pickupBeats'), isFalse);
      final section =
          (sheet['items']! as List<Object?>).first as Map<String, Object?>;
      expect(section.containsKey('timeSignature'), isFalse);
    });

    test('song part start bars are not stored — they cannot disagree', () {
      final json =
          jsonDecode(SongJson.encode(fullSong())) as Map<String, Object?>;
      final parts =
          (json['structure']! as Map<String, Object?>)['parts']!
              as List<Object?>;
      for (final part in parts) {
        expect(
          (part! as Map<String, Object?>).containsKey('startBar'),
          isFalse,
        );
      }
    });

    test('it is readable JSON, indented', () {
      final text = SongJson.encode(Song.blank(id: 'blank'));
      expect(text, contains('\n  "title"'));
      expect(text.split('\n').length, greaterThan(5));
    });
  });

  group('files that will not read', () {
    test('nonsense is refused with a message', () {
      expect(
        () => SongJson.decode('this is not json'),
        throwsA(isA<SongFormatException>()),
      );
      expect(() => SongJson.decode('[]'), throwsA(isA<SongFormatException>()));
    });

    test('a missing schema version is refused', () {
      expect(
        () => SongJson.decode('{"id":"a","title":"b"}'),
        throwsA(
          isA<SongFormatException>().having(
            (e) => e.message,
            'message',
            contains('schemaVersion'),
          ),
        ),
      );
    });

    test('a file from the future is refused rather than guessed at', () {
      final json = jsonDecode(
        SongJson.encode(Song.blank(id: 'blank')),
      ) as Map<String, Object?>;
      json['schemaVersion'] = songSchemaVersion + 5;
      expect(
        () => SongJson.fromJson(json),
        throwsA(
          isA<SongFormatException>().having(
            (e) => e.message,
            'message',
            contains('update Bandstand'),
          ),
        ),
      );
    });

    test('a bad field is named', () {
      expect(
        () => SongJson.decode(
          '{"schemaVersion":1,"id":"a","title":"b",'
          '"leadSheet":{"barCount":"four","items":[]}}',
        ),
        throwsA(
          isA<SongFormatException>().having(
            (e) => e.field,
            'field',
            'leadSheet.barCount',
          ),
        ),
      );
    });

    test('an unreadable chord symbol is refused, not guessed at', () {
      expect(
        () => SongJson.decode(
          '{"schemaVersion":1,"id":"a","title":"b",'
          '"leadSheet":{"barCount":4,"items":['
          '{"kind":"chord","bar":0,"beat":0,"symbol":"Cwobble"}]}}',
        ),
        throwsA(isA<SongFormatException>()),
      );
    });

    test('an unknown item kind is refused', () {
      expect(
        () => SongJson.decode(
          '{"schemaVersion":1,"id":"a","title":"b",'
          '"leadSheet":{"barCount":4,"items":[{"kind":"wobble","bar":0}]}}',
        ),
        throwsA(isA<SongFormatException>()),
      );
    });

    test(
      'a written note outside MIDI range is a format error, not a crash',
      () {
        // The note constructor throws ArgumentError; a corrupt file must arrive
        // as a SongFormatException like every other bad field.
        expect(
          () => SongJson.decode(
            '{"schemaVersion":2,"id":"a","title":"b",'
            '"leadSheet":{"barCount":4,"items":[]},'
            '"writtenParts":[{"id":"p","displayName":"Part",'
            '"notes":[[0,0,200,1,100]]}]}',
          ),
          throwsA(isA<SongFormatException>()),
        );
      },
    );

    test('a playlist below schema version 1 is not a version', () {
      expect(
        () => PlaylistJson.decode(
          '{"schemaVersion":0,"id":"a","name":"b","entries":[]}',
        ),
        throwsA(
          isA<SongFormatException>().having(
            (e) => e.message,
            'message',
            contains('is not a version'),
          ),
        ),
      );
    });

    test('an unknown scale hint is dropped rather than losing the chart', () {
      final song = SongJson.decode(
        '{"schemaVersion":1,"id":"a","title":"b",'
        '"leadSheet":{"barCount":4,"items":['
        '{"kind":"chord","bar":0,"beat":0,"symbol":"C7",'
        '"scale":{"name":"Nonexistent","root":"C"}}]}}',
      );
      expect(song.leadSheet.chordItems.single.chord.scale, isNull);
      expect(song.leadSheet.chordItems.single.chord.format(), 'C7');
    });
  });

  group('migration', () {
    test('walks a file up one version at a time', () {
      var applied = <int>[];
      final migrations = <int, SongMigration>{
        1: (json) {
          applied.add(1);
          return <String, Object?>{...json, 'addedAtTwo': true};
        },
        2: (json) {
          applied.add(2);
          return <String, Object?>{...json, 'addedAtThree': true};
        },
      };
      final migrated = SongJson.applyMigrationChain(
        <String, Object?>{'schemaVersion': 1, 'id': 'a'},
        migrations,
        3,
      );
      expect(applied, <int>[1, 2]);
      expect(migrated['schemaVersion'], 3);
      expect(migrated['addedAtTwo'], isTrue);
      expect(migrated['addedAtThree'], isTrue);
      applied = <int>[];
    });

    test('a file already at the target is left alone', () {
      final json = <String, Object?>{'schemaVersion': 2, 'id': 'a'};
      expect(
        SongJson.applyMigrationChain(json, const <int, SongMigration>{}, 2),
        json,
      );
    });

    test('a missing step names both versions rather than guessing', () {
      expect(
        () => SongJson.applyMigrationChain(
          <String, Object?>{'schemaVersion': 1},
          const <int, SongMigration>{},
          3,
        ),
        throwsA(
          isA<SongFormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('version 1'), contains('version 3')),
          ),
        ),
      );
    });

    test('a version below one is not a version', () {
      expect(
        () => SongJson.applyMigrationChain(
          <String, Object?>{'schemaVersion': 0},
          const <int, SongMigration>{},
          1,
        ),
        throwsA(isA<SongFormatException>()),
      );
    });
  });
}
