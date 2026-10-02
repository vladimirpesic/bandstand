import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/domain/song/song_chord_sequence.dart';
import 'package:bandstand/domain/song/song_commands.dart';
import 'package:bandstand/domain/generation/song_generator.dart';
import 'package:bandstand/render/chart_style.dart';
import 'package:bandstand/render/chart_view.dart';
import 'package:bandstand/state/export_state.dart';
import 'package:bandstand/state/generation_state.dart';
import 'package:bandstand/state/library_state.dart';
import 'package:bandstand/ui/screens/chart_editor_screen.dart';
import 'package:bandstand/ui/screens/chord_reference_screen.dart';
import 'package:bandstand/ui/screens/practice_screen.dart';
import 'package:bandstand/ui/screens/reading_mode_screen.dart';
import 'package:bandstand/ui/widgets/labelled_value.dart';
import 'package:bandstand/ui/widgets/song_transport_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A song's metadata, arrangement and form, with undo.
///
/// The chart itself is drawn at M3; this is what M2 can honestly show — and it
/// is what proves the command pattern works end to end, because every field
/// here is edited through a [Command].
class SongDetailsScreen extends ConsumerWidget {
  const SongDetailsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final song = ref.watch(songEditorProvider);
    final editor = ref.read(songEditorProvider.notifier);

    if (song == null) {
      return const Scaffold(body: Center(child: Text('No song is open.')));
    }

    // The export result is reported wherever the export was started from, so
    // the listener lives on the screen rather than in the export menu — the
    // narrow layout below has no room for a separate export menu.
    ref.listen(exportProvider, (previous, next) {
      final messenger = ScaffoldMessenger.of(context);
      final path = next.lastPath;
      final error = next.errorMessage;
      if (path != null && path != previous?.lastPath) {
        messenger.showSnackBar(SnackBar(content: Text('Exported to $path')));
      } else if (error != null && error != previous?.errorMessage) {
        messenger.showSnackBar(
          SnackBar(content: Text('The export failed: $error')),
        );
      }
    });

