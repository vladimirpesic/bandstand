import 'command.dart';

/// One step on the undo stack: the value before and after an edit.
class UndoStep<T> {
  /// Create a step.
  const UndoStep(this.label, this.before, this.after);

  /// What the undo menu calls it.
  final String label;

  /// The value before the edit.
  final T before;

  /// The value after it.
  final T after;

  @override
  String toString() => label;
}

/// The undo history for one document (§4.4).
///
/// Holds whole values rather than deltas. The model is immutable and structural
/// sharing makes that cheap, and it removes the entire class of bug where an
/// inverse operation is subtly not the inverse.
class UndoStack<T> {
  /// Create a stack over an initial value.
  ///
  /// Throws [ArgumentError] if `limit` is below one.
  UndoStack(
    T initial, {
    this.limit = 200,
    this.mergeWindow = const Duration(milliseconds: 900),
  }) : _value = initial {
    if (limit < 1) {
      throw ArgumentError.value(limit, 'limit', 'must be at least one');
    }
  }

  /// How many steps are remembered. Older ones fall off the bottom.
  final int limit;

  /// How close together two mergeable edits must be to become one step.
  final Duration mergeWindow;

  final List<UndoStep<T>> _undo = <UndoStep<T>>[];
  final List<UndoStep<T>> _redo = <UndoStep<T>>[];
  T _value;
  Command<T>? _lastCommand;
  DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// The current value.
  T get value => _value;

  /// Whether there is anything to undo.
  bool get canUndo => _undo.isNotEmpty;

  /// Whether there is anything to redo.
  bool get canRedo => _redo.isNotEmpty;

  /// What the next undo would reverse, or null.
  String? get undoLabel => _undo.isEmpty ? null : _undo.last.label;

  /// What the next redo would repeat, or null.
  String? get redoLabel => _redo.isEmpty ? null : _redo.last.label;

  /// How many steps are on the undo stack.
  int get undoLength => _undo.length;

  /// How many steps are on the redo stack.
  int get redoLength => _redo.length;

  /// Run [command], remember it, and return the new value.
  ///
  /// A command that changes nothing is not recorded: pressing undo should never
  /// appear to do nothing.
  T run(Command<T> command, {DateTime? at}) {
    final now = at ?? DateTime.now();
    final before = _value;
    final after = command.apply(before);
    if (after == before) {
      return before;
    }

    final previous = _lastCommand;
    final mergeable =
        previous != null &&
        _undo.isNotEmpty &&
        now.difference(_lastAt) <= mergeWindow &&
        previous.canMergeWith(command);

    if (mergeable) {
      final merged = _undo.removeLast();
      _undo.add(UndoStep<T>(command.label, merged.before, after));
    } else {
      _undo.add(UndoStep<T>(command.label, before, after));
      if (_undo.length > limit) {
        _undo.removeAt(0);
      }
    }

    _redo.clear();
    _value = after;
    _lastCommand = command;
    _lastAt = now;
    return after;
  }

  /// Undo one step and return the value. Does nothing when there is none.
  T undo() {
    if (_undo.isEmpty) {
      return _value;
    }
    final step = _undo.removeLast();
    _redo.add(step);
    _value = step.before;
    _lastCommand = null;
    return _value;
  }

  /// Redo one step and return the value. Does nothing when there is none.
  T redo() {
    if (_redo.isEmpty) {
      return _value;
    }
    final step = _redo.removeLast();
    _undo.add(step);
    _value = step.after;
    _lastCommand = null;
    return _value;
  }

  /// Replace the value without recording a step, and forget the history.
  ///
  /// What loading a different song does. Keeping the old song's history would
  /// let undo apply one document's edits to another.
  void reset(T newValue) {
    _value = newValue;
    _undo.clear();
    _redo.clear();
    _lastCommand = null;
  }

  /// Forget the history, keeping the value — "this is the saved state now".
  void clearHistory() {
    _undo.clear();
    _redo.clear();
    _lastCommand = null;
  }

  @override
  String toString() => 'UndoStack(${_undo.length} undo, ${_redo.length} redo)';
}
