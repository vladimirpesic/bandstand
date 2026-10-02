import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:bandstand/domain/song/chord_leadsheet.dart';
import 'package:bandstand/domain/song/lead_sheet_item.dart';
import 'package:bandstand/domain/song/playlist.dart';
import 'package:bandstand/domain/song/section.dart';
import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/domain/song/song_part.dart';
import 'package:bandstand/domain/song/song_structure.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harmony/harmony_test_support.dart';

void main() {
  installTestHarmony();

  Song blueBossa() {
    final sheet = ChordLeadSheet(
      barCount: 8,
      items: <LeadSheetItem>[
        CliSection(Section(name: 'A', startBar: 0)),
        CliChordSymbol(Position(0), ExtChordSymbol.parse('Cm7')),
        CliChordSymbol(Position(2), ExtChordSymbol.parse('Fm7')),
        CliChordSymbol(Position(4), ExtChordSymbol.parse('Dm7b5')),
        CliChordSymbol(Position(5), ExtChordSymbol.parse('G7')),
      ],
    );
    return Song(
      id: 'blue-bossa',
      title: 'Blue Bossa',
      composer: 'Kenny Dorham',
      leadSheet: sheet,
      structure: SongStructure(<SongPart>[
        SongPart(
          parentSectionName: 'A',
          startBar: 0,
          barCount: 8,
          rhythmId: 'bossa',
        ),
      ]),
      tempo: 148,
      key: KeySignature.parse('Cm'),
    );
  }

  group('entries', () {
    test('a plain entry changes nothing', () {
      final song = blueBossa();
      final entry = PlaylistEntry(songId: song.id);
      expect(entry.isPlain, isTrue);
      expect(entry.applyTo(song), song);
    });

    test('a tempo override changes the tempo and nothing else', () {
      final song = blueBossa();
      final played = PlaylistEntry(
        songId: song.id,
        tempoOverride: 200,
      ).applyTo(song);
      expect(played.tempo, 200);
      expect(played.leadSheet, song.leadSheet);
      expect(played.key, song.key);
    });

    test('a transpose override moves the chart and the key', () {
      final song = blueBossa();
      final played = PlaylistEntry(
        songId: song.id,
        transposeOverride: 2,
      ).applyTo(song);
      expect(played.key.toString(), 'Dm');
      expect(
        played.leadSheet.chordItems.map((c) => c.chord.format()).toList(),
        <String>['Dm7', 'Gm7', 'Em7b5', 'A7'],
      );
    });

    test('a key override finds the shortest way there', () {
      final song = blueBossa();
      // Cm to Bbm is down two, not up ten.
      final entry = PlaylistEntry(
        songId: song.id,
        keyOverride: KeySignature.parse('Bbm'),
      );
      expect(entry.transpositionFor(song), -2);
      final played = entry.applyTo(song);
      expect(played.key.toString(), 'Bbm');
      expect(
        played.leadSheet.chordItems.map((c) => c.chord.format()).toList(),
        <String>['Bbm7', 'Ebm7', 'Cm7b5', 'F7'],
      );
    });

    test('an explicit transpose beats a key override', () {
      final song = blueBossa();
      final entry = PlaylistEntry(
        songId: song.id,
        transposeOverride: 5,
        keyOverride: KeySignature.parse('Fm'),
      );
      expect(entry.transpositionFor(song), 5);
      expect(entry.applyTo(song).key.toString(), 'Fm');
    });

    test('a chorus count repeats the arrangement', () {
      final song = blueBossa();
      final played = PlaylistEntry(
        songId: song.id,
        chorusCount: 3,
      ).applyTo(song);
      expect(played.structure.songParts, hasLength(3));
      expect(played.structure.barCount, 24);
      expect(song.structure.songParts, hasLength(1));
    });

    test('the song in the library is never touched — §10 M2', () {
      final song = blueBossa();
      final before = SongJsonSnapshot.of(song);
      final entry = PlaylistEntry(
        songId: song.id,
        tempoOverride: 200,
        transposeOverride: 3,
        chorusCount: 4,
      );
      final played = entry.applyTo(song);
      expect(played.tempo, 200);
      expect(SongJsonSnapshot.of(song), before);
      expect(song.tempo, 148);
      expect(song.key.toString(), 'Cm');
      expect(song.structure.songParts, hasLength(1));
      expect(song.leadSheet.chordItems.first.chord.format(), 'Cm7');
    });

    test('overrides that are not overrides are refused', () {
      expect(() => PlaylistEntry(songId: ''), throwsArgumentError);
      expect(
        () => PlaylistEntry(songId: 'a', tempoOverride: 5),
        throwsArgumentError,
      );
      expect(
        () => PlaylistEntry(songId: 'a', transposeOverride: 20),
        throwsArgumentError,
      );
      expect(
        () => PlaylistEntry(songId: 'a', chorusCount: 0),
        throwsArgumentError,
      );
    });

    test('copyWith can clear an override as well as set one', () {
      final entry = PlaylistEntry(songId: 'a', tempoOverride: 200);
      expect(entry.copyWith(clearTempo: true).tempoOverride, isNull);
      expect(entry.copyWith(tempoOverride: 100).tempoOverride, 100);
    });
  });

  group('the set list', () {
    Playlist gig() => Playlist(
      id: 'friday',
      name: 'Friday, The Vortex',
      entries: <PlaylistEntry>[
        PlaylistEntry(songId: 'a'),
        PlaylistEntry(songId: 'b'),
        PlaylistEntry(songId: 'c'),
      ],
    );

    test('needs an id and a name', () {
      expect(() => Playlist(id: '', name: 'x'), throwsArgumentError);
      expect(() => Playlist(id: 'x', name: ' '), throwsArgumentError);
    });

    test('reorders by dragging', () {
      final reordered = gig().withEntryMoved(2, 0);
      expect(reordered.entries.map((e) => e.songId).toList(), <String>[
        'c',
        'a',
        'b',
      ]);
    });

    test('inserts, replaces and removes', () {
      var playlist = gig().withEntryInserted(1, PlaylistEntry(songId: 'x'));
      expect(playlist.length, 4);
      expect(playlist.entries[1].songId, 'x');
      playlist = playlist.withEntryReplaced(
        1,
        PlaylistEntry(songId: 'x', tempoOverride: 90),
      );
      expect(playlist.entries[1].tempoOverride, 90);
      playlist = playlist.withEntryRemoved(1);
      expect(playlist.entries.map((e) => e.songId).toList(), <String>[
        'a',
        'b',
        'c',
      ]);
    });

    test('refuses indices that are not there', () {
      expect(() => gig().withEntryRemoved(9), throwsRangeError);
      expect(
        () => gig().withEntryInserted(9, PlaylistEntry(songId: 'x')),
        throwsRangeError,
      );
      expect(() => gig().withEntryMoved(0, 9), throwsRangeError);
    });

    test('the same tune can appear twice in different keys — §9', () {
      final playlist = Playlist(
        id: 'sets',
        name: 'Two sets',
        entries: <PlaylistEntry>[
          PlaylistEntry(
            songId: 'blue-bossa',
            keyOverride: KeySignature.parse('Cm'),
          ),
          PlaylistEntry(
            songId: 'blue-bossa',
            keyOverride: KeySignature.parse('Gm'),
          ),
        ],
      );
      final song = blueBossa();
      expect(playlist.entries[0].applyTo(song).key.toString(), 'Cm');
      expect(playlist.entries[1].applyTo(song).key.toString(), 'Gm');
      expect(song.key.toString(), 'Cm');
    });

    test('renaming keeps the entries', () {
      expect(gig().renamed('Saturday').name, 'Saturday');
      expect(gig().renamed('Saturday').entries, gig().entries);
      expect(gig().withNote('two sets').note, 'two sets');
    });

    test('every edit moves modifiedAt forward — §4.4', () {
      // The rebuild methods used to drop modifiedAt, so the factory fell back
      // to createdAt and every edit moved the timestamp backwards — which
      // also made the edited playlist compare equal to its pre-edit self.
      final created = DateTime.utc(2026, 1, 1);
      final playlist = Playlist(
        id: 'gig',
        name: 'Gig',
        createdAt: created,
        entries: <PlaylistEntry>[PlaylistEntry(songId: 'a')],
      );
      final edited = <Playlist>[
        playlist.renamed('Late Gig'),
        playlist.withNote('two sets'),
        playlist.withEntryAppended(PlaylistEntry(songId: 'b')),
        playlist.withEntryInserted(0, PlaylistEntry(songId: 'c')),
        playlist.withEntryReplaced(0, PlaylistEntry(songId: 'd')),
        playlist.withEntryRemoved(0),
        playlist.withEntryMoved(0, 0),
      ];
      for (final next in edited) {
        expect(
          next.modifiedAt.isAfter(created),
          isTrue,
          reason: '$next did not move modifiedAt forward',
        );
        expect(next, isNot(playlist));
      }
    });
  });
}

/// A cheap deep snapshot, so a test can prove a value did not change.
abstract final class SongJsonSnapshot {
  /// A string that changes whenever anything about [song] does.
  static String of(Song song) =>
      '${song.id}|${song.title}|${song.composer}|${song.tempo}|'
      '${song.key}|${song.mixer}|${song.tags.join(',')}|'
      '${song.meta.entries.map((e) => '${e.key}=${e.value}').join(',')}|'
      '${song.createdAt}|${song.modifiedAt}|'
      '${song.leadSheet.barCount}|${song.leadSheet.pickupBeats}|'
      '${song.leadSheet.items.join(',')}|${song.structure.songParts.join(',')}|'
      '${song.writtenParts.join(',')}';
}
