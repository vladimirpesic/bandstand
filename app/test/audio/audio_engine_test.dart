import 'dart:async';

import 'package:bandstand/audio/audio_engine.dart';
import 'package:bandstand/bridge/api/audio.dart' as bridge;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The controller's own logic — queueing a press that arrives mid-flight,
/// tone-push failure handling, polling hygiene — with the FFI behind a fake,
/// so none of it needs a running engine.
class _FakeBridge extends AudioEngineBridge {
  _FakeBridge();

  final List<bridge.AudioStreamRequest> startCalls =
      <bridge.AudioStreamRequest>[];
  var stopCalls = 0;
  var statusCalls = 0;

  final List<Completer<bridge.AudioStreamStatus>> _pendingStarts =
      <Completer<bridge.AudioStreamStatus>>[];
  Completer<bridge.AudioStreamStatus?>? hangingStatus;
  Object? toneError;
  Object? statusError;

  static bridge.AudioStreamStatus streamStatus() => bridge.AudioStreamStatus(
    deviceName: 'fake',
    sampleRate: 48000,
    channels: 2,
    sampleFormat: 'f32',
    errorCount: BigInt.zero,
    blockCount: BigInt.zero,
    frameCount: BigInt.zero,
  );

  int get pendingStartCount => _pendingStarts.length;

  void completeNextStart() =>
      _pendingStarts.removeAt(0).complete(streamStatus());

  @override
  Future<bridge.AudioStreamStatus> start({
    required bridge.AudioStreamRequest request,
  }) {
    startCalls.add(request);
    final completer = Completer<bridge.AudioStreamStatus>();
    _pendingStarts.add(completer);
    return completer.future;
  }

  /// Set to make the next and every later `stop` throw.
  Object? stopError;

  @override
  Future<void> stop() async {
    stopCalls++;
    final error = stopError;
    if (error != null) {
      throw error;
    }
  }

  @override
  Future<bridge.AudioStreamStatus?> status() async {
    statusCalls++;
    final hanging = hangingStatus;
    if (hanging != null) {
      hangingStatus = null;
      return hanging.future;
    }
    final error = statusError;
    if (error != null) {
      throw error;
    }
    return streamStatus();
  }

  @override
  Future<void> setTestTone({
    required bool enabled,
    required double frequencyHz,
    required double amplitude,
  }) async {
    final error = toneError;
    if (error != null) {
      throw error;
    }
  }
}

void main() {
  late _FakeBridge fake;
  late ProviderContainer container;
  late AudioEngineController controller;

  setUp(() {
    fake = _FakeBridge();
    container = ProviderContainer(
      overrides: [
        audioEngineProvider.overrideWith(
          () => AudioEngineController(bridge: fake),
        ),
      ],
    );
    controller = container.read(audioEngineProvider.notifier);
  });

  tearDown(() {
    container.dispose();
  });

  test(
    'stop pressed during an in-flight start still ends up stopped',
    () async {
      final started = controller.start();
      expect(container.read(audioEngineProvider).busy, isTrue);

      // The open is held across the FFI round-trip; the press must be queued,
      // not dropped.
      await controller.stop();
      expect(fake.stopCalls, 0);

      fake.completeNextStart();
      await started;

      expect(fake.stopCalls, 1);
      expect(container.read(audioEngineProvider).isRunning, isFalse);
    },
  );

  test(
    'a settings change during an in-flight open is applied, not dropped',
    () async {
      final started = controller.start();
      await controller.selectSampleRate(96000);
      expect(fake.startCalls.single.sampleRate, 48000);

      fake.completeNextStart();
      // The queued restart picks the new setting up.
      await Future<void>.delayed(Duration.zero);
      expect(fake.pendingStartCount, 1);
      fake.completeNextStart();
      await started;

      expect(fake.startCalls.last.sampleRate, 96000);
      expect(container.read(audioEngineProvider).isRunning, isTrue);
    },
  );

  test(
    'a tone-push failure keeps the running stream and can be retried',
    () async {
      fake.toneError = 'tone boom';
      final started = controller.start();
      fake.completeNextStart();
      await started;

      final state = container.read(audioEngineProvider);
      expect(
        state.isRunning,
        isTrue,
        reason: 'the stream opened; only the tone push failed',
      );
      expect(state.errorMessage, 'tone boom');

      fake.toneError = null;
      await controller.retryTone();
      expect(container.read(audioEngineProvider).errorMessage, isNull);
      expect(container.read(audioEngineProvider).isRunning, isTrue);
    },
  );

  test(
    'a failing status read stops polling instead of erroring every second',
    () async {
      final started = controller.start();
      fake.completeNextStart();
      await started;
      fake.statusError = 'engine gone';

      await Future<void>.delayed(const Duration(milliseconds: 2100));

      expect(fake.statusCalls, 1, reason: 'polling cancelled itself on error');
      expect(container.read(audioEngineProvider).isRunning, isTrue);
    },
  );

  test('a poll in flight across dispose writes nothing', () async {
    final started = controller.start();
    fake.completeNextStart();
    await started;
    final hanging = Completer<bridge.AudioStreamStatus?>();
    fake.hangingStatus = hanging;

    // Let the first poll fire and park on the hanging future.
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(fake.statusCalls, 1);

    container.dispose();
    container = ProviderContainer();
    hanging.complete(_FakeBridge.streamStatus());
    await Future<void>.delayed(Duration.zero);
    // With the guard missing this completes into a disposed notifier and
    // throws as an unhandled async error; nothing above catching it is the
    // assertion.
  });

  test('a stop that fails does not wedge the engine', () async {
    // `start` has always caught its failures; `stop` had only a `finally`, so
    // a throwing stop left `busy` set for good. Every later start and stop hit
    // the busy guard and did nothing, and the error went nowhere either — the
    // engine was bricked until the app restarted, silently.
    final opening = controller.start();
    fake.completeNextStart();
    await opening;
    expect(container.read(audioEngineProvider).isRunning, isTrue);

    fake.stopError = 'the device went away';
    await controller.stop();

    final afterFailure = container.read(audioEngineProvider);
    expect(afterFailure.busy, isFalse);
    expect(afterFailure.errorMessage, 'the device went away');
    expect(afterFailure.isRunning, isFalse);

    // And it really does recover: the next start and stop reach the bridge.
    fake.stopError = null;
    final started = controller.start();
    fake.completeNextStart();
    await started;
    await controller.stop();
    expect(fake.stopCalls, 2);
    expect(container.read(audioEngineProvider).busy, isFalse);
  });
}
