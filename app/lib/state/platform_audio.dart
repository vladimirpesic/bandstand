import 'dart:io';

import 'package:bandstand/bridge/api/audio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What the platform did with our claim on the device's audio.
///
/// `docs/rules/android-audio.md` §2: what a backing band should do depends on
/// *how* focus was lost, not merely that it was.
enum AudioFocusEvent {
  /// Focus is ours; resume if we paused for a transient loss.
  gained,

  /// Another app took over for good. Stop — the user has left.
  lost,

  /// A call or an alarm. Pause, and resume when it is over.
  lostTransient,

  /// A navigation prompt. Duck, and restore the level after.
  lostTransientDuck;

  /// Parse the name Kotlin sends.
  static AudioFocusEvent? parse(String name) => switch (name) {
    'GAINED' => AudioFocusEvent.gained,
    'LOST' => AudioFocusEvent.lost,
    'LOST_TRANSIENT' => AudioFocusEvent.lostTransient,
    'LOST_TRANSIENT_DUCK' => AudioFocusEvent.lostTransientDuck,
    _ => null,
  };
}

/// The platform integration of `docs/rules/android-audio.md`, from Dart.
///
/// Everything here is a no-op off Android. The desktop keeps a device until it
/// closes it, nothing takes focus away, and a process is not killed for being
/// in the background — so there is nothing to cooperate with (ADR 0009).
class PlatformAudio {
  /// Create the binding.
  PlatformAudio({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  /// The channel `MainActivity` serves.
  static const String channelName = 'dev.bandstand/platform';

  final MethodChannel _channel;

  /// Whether this platform has anything to cooperate with.
  ///
  /// Read through [Platform] rather than a compile-time constant so a test can
  /// exercise the Android path on a desktop.
  static bool get isSupported => Platform.isAndroid;

  /// Start listening for focus changes.
  void listen(void Function(AudioFocusEvent) onFocus) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'audioFocus') {
        final event = AudioFocusEvent.parse(call.arguments as String? ?? '');
        if (event != null) {
          onFocus(event);
        }
      }
      return null;
    });
  }

  /// Stop listening.
  void dispose() => _channel.setMethodCallHandler(null);

  /// Take focus and start the foreground service.
  ///
  /// Returns false when the system refused focus — a phone call in progress,
  /// say — in which case the transport must not start.
  Future<bool> startPlayback({required String title}) async {
    if (!isSupported) {
      return true;
    }
    final granted = await _channel.invokeMethod<bool>('startPlayback', {
      'title': title,
    });
    return granted ?? false;
  }

  /// Give focus back and stop the service.
  Future<void> stopPlayback() async {
    if (!isSupported) {
      return;
    }
    await _channel.invokeMethod<void>('stopPlayback');
  }

  /// Whether the native audio engine could be reached at all.
  ///
  /// False when the Android context could not be installed, which means every
  /// device call would panic. Reported rather than discovered.
  Future<bool> isEngineAvailable() async {
    if (!isSupported) {
      return true;
    }
    final available = await _channel.invokeMethod<bool>('isEngineAvailable');
    return available ?? false;
  }
}

/// The engine surface the focus policy drives: the transport, and the master
/// gain — of which this policy is the app's only writer.
///
/// The same shape as `PracticeTransport` in `practice_state.dart`: what a
/// focus loss pauses, what a gain resumes and what a duck leaves running is
/// policy worth testing, and none of it needs a running engine. Without this
/// seam no unit test could reach `handleFocus` at all — the bridge throws
/// until `RustLib.init()` has run (L-A3).
class PlatformTransport {
  /// The real engine, over flutter_rust_bridge.
  const PlatformTransport();

  /// Start playing.
  Future<void> play() => transportPlay();

  /// Pause, applying at the next audio block.
  Future<void> pause() => transportPause();

  /// Stop and rewind.
  Future<void> stop() => transportStop();

  /// Where the transport is, and whether it is running.
  TransportPosition position() => transportPosition();

  /// Set the master gain, 0 to 1.
  ///
  /// Not called `setMasterGain`: that is the bridge function it forwards to,
  /// and an instance method of the same name would shadow it.
  Future<void> applyGain({required double gain}) => setMasterGain(gain: gain);
}

/// What the app currently believes about focus.
class PlatformAudioState {
  /// Create a state.
  const PlatformAudioState({
    this.focus = AudioFocusEvent.gained,
    this.pausedForFocus = false,
    this.ducked = false,
  });

  /// The last thing the platform said.
  final AudioFocusEvent focus;

  /// Whether *we* paused because focus was lost, as against the user pausing.
  ///
  /// The distinction is the whole of §2's "resume is only automatic after a
  /// transient loss that Bandstand caused a pause for": if the user paused
  /// before the interruption, focus returning must not start the band playing
  /// at them.
  final bool pausedForFocus;

  /// Whether the level is currently reduced for a navigation prompt.
  final bool ducked;

