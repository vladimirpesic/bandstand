import 'package:bandstand/audio/playhead.dart';
import 'package:bandstand/bridge/api/audio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 120 bpm at 960 ppq: 1920 ticks per second, so 1.92e-6 ticks per nanosecond.
const double ticksPerNs = 1.92e-6;

TransportPosition position({
  required double tick,
  required int hostTimeNs,
  required int readAtNs,
  TransportState state = TransportState.playing,
  int loopGeneration = 0,
}) {
  return TransportPosition(
    tick: tick,
    hostTimeNs: BigInt.from(hostTimeNs),
    readAtNs: BigInt.from(readAtNs),
    state: state,
    loopGeneration: loopGeneration,
    ticksPerNanosecond: ticksPerNs,
    bpm: 120,
    ppq: 960,
  );
}

void main() {
  group('Playhead.resolve', () {
    test('extrapolates forward while playing', () {
      // 50 ms after the published block was heard: a handful of audio blocks,
      // and well inside the lookahead limit.
      final reading = Playhead.resolve(
        position(tick: 0, hostTimeNs: 0, readAtNs: 50000000),
      );
      expect(reading.tick, closeTo(0.05 * 1e9 * ticksPerNs, 1e-6));
      expect(reading.state, TransportState.playing);
    });

    test(
      'reads slightly behind the published tick when latency is included',
      () {
        // The block has not been heard yet: host time is 10 ms in the future.
        final reading = Playhead.resolve(
          position(tick: 960, hostTimeNs: 10000000, readAtNs: 0),
        );
        expect(reading.tick, lessThan(960));
        expect(reading.tick, closeTo(960 - 0.01 * 1e9 * ticksPerNs, 1e-6));
      },
    );

    test('never extrapolates below zero', () {
      final reading = Playhead.resolve(
        position(tick: 1, hostTimeNs: 50000000, readAtNs: 0),
      );
      expect(reading.tick, 0);
    });

    test('clamps a stalled UI to the lookahead limit', () {
      // Ten seconds since the last publication: the audio thread is wedged, or
      // the UI isolate was. Either way the cursor must not run away.
      final reading = Playhead.resolve(
        position(tick: 0, hostTimeNs: 0, readAtNs: 10000000000),
      );
      expect(reading.tick, closeTo(Playhead.maxLookaheadNs * ticksPerNs, 1e-6));
    });

    test('does not extrapolate when paused or stopped', () {
      for (final state in <TransportState>[
        TransportState.paused,
        TransportState.stopped,
      ]) {
        final reading = Playhead.resolve(
          position(tick: 480, hostTimeNs: 0, readAtNs: 500000000, state: state),
        );
        expect(reading.tick, 480);
      }
    });
  });

  group('PlayheadReading', () {
    test('converts ticks to beats', () {
      const reading = PlayheadReading(
        tick: 1920,
        state: TransportState.stopped,
        bpm: 120,
        ppq: 960,
        loopGeneration: 0,
      );
      expect(reading.beats, 2);
    });

    test('reports one-based bar and beat in 4/4', () {
      const reading = PlayheadReading(
        tick: 960 * 5,
        state: TransportState.stopped,
        bpm: 120,
        ppq: 960,
        loopGeneration: 0,
      );
      final position = reading.barAndBeat();
      expect(position.bar, 2);
      expect(position.beat, closeTo(2, 1e-9));
    });

    test('reports one-based bar and beat in 3/4', () {
      const reading = PlayheadReading(
        tick: 960 * 4,
        state: TransportState.stopped,
        bpm: 120,
        ppq: 960,
        loopGeneration: 0,
      );
      final position = reading.barAndBeat(beatsPerBar: 3);
      expect(position.bar, 2);
      expect(position.beat, closeTo(2, 1e-9));
    });

    test('a tick a whisker short of the bar line reads as the downbeat', () {
      const reading = PlayheadReading(
        tick: 960 * 3.9999999,
        state: TransportState.stopped,
        bpm: 120,
        ppq: 960,
        loopGeneration: 0,
      );
      final position = reading.barAndBeat();
      expect(position.bar, 2);
      expect(position.beat, closeTo(1, 1e-9));
    });

    test('survives a nonsensical meter', () {
      const reading = PlayheadReading(
        tick: 100,
        state: TransportState.stopped,
        bpm: 120,
        ppq: 960,
        loopGeneration: 0,
      );
      final position = reading.barAndBeat(beatsPerBar: 0);
      expect(position.bar, 1);
      expect(position.beat, 1);
    });
  });
}
