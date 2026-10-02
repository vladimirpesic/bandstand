import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:bandstand/domain/song/chord_leadsheet.dart';
import 'package:bandstand/domain/song/lead_sheet_item.dart';
import 'package:bandstand/domain/song/section.dart';
import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/domain/song/song_chord_sequence.dart';
import 'package:bandstand/domain/song/song_part.dart';
import 'package:bandstand/domain/song/song_structure.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harmony/harmony_test_support.dart';

CliChordSymbol chord(int bar, double beat, String symbol) =>
    CliChordSymbol(Position(bar, beat), ExtChordSymbol.parse(symbol));

void main() {
  installTestHarmony();

  ChordLeadSheet aabaSheet() => ChordLeadSheet(
    barCount: 16,
    items: <LeadSheetItem>[
      CliSection(Section(name: 'A', startBar: 0)),
      CliSection(Section(name: 'B', startBar: 8)),
      chord(0, 0, 'Cmaj7'),
      chord(4, 0, 'Dm7'),
      chord(8, 0, 'Fm7'),
      chord(12, 0, 'Bb7'),
    ],
  );

  Song songOf(ChordLeadSheet sheet, SongStructure structure) =>
      Song(id: 'test', title: 'Test', leadSheet: sheet, structure: structure);

  group('with an arrangement', () {
    test('each part contributes its section, in the order they are listed', () {
      final sheet = aabaSheet();
      final song = songOf(
        sheet,
        SongStructure(<SongPart>[
          SongPart(
            parentSectionName: 'A',
            startBar: 0,
            barCount: 8,
            rhythmId: 'r',
          ),
          SongPart(
            parentSectionName: 'B',
            startBar: 0,
            barCount: 8,
            rhythmId: 'r',
          ),
          SongPart(
            parentSectionName: 'A',
            startBar: 0,
            barCount: 8,
            rhythmId: 'r',
          ),
        ]),
      );
      final sequence = SongChordSequence.of(song);
      expect(sequence.barCount, 24);
      expect(sequence.sourceBars.take(8), <int>[0, 1, 2, 3, 4, 5, 6, 7]);
      expect(sequence.sourceBars.skip(8).take(8), <int>[
        8,
        9,
        10,
        11,
        12,
        13,
        14,
        15,
      ]);
      expect(sequence.sourceBars.skip(16).take(8), <int>[
        0,
        1,
        2,
        3,
        4,
        5,
        6,
        7,
      ]);
      expect(sequence.isWellFormed, isTrue);
    });

    test('a part longer than its section loops the section', () {
      final song = songOf(
        aabaSheet(),
        SongStructure(<SongPart>[
          SongPart(
            parentSectionName: 'B',
            startBar: 0,
            barCount: 16,
            rhythmId: 'r',
          ),
        ]),
      );
      final sequence = SongChordSequence.of(song);
      expect(sequence.barCount, 16);
      expect(sequence.sourceBars.take(8), <int>[8, 9, 10, 11, 12, 13, 14, 15]);
      expect(sequence.sourceBars.skip(8), <int>[8, 9, 10, 11, 12, 13, 14, 15]);
    });

    test('a part shorter than its section is truncated', () {
      final song = songOf(
        aabaSheet(),
        SongStructure(<SongPart>[
          SongPart(
            parentSectionName: 'A',
            startBar: 0,
            barCount: 3,
            rhythmId: 'r',
          ),
        ]),
      );
      expect(SongChordSequence.of(song).sourceBars, <int>[0, 1, 2]);
    });

    test('repeats written inside a section are expanded', () {
      final sheet = ChordLeadSheet(
        barCount: 8,
        items: <LeadSheetItem>[
          CliSection(Section(name: 'A', startBar: 0)),
          CliRepeat(Position(0), isStart: true),
          CliRepeat(Position(3), isStart: false),
          chord(0, 0, 'C'),
        ],
      );
      final song = songOf(
        sheet,
        SongStructure(<SongPart>[
          SongPart(
            parentSectionName: 'A',
            startBar: 0,
            barCount: 16,
            rhythmId: 'r',
          ),
        ]),
      );
      final sequence = SongChordSequence.of(song);
      expect(sequence.sourceBars.take(12), <int>[
        0,
        1,
        2,
        3,
        0,
        1,
        2,
        3,
        4,
        5,
        6,
        7,
      ]);
    });

    test(
      'a part naming a section that is gone is reported, not guessed at',
      () {
        final song = songOf(
          aabaSheet(),
          SongStructure(<SongPart>[
            SongPart(
              parentSectionName: 'Nowhere',
              startBar: 0,
              barCount: 8,
              rhythmId: 'r',
            ),
          ]),
        );
        final sequence = SongChordSequence.of(song);
        expect(sequence.barCount, 0);
        expect(sequence.problems, hasLength(1));
        expect(sequence.problems.single.message, contains('Nowhere'));
      },
    );

    test('every bar knows which song part produced it', () {
      final song = songOf(
        aabaSheet(),
        SongStructure(<SongPart>[
          SongPart(
            parentSectionName: 'A',
            startBar: 0,
            barCount: 8,
            rhythmId: 'r',
          ),
          SongPart(
            parentSectionName: 'B',
            startBar: 0,
            barCount: 8,
            rhythmId: 'r',
          ),
        ]),
      );
      final sequence = SongChordSequence.of(song);
      expect(sequence.barsOfPart(0), hasLength(8));
      expect(sequence.barsOfPart(1), hasLength(8));
      expect(sequence.bars.first.songPartIndex, 0);
      expect(sequence.bars.last.songPartIndex, 1);
    });
  });

  group('with no arrangement', () {
    test('the written page is played as written', () {
      final song = songOf(aabaSheet(), SongStructure.empty());
      final sequence = SongChordSequence.of(song);
      expect(sequence.barCount, 16);
      expect(sequence.sourceBars, List<int>.generate(16, (i) => i));
      expect(sequence.bars.first.songPartIndex, isNull);
    });

    test('page-level repeats and jumps are expanded', () {
      final sheet = ChordLeadSheet(
        barCount: 4,
        items: <LeadSheetItem>[
          CliRepeat(Position(0), isStart: true),
          CliRepeat(Position(1), isStart: false),
          chord(0, 0, 'C'),
        ],
      );
      final sequence = SongChordSequence.of(
        songOf(sheet, SongStructure.empty()),
      );
      expect(sequence.sourceBars, <int>[0, 1, 0, 1, 2, 3]);
    });
  });

  group('chords and time', () {
    test('every chord lands in every bar it is played in', () {
      final sheet = ChordLeadSheet(
        barCount: 2,
        items: <LeadSheetItem>[
          CliSection(Section(name: 'A', startBar: 0)),
          CliRepeat(Position(0), isStart: true),
          CliRepeat(Position(1), isStart: false),
          chord(0, 0, 'Cmaj7'),
          chord(0, 2, 'A7'),
          chord(1, 0, 'Dm7'),
        ],
      );
      final sequence = SongChordSequence.asWritten(sheet);
      expect(sequence.barCount, 4);
      expect(sequence.chords, hasLength(6));
      expect(sequence.chords.map((c) => c.chord.format()).toList(), <String>[
        'Cmaj7',
        'A7',
        'Dm7',
        'Cmaj7',
        'A7',
        'Dm7',
      ]);
      expect(sequence.chordsInBar(2), hasLength(2));
    });

    test('positions are absolute quarter notes from the start', () {
      final sheet = ChordLeadSheet(
        barCount: 2,
        items: <LeadSheetItem>[
          chord(0, 0, 'C'),
          chord(0, 2, 'F'),
          chord(1, 0, 'G'),
        ],
      );
      final sequence = SongChordSequence.asWritten(sheet);
      expect(sequence.chords.map((c) => c.startQuarters).toList(), <double>[
        0,
        2,
        4,
      ]);
      expect(sequence.totalQuarters, 8);
    });

    test('a meter change changes how long a bar is', () {
      final sheet = ChordLeadSheet(
        barCount: 4,
        items: <LeadSheetItem>[
          CliSection(Section(name: 'A', startBar: 0)),
          CliSection(
            Section(
              name: 'B',
              startBar: 2,
              timeSignature: TimeSignature.threeFour,
            ),
          ),
        ],
      );
      final sequence = SongChordSequence.asWritten(sheet);
      expect(sequence.bars.map((b) => b.startQuarters).toList(), <double>[
        0,
        4,
        8,
        11,
      ]);
      expect(sequence.totalQuarters, 14);
    });

    test('the chord sounding at a moment is the last one before it', () {
      final sheet = ChordLeadSheet(
        barCount: 2,
        items: <LeadSheetItem>[chord(0, 0, 'C'), chord(1, 0, 'G7')],
      );
      final sequence = SongChordSequence.asWritten(sheet);
      expect(sequence.chordAtQuarters(0)!.format(), 'C');
      expect(sequence.chordAtQuarters(3.9)!.format(), 'C');
      expect(sequence.chordAtQuarters(4)!.format(), 'G7');
      expect(sequence.chordAtQuarters(-1), isNull);
    });

    test('the bar containing a moment can be found', () {
      final sequence = SongChordSequence.asWritten(ChordLeadSheet(barCount: 4));
      expect(sequence.barAtQuarters(0)!.index, 0);
      expect(sequence.barAtQuarters(4)!.index, 1);
      expect(sequence.barAtQuarters(15.9)!.index, 3);
      expect(sequence.barAtQuarters(16), isNull);
    });

    test('every playback bar maps back to a written bar', () {
      final sheet = ChordLeadSheet(
        barCount: 4,
        items: <LeadSheetItem>[
          CliRepeat(Position(0), isStart: true),
          CliRepeat(Position(1), isStart: false),
        ],
      );
      final sequence = SongChordSequence.asWritten(sheet);
      expect(sequence.playbackBarsFor(0), <int>[0, 2]);
      expect(sequence.playbackBarsFor(3), <int>[5]);
      for (final source in sequence.sourceBars) {
        expect(source, inInclusiveRange(0, 3));
      }
    });
  });
}
