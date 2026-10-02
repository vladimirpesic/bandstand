import 'package:bandstand/bridge/api/audio.dart';
import 'package:bandstand/domain/song/ticks.dart';

/// A playhead position resolved for the current instant.
///
/// The Rust audio thread publishes `(tick, host_time)` once per audio block
/// (see `docs/rules/transport-clock.md` §4). The UI reads that pair and
/// extrapolates forward to the frame it is about to paint, so the cursor moves
/// smoothly at display rate rather than in audio-block steps.
class PlayheadReading {
  const PlayheadReading({
    required this.tick,
    required this.state,
    required this.bpm,
    required this.ppq,
    required this.loopGeneration,
  });

  /// Position in ticks, extrapolated to now.
  final double tick;

  /// What the transport is doing.
  final TransportState state;

  /// Tempo in effect at [tick].
  final double bpm;

  /// Ticks per quarter note.
  final int ppq;

  /// Increments on every loop wrap.
  final int loopGeneration;

  /// A playhead parked at the start, stopped.
  static const PlayheadReading stopped = PlayheadReading(
    tick: 0,
    state: TransportState.stopped,
    bpm: 120,
    ppq: kTicksPerQuarter,
    loopGeneration: 0,
  );

  /// Position in beats (quarter notes).
  double get beats => ppq == 0 ? 0 : tick / ppq;

  /// Elapsed musical time as `bar.beat`, one-based, for a given meter.
  ///
  /// Bandstand ships 4/4 first (§4.6) but the model is general from day one, so
  /// the meter is a parameter rather than a constant.
  ({int bar, double beat}) barAndBeat({int beatsPerBar = 4}) {
    if (beatsPerBar <= 0 || ppq == 0) {
      return (bar: 1, beat: 1);
    }
    // Round away float noise before splitting: a tick that is a nanounit shy
    // of the bar line (extrapolation arithmetic makes those) would otherwise
    // read as the last beat of the previous bar.
    final totalBeats = (tick / ppq * 1e6).round() / 1e6;
    final bar = totalBeats ~/ beatsPerBar;
    final beat = totalBeats - bar * beatsPerBar;
    return (bar: bar + 1, beat: beat + 1);
  }
}

/// Turns a published [TransportPosition] into a position for right now.
abstract final class Playhead {
  /// How far the cursor may be extrapolated past the published position.
  ///
  /// One audio block is a few milliseconds; 100 ms is several blocks' grace for
  /// a stalled UI isolate, and short enough that a genuinely wedged audio
  /// thread visibly freezes the cursor instead of running away with it.
  static const int maxLookaheadNs = 100 * 1000 * 1000;

  /// Resolve [position] to the current instant.
  ///
  /// `hostTimeNs` is when the published block reaches the speakers, which is
  /// slightly *after* the moment it was published — it includes the device's
  /// output latency. So the elapsed time is normally negative, and the cursor
  /// correctly shows what is audible now rather than what is queued.
  static PlayheadReading resolve(TransportPosition position) {
    var tick = position.tick;
    if (position.state == TransportState.playing) {
      final elapsedNs = _clamp(
        position.readAtNs.toDouble() - position.hostTimeNs.toDouble(),
        -maxLookaheadNs.toDouble(),
        maxLookaheadNs.toDouble(),
      );
      tick += elapsedNs * position.ticksPerNanosecond;
      if (tick < 0) {
        tick = 0;
      }
    }
    return PlayheadReading(
      tick: tick,
      state: position.state,
      bpm: position.bpm,
      ppq: position.ppq,
      loopGeneration: position.loopGeneration,
    );
  }

  static double _clamp(double value, double low, double high) =>
      value < low ? low : (value > high ? high : value);
}