  /// A copy with some fields replaced.
  PlatformAudioState copyWith({
    AudioFocusEvent? focus,
    bool? pausedForFocus,
    bool? ducked,
  }) => PlatformAudioState(
    focus: focus ?? this.focus,
    pausedForFocus: pausedForFocus ?? this.pausedForFocus,
    ducked: ducked ?? this.ducked,
  );
}

/// Applies the focus policy of `docs/rules/android-audio.md` §2.
///
/// The policy is here rather than in Kotlin because the transport that has to
/// act on it is Dart's (ADR 0009).
class PlatformAudioController extends Notifier<PlatformAudioState> {
  /// Create a controller, optionally over a stand-in engine surface.
  PlatformAudioController({this.transport = const PlatformTransport()});

  /// The engine surface this policy drives. Replaced in tests (L-A3).
  final PlatformTransport transport;

  PlatformAudio? _platform;

  @override
  PlatformAudioState build() {
    final platform = PlatformAudio();
    _platform = platform;
    platform.listen(handleFocus);
    ref.onDispose(platform.dispose);
    return const PlatformAudioState();
  }

  /// The gain a ducked band plays at.
  ///
  /// Loud enough to stay with, quiet enough that a navigation prompt wins.
  static const double duckedGain = 0.25;

  /// The gain everything else plays at.
  static const double normalGain = 1;

  /// The gain the policy last applied, or [normalGain] before it applied any.
  ///
  /// The engine itself has no readback, so this is the only record of what
  /// the duck did — and what a permanent loss has to undo. The controller is
  /// the only writer of the master gain in the app, so it cannot drift from
  /// the engine's truth.
  double get masterGain => _masterGain;
  double _masterGain = normalGain;

  Future<void> _applyGain(double gain) async {
    await transport.applyGain(gain: gain);
    _masterGain = gain;
  }

  /// Start the transport, having taken focus and started the service first.
  ///
  /// **This is how playback starts.** Every UI path goes through here rather
  /// than calling `transportPlay` directly, so the platform handshake cannot
  /// be forgotten in one screen and remembered in another — and so that a
  /// refused focus request stops the band before it starts rather than after.
  ///
  /// Returns false when the system refused focus, in which case nothing began.
  Future<bool> play({required String title}) async {
    if (!await beginPlayback(title: title)) {
      return false;
    }
    await transport.play();
    return true;
  }

  /// Pause, keeping focus and the service.
  ///
  /// A pause is a user saying "hold on", not "I have finished": giving focus
  /// back would let another app take the device, and the player would press
  /// play into silence.
  Future<void> pause() async {
    await transport.pause();
    state = state.copyWith(pausedForFocus: false);
  }

  /// Stop, and give the platform everything back.
  Future<void> stop() async {
    await transport.stop();
    await endPlayback();
  }

  /// Ask for focus and start the service. False means do not start playing.
  Future<bool> beginPlayback({required String title}) async {
    final granted = await (_platform ?? PlatformAudio()).startPlayback(
      title: title,
    );
    if (granted) {
      state = state.copyWith(pausedForFocus: false);
    }
    return granted;
  }

  /// Release focus and stop the service.
  Future<void> endPlayback() async {
    await (_platform ?? PlatformAudio()).stopPlayback();
    state = state.copyWith(pausedForFocus: false, ducked: false);
  }

  /// React to what the platform said (§2).
  Future<void> handleFocus(AudioFocusEvent event) async {
    state = state.copyWith(focus: event);
    switch (event) {
      case AudioFocusEvent.lost:
        // Permanent: the user has gone to another app. Stop, do not pause —
        // there is nothing to come back to.
        await transport.stop();
        if (state.ducked) {
          // No `gained` follows a permanent loss, and `play()` never touches
          // the gain — without this the duck would outlive the session and
          // the next play would start at a whisper.
          await _applyGain(normalGain);
        }
        await (_platform ?? PlatformAudio()).stopPlayback();
        state = state.copyWith(pausedForFocus: false, ducked: false);

      case AudioFocusEvent.lostTransient:
        // §2: resume is automatic only for a pause *we* made. Snapshot
        // whether the transport was running before touching it — if the
        // user had already paused, leaving the flag false is what stops
        // `gained` starting the band playing at them.
        final wasPlaying =
            state.pausedForFocus ||
            transport.position().state == TransportState.playing;
        if (wasPlaying) {
          await transport.pause();
        }
        state = state.copyWith(pausedForFocus: wasPlaying);

      case AudioFocusEvent.lostTransientDuck:
        // A gain change, not a pause: the transport keeps running so the cursor
        // stays where the player is looking.
        await _applyGain(duckedGain);
        state = state.copyWith(ducked: true);

      case AudioFocusEvent.gained:
        if (state.ducked) {
          await _applyGain(normalGain);
        }
        if (state.pausedForFocus) {
          await transport.play();
        }
        state = state.copyWith(pausedForFocus: false, ducked: false);
    }
  }
}

/// The platform audio policy.
final platformAudioProvider =
    NotifierProvider<PlatformAudioController, PlatformAudioState>(
      PlatformAudioController.new,
    );
