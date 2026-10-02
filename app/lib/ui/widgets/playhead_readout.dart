import 'dart:async';

import 'package:bandstand/audio/playhead.dart';
import 'package:bandstand/bridge/api/audio.dart';
import 'package:bandstand/ui/theme/bandstand_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Live playhead display, driven by a [Ticker].
///
/// This is the §3 readback path end to end: the Rust audio thread publishes
/// `(tick, host_time)` into a shared cell once per audio block, and this widget
/// reads that cell directly over FFI once per display frame and extrapolates.
/// No callback crosses the boundary, and nothing is polled per frame except one
/// synchronous atomic read.
class PlayheadReadout extends StatefulWidget {
  const PlayheadReadout({this.beatsPerBar = 4, super.key});

  /// How often the playhead is checked while the transport is not playing.
  ///
  /// A stopped transport does not need display-rate polling; it needs to notice
  /// promptly that someone pressed play. Five times a second is imperceptible
  /// as a delay and costs nothing on a battery.
  static const Duration idlePollInterval = Duration(milliseconds: 200);

  /// Beats per bar used to display bar and beat. 4/4 ships first (§4.6).
  final int beatsPerBar;

  /// `seconds` as `m:ss.hh`, rounding to the nearest hundredth first so the
  /// seconds and hundredths never disagree — 59.997 s is `1:00.00`, never
  /// `0:60.00`.
  static String formatDuration(double seconds) {
    final hundredths = ((seconds.isFinite && seconds > 0 ? seconds : 0.0) * 100)
        .round();
    final minutes = hundredths ~/ 6000;
    final rest = (hundredths % 6000) / 100;
    return '$minutes:${rest.toStringAsFixed(2).padLeft(5, '0')}';
  }

  @override
  State<PlayheadReadout> createState() => _PlayheadReadoutState();
}

class _PlayheadReadoutState extends State<PlayheadReadout>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Timer? _idlePoll;
  PlayheadReading _reading = PlayheadReading.stopped;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onFrame);
    // First read happens during initState, so the widget's very first frame
    // already shows the truth rather than a placeholder.
    _reading = Playhead.resolve(transportPosition());
    _syncDriver(_reading);
  }

  void _onFrame(Duration _) => _read(notify: true);

  void _read({required bool notify}) {
    final reading = Playhead.resolve(transportPosition());
    _syncDriver(reading);
    // Repaint only when something the readout shows has actually changed.
    final changed =
        reading.tick != _reading.tick ||
        reading.state != _reading.state ||
        reading.bpm != _reading.bpm ||
        reading.loopGeneration != _reading.loopGeneration;
    if (!changed) {
      return;
    }
    if (notify && mounted) {
      setState(() => _reading = reading);
    } else {
      _reading = reading;
    }
  }

  /// A running [Ticker] schedules a frame forever, which keeps the whole app
  /// out of its idle state — bad for battery on a tablet, and it makes
  /// `pumpAndSettle` in a test hang. So the ticker runs only while the
  /// transport is playing; the rest of the time a slow timer watches for the
  /// transition.
  void _syncDriver(PlayheadReading reading) {
    final playing = reading.state == TransportState.playing;
    if (playing) {
      _idlePoll?.cancel();
      _idlePoll = null;
      if (!_ticker.isActive) {
        _ticker.start();
      }
    } else {
      if (_ticker.isActive) {
        _ticker.stop();
      }
      _idlePoll ??= Timer.periodic(
        PlayheadReadout.idlePollInterval,
        (_) => _read(notify: true),
      );
    }
  }

  @override
  void dispose() {
    _idlePoll?.cancel();
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final position = _reading.barAndBeat(beatsPerBar: widget.beatsPerBar);
    final seconds = _reading.bpm <= 0
        ? 0.0
        : _reading.beats * 60.0 / _reading.bpm;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'PLAYHEAD',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  letterSpacing: 0.8,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${position.bar}.${position.beat.toStringAsFixed(2)}',
                style: theme.textTheme.displaySmall
                    ?.merge(BandstandTheme.numeric)
                    .copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            _StateChip(state: _reading.state),
            const SizedBox(height: 6),
            Text(
              '${PlayheadReadout.formatDuration(seconds)}  ·  ${_reading.bpm.toStringAsFixed(1)} bpm',
              style: theme.textTheme.bodyMedium?.merge(BandstandTheme.numeric),
            ),
            Text(
              'tick ${_reading.tick.toStringAsFixed(0)}  ·  loop ${_reading.loopGeneration}',
              style: theme.textTheme.bodySmall
                  ?.merge(BandstandTheme.numeric)
                  .copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ],
    );
  }
}

class _StateChip extends StatelessWidget {
  const _StateChip({required this.state});

  final TransportState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (String label, Color colour) = switch (state) {
      TransportState.playing => ('PLAYING', scheme.primary),
      TransportState.paused => ('PAUSED', scheme.tertiary),
      TransportState.stopped => ('STOPPED', scheme.onSurfaceVariant),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colour),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium
            ?.copyWith(color: colour, letterSpacing: 1),
      ),
    );
  }
}
