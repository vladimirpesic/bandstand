import 'dart:math' as math;

import 'package:bandstand/audio/audio_engine.dart';
import 'package:bandstand/bridge/api/audio.dart';
import 'package:bandstand/ui/widgets/labelled_value.dart';
import 'package:bandstand/ui/widgets/playback_panel.dart';
import 'package:bandstand/ui/widgets/playhead_readout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Audio device, transport and diagnostics.
///
/// This is Settings → Audio (§8.2). Until the library screen exists it is also
/// the app's home screen, because it is the only thing there is to look at.
class AudioEngineScreen extends ConsumerWidget {
  const AudioEngineScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(audioEngineProvider);
    final controller = ref.read(audioEngineProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Bandstand'),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Text(
                'Audio engine',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 720;
          final content = <Widget>[
            if (state.errorMessage != null)
              _ErrorBanner(
                message: state.errorMessage!,
                onDismiss: controller.dismissError,
              ),
            _Section(
              title: 'Output device',
              child: _DeviceControls(state: state, controller: controller),
            ),
            _Section(
              title: 'Stream',
              child: _StreamStatus(status: state.status),
            ),
            const _Section(title: 'Playback', child: PlaybackPanel()),
            _Section(title: 'Transport', child: const _TransportControls()),
            _Section(
              title: 'Test tone',
              child: _ToneControls(state: state, controller: controller),
            ),
          ];

          return ListView(
            padding: EdgeInsets.symmetric(
              horizontal: wide ? 32 : 16,
              vertical: 16,
            ),
            children: <Widget>[
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: content,
                ),
              ),
            ],
          );
        },
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

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.error_outline, color: scheme.onErrorContainer),
          const SizedBox(width: 12),
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

class _DeviceControls extends ConsumerWidget {
  const _DeviceControls({required this.state, required this.controller});

