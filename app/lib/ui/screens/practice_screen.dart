import 'dart:math' as math;

import 'package:bandstand/domain/song/practice_session.dart';
import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/domain/song/song_chord_sequence.dart';
import 'package:bandstand/state/practice_state.dart';
import 'package:bandstand/ui/widgets/labelled_value.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Tempo ramp, key cycling and loop practice (§9, M7).
///
/// The screen owns nothing musical: it builds a [PracticeSession], hands it to
/// the controller, and shows what the session says each chorus will be. Every
/// number below comes from `PracticeSession.planFor`, so what is previewed is
/// exactly what will play.
class PracticeScreen extends ConsumerStatefulWidget {
  /// Create the screen for a song.
  const PracticeScreen({required this.song, super.key});

  /// The tune being practised.
  final Song song;

  @override
  ConsumerState<PracticeScreen> createState() => _PracticeScreenState();
}

class _PracticeScreenState extends ConsumerState<PracticeScreen> {
  late int _startingTempo = widget.song.tempo;
  int _tempoStep = 0;
  int _tempoEvery = 4;
  int _ceiling = 240;
  int _keyStep = 0;
  int _keyEvery = 1;
  KeyCycleOrder _order = KeyCycleOrder.fourths;
  bool _looping = false;
  int _loopFirst = 1;
  int _loopLast = 8;

  int get _formBars => SongChordSequence.of(widget.song).barCount;

  @override
  void initState() {
    super.initState();
    // The defaults assume an eight-bar form; a shorter tune starts with the
    // loop already inside it. The song is final, so this cannot change later.
    _loopLast = math.min(_loopLast, _formBars);
    _loopFirst = math.min(_loopFirst, _loopLast);
  }

  PracticeSession _buildSession() => PracticeSession(
    startingTempo: _startingTempo,
    tempoStep: _tempoStep,
    tempoStepEveryChoruses: _tempoEvery,
    tempoCeiling: _ceiling,
    keyStep: _keyStep,
    keyStepEveryChoruses: _keyEvery,
    keyOrder: _order,
    loop: _looping
        ? LoopRange(firstBar: _loopFirst - 1, lastBar: _loopLast - 1)
        : null,
  );

  @override
  Widget build(BuildContext context) {
    final practice = ref.watch(practiceProvider);
    final session = _buildSession();

    return Scaffold(
      appBar: AppBar(
        title: Text('Practice — ${widget.song.title}'),
        actions: <Widget>[
          if (practice.running)
            FilledButton.tonalIcon(
              onPressed: () =>
                  ref.read(practiceProvider.notifier).stop(widget.song),
              icon: const Icon(Icons.stop),
              label: const Text('Stop'),
            )
          else
            FilledButton.icon(
              onPressed: () => ref
                  .read(practiceProvider.notifier)
                  .start(session, widget.song),
              icon: const Icon(Icons.play_arrow),
              label: const Text('Start'),
            ),
          const SizedBox(width: 12),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          if (practice.errorMessage != null)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(practice.errorMessage!),
              ),
            ),
          if (practice.running) _Running(practice: practice, song: widget.song),
          _Section(
            title: 'Tempo ramp',
            child: _TempoRamp(
              startingTempo: _startingTempo,
              step: _tempoStep,
              every: _tempoEvery,
              ceiling: _ceiling,
              onChanged: (start, step, every, ceiling) => setState(() {
                _startingTempo = start;
                _tempoStep = step;
                _tempoEvery = every;
                _ceiling = ceiling;
              }),
            ),
          ),
          _Section(
            title: 'Key cycling',
            child: _KeyCycling(
              step: _keyStep,
              every: _keyEvery,
              order: _order,
              onChanged: (step, every, order) => setState(() {
                _keyStep = step;
                _keyEvery = every;
                _order = order;
              }),
            ),
          ),
          _Section(
            title: 'Loop',
            child: _Loop(
              enabled: _looping,
              firstBar: _loopFirst,
              lastBar: _loopLast,
              formBars: _formBars,
              onChanged: (enabled, first, last) => setState(() {
                _looping = enabled;
                _loopFirst = first;
                _loopLast = last;
              }),
            ),
          ),
          _Section(
            title: 'What will happen',
            child: _Preview(session: session, formBars: _formBars),
          ),
        ],
      ),
    );
  }
}

class _Running extends ConsumerWidget {
  const _Running({required this.practice, required this.song});

  final PracticeState practice;
  final Song song;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plan = practice.plan;
    return Card(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Wrap(
                spacing: 28,
                runSpacing: 12,
                children: <Widget>[
                  LabelledValue(
                    label: 'Chorus',
                    value: '${practice.chorus + 1}',
                  ),
                  LabelledValue(
                    label: 'Tempo',
                    value: '${plan?.tempo ?? song.tempo} bpm',
                  ),
                  LabelledValue(
                    label: 'Key',
                    // The key spells its own new tonic: §3.2 of the practice
                    // rules requires the spelling to follow the destination,
                    // and F# major and Gb major are not interchangeable.
                    value: plan == null || plan.transposition == 0
                        ? '${song.key} (as written)'
                        : '${song.key.transposed(plan.transposition)}',
                  ),
                  if (plan?.loop != null)
                    LabelledValue(label: 'Loop', value: '${plan!.loop}'),
                ],
              ),
            ),
            if (practice.busy)
              const Padding(
                padding: EdgeInsets.only(right: 12),
                child: Text('Regenerating…'),
              ),
            FilledButton.tonalIcon(
              onPressed: () =>
                  ref.read(practiceProvider.notifier).advance(song),
              icon: const Icon(Icons.skip_next),
              label: const Text('Next chorus'),
            ),
          ],
        ),
      ),
    );
  }
}

