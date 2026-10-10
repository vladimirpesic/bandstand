import 'package:bandstand/domain/command/undo_stack.dart';
import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:bandstand/domain/song/chord_leadsheet.dart';
import 'package:bandstand/domain/song/lead_sheet_item.dart';
import 'package:bandstand/domain/song/section.dart';
import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/domain/song/song_commands.dart';
import 'package:bandstand/domain/song/song_structure.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harmony/harmony_test_support.dart';

/// `transposeTo` is what the key picker runs, and the property it must hold
/// is that the chart and the key move *together*: a picker that relabels the
/// key without moving the chart is how the two end up disagreeing about what
/// tune they are in, which reads on stage as "transpose is erratic".
void main() {
  installTestHarmony();

  Song tuneInC() {
    final sheet = ChordLeadSheet(
      barCount: 4,
      items: <LeadSheetItem>[
        CliSection(Section(name: 'A', startBar: 0)),
        CliChordSymbol(Position(0), ExtChordSymbol.parse('Cmaj7')),
        CliChordSymbol(Position(1), ExtChordSymbol.parse('Dm7')),
        CliChordSymbol(Position(2), ExtChordSymbol.parse('G7')),
        CliChordSymbol(Position(3), ExtChordSymbol.parse('Cmaj7')),
      ],
    );
    return Song(
      id: 'tune',
      title: 'Tune',
      leadSheet: sheet,
      structure: SongStructure.fromLeadSheet(sheet, rhythmId: 'swing'),
    );
  }

  List<String> chordsOf(Song song) => <String>[
    for (final item in song.leadSheet.chordItems) item.chord.format(),
  ];

  group('SongCommands.transposeTo', () {
    test('moves the chart and the key together', () {
      final song = tuneInC();
      final moved = SongCommands.transposeTo(
        song.key,
        KeySignature.parse('Eb'),
      ).apply(song);
      expect(moved.key.toString(), 'Eb');
      expect(chordsOf(moved), <String>['Ebmaj7', 'Fm7', 'Bb7', 'Ebmaj7']);
    });

    test('takes the shorter of the two paths', () {
      // C to F is up a fourth, not down a fifth. Both arrive; the shorter
      // ride is the one the undo label and the listener's register expect.
      final song = tuneInC();
      final moved = SongCommands.transposeTo(
        song.key,
        KeySignature.parse('F'),
      ).apply(song);
      expect(moved.key.toString(), 'F');
      expect(chordsOf(moved), <String>['Fmaj7', 'Gm7', 'C7', 'Fmaj7']);
    });

    test('the target names the key, not the arithmetic', () {
      // Gb is six semitones away in both directions; the song ends up in the
      // key that was picked, spelled the way that key spells itself.
      final song = tuneInC();
      final moved = SongCommands.transposeTo(
        song.key,
        KeySignature.parse('Gb'),
      ).apply(song);
      expect(moved.key.toString(), 'Gb');
      expect(chordsOf(moved).first, 'Gbmaj7');
    });

    test('the mode comes from the target', () {
      // Picking Eb minor from C major: the chart moves a minor third up, and
      // the key says minor, because that is what was picked.
      final song = tuneInC();
      final moved = SongCommands.transposeTo(
        song.key,
        KeySignature.parse('Ebm'),
      ).apply(song);
      expect(moved.key.toString(), 'Ebm');
      expect(chordsOf(moved), <String>['Ebmaj7', 'Fm7', 'Bb7', 'Ebmaj7']);
    });

    test('merges with stepper nudges into one undo step', () {
      final original = tuneInC();
      final stack = UndoStack<Song>(original);
      stack.run(SongCommands.transpose(1));
      stack.run(
        SongCommands.transposeTo(
          KeySignature.parse('C'),
          KeySignature.parse('D'),
        ),
      );
      final undone = stack.undo();
      expect(undone.key.toString(), 'C');
      expect(chordsOf(undone), chordsOf(original));
    });
  });
}
