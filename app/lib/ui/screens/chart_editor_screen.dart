import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:bandstand/domain/song/lead_sheet_item.dart';
import 'package:bandstand/domain/song/section.dart';
import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/domain/song/song_commands.dart';
import 'package:bandstand/render/chart_style.dart';
import 'package:bandstand/render/chart_view.dart';
import 'package:bandstand/state/library_state.dart';
import 'package:bandstand/ui/screens/reading_mode_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Where the next chord goes.
class EditPosition {
  /// Create a caret position.
  const EditPosition(this.bar, this.beat);

  /// The written bar.
  final int bar;

  /// The beat within it.
  final double beat;

  /// The position as the model writes it.
  Position get position => Position(bar, beat);

  @override
  bool operator ==(Object other) =>
      other is EditPosition && other.bar == bar && other.beat == beat;

  @override
  int get hashCode => Object.hash(bar, beat);
}

/// The chart editor (§8.2).
///
/// Chord entry is the friction point, so it is a text field that is always
/// focused: type `Dm7`, press enter, the chord lands and the caret moves to the
/// next bar. Arrow keys move the caret without touching the keyboard's home
/// row. Everything else — sections, repeats, endings, marks — is a button, and
/// every one of them is a [Command], so every one of them undoes.
class ChartEditorScreen extends ConsumerStatefulWidget {
  const ChartEditorScreen({super.key});

  @override
  ConsumerState<ChartEditorScreen> createState() => _ChartEditorScreenState();
}

class _ChartEditorScreenState extends ConsumerState<ChartEditorScreen> {
  final TextEditingController _entry = TextEditingController();
  final FocusNode _entryFocus = FocusNode();
  EditPosition _caret = const EditPosition(0, 0);

  /// How far the caret moves after a chord is entered, in beats.
  ///
  /// A whole bar by default, because most bars hold one chord. Half a bar is a
  /// toggle rather than a mode you can get stuck in.
  bool _halfBarSteps = false;

  @override
  void dispose() {
    _entry.dispose();
    _entryFocus.dispose();
    super.dispose();
  }

  Song? get _song => ref.read(songEditorProvider);
  SongEditor get _editor => ref.read(songEditorProvider.notifier);

  double _beatsPerBar(int bar) =>
      (_song?.leadSheet.timeSignatureAt(bar).upper ?? 4).toDouble();

  void _moveTo(int bar, double beat) {
    final song = _song;
    if (song == null) {
      return;
    }
    final clampedBar = bar.clamp(0, song.leadSheet.barCount - 1);
    setState(() {
      _caret = EditPosition(
        clampedBar,
        // The target bar's meter decides how far the beat may go — landing in
        // a 3/4 bar after a 4/4 one must not keep the wider bar's last beat.
        beat.clamp(0, _beatsPerBar(clampedBar) - 0.5),
      );
      _entry.text =
          song.leadSheet
              .itemsInBarOfType<CliChordSymbol>(_caret.bar)
              .where((item) => item.position.beat == _caret.beat)
              .firstOrNull
              ?.chord
              .format() ??
          '';
      _entry.selection = TextSelection.collapsed(offset: _entry.text.length);
    });
    _entryFocus.requestFocus();
  }

  void _step(int direction) {
    final song = _song;
    if (song == null) {
      return;
    }
    // Walk bar by bar: the meter can change at any bar line, so a step is
    // "past the end of this bar" in *this* bar's beats, not arithmetic in a
    // global beat count that assumes one meter throughout.
    final last = song.leadSheet.barCount - 1;
    var bar = _caret.bar;
    final stride = _halfBarSteps ? _beatsPerBar(bar) / 2 : _beatsPerBar(bar);
    var beat = _caret.beat + direction * stride;
    if (direction > 0) {
      while (beat > _beatsPerBar(bar) - 0.5) {
        if (bar >= last) {
          beat = _beatsPerBar(bar) - 0.5;
          break;
        }
        beat -= _beatsPerBar(bar);
        bar++;
      }
    } else {
      while (beat < 0) {
        if (bar <= 0) {
          beat = 0;
          break;
        }
        bar--;
        beat += _beatsPerBar(bar);
      }
    }
    _moveTo(bar, beat);
  }