  final AudioEngineState state;
  final AudioEngineController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = ref.watch(audioDevicesProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        devices.when(
          // Not a progress indicator: an indeterminate one animates forever, so
          // it schedules a frame forever, so `pumpAndSettle` spins until it
          // times out. The same trap as the M0 ticker and the M6 rhythm picker.
          loading: () => const InputDecorator(
            decoration: InputDecoration(labelText: 'Device'),
            child: Text('Looking for devices…'),
          ),
          error: (error, _) => Text('Could not list devices: $error'),
          data: (list) => DropdownButtonFormField<String?>(
            // Null when the remembered device is no longer in the list — the
            // interface was unplugged, or the rescan renamed it. A
            // `DropdownButtonFormField` asserts when its value matches none of
            // its items, so passing the stale name crashed the panel outright.
            // `song_details_screen.dart` guards its dropdowns the same way.
            initialValue: list.any((device) => device.name == state.deviceName)
                ? state.deviceName
                : null,
            // Device names on Android run long; without this the selected item
            // sizes to its text and overflows the field rather than eliding.
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Device'),
            items: <DropdownMenuItem<String?>>[
              const DropdownMenuItem<String?>(child: Text('System default')),
              for (final device in list)
                DropdownMenuItem<String?>(
                  value: device.name,
                  child: Text(
                    device.isDefault
                        ? '${device.name}  (default)'
                        : device.name,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: state.busy ? null : controller.selectDevice,
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            Expanded(
              child: DropdownButtonFormField<int>(
                initialValue: state.sampleRate,
                decoration: const InputDecoration(labelText: 'Sample rate'),
                items: <DropdownMenuItem<int>>[
                  for (final rate in kSampleRateChoices)
                    DropdownMenuItem<int>(value: rate, child: Text('$rate Hz')),
                ],
                onChanged: state.busy
                    ? null
                    : (rate) {
                        if (rate != null) {
                          controller.selectSampleRate(rate);
                        }
                      },
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: DropdownButtonFormField<int>(
                initialValue: state.bufferFrames,
                decoration: const InputDecoration(labelText: 'Buffer'),
                items: <DropdownMenuItem<int>>[
                  for (final frames in kBufferFrameChoices)
                    DropdownMenuItem<int>(
                      value: frames,
                      child: Text('$frames frames'),
                    ),
                ],
                onChanged: state.busy
                    ? null
                    : (frames) {
                        if (frames != null) {
                          controller.selectBufferFrames(frames);
                        }
                      },
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        // A Wrap, not a Row: three buttons fit side by side on a desktop and
        // overflow a phone by about 74 pixels, which is how the emulator found
        // this. Wrapping costs nothing on a wide window and is correct on a
        // narrow one.
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: <Widget>[
            FilledButton.icon(
              onPressed: state.busy || state.isRunning
                  ? null
                  : controller.start,
              icon: const Icon(Icons.power_settings_new),
              label: const Text('Start engine'),
            ),
            OutlinedButton.icon(
              onPressed: state.busy || !state.isRunning
                  ? null
                  : controller.stop,
              icon: const Icon(Icons.stop_circle_outlined),
              label: const Text('Stop engine'),
            ),
            OutlinedButton.icon(
              onPressed: state.busy
                  ? null
                  : () => ref.invalidate(audioDevicesProvider),
              icon: const Icon(Icons.refresh),
              label: const Text('Rescan'),
            ),
          ],
        ),
      ],
    );
  }
}

class _StreamStatus extends StatelessWidget {
  const _StreamStatus({required this.status});

  final AudioStreamStatus? status;

  @override
  Widget build(BuildContext context) {
    final s = status;
    if (s == null) {
      return Text(
        'The engine is stopped.',
        style: Theme.of(context).textTheme.bodyLarge,
      );
    }
    final latencyMs = s.bufferFrames == null
        ? null
        : s.bufferFrames! * 1000 / s.sampleRate;
    return Wrap(
      spacing: 32,
      runSpacing: 16,
      children: <Widget>[
        LabelledValue(label: 'Device', value: s.deviceName),
        LabelledValue(label: 'Rate', value: '${s.sampleRate} Hz'),
        LabelledValue(label: 'Channels', value: '${s.channels}'),
        LabelledValue(
          label: 'Buffer',
          value: s.bufferFrames == null
              ? 'backend default'
              : '${s.bufferFrames} frames',
        ),
        if (latencyMs != null)
          LabelledValue(
            label: 'Buffer latency',
            value: '${latencyMs.toStringAsFixed(1)} ms',
          ),
        LabelledValue(label: 'Format', value: s.sampleFormat),
        LabelledValue(label: 'Blocks', value: '${s.blockCount}'),
        LabelledValue(
          label: 'Dropouts',
          value: '${s.errorCount}',
          emphasis: s.errorCount != BigInt.zero,
        ),
      ],
    );
  }
}

class _TransportControls extends StatelessWidget {
  const _TransportControls();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const PlayheadReadout(),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: <Widget>[
            FilledButton.icon(
              onPressed: transportPlay,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Play'),
            ),
            OutlinedButton.icon(
              onPressed: transportPause,
              icon: const Icon(Icons.pause),
              label: const Text('Pause'),
            ),
            OutlinedButton.icon(
              onPressed: transportStop,
              icon: const Icon(Icons.stop),
              label: const Text('Stop'),
            ),
            OutlinedButton.icon(
              onPressed: () => transportSeek(tick: 0),
              icon: const Icon(Icons.skip_previous),
              label: const Text('To start'),
            ),
          ],
        ),
      ],
    );
  }
}

class _ToneControls extends StatelessWidget {
  const _ToneControls({required this.state, required this.controller});

  final AudioEngineState state;
  final AudioEngineController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: state.toneEnabled,
          onChanged: controller.setToneEnabled,
          title: const Text('Reference tone'),
          subtitle: const Text(
            'A sine wave through the whole audio path, for checking the device '
            'and the routing.',
          ),
        ),
        const SizedBox(height: 8),
        _Slider(
          label: 'Frequency',
          value: state.toneFrequencyHz,
          min: 55,
          max: 2000,
          display: '${state.toneFrequencyHz.round()} Hz',
          onChanged: controller.setToneFrequency,
        ),
        _Slider(
          label: 'Level',
          value: state.toneAmplitude,
          min: 0,
          max: 1,
          display: state.toneAmplitude <= 0
              ? 'silent'
              : '${(20 * _log10(state.toneAmplitude)).toStringAsFixed(1)} dBFS',
          onChanged: controller.setToneAmplitude,
        ),
      ],
    );
  }

  /// Linear gain as decibels relative to full scale.
  static double _log10(double value) =>
      value <= 0 ? double.negativeInfinity : math.log(value) / math.ln10;
}

class _Slider extends StatelessWidget {
  const _Slider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.display,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String display;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: <Widget>[
        SizedBox(
          width: 88,
          child: Text(label, style: theme.textTheme.bodyMedium),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 88,
          child: Text(
            display,
            textAlign: TextAlign.right,
            style: theme.textTheme.bodyMedium,
          ),
        ),
      ],
    );
  }
}
