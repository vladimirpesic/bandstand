import 'package:bandstand/domain/command/command.dart';
import 'package:bandstand/domain/command/undo_stack.dart';
import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/domain/song/written_part.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  WrittenNote note(int bar) =>
      WrittenNote(bar: bar, beat: 0, key: 60, durationBeats: 1);

  Song songWith(WrittenPart part) {
    final blank = Song.blank(id: 'blank');
    return Song(
      id: 'tune',
      title: 'Tune',
      leadSheet: blank.leadSheet,
      structure: blank.structure,
      writtenParts: <WrittenPart>[part],
      createdAt: DateTime.utc(2026, 1, 1),
      modifiedAt: DateTime.utc(2026, 1, 1),
    );
  }

  group('value equality', () {
    test('songs differing only in written parts are not equal', () {
      final a = songWith(
        WrittenPart(id: 'head', displayName: 'Head', notes: [note(0)]),
      );
      final b = songWith(
        WrittenPart(id: 'head', displayName: 'Head', notes: [note(0), note(1)]),
      );
      expect(a, isNot(b));
      expect(a.hashCode, isNot(b.hashCode));
    });

    test('writtenParts are compared pairwise, not by identity', () {
      final part = WrittenPart(
        id: 'head',
        displayName: 'Head',
        notes: [note(0)],
      );
      final a = songWith(part);
      final b = songWith(
        WrittenPart(id: 'head', displayName: 'Head', notes: [note(0)]),
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });

  group('undo (§4.4)', () {
    test('an edit touching only written parts is recorded and undone', () {
      // UndoStack.run discards a command whose before and after compare
      // equal — so when Song.== ignored writtenParts, an edit that changed
      // nothing else was silently non-undoable. modifiedAt is preserved
      // deliberately: only writtenParts may differ between before and after.
      final song = songWith(
        WrittenPart(id: 'head', displayName: 'Head', notes: [note(0)]),
      );
      final stack = UndoStack<Song>(song);
      stack.run(
        FunctionCommand<Song>(
          'Add note',
          (value) => value.copyWith(
            writtenParts: <WrittenPart>[
              value.writtenParts.single.copyWith(
                notes: <WrittenNote>[note(0), note(1)],
              ),
            ],
            modifiedAt: value.modifiedAt,
          ),
        ),
      );
      expect(stack.canUndo, isTrue);
      final undone = stack.undo();
      expect(undone.writtenParts.single.notes, hasLength(1));
      expect(undone, song);
      expect(stack.redoLabel, 'Add note');
    });
  });
}
