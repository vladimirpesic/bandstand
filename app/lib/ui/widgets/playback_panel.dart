import 'dart:io';

import 'package:bandstand/audio/soundbank_library.dart';
import 'package:bandstand/bridge/api/audio.dart';
import 'package:bandstand/state/playback_state.dart';
import 'package:bandstand/ui/widgets/bank_download_controls.dart';
import 'package:bandstand/ui/widgets/labelled_value.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Loading a soundbank and a MIDI file, and playing them.
///
/// This is what makes M4 audible: a bank, a sequence, and the transport that
/// was built at M0 driving both.
class PlaybackPanel extends ConsumerWidget {
  const PlaybackPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(playbackProvider);
    final controller = ref.read(playbackProvider.notifier);
    final banks = ref.watch(soundbanksProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (state.errorMessage != null)
          _Banner(
            message: state.errorMessage!,
            onDismiss: controller.dismissError,
          ),
        banks.when(
          loading: () => const LinearProgressIndicator(),
          error: (error, _) => Text('Could not look for soundbanks: $error'),
          data: (found) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _BankPicker(
                found: found,
                selected: state.bank,
                busy: state.busy,
                onPick: controller.loadBank,
                onClear: controller.unloadBank,
              ),
              // An empty picker is the download's other home: this is where
              // somebody who wants sound *right now* is standing.
              if (found.isEmpty) ...<Widget>[
                const SizedBox(height: 12),
                const BankDownloadControls(),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SequencePicker(state: state, controller: controller),
        if (state.bank != null || state.eventCount > 0) ...<Widget>[
          const SizedBox(height: 16),
          Wrap(
            spacing: 32,
            runSpacing: 16,
            children: <Widget>[
              if (state.bank case final SoundBankInfo bank) ...<Widget>[
                LabelledValue(label: 'Soundbank', value: bank.name),
                LabelledValue(label: 'Presets', value: '${bank.presetCount}'),
                LabelledValue(label: 'Samples', value: '${bank.sampleCount}'),
              ],
              if (state.eventCount > 0) ...<Widget>[
                LabelledValue(label: 'Events', value: '${state.eventCount}'),
                LabelledValue(
                  label: 'Length',
                  value: formatDuration(state.durationSeconds),
                ),
                LabelledValue(
                  label: 'Tempo',
                  value: '${state.tempoBpm.round()} bpm',
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }

  /// `seconds` as `m:ss`, rounding to the nearest second first — 119.6 s is
  /// `2:00`, never `1:60`.
  static String formatDuration(double seconds) {
    if (seconds <= 0) {
      return '—';
    }
    final total = seconds.round();
    final minutes = total ~/ 60;
    final rest = total % 60;
    return '$minutes:${rest.toString().padLeft(2, '0')}';
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
          IconButton(
            onPressed: onDismiss,
            icon: const Icon(Icons.close),
            color: scheme.onErrorContainer,
            tooltip: 'Dismiss',
          ),
        ],
      ),
    );
  }
}

class _BankPicker extends StatelessWidget {
  const _BankPicker({
    required this.found,
    required this.selected,
    required this.busy,
    required this.onPick,
    required this.onClear,
  });

  final List<SoundbankFile> found;
  final SoundBankInfo? selected;
  final bool busy;
  final ValueChanged<String> onPick;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    if (found.isEmpty) {
      return const Text(
        'No soundbanks found. Put a .sf2 file in the soundbanks folder of your '
        'Bandstand library.',
      );
    }
    return Row(
      children: <Widget>[
        Expanded(
          child: DropdownButtonFormField<String>(
            // Only when the bank is still on the list: a soundbank deleted or
            // moved since it was chosen would otherwise trip the dropdown's
            // own assertion and take the panel down with it.
            initialValue: found.any((bank) => bank.path == selected?.path)
                ? selected?.path
                : null,
            decoration: const InputDecoration(labelText: 'Soundbank'),
            items: <DropdownMenuItem<String>>[
              for (final bank in found)
                DropdownMenuItem<String>(
                  value: bank.path,
                  child: Text(
                    bank.isSystem
                        ? '${bank.name}  ·  ${bank.sizeLabel}  (system)'
                        : '${bank.name}  ·  ${bank.sizeLabel}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: busy
                ? null
                : (path) {
                    if (path != null) {
                      onPick(path);
                    }
                  },
          ),
        ),
        if (selected != null) ...<Widget>[
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Unload',
            onPressed: busy ? null : onClear,
            icon: const Icon(Icons.eject_outlined),
          ),
        ],
      ],
    );
  }
}

class _SequencePicker extends StatefulWidget {
  const _SequencePicker({required this.state, required this.controller});

  final PlaybackState state;
  final PlaybackController controller;

  @override
  State<_SequencePicker> createState() => _SequencePickerState();
}

class _SequencePickerState extends State<_SequencePicker> {
  final TextEditingController _path = TextEditingController();

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _path,
                decoration: InputDecoration(
                  labelText: 'MIDI file',
                  hintText: widget.state.sequenceName ?? '/path/to/tune.mid',
                ),
                onSubmitted: (_) => _load(),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.tonal(
              onPressed: widget.state.busy ? null : _load,
              child: const Text('Load'),
            ),
            if (widget.state.eventCount > 0) ...<Widget>[
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Clear the sequence',
                onPressed: widget.controller.clear,
                icon: const Icon(Icons.clear),
              ),
            ],
          ],
        ),
        if (widget.state.sequenceName != null) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            'Loaded: ${widget.state.sequenceName}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }

  Future<void> _load() async {
    final path = _path.text.trim();
    if (path.isEmpty) {
      return;
    }
    await widget.controller.loadMidiFile(File(path));
  }
}