    final undo = IconButton(
      tooltip: editor.undoLabel == null
          ? 'Nothing to undo'
          : 'Undo ${editor.undoLabel}',
      onPressed: editor.canUndo ? editor.undo : null,
      icon: const Icon(Icons.undo),
    );
    final redo = IconButton(
      tooltip: editor.redoLabel == null
          ? 'Nothing to redo'
          : 'Redo ${editor.redoLabel}',
      onPressed: editor.canRedo ? editor.redo : null,
      icon: const Icon(Icons.redo),
    );
    final editChart = IconButton(
      tooltip: 'Edit the chart',
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const ChartEditorScreen()),
      ),
      icon: const Icon(Icons.edit_note),
    );
    final chordReference = IconButton(
      tooltip: 'Chords and scales',
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChordReferenceScreen(song: song),
        ),
      ),
      icon: const Icon(Icons.grid_on),
    );
    final practice = IconButton(
      tooltip: 'Practice',
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => PracticeScreen(song: song)),
      ),
      icon: const Icon(Icons.fitness_center),
    );
    final readingMode = IconButton(
      tooltip: 'Reading mode',
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => ReadingModeScreen(song: song)),
      ),
      icon: const Icon(Icons.fullscreen),
    );
    final save = FilledButton.icon(
      onPressed: () => _save(context, ref),
      icon: const Icon(Icons.save_outlined),
      label: const Text('Save'),
    );

    // The whole row — six icon buttons, the export menu and a labelled Save
    // button — is about 460 dp wide, which overflows a 411 dp phone portrait
    // by ~49 px and broke every suite that opened this screen there (found
    // by the Android emulator run; F-12, AUDIT_REPORT.md). A narrow screen
    // keeps what the player reaches mid-edit — undo, redo, edit, reading
    // mode, save — and the rest goes behind one overflow menu.
    final wide = MediaQuery.sizeOf(context).width >= 600;

    return Scaffold(
      appBar: AppBar(
        // The title gets whatever the actions leave it; shrink the text
        // rather than paint it under the buttons.
        title: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(song.title),
        ),
        actions: wide
            ? <Widget>[
                undo,
                redo,
                const SizedBox(width: 8),
                editChart,
                chordReference,
                practice,
                readingMode,
                _ExportMenu(song: song),
                const SizedBox(width: 8),
                save,
                const SizedBox(width: 12),
              ]
            : <Widget>[
                undo,
                redo,
                editChart,
                readingMode,
                _OverflowMenu(song: song),
                save,
              ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          _Section(
            title: 'Details',
            child: _Details(song: song, editor: editor),
          ),
          _Section(
            title: 'Chart',
            child: SizedBox(
              height: 280,
              child: ChartView(
                sheet: song.leadSheet,
                style: ChartStyle.editing(Theme.of(context).colorScheme),
              ),
            ),
          ),
          _Section(
            title: 'Play',
            child: SongTransportBar(song: song),
          ),
          _Section(
            title: 'Form',
            child: _Form(song: song),
          ),
          _Section(
            title: 'Arrangement',
            child: _Arrangement(song: song, editor: editor),
          ),
        ],
      ),
    );
  }

  Future<void> _save(BuildContext context, WidgetRef ref) async {
    // A failed save is the one thing the player must not miss: the disk is
    // full, the library folder has gone, the file is read-only. It used to
    // propagate as an unhandled async error, so the tune stayed unsaved, no
    // "Saved." appeared, and nothing said why.
    try {
      await ref.read(songEditorProvider.notifier).save();
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

/// Writes the tune out (§5.3).
///
/// A menu rather than a screen: three formats, one tap each, and the result is
/// a line saying where the file went — an export the user cannot find has not
/// happened (`docs/rules/exporters.md` §6).
class _ExportMenu extends ConsumerWidget {
  const _ExportMenu({required this.song});

  final Song song;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The export result snackbars are listened for by the screen itself, so
    // they fire exactly once in both the wide row and the overflow menu.
    final export = ref.watch(exportProvider);

    if (export.busy) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12),
        child: Text('Exporting…'),
      );
    }
    return PopupMenuButton<ExportFormat>(
      tooltip: 'Export',
      icon: const Icon(Icons.ios_share),
      onSelected: (format) =>
          ref.read(exportProvider.notifier).export(song, format),
      itemBuilder: (context) => <PopupMenuEntry<ExportFormat>>[
        for (final format in ExportFormat.values)
          PopupMenuItem<ExportFormat>(
            value: format,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(format.displayName),
              subtitle: Text(format.description),
            ),
          ),
      ],
    );
  }
}

/// The narrow-screen overflow for the song details actions: the chord
/// reference, practice and the exports, behind one kebab (the wide row has
/// no room for them on a phone; see the build method above).
class _OverflowMenu extends ConsumerWidget {
  const _OverflowMenu({required this.song});

  final Song song;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final export = ref.watch(exportProvider);

    return PopupMenuButton<Object>(
      tooltip: 'More actions',
      icon: const Icon(Icons.more_vert),
      onSelected: (value) {
        if (value == _OverflowTarget.chords) {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => ChordReferenceScreen(song: song),
            ),
          );
        } else if (value == _OverflowTarget.practice) {
          Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => PracticeScreen(song: song)),
          );
        } else if (value is ExportFormat) {
          ref.read(exportProvider.notifier).export(song, value);
        }
      },
      itemBuilder: (context) => <PopupMenuEntry<Object>>[
        const PopupMenuItem<_OverflowTarget>(
          value: _OverflowTarget.chords,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(Icons.grid_on),
            title: Text('Chords and scales'),
          ),
        ),
        const PopupMenuItem<_OverflowTarget>(
          value: _OverflowTarget.practice,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(Icons.fitness_center),
            title: Text('Practice'),
          ),
        ),
        if (export.busy)
          const PopupMenuItem<Object>(
            enabled: false,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(Icons.ios_share),
              title: Text('Exporting…'),
            ),
          )
        else
          for (final format in ExportFormat.values)
            PopupMenuItem<ExportFormat>(
              value: format,
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: const Icon(Icons.ios_share),
                title: Text('Export ${format.displayName}'),
              ),
            ),
      ],
    );
  }
}

