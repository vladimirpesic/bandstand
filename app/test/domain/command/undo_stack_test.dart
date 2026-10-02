import 'package:bandstand/domain/command/command.dart';
import 'package:bandstand/domain/command/undo_stack.dart';
import 'package:flutter_test/flutter_test.dart';

Command<int> add(int n) => FunctionCommand<int>('Add $n', (v) => v + n);
Command<int> typing(int n) =>
    FunctionCommand<int>('Type', (v) => v + n, mergeKey: 'typing');

void main() {
  group('running commands', () {
    test('applies and remembers', () {
      final stack = UndoStack<int>(0);
      expect(stack.run(add(1)), 1);
      expect(stack.run(add(2)), 3);
      expect(stack.value, 3);
      expect(stack.canUndo, isTrue);
      expect(stack.undoLabel, 'Add 2');
      expect(stack.canRedo, isFalse);
    });

    test('a command that changes nothing is not recorded', () {
      final stack = UndoStack<int>(5);
      expect(stack.run(add(0)), 5);
      expect(stack.canUndo, isFalse);
      expect(stack.undoLength, 0);
    });

    test('running after an undo forgets the redo', () {
      final stack = UndoStack<int>(0)
        ..run(add(1))
        ..run(add(2));
      stack.undo();
      expect(stack.canRedo, isTrue);
      stack.run(add(10));
      expect(stack.canRedo, isFalse);
      expect(stack.value, 11);
    });
  });

  group('undo and redo', () {
    test('walk the history in both directions', () {
      final stack = UndoStack<int>(0)
        ..run(add(1))
        ..run(add(2))
        ..run(add(3));
      expect(stack.value, 6);
      expect(stack.undo(), 3);
      expect(stack.undo(), 1);
      expect(stack.undo(), 0);
      expect(stack.canUndo, isFalse);
      expect(stack.undo(), 0);
      expect(stack.redo(), 1);
      expect(stack.redo(), 3);
      expect(stack.redo(), 6);
      expect(stack.canRedo, isFalse);
      expect(stack.redo(), 6);
    });

    test('fifty operations undo and redo without diverging', () {
      // §10 M2: undo/redo 50 operations without divergence.
      final stack = UndoStack<int>(0);
      final expected = <int>[0];
      for (var i = 1; i <= 50; i++) {
        stack.run(add(i));
        expected.add(expected.last + i);
      }
      expect(stack.value, expected.last);
      for (var i = 50; i >= 1; i--) {
        expect(stack.undo(), expected[i - 1], reason: 'undo $i');
      }
      expect(stack.value, 0);
      for (var i = 1; i <= 50; i++) {
        expect(stack.redo(), expected[i], reason: 'redo $i');
      }
      expect(stack.value, expected.last);
      // And round again, to prove the history is not consumed.
      for (var i = 50; i >= 1; i--) {
        expect(stack.undo(), expected[i - 1]);
      }
      expect(stack.value, 0);
    });

    test('the labels say what will happen', () {
      final stack = UndoStack<int>(0)..run(add(1));
      expect(stack.undoLabel, 'Add 1');
      expect(stack.redoLabel, isNull);
      stack.undo();
      expect(stack.undoLabel, isNull);
      expect(stack.redoLabel, 'Add 1');
    });
  });

  group('merging', () {
    test('keystrokes close together become one step', () {
      final start = DateTime(2026);
      final stack = UndoStack<int>(0)
        ..run(typing(1), at: start)
        ..run(typing(1), at: start.add(const Duration(milliseconds: 100)))
        ..run(typing(1), at: start.add(const Duration(milliseconds: 200)));
      expect(stack.value, 3);
      expect(stack.undoLength, 1);
      expect(stack.undo(), 0);
    });

    test('a pause ends the merge', () {
      final start = DateTime(2026);
      final stack = UndoStack<int>(0)
        ..run(typing(1), at: start)
        ..run(typing(1), at: start.add(const Duration(seconds: 5)));
      expect(stack.undoLength, 2);
    });

    test('a different kind of edit ends the merge', () {
      final start = DateTime(2026);
      final stack = UndoStack<int>(0)
        ..run(typing(1), at: start)
        ..run(add(1), at: start.add(const Duration(milliseconds: 10)))
        ..run(typing(1), at: start.add(const Duration(milliseconds: 20)));
      expect(stack.undoLength, 3);
    });

    test('commands without a merge key never merge', () {
      final start = DateTime(2026);
      final stack = UndoStack<int>(0)
        ..run(add(1), at: start)
        ..run(add(1), at: start.add(const Duration(milliseconds: 10)));
      expect(stack.undoLength, 2);
    });
  });

  group('limits and resets', () {
    test('the oldest steps fall off the bottom', () {
      final stack = UndoStack<int>(0, limit: 3);
      for (var i = 0; i < 10; i++) {
        stack.run(add(1));
      }
      expect(stack.undoLength, 3);
      expect(stack.value, 10);
      stack
        ..undo()
        ..undo()
        ..undo();
      expect(stack.value, 7);
      expect(stack.canUndo, isFalse);
    });

    test('a limit below one is refused', () {
      expect(() => UndoStack<int>(0, limit: 0), throwsArgumentError);
    });

    test('reset replaces the value and forgets everything', () {
      final stack = UndoStack<int>(0)
        ..run(add(5))
        ..reset(99);
      expect(stack.value, 99);
      expect(stack.canUndo, isFalse);
      expect(stack.canRedo, isFalse);
    });

    test('clearHistory keeps the value', () {
      final stack = UndoStack<int>(0)
        ..run(add(5))
        ..clearHistory();
      expect(stack.value, 5);
      expect(stack.canUndo, isFalse);
    });
  });
}
