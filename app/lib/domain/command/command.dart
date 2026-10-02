/// A reversible edit (§4.4).
///
/// The UI never mutates the model directly: it builds a command, hands it to an
/// [UndoStack], and reads the result. Retrofitting undo into a chart editor is
/// miserable, so it is here from the first edit.
///
/// The model is immutable, so a command is a pure function of the old value —
/// which makes undo exact rather than approximately exact.
abstract class Command<T> {
  /// Create a command.
  const Command(this.label);

  /// What the undo menu calls it: "Add chord", "Delete 4 bars".
  final String label;

  /// The value after the edit.
  T apply(T value);

  /// Whether this command can absorb [next] into itself.
  ///
  /// Typing a chord symbol produces one command per keystroke; a user pressing
  /// undo expects the whole word back, not the last letter. Commands that
  /// return true here are merged while they arrive within the stack's merge
  /// window.
  bool canMergeWith(Command<T> next) => false;

  @override
  String toString() => label;
}

/// A command built from a function.
///
/// Most edits are one line — "replace the lead sheet with this one" — and do
/// not deserve a class each.
class FunctionCommand<T> extends Command<T> {
  /// Create a command from [transform].
  const FunctionCommand(super.label, this.transform, {this.mergeKey});

  /// The edit.
  final T Function(T value) transform;

  /// Commands sharing a non-null merge key are merged when they arrive close
  /// together — one undo step per word typed, not per keystroke.
  final String? mergeKey;

  @override
  T apply(T value) => transform(value);

  @override
  bool canMergeWith(Command<T> next) =>
      mergeKey != null &&
      next is FunctionCommand<T> &&
      next.mergeKey == mergeKey;
}