enum _OverflowTarget { chords, practice }

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(bottom: 8, left: 4),
            child: Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                letterSpacing: 0.4,
              ),
            ),
          ),
          Card(
            child: Padding(padding: const EdgeInsets.all(16), child: child),
          ),
        ],
      ),
    );
  }
}

class _Details extends StatelessWidget {
  const _Details({required this.song, required this.editor});

  final Song song;
  final SongEditor editor;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _TextRow(
          label: 'Title',
          value: song.title,
          onChanged: (value) => value.trim().isEmpty
              ? null
              : editor.run(SongCommands.setTitle(value)),
        ),
        const SizedBox(height: 12),
        _TextRow(
          label: 'Composer',
          value: song.composer,
          onChanged: (value) => editor.run(SongCommands.setComposer(value)),
        ),
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            Expanded(
              child: _TempoField(song: song, editor: editor),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _KeyField(song: song, editor: editor),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: <Widget>[
            for (final semitones in <int>[-2, -1, 1, 2])
              OutlinedButton(
                onPressed: () => editor.run(SongCommands.transpose(semitones)),
                child: Text('Transpose ${semitones > 0 ? '+' : ''}$semitones'),
              ),
          ],
        ),
      ],
    );
  }
}

class _TextRow extends StatefulWidget {
  const _TextRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  State<_TextRow> createState() => _TextRowState();
}

class _TextRowState extends State<_TextRow> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.value,
  );

  @override
  void didUpdateWidget(_TextRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // An undo changes the value under the field; keep the two in step without
    // fighting the user's cursor while they type.
    if (widget.value != _controller.text) {
      _controller.value = TextEditingValue(
        text: widget.value,
        selection: TextSelection.collapsed(offset: widget.value.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _controller,
    decoration: InputDecoration(labelText: widget.label),
    onChanged: widget.onChanged,
  );
}

class _TempoField extends StatelessWidget {
  const _TempoField({required this.song, required this.editor});

  final Song song;
  final SongEditor editor;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: Slider(
            value: song.tempo.toDouble().clamp(
              minTempo.toDouble(),
              maxTempo.toDouble(),
            ),
            min: minTempo.toDouble(),
            max: maxTempo.toDouble(),
            onChanged: (value) =>
                editor.run(SongCommands.setTempo(value.round())),
          ),
        ),
        SizedBox(
          width: 80,
          child: Text(
            '${song.tempo} bpm',
            textAlign: TextAlign.right,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      ],
    );
  }
}

class _KeyField extends StatelessWidget {
  const _KeyField({required this.song, required this.editor});

  final Song song;
  final SongEditor editor;

  static const List<String> _keys = <String>[
    'C', 'Db', 'D', 'Eb', 'E', 'F', 'Gb', 'G', 'Ab', 'A', 'Bb', 'B', //
    'Cm', 'C#m', 'Dm', 'Ebm', 'Em', 'Fm', 'F#m', 'Gm', 'G#m', 'Am', 'Bbm', 'Bm',
  ];

  @override
  Widget build(BuildContext context) {
    final current = song.key.toString();
    return DropdownButtonFormField<String>(
      initialValue: _keys.contains(current) ? current : null,
      decoration: const InputDecoration(labelText: 'Key'),
      items: <DropdownMenuItem<String>>[
        for (final key in _keys)
          DropdownMenuItem<String>(value: key, child: Text(key)),
      ],
      onChanged: (value) {
        if (value != null) {
          editor.run(SongCommands.setKey(KeySignature.parse(value)));
        }
      },
    );
  }
}

/// Which band plays the tune.
///
/// Every part shares one rhythm here. Per-part rhythms are what the model
/// allows and what an arranger eventually wants — a two-feel head into a
/// walking solo — but choosing one for the whole tune is what makes a
/// generator audible at all, and that has to exist before the finer control
/// is worth building.
class _RhythmPicker extends ConsumerWidget {
  const _RhythmPicker({required this.song, required this.editor});

