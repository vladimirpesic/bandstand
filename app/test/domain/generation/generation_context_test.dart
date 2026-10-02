import 'package:bandstand/domain/generation/generation_context.dart';
import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:bandstand/domain/phrase/float_range.dart';
import 'package:bandstand/domain/song/chord_leadsheet.dart';
import 'package:bandstand/domain/song/lead_sheet_item.dart';
import 'package:bandstand/domain/song/section.dart';
import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/domain/song/song_chord_sequence.dart';
import 'package:bandstand/domain/song/song_part.dart';
import 'package:bandstand/domain/song/song_structure.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harmony/harmony_test_support.dart';

void main() {
  installTestHarmony();

  GenerationContext contextOf(List<ContextChord> chords) => GenerationContext(
    chords: chords,
    beatRange: FloatRange(0, 8),
    timeSignature: TimeSignature.fourFour,
    tempo: 120,
    randomSeed: 1,
    parameterValues: const <String, Object>{},
  );

  group('chordAt', () {
    test('the chord sounding at a beat is the one that contains it', () {
      final context = contextOf(<ContextChord>[
        ContextChord(
          chord: ExtChordSymbol.parse('Dm7'),
          startBeat: 0,
          endBeat: 4,
        ),
        ContextChord(
          chord: ExtChordSymbol.parse('G7'),
          startBeat: 4,
          endBeat: 8,
        ),
      ]);
      expect(context.chordAt(-1), isNull);
      expect(context.chordAt(0)!.chord.format(), 'Dm7');
      expect(context.chordAt(3.99)!.chord.format(), 'Dm7');
      expect(context.chordAt(4)!.chord.format(), 'G7');
    });

    test('a chord is not returned once it has stopped sounding', () {
      // `endBeat` is half the contract of `ContextChord.contains`; a chord
      // past it is hold-over, not harmony, and accenting a note with a chord
      // that no longer sounds is how a chart lies about its own rhythm.
      final context = contextOf(<ContextChord>[
        ContextChord(
          chord: ExtChordSymbol.parse('Dm7'),
          startBeat: 0,
          endBeat: 4,
        ),
        ContextChord(
          chord: ExtChordSymbol.parse('G7'),
          startBeat: 4,
          endBeat: 8,
        ),
      ]);
      expect(context.chordAt(8), isNull);
      expect(context.chordAt(100), isNull);
    });
  });

  group('forPart', () {
    /// Two bars of 4/4, then two of 6/8, one part per section, with a chord
    /// on the downbeat of every bar.
    Song meterChangeSong() {
      final sheet = ChordLeadSheet(
        barCount: 4,
        items: <LeadSheetItem>[
          CliSection(
            Section(
              name: 'A',
              startBar: 0,
              timeSignature: TimeSignature.fourFour,
            ),
          ),
          CliSection(
            Section(
              name: 'B',
              startBar: 2,
              timeSignature: TimeSignature.sixEight,
            ),
          ),
          for (var bar = 0; bar < 4; bar++)
            CliChordSymbol(
              Position(bar),
              ExtChordSymbol.parse(<String>['Dm7', 'G7', 'Cmaj7', 'A7'][bar]),
            ),
        ],
      );
      return Song(
        id: 'test',
        title: 'Meter change',
        leadSheet: sheet,
        structure: SongStructure(<SongPart>[
          SongPart(
            parentSectionName: 'A',
            startBar: 0,
            barCount: 2,
            rhythmId: 'drums',
          ),
          SongPart(
            parentSectionName: 'B',
            startBar: 0,
            barCount: 2,
            rhythmId: 'drums',
          ),
        ]),
        tempo: 140,
      );
    }

    test('a 6/8 part reports positions in 6/8 beats', () {
      final song = meterChangeSong();
      final sequence = SongChordSequence.of(song);
      final context = GenerationContext.forPart(
        sequence: sequence,
        partIndex: 1,
        partCount: 2,
        part: song.structure.songParts[1],
        tempo: song.tempo,
        randomSeed: 1,
      );
      expect(context.timeSignature, TimeSignature.sixEight);
      // The part begins at quarter 8 (two 4/4 bars). Its first bar is three
      // quarters — six beats — long, so the bar-3 chord lands on beat 6,
      // and the part runs for twelve beats in all.
      expect(context.beatRange.end, 12);
      expect(context.chords, hasLength(2));
      expect(context.chords[0].chord.format(), 'Cmaj7');
      expect(context.chords[0].startBeat, 0);
      expect(context.chords[1].chord.format(), 'A7');
      expect(context.chords[1].startBeat, 6);
      expect(context.chords[1].endBeat, 12);
    });

    test('a part plays one meter, however long it is', () {
      // The invariant the single beat grid rests on, and the reason
      // `forPart`'s conversion is one division rather than a walk over the
      // bars accumulating each one's own beat length. A part names a section,
      // a section carries one meter, and a part longer than its section loops
      // it — so the bars never change meter under the grid. The walking form
      // was not monotonic when they did, and this is what says they cannot.
      final song = meterChangeSong();
      final sequence = SongChordSequence.of(song);
      for (final part in <SongPart>[
        SongPart(
          parentSectionName: 'A',
          startBar: 0,
          barCount: 6,
          rhythmId: 'drums',
        ),
        SongPart(
          parentSectionName: 'B',
          startBar: 0,
          barCount: 6,
          rhythmId: 'drums',
        ),
      ]) {
        final structure = SongStructure(<SongPart>[part]);
        final flattened = SongChordSequence.of(
          song.copyWith(structure: structure),
        );
        final bars = flattened.barsOfPart(0);
        expect(bars, isNotEmpty);
        expect(
          bars.map((bar) => bar.timeSignature).toSet(),
          hasLength(1),
          reason: '${part.parentSectionName} spans a meter change',
        );
      }
      expect(sequence.bars, isNotEmpty);
    });

    test('a 4/4 part next to a 6/8 one keeps its own beat frame', () {
      // The meter change falls on the boundary between the two parts here;
      // what this locks is that a part's beat frame is its own first bar's,
      // whatever meter the neighbouring part is in.
      final song = meterChangeSong();
      final sequence = SongChordSequence.of(song);
      final context = GenerationContext.forPart(
        sequence: sequence,
        partIndex: 0,
        partCount: 2,
        part: song.structure.songParts[0],
        tempo: song.tempo,
        randomSeed: 1,
      );
      expect(context.timeSignature, TimeSignature.fourFour);
      expect(context.beatRange.end, 8);
      expect(context.chords[1].chord.format(), 'G7');
      expect(context.chords[1].startBeat, 4);
      expect(context.chords[1].endBeat, 8);
    });
  });
}
