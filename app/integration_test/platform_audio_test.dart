import 'dart:io';

import 'package:bandstand/audio/playhead.dart';
import 'package:bandstand/bridge/api/audio.dart';
import 'package:bandstand/bridge/frb_generated.dart';
import 'package:bandstand/state/platform_audio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// The Android platform integration of `docs/rules/android-audio.md`, driven
/// through the real activity.
///
/// Everything here is a no-op off Android, so the suite passes trivially on the
/// desktop and means something only on a device — which is the point: the
/// Kotlin it exercises exists solely for Android, and the JNI context it needs
/// is what made the M0 acceptance leg impossible until M8.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  tearDown(() async {
    await transportStop();
    await PlatformAudio().stopPlayback();
  });

  /// The pattern of `audio_engine_test.dart`: a transport command applies at
  /// the next audio block, so poll for the settled state rather than trusting
  /// the microseconds between two calls (M16).
  Future<PlayheadReading> settledAt(
    TransportState state, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final reading = Playhead.resolve(transportPosition());
      if (reading.state == state) {
        return reading;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    throw StateError('the transport never reached $state within $timeout');
  }

  testWidgets('the native engine is reachable', (tester) async {
    // On Android this is false when the JNI context could not be installed,
    // which would mean every device call panics. It is the single most
    // important thing to know about this platform.
    expect(await PlatformAudio().isEngineAvailable(), isTrue);
  });

  testWidgets('the Android context really was installed', (tester) async {
    if (!Platform.isAndroid) {
      markTestSkipped('not Android');
      return;
    }
    // Proof rather than assertion: enumerating devices goes through Oboe,
    // which asks `ndk_context` for the JavaVM and the Context and panics
    // without them. Before M8 this threw
    // "android context was not initialized".
    final devices = await audioDevices();
    expect(devices, isNotEmpty);
  });

  testWidgets('taking focus starts the service, and giving it back stops it', (
    tester,
  ) async {
    // The whole Kotlin path: `AudioFocus.request`, then
    // `PlaybackService.start` with a typed foreground service and a
    // notification channel. Android kills the app if `startForeground` is not
    // called within a few seconds, and rejects the service outright if the
    // channel or the manifest type is wrong — so a false here, or a hang, is
    // the platform refusing something.
    final platform = PlatformAudio();
    expect(await platform.startPlayback(title: 'Integration test'), isTrue);
    await platform.stopPlayback();

    // And again: focus and the service must both be re-acquirable, because a
    // set is a sequence of tunes rather than one.
    expect(await platform.startPlayback(title: 'Second tune'), isTrue);
    await platform.stopPlayback();
  });

  testWidgets('the focus policy pauses and resumes, but only what it paused', (
    tester,
  ) async {
    if ((await audioDevices()).isEmpty) {
      markTestSkipped('no audio device');
      return;
    }
    await audioStart(request: const AudioStreamRequest());
    await transportSeek(tick: 0);
    await transportPlay();

    // A Notifier only has state inside a container: constructing one directly
    // and touching `state` is what Riverpod's "uninitialized" error is for.
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(platformAudioProvider.notifier);

    // A transient loss pauses (§2), and the state records that *we* did it.
    await controller.handleFocus(AudioFocusEvent.lostTransient);
    expect(container.read(platformAudioProvider).pausedForFocus, isTrue);

    // Getting it back resumes, because we were the ones who paused.
    await controller.handleFocus(AudioFocusEvent.gained);
    expect(container.read(platformAudioProvider).pausedForFocus, isFalse);

    // A duck is a gain change, not a pause: the transport keeps running so the
    // cursor stays where the player is looking.
    await controller.handleFocus(AudioFocusEvent.lostTransientDuck);
    expect(container.read(platformAudioProvider).ducked, isTrue);
    expect(container.read(platformAudioProvider).pausedForFocus, isFalse);
    await controller.handleFocus(AudioFocusEvent.gained);
    expect(container.read(platformAudioProvider).ducked, isFalse);

    await audioStop();
  });

  testWidgets('a transient loss does not restart what the user paused', (
    tester,
  ) async {
    if ((await audioDevices()).isEmpty) {
      markTestSkipped('no audio device');
      return;
    }
    await audioStart(request: const AudioStreamRequest());
    await transportSeek(tick: 0);
    await transportPlay();

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(platformAudioProvider.notifier);

    // The user paused before the interruption. §2 forbids an automatic
    // resume in exactly this case, and the state must not record a pause
    // *we* did not make.
    await controller.pause();
    // M16: a pause applies at the next audio block, so reading the transport
    // microseconds after `pause()` returns can catch it still playing —
    // making the flag below record a pause *we* made — or pass while a
    // still-pending request applies afterwards and leaves playback running
    // into the next test. Poll for the settled state first.
    await settledAt(TransportState.paused);
    await controller.handleFocus(AudioFocusEvent.lostTransient);
    expect(container.read(platformAudioProvider).pausedForFocus, isFalse);

    await controller.handleFocus(AudioFocusEvent.gained);
    expect(
      Playhead.resolve(transportPosition()).state,
      TransportState.paused,
      reason: 'focus returning must not start the band playing at the user',
    );
    // And it stays paused: no request posted during the window applies
    // afterwards.
    await settledAt(TransportState.paused);

    await audioStop();
  });

  testWidgets('a permanent loss restores the duck', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(platformAudioProvider.notifier);

    await controller.handleFocus(AudioFocusEvent.lostTransientDuck);
    expect(controller.masterGain, PlatformAudioController.duckedGain);

    // No `gained` follows a permanent loss, so the loss itself has to undo
    // the duck — otherwise the next play starts at a whisper and stays there.
    await controller.handleFocus(AudioFocusEvent.lost);
    expect(controller.masterGain, PlatformAudioController.normalGain);
    expect(container.read(platformAudioProvider).ducked, isFalse);

    // And neither playing nor stopping afterwards touches the level.
    await controller.play(title: 'Duck test');
    expect(controller.masterGain, PlatformAudioController.normalGain);
    await controller.stop();
    expect(controller.masterGain, PlatformAudioController.normalGain);
  });
}