  final Song song;
  final SongEditor editor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final generators = ref.watch(generatorsProvider);
    final current = song.structure.songParts.first.rhythmId;

    return switch (generators) {
      AsyncData<SongGenerator>(:final value) => Row(
        children: <Widget>[
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: value[current] == null ? null : current,
              decoration: const InputDecoration(
                labelText: 'Rhythm',
                helperText: 'Who plays. Changing it keeps the arrangement.',
              ),
              items: <DropdownMenuItem<String>>[
                for (final generator in value.generators)
                  DropdownMenuItem<String>(
                    value: generator.id,
                    child: Text(generator.displayName),
                  ),
              ],
              onChanged: (id) {
                if (id != null && id != current) {
                  editor.run(SongCommands.setRhythm(id));
                }
              },
            ),
          ),
        ],
      ),
      AsyncError<SongGenerator>(:final error) => Text(
        'The generators did not load: $error',
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      ),
      // Deliberately not a progress indicator. An indeterminate one animates
      // forever, so it schedules a frame forever, so `pumpAndSettle` spins
      // until it times out — which is how this screen made the library
      // integration test take three minutes and then fail. The wait here is a
      // bundled asset being decoded, measured in milliseconds; a static label
      // is both honest about that and testable.
      _ => const InputDecorator(
        decoration: InputDecoration(labelText: 'Rhythm'),
        child: Text('Loading…'),
      ),
    };
  }
}

class _Form extends StatelessWidget {
  const _Form({required this.song});

  final Song song;

  @override
  Widget build(BuildContext context) {
    final sequence = SongChordSequence.of(song);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Wrap(
          spacing: 32,
          runSpacing: 16,
          children: <Widget>[
            LabelledValue(
              label: 'Written',
              value: '${song.writtenBarCount} bars',
            ),
            LabelledValue(label: 'Played', value: '${sequence.barCount} bars'),
            LabelledValue(label: 'Chords', value: '${sequence.chords.length}'),
            LabelledValue(
              label: 'Sections',
              value: song.leadSheet.sections.isEmpty
                  ? '—'
                  : song.leadSheet.sections.map((s) => s.name).join(' '),
            ),
            LabelledValue(label: 'Meter', value: '${song.timeSignature}'),
          ],
        ),
        if (sequence.problems.isNotEmpty) ...<Widget>[
          const SizedBox(height: 16),
          Text(
            'Problems with the form',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          for (final problem in sequence.problems)
            Text(
              '• $problem',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ],
    );
  }
}

class _Arrangement extends ConsumerWidget {
  const _Arrangement({required this.song, required this.editor});

  final Song song;
  final SongEditor editor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final parts = song.structure.songParts;
    if (parts.isEmpty) {
      return const Text(
        'No arrangement: the chart plays as written, repeats and all.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _RhythmPicker(song: song, editor: editor),
        const Divider(height: 24),
        for (var i = 0; i < parts.length; i++)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: CircleAvatar(
              radius: 14,
              child: Text(
                '${i + 1}',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
            title: Text(parts[i].displayName),
            subtitle: Text(
              'bars ${parts[i].startBar + 1}–${parts[i].endBar}  ·  '
              '${parts[i].rhythmId}',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                IconButton(
                  tooltip: 'Move up',
                  onPressed: i == 0
                      ? null
                      : () => editor.run(SongCommands.moveSongPart(i, i - 1)),
                  icon: const Icon(Icons.arrow_upward, size: 18),
                ),
                IconButton(
                  tooltip: 'Move down',
                  onPressed: i == parts.length - 1
                      ? null
                      : () => editor.run(SongCommands.moveSongPart(i, i + 1)),
                  icon: const Icon(Icons.arrow_downward, size: 18),
                ),
                IconButton(
                  tooltip: 'Remove',
                  onPressed: () => editor.run(SongCommands.removeSongPart(i)),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