class _TempoRamp extends StatelessWidget {
  const _TempoRamp({
    required this.startingTempo,
    required this.step,
    required this.every,
    required this.ceiling,
    required this.onChanged,
  });

  final int startingTempo;
  final int step;
  final int every;
  final int ceiling;
  final void Function(int start, int step, int every, int ceiling) onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _NumberRow(
          label: 'Start at',
          suffix: 'bpm',
          value: startingTempo,
          minimum: minTempo,
          maximum: maxTempo,
          onChanged: (value) => onChanged(value, step, every, ceiling),
        ),
        _NumberRow(
          label: 'Change by',
          suffix: 'bpm',
          value: step,
          minimum: -20,
          maximum: 20,
          helper: 'Negative descends, which is the harder exercise.',
          onChanged: (value) => onChanged(startingTempo, value, every, ceiling),
        ),
        _NumberRow(
          label: 'Every',
          suffix: 'choruses',
          value: every,
          minimum: 1,
          maximum: 16,
          helper:
              'Changing every chorus is a fairground ride; four is a '
              'rehearsal.',
          onChanged: (value) => onChanged(startingTempo, step, value, ceiling),
        ),
        _NumberRow(
          label: 'Up to',
          suffix: 'bpm',
          value: ceiling,
          minimum: minTempo,
          maximum: maxTempo,
          onChanged: (value) => onChanged(startingTempo, step, every, value),
        ),
      ],
    );
  }
}

class _KeyCycling extends StatelessWidget {
  const _KeyCycling({
    required this.step,
    required this.every,
    required this.order,
    required this.onChanged,
  });

  final int step;
  final int every;
  final KeyCycleOrder order;
  final void Function(int step, int every, KeyCycleOrder order) onChanged;

  static const Map<KeyCycleOrder, String> _names = <KeyCycleOrder, String>{
    KeyCycleOrder.fourths: 'Round the fourths',
    KeyCycleOrder.chromaticUp: 'Chromatic, up',
    KeyCycleOrder.chromaticDown: 'Chromatic, down',
  };

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Change key as it repeats'),
          value: step != 0,
          onChanged: (on) => onChanged(on ? 1 : 0, every, order),
        ),
        if (step != 0) ...<Widget>[
          DropdownButtonFormField<KeyCycleOrder>(
            initialValue: order,
            decoration: const InputDecoration(labelText: 'Order'),
            items: <DropdownMenuItem<KeyCycleOrder>>[
              for (final entry in _names.entries)
                DropdownMenuItem<KeyCycleOrder>(
                  value: entry.key,
                  child: Text(entry.value),
                ),
            ],
            onChanged: (value) {
              if (value != null) {
                onChanged(step, every, value);
              }
            },
          ),
          _NumberRow(
            label: 'Every',
            suffix: 'choruses',
            value: every,
            minimum: 1,
            maximum: 8,
            onChanged: (value) => onChanged(step, value, order),
          ),
        ],
      ],
    );
  }
}

class _Loop extends StatelessWidget {
  const _Loop({
    required this.enabled,
    required this.firstBar,
    required this.lastBar,
    required this.formBars,
    required this.onChanged,
  });

  final bool enabled;
  final int firstBar;
  final int lastBar;
  final int formBars;
  final void Function(bool enabled, int first, int last) onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Loop a section'),
          subtitle: Text('The form is $formBars bars.'),
          value: enabled,
          onChanged: (on) => onChanged(on, firstBar, lastBar),
        ),
        if (enabled)
          Row(
            children: <Widget>[
              Expanded(
                child: _NumberRow(
                  label: 'From bar',
                  value: firstBar,
                  minimum: 1,
                  maximum: formBars,
                  onChanged: (value) => onChanged(
                    enabled,
                    value,
                    value > lastBar ? value : lastBar,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _NumberRow(
                  label: 'To bar',
                  value: lastBar,
                  minimum: 1,
                  maximum: formBars,
                  onChanged: (value) => onChanged(
                    enabled,
                    value < firstBar ? value : firstBar,
                    value,
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }
}

/// The first several choruses, exactly as the session will play them.
class _Preview extends StatelessWidget {
  const _Preview({required this.session, required this.formBars});

  final PracticeSession session;
  final int formBars;

  @override
  Widget build(BuildContext context) {
    if (session.isStatic && session.loop == null) {
      return const Text(
        'Nothing changes: the tune repeats as written. Set a tempo step or a '
        'key cycle above.',
      );
    }
    final plans = session.plans(8, formBars: formBars);
    final cycle = session.chorusesPerKeyCycle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final plan in plans)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('$plan'),
          ),
        if (cycle != null) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            'Back to the starting key after $cycle choruses.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}

class _NumberRow extends StatelessWidget {
  const _NumberRow({
    required this.label,
    required this.value,
    required this.minimum,
    required this.maximum,
    required this.onChanged,
    this.suffix,
    this.helper,
  });

  final String label;
  final int value;
  final int minimum;
  final int maximum;
  final String? suffix;
  final String? helper;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  suffix == null ? label : '$label  $value $suffix',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                if (helper != null)
                  Text(helper!, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Less',
            onPressed: value > minimum ? () => onChanged(value - 1) : null,
            icon: const Icon(Icons.remove),
          ),
          SizedBox(
            width: 48,
            child: Text('$value', textAlign: TextAlign.center),
          ),
          IconButton(
            tooltip: 'More',
            onPressed: value < maximum ? () => onChanged(value + 1) : null,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}

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