  void _commit() {
    final song = _song;
    if (song == null) {
      return;
    }
    final text = _entry.text.trim();
    if (text.isEmpty) {
      _editor.run(SongCommands.removeChord(_caret.position));
      _step(1);
      return;
    }
    final chord = ExtChordSymbol.tryParse(text);
    if (chord == null) {
      return;
    }
    _editor.run(SongCommands.setChord(_caret.position, chord));
    _step(1);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowRight:
        _step(1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowLeft:
        _step(-1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        _moveTo(_caret.bar + 4, _caret.beat);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        _moveTo(_caret.bar - 4, _caret.beat);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.tab:
        setState(() => _halfBarSteps = !_halfBarSteps);
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  @override
  Widget build(BuildContext context) {
    final song = ref.watch(songEditorProvider);
    if (song == null) {
      return const Scaffold(body: Center(child: Text('No song is open.')));
    }
    final scheme = Theme.of(context).colorScheme;
    final parsed = ExtChordSymbol.tryParse(_entry.text.trim());
    final entryIsBad = _entry.text.trim().isNotEmpty && parsed == null;

    return Scaffold(
      appBar: AppBar(
        title: Text(song.title),
        actions: <Widget>[
          IconButton(
            tooltip: _editor.canUndo
                ? 'Undo ${_editor.undoLabel}'
                : 'Nothing to undo',
            onPressed: _editor.canUndo
                ? () {
                    _editor.undo();
                    _moveTo(_caret.bar, _caret.beat);
                  }
                : null,
            icon: const Icon(Icons.undo),
          ),
          IconButton(
            tooltip: _editor.canRedo
                ? 'Redo ${_editor.redoLabel}'
                : 'Nothing to redo',
            onPressed: _editor.canRedo
                ? () {
                    _editor.redo();
                    _moveTo(_caret.bar, _caret.beat);
                  }
                : null,
            icon: const Icon(Icons.redo),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Reading mode',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ReadingModeScreen(song: song),
              ),
            ),
            icon: const Icon(Icons.fullscreen),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: () => _save(context),
            icon: const Icon(Icons.save_outlined),
            label: const Text('Save'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            child: ChartView(
              sheet: song.leadSheet,
              style: ChartStyle.editing(scheme),
              selectedBar: _caret.bar,
              onBarTapped: _moveTo,
              padding: const EdgeInsets.all(12),
            ),
          ),
          const Divider(height: 1),
          _EntryBar(
            controller: _entry,
            focusNode: _entryFocus,
            caret: _caret,
            halfBarSteps: _halfBarSteps,
            isBad: entryIsBad,
            onKey: _onKey,
            // `entryIsBad` is computed in `build`, and a `TextField` typing
            // into its controller does not rebuild its parent — so the "Not a
            // chord symbol" indicator never appeared while the chord was
            // being typed, which is the only time it is any use.
            // `import_dialog.dart` documents the same trap.
            onEntryChanged: () => setState(() {}),
            onSubmitted: (_) => _commit(),
            onToggleStep: () => setState(() => _halfBarSteps = !_halfBarSteps),
            onCommit: _commit,
          ),
          _StructureBar(
            song: song,
            caret: _caret,
            editor: _editor,
            onChanged: () => _moveTo(_caret.bar, _caret.beat),
          ),
        ],
      ),
    );
  }

  Future<void> _save(BuildContext context) async {
    // A failed save is the one thing the player must not miss: the disk is
    // full, the library folder has gone, the file is read-only. It used to
    // propagate as an unhandled async error, so the tune stayed unsaved, no
    // "Saved." appeared, and nothing said why.
    try {
      await _editor.save();
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not save: $error')));
      return;
    }
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Saved.')));
  }
}

class _EntryBar extends StatelessWidget {
  const _EntryBar({
    required this.controller,
    required this.focusNode,
    required this.caret,
    required this.halfBarSteps,
    required this.isBad,
    required this.onKey,
    required this.onEntryChanged,
    required this.onSubmitted,
    required this.onToggleStep,
    required this.onCommit,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final EditPosition caret;
  final bool halfBarSteps;
  final bool isBad;

  /// Called as the field is typed into, so the error indicator can appear.
  final VoidCallback onEntryChanged;
  final KeyEventResult Function(FocusNode, KeyEvent) onKey;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onToggleStep;
  final VoidCallback onCommit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 132,
            child: Text(
              'Bar ${caret.bar + 1}  beat ${(caret.beat + 1).toStringAsFixed(caret.beat % 1 == 0 ? 0 : 1)}',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          Expanded(
            child: Focus(
              onKeyEvent: onKey,
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                autofocus: true,
                textCapitalization: TextCapitalization.none,
                decoration: InputDecoration(
                  hintText: 'Chord — Dm7, Bbmaj7#11, N.C.  (enter to place)',
                  errorText: isBad ? 'Not a chord symbol' : null,
                  suffixIcon: IconButton(
                    tooltip: 'Place',
                    onPressed: onCommit,
                    icon: const Icon(Icons.keyboard_return),
                  ),
                ),
                onChanged: (_) => onEntryChanged(),
                onSubmitted: onSubmitted,
              ),
            ),
          ),
          const SizedBox(width: 12),
          FilterChip(
            label: Text(halfBarSteps ? 'Half bar' : 'Whole bar'),
            selected: halfBarSteps,
            onSelected: (_) => onToggleStep(),
            avatar: const Icon(Icons.straighten, size: 18),
            tooltip: 'How far the caret moves after a chord (tab)',
            backgroundColor: scheme.surfaceContainerHighest,
          ),
        ],
      ),
    );
  }
}

