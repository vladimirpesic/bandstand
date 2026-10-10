import 'package:bandstand/bridge/api/audio.dart';
import 'package:bandstand/state/platform_audio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records what the policy asked of the engine, and reports the transport
/// state the test last set.
class _RecordingTransport extends PlatformTransport {
  final List<String> calls = <String>[];
  final List<double> gains = <double>[];
  TransportState state = TransportState.stopped;

  @override
  Future<void> play() async => calls.add('play');

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<void> applyGain({required double gain}) async => gains.add(gain);

  @override
  TransportPosition position() => TransportPosition(
    tick: 0,
    hostTimeNs: BigInt.zero,
    readAtNs: BigInt.zero,
    state: state,
    loopGeneration: 0,
    ticksPerNanosecond: 9.6e-7,
    bpm: 120,
    ppq: 480,
  );
}

/// The focus policy of `docs/rules/android-audio.md` §2, without an engine:
/// what a loss pauses, what a gain resumes, and what a duck leaves running.
///
/// L-A3: the transient-loss logic shipped with P1.1/P1.2 without its
/// regression tests, because the bridge throws until `RustLib.init()` has
/// run and no unit test could reach `handleFocus`. The `PlatformTransport`
/// seam — the same shape as `PracticeTransport` in `practice_state.dart` —
/// is what makes these possible.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer containerWith(_RecordingTransport transport) {
    final container = ProviderContainer(
      overrides: [
        platformAudioProvider.overrideWith(
          () => PlatformAudioController(transport: transport),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test(
    'a transient loss pauses a playing transport, and a gain resumes it',
    () async {
      final transport = _RecordingTransport()..state = TransportState.playing;
      final container = containerWith(transport);
      final controller = container.read(platformAudioProvider.notifier);

      await controller.handleFocus(AudioFocusEvent.lostTransient);
      expect(transport.calls, contains('pause'));
      expect(container.read(platformAudioProvider).pausedForFocus, isTrue);

      await controller.handleFocus(AudioFocusEvent.gained);
      expect(transport.calls, contains('play'));
      expect(container.read(platformAudioProvider).pausedForFocus, isFalse);
    },
  );

  test(
    'a transient loss does not touch what the user already paused',
    () async {
      // §2: resume is automatic only for a pause we made. If the user paused
      // before the interruption, focus returning must not start the band
      // playing at them.
      final transport = _RecordingTransport()..state = TransportState.paused;
      final container = containerWith(transport);
      final controller = container.read(platformAudioProvider.notifier);

      await controller.handleFocus(AudioFocusEvent.lostTransient);
      expect(transport.calls, isNot(contains('pause')));
      expect(container.read(platformAudioProvider).pausedForFocus, isFalse);

      await controller.handleFocus(AudioFocusEvent.gained);
      expect(transport.calls, isNot(contains('play')));
      expect(container.read(platformAudioProvider).pausedForFocus, isFalse);
    },
  );

  test('a duck changes the level, not the transport', () async {
    final transport = _RecordingTransport()..state = TransportState.playing;
    final container = containerWith(transport);
    final controller = container.read(platformAudioProvider.notifier);

    await controller.handleFocus(AudioFocusEvent.lostTransientDuck);
    expect(transport.gains, <double>[PlatformAudioController.duckedGain]);
    expect(
      transport.calls,
      isEmpty,
      reason: 'a duck is a gain change, not a pause',
    );
    expect(container.read(platformAudioProvider).ducked, isTrue);

    await controller.handleFocus(AudioFocusEvent.gained);
    expect(transport.gains, <double>[
      PlatformAudioController.duckedGain,
      PlatformAudioController.normalGain,
    ]);
    expect(
      transport.calls,
      isEmpty,
      reason: 'the transport never stopped, so nothing resumes',
    );
    expect(container.read(platformAudioProvider).ducked, isFalse);
  });

  test('a permanent loss stops the band and undoes the duck itself', () async {
    // No `gained` follows a permanent loss, so the loss itself has to undo
    // the duck — otherwise the next play starts at a whisper and stays there.
    final transport = _RecordingTransport()..state = TransportState.playing;
    final container = containerWith(transport);
    final controller = container.read(platformAudioProvider.notifier);

    await controller.handleFocus(AudioFocusEvent.lostTransientDuck);
    await controller.handleFocus(AudioFocusEvent.lost);
    expect(transport.calls, contains('stop'));
    expect(controller.masterGain, PlatformAudioController.normalGain);
    final state = container.read(platformAudioProvider);
    expect(state.ducked, isFalse);
    expect(state.pausedForFocus, isFalse);
  });
}
