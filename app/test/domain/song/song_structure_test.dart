import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:bandstand/domain/song/chord_leadsheet.dart';
import 'package:bandstand/domain/song/lead_sheet_item.dart';
import 'package:bandstand/domain/song/rhythm.dart';
import 'package:bandstand/domain/song/section.dart';
import 'package:bandstand/domain/song/song_part.dart';
import 'package:bandstand/domain/song/song_structure.dart';
import 'package:flutter_test/flutter_test.dart';

SongPart part(String section, int bars, {String rhythm = 'swing'}) => SongPart(
  parentSectionName: section,
  startBar: 0,
  barCount: bars,
  rhythmId: rhythm,
);

void main() {
  group('SongPart', () {
    test('rejects a part that is not a place', () {
      expect(
        () => SongPart(
          parentSectionName: '',
          startBar: 0,
          barCount: 4,
          rhythmId: 'a',
        ),
        throwsArgumentError,
      );
      expect(
        () => SongPart(
          parentSectionName: 'A',
          startBar: -1,
          barCount: 4,
          rhythmId: 'a',
        ),
        throwsArgumentError,
      );
      expect(
        () => SongPart(
          parentSectionName: 'A',
          startBar: 0,
          barCount: 0,
          rhythmId: 'a',
        ),
        throwsArgumentError,
      );
    });

    test('knows which bars it covers', () {
      final p = SongPart(
        parentSectionName: 'A',
        startBar: 8,
        barCount: 4,
        rhythmId: 'swing',
      );
      expect(p.endBar, 12);
      expect(p.contains(8), isTrue);
      expect(p.contains(11), isTrue);
      expect(p.contains(12), isFalse);
      expect(p.contains(7), isFalse);
    });

    test('falls back to the rhythm default for an unset parameter', () {
      final rhythm = Rhythm(
        id: 'swing',
        displayName: 'Swing',
        timeSignature: TimeSignature.fourFour,
        parameters: <RhythmParameterSpec>[
          RhythmParameterSpec(
            id: 'intensity',
            displayName: 'Intensity',
            kind: RhythmParameterKind.integer,
            defaultValue: 50,
            minimum: 0,
            maximum: 100,
          ),
        ],
      );
      final plain = part('A', 8);
      expect(plain.parameterValue('intensity', rhythm: rhythm), 50);
      expect(
        plain
            .withParameter('intensity', 80)
            .parameterValue('intensity', rhythm: rhythm),
        80,
      );
      // A value the parameter would not accept falls back to the default.
      expect(
        plain
            .withParameter('intensity', 900)
            .parameterValue('intensity', rhythm: rhythm),
        50,
      );
    });

    test('the display name falls back to the section', () {
      expect(part('A', 8).displayName, 'A');
      expect(part('A', 8).copyWith(name: 'Head').displayName, 'Head');
      expect(
        part('A', 8).copyWith(name: 'Head').copyWith(clearName: true).name,
        isNull,
      );
    });
  });

  group('SongStructure', () {
    test('lays parts out end to end, whatever start bars they came with', () {
      final structure = SongStructure(<SongPart>[
        part('A', 8),
        part('B', 4),
        part('A', 8),
      ]);
      expect(structure.songParts.map((p) => p.startBar).toList(), <int>[
        0,
        8,
        12,
      ]);
      expect(structure.barCount, 20);
    });

    test('finds the part covering a bar', () {
      final structure = SongStructure(<SongPart>[part('A', 8), part('B', 4)]);
      expect(structure.partAt(0)!.parentSectionName, 'A');
      expect(structure.partAt(7)!.parentSectionName, 'A');
      expect(structure.partAt(8)!.parentSectionName, 'B');
      expect(structure.partAt(12), isNull);
      expect(structure.indexAt(8), 1);
      expect(structure.indexAt(99), -1);
    });

    test('editing keeps the layout contiguous', () {
      var structure = SongStructure(<SongPart>[part('A', 8), part('B', 4)]);
      structure = structure.withPartInserted(1, part('C', 2));
      expect(structure.songParts.map((p) => p.startBar).toList(), <int>[
        0,
        8,
        10,
      ]);
      structure = structure.withPartMoved(2, 0);
      expect(
        structure.songParts.map((p) => p.parentSectionName).toList(),
        <String>['B', 'A', 'C'],
      );
      expect(structure.songParts.map((p) => p.startBar).toList(), <int>[
        0,
        4,
        12,
      ]);
      structure = structure.withPartRemoved(0);
      expect(structure.barCount, 10);
    });

    test('refuses indices that are not there', () {
      final structure = SongStructure(<SongPart>[part('A', 8)]);
      expect(() => structure.withPartRemoved(3), throwsRangeError);
      expect(
        () => structure.withPartInserted(5, part('B', 4)),
        throwsRangeError,
      );
      expect(() => structure.withPartMoved(0, 4), throwsRangeError);
      expect(
        () => structure.withPartReplaced(2, part('B', 4)),
        throwsRangeError,
      );
    });

    test('an empty structure plays nothing', () {
      expect(SongStructure.empty().isEmpty, isTrue);
      expect(SongStructure.empty().barCount, 0);
      expect(SongStructure.empty().partAt(0), isNull);
    });

    test('builds one part per section from a chart', () {
      final sheet = ChordLeadSheet(
        barCount: 24,
        items: <LeadSheetItem>[
          CliSection(Section(name: 'A', startBar: 0)),
          CliSection(Section(name: 'B', startBar: 16)),
        ],
      );
      final structure = SongStructure.fromLeadSheet(sheet, rhythmId: 'swing');
      expect(structure.songParts, hasLength(2));
      expect(structure.songParts[0].barCount, 16);
      expect(structure.songParts[1].barCount, 8);
      expect(structure.barCount, 24);
    });

    test('a chart with no sections still gets one part', () {
      final structure = SongStructure.fromLeadSheet(
        ChordLeadSheet(barCount: 12),
        rhythmId: 'swing',
      );
      expect(structure.songParts, hasLength(1));
      expect(structure.songParts.single.barCount, 12);
    });

    test('reports parts pointing at sections the chart does not have', () {
      final sheet = ChordLeadSheet(
        barCount: 8,
        items: <LeadSheetItem>[CliSection(Section(name: 'A', startBar: 0))],
      );
      final structure = SongStructure(<SongPart>[part('A', 8), part('Z', 8)]);
      expect(structure.danglingParts(sheet), hasLength(1));
      expect(structure.danglingParts(sheet).single.parentSectionName, 'Z');
    });
  });

  group('Rhythm', () {
    test('rejects duplicate voices and parameters', () {
      final voice = RhythmVoice(
        id: 'bass',
        displayName: 'Bass',
        isDrums: false,
      );
      expect(
        () => Rhythm(
          id: 'r',
          displayName: 'R',
          timeSignature: TimeSignature.fourFour,
          voices: <RhythmVoice>[voice, voice],
        ),
        throwsArgumentError,
      );
    });

    test('sanitises a parameter map to what it actually offers', () {
      final rhythm = Rhythm(
        id: 'swing',
        displayName: 'Swing',
        timeSignature: TimeSignature.fourFour,
        parameters: <RhythmParameterSpec>[
          RhythmParameterSpec(
            id: 'intensity',
            displayName: 'Intensity',
            kind: RhythmParameterKind.integer,
            defaultValue: 50,
            minimum: 0,
            maximum: 100,
          ),
          RhythmParameterSpec(
            id: 'variation',
            displayName: 'Variation',
            kind: RhythmParameterKind.choice,
            defaultValue: 'A',
            choices: <String>['A', 'B'],
          ),
        ],
      );
      final cleaned = rhythm.sanitise(<String, Object?>{
        'intensity': 700,
        'variation': 'B',
        'nonsense': true,
      });
      expect(cleaned, <String, Object>{'intensity': 50, 'variation': 'B'});
    });

    test('a registry answers by id and by meter', () {
      final swing = Rhythm(
        id: 'swing',
        displayName: 'Swing',
        timeSignature: TimeSignature.fourFour,
      );
      final waltz = Rhythm(
        id: 'waltz',
        displayName: 'Waltz',
        timeSignature: TimeSignature.threeFour,
      );
      final registry = RhythmRegistry(<Rhythm>[swing, waltz]);
      expect(registry['swing'], swing);
      expect(registry['nothing'], isNull);
      expect(registry.forTimeSignature(TimeSignature.threeFour), <Rhythm>[
        waltz,
      ]);
      expect(registry.length, 2);
    });

    test('an empty registry is what a build with no generators has', () {
      expect(RhythmRegistry().all, isEmpty);
      expect(RhythmRegistry()['swing'], isNull);
    });
  });
}