class _StructureBar extends StatelessWidget {
  const _StructureBar({
    required this.song,
    required this.caret,
    required this.editor,
    required this.onChanged,
  });

  final Song song;
  final EditPosition caret;
  final SongEditor editor;
  final VoidCallback onChanged;

  void _run(void Function() action) {
    action();
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final sheet = song.leadSheet;
    final bar = caret.bar;
    final hasRepeatStart = sheet
        .itemsInBarOfType<CliRepeat>(bar)
        .any((item) => item.isStart);
    final hasRepeatEnd = sheet
        .itemsInBarOfType<CliRepeat>(bar)
        .any((item) => !item.isStart);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(
        children: <Widget>[
          _Action(
            label: 'Section',
            icon: Icons.bookmark_outline,
            onPressed: () => _run(
              () => editor.run(
                SongCommands.addSection(
                  Section(
                    name: _nextSectionName(song),
                    startBar: bar,
                    timeSignature: sheet.timeSignatureAt(bar),
                  ),
                ),
              ),
            ),
          ),
          _Action(
            label: hasRepeatStart ? 'Remove |:' : 'Repeat |:',
            icon: Icons.first_page,
            onPressed: () => _run(() {
              final existing = sheet
                  .itemsInBarOfType<CliRepeat>(bar)
                  .where((item) => item.isStart)
                  .firstOrNull;
              editor.run(
                existing != null
                    ? SongCommands.removeItem(existing)
                    : SongCommands.addItem(
                        CliRepeat(Position(bar), isStart: true),
                      ),
              );
            }),
          ),
          _Action(
            label: hasRepeatEnd ? 'Remove :|' : 'Repeat :|',
            icon: Icons.last_page,
            onPressed: () => _run(() {
              final existing = sheet
                  .itemsInBarOfType<CliRepeat>(bar)
                  .where((item) => !item.isStart)
                  .firstOrNull;
              editor.run(
                existing != null
                    ? SongCommands.removeItem(existing)
                    : SongCommands.addItem(
                        CliRepeat(Position(bar), isStart: false),
                      ),
              );
            }),
          ),
          _Action(
            label: 'Ending 1',
            icon: Icons.looks_one_outlined,
            onPressed: () => _run(
              () => editor.run(
                SongCommands.addItem(CliEnding(Position(bar), <int>{1})),
              ),
            ),
          ),
          _Action(
            label: 'Ending 2',
            icon: Icons.looks_two_outlined,
            onPressed: () => _run(
              () => editor.run(
                SongCommands.addItem(CliEnding(Position(bar), <int>{2})),
              ),
            ),
          ),
          _MarkMenu(
            onSelected: (mark) => _run(
              () => editor.run(
                SongCommands.addItem(CliNavigation(Position(bar), mark)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _Action(
            label: 'Insert 4 bars',
            icon: Icons.add,
            onPressed: () =>
                _run(() => editor.run(SongCommands.insertBars(bar, 4))),
          ),
          _Action(
            label: 'Delete bar',
            icon: Icons.remove,
            onPressed: sheet.barCount <= 1
                ? null
                : () => _run(() => editor.run(SongCommands.removeBars(bar, 1))),
          ),
        ],
      ),
    );
  }

  /// The next unused letter, so adding a section does not need a dialog.
  static String _nextSectionName(Song song) {
    final used = song.leadSheet.sections.map((s) => s.name).toSet();
    for (var code = 'A'.codeUnitAt(0); code <= 'Z'.codeUnitAt(0); code++) {
      final name = String.fromCharCode(code);
      if (!used.contains(name)) {
        return name;
      }
    }
    return 'Section ${used.length + 1}';
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.label, required this.icon, this.onPressed});

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
    ),
  );
}

class _MarkMenu extends StatelessWidget {
  const _MarkMenu({required this.onSelected});

  final ValueChanged<NavigationMark> onSelected;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: PopupMenuButton<NavigationMark>(
      tooltip: 'Add a navigation mark',
      onSelected: onSelected,
      itemBuilder: (context) => <PopupMenuEntry<NavigationMark>>[
        for (final mark in NavigationMark.values)
          PopupMenuItem<NavigationMark>(value: mark, child: Text(mark.label)),
      ],
      child: OutlinedButton.icon(
        onPressed: null,
        icon: const Icon(Icons.alt_route, size: 18),
        label: const Text('Mark'),
      ),
    ),
  );
}
