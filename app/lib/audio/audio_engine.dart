import 'dart:async';

import 'package:bandstand/bridge/api/audio.dart' as bridge;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Buffer sizes offered in Settings, in frames.
///
/// Powers of two from 64 (1.3 ms at 48 kHz, for a machine that can take it) to
/// 2048 (43 ms, the "just make it stop crackling" setting).
const List<int> kBufferFrameChoices = <int>[64, 128, 256, 512, 1024, 2048];

/// Sample rates offered in Settings.
const List<int> kSampleRateChoices = <int>[44100, 48000, 88200, 96000];

/// Everything the audio settings UI needs to render.
class AudioEngineState {
  const AudioEngineState({
    this.status,
    this.deviceName,
    this.sampleRate = 48000,
    this.bufferFrames = 256,
    this.toneEnabled = false,
    this.toneFrequencyHz = 440,
    this.toneAmplitude = 0.125,
    this.busy = false,
    this.errorMessage,
  });

  /// The stream currently open, or null when stopped.
  final bridge.AudioStreamStatus? status;

  /// Device the user picked, or null for the system default.
  final String? deviceName;

  /// Sample rate to request.
  final int sampleRate;

  /// Buffer size to request, in frames.
  final int bufferFrames;

  /// Whether the reference test tone is switched on.
  final bool toneEnabled;

  /// Test-tone frequency in hertz.
  final double toneFrequencyHz;

  /// Test-tone amplitude, linear gain.
  final double toneAmplitude;

  /// True while an open or close is in flight.
  final bool busy;

  /// The last failure, or null.
  final String? errorMessage;

  /// Whether a stream is open.
  bool get isRunning => status != null;

  AudioEngineState copyWith({
    bridge.AudioStreamStatus? status,
    bool clearStatus = false,
    String? deviceName,
    bool clearDeviceName = false,
    int? sampleRate,
    int? bufferFrames,
    bool? toneEnabled,
    double? toneFrequencyHz,
    double? toneAmplitude,
    bool? busy,
    String? errorMessage,
    bool clearError = false,
  }) {
    return AudioEngineState(
      status: clearStatus ? null : (status ?? this.status),
      deviceName: clearDeviceName ? null : (deviceName ?? this.deviceName),
      sampleRate: sampleRate ?? this.sampleRate,
      bufferFrames: bufferFrames ?? this.bufferFrames,
      toneEnabled: toneEnabled ?? this.toneEnabled,
      toneFrequencyHz: toneFrequencyHz ?? this.toneFrequencyHz,
      toneAmplitude: toneAmplitude ?? this.toneAmplitude,
      busy: busy ?? this.busy,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

/// The output devices the platform offers.
final audioDevicesProvider = FutureProvider<List<bridge.AudioDevice>>((ref) {
  return bridge.audioDevices();
});

/// The engine FFI calls the controller makes.
///
/// One seam rather than top-level calls, so the controller's own logic —
/// queueing a press that arrives mid-flight, tone-push failure handling,
/// polling — can be tested without a running engine.
class AudioEngineBridge {
  /// The real bridge, over flutter_rust_bridge.
  const AudioEngineBridge();

  /// Open (or reopen) the output stream.
  Future<bridge.AudioStreamStatus> start({
    required bridge.AudioStreamRequest request,
  }) => bridge.audioStart(request: request);

  /// Close the output stream.
  Future<void> stop() => bridge.audioStop();

  /// The state of the stream currently open, or null when none is.
  Future<bridge.AudioStreamStatus?> status() => bridge.audioStatus();

  /// Switch the reference test tone on or off and set its level.
  Future<void> setTestTone({
    required bool enabled,
    required double frequencyHz,
    required double amplitude,
  }) => bridge.setTestTone(
    enabled: enabled,
    frequencyHz: frequencyHz,
    amplitude: amplitude,
  );
}

/// Drives the Rust audio engine.
class AudioEngineController extends Notifier<AudioEngineState> {
  AudioEngineController({AudioEngineBridge? bridge})
    : _bridge = bridge ?? const AudioEngineBridge();

  final AudioEngineBridge _bridge;
  Timer? _statusTimer;

  /// Whether the notifier has been disposed; a poll in flight across an FFI
  /// round-trip must not write state once it is.
  bool _disposed = false;

  /// What to run when the in-flight open or close completes.
  ///
  /// [AudioEngineState.busy] is held across an unbounded FFI round-trip, and
  /// a control touched during that window used to be dropped silently — a
  /// user pressing Stop while the engine opened got nothing. The last
  /// request made during the window is queued here and applied when the
  /// window closes.
  Future<void> Function()? _pending;

  @override
  AudioEngineState build() {
    _disposed = false;
    ref.onDispose(() {
      _disposed = true;
      _pending = null;
      _statusTimer?.cancel();
      _statusTimer = null;
    });
    return const AudioEngineState();
  }

  /// Open the output stream with the current settings.
  Future<void> start() async {
    if (state.busy) {
      return;
    }
    state = state.copyWith(busy: true, clearError: true);
    try {
      final status = await _bridge.start(
        request: bridge.AudioStreamRequest(
          deviceName: state.deviceName,
          sampleRate: state.sampleRate,
          bufferFrames: state.bufferFrames,
        ),
      );
      state = state.copyWith(status: status, busy: false);
    } catch (error) {
      // The Rust side reports failures as plain strings, which
      // flutter_rust_bridge rethrows verbatim.
      state = state.copyWith(
        busy: false,
        clearStatus: true,
        errorMessage: error is String ? error : error.toString(),
      );
      await _runPending();
      return;
    }
    // Re-apply the tone so a restarted stream keeps the user's setting. A
    // failure here is not a stream failure: the engine is running and
    // reporting healthy, only the tone is wrong. Keep the started status,
    // report the tone error, and start polling so the panel stays live.
    try {
      await _pushTone();
    } catch (error) {
      state = state.copyWith(
        errorMessage: error is String ? error : error.toString(),
      );
    }
    _startPolling();
    await _runPending();
  }

  /// Close the output stream.
  Future<void> stop() async {
    if (state.busy) {
      _pending = stop;
      return;
    }
    state = state.copyWith(busy: true);
    _statusTimer?.cancel();
    _statusTimer = null;
    try {
      await _bridge.stop();
      state = state.copyWith(busy: false, clearStatus: true);
    } catch (error) {
      // `start` has always caught; this had only a `finally`, so a stop that
      // threw left `busy` set for good. The status timer is already cancelled
      // and every later start and stop hits the busy guard, so the engine was
      // bricked until the app restarted — silently, because the error went
      // nowhere either. The state is reset and the failure surfaced instead.
      state = state.copyWith(
        busy: false,
        clearStatus: true,
        errorMessage: error is String ? error : error.toString(),
      );
    } finally {
      await _runPending();
    }
  }

  /// Choose the output device; null means the system default.
  Future<void> selectDevice(String? name) async {
    state = name == null
        ? state.copyWith(clearDeviceName: true)
        : state.copyWith(deviceName: name);
    await _restartIfRunning();
  }

  /// Choose the sample rate to request.
  Future<void> selectSampleRate(int rate) async {
    state = state.copyWith(sampleRate: rate);
    await _restartIfRunning();
  }

  /// Choose the buffer size to request.
  Future<void> selectBufferFrames(int frames) async {
    state = state.copyWith(bufferFrames: frames);
    await _restartIfRunning();
  }

  /// Restart the stream so a settings change takes effect.
  ///
  /// A change made while an open is in flight is queued rather than dropped:
  /// when the in-flight open completes this re-runs and restarts with the
  /// new settings.
  Future<void> _restartIfRunning() async {
    if (state.busy) {
      _pending = _restartIfRunning;
      return;
    }
    if (state.isRunning) {
      await start();
    }
  }

  /// Switch the reference test tone on or off.
  Future<void> setToneEnabled(bool enabled) async {
    state = state.copyWith(toneEnabled: enabled);
    await _pushTone();
  }

  /// Set the test-tone frequency, in hertz.
  Future<void> setToneFrequency(double hz) async {
    state = state.copyWith(toneFrequencyHz: hz);
    await _pushTone();
  }

  /// Set the test-tone amplitude, as linear gain in 0..1.
  Future<void> setToneAmplitude(double amplitude) async {
    state = state.copyWith(toneAmplitude: amplitude);
    await _pushTone();
  }

  /// Try the test-tone push again after [start] reported it failed.
  Future<void> retryTone() async {
    try {
      await _pushTone();
      state = state.copyWith(clearError: true);
    } catch (error) {
      state = state.copyWith(
        errorMessage: error is String ? error : error.toString(),
      );
    }
  }

  /// Clear the displayed error.
  void dismissError() {
    state = state.copyWith(clearError: true);
  }

  Future<void> _pushTone() {
    return _bridge.setTestTone(
      enabled: state.toneEnabled,
      frequencyHz: state.toneFrequencyHz,
      amplitude: state.toneAmplitude,
    );
  }

  Future<void> _runPending() async {
    final pending = _pending;
    if (pending != null) {
      _pending = null;
      await pending();
    }
  }

  void _startPolling() {
    _statusTimer?.cancel();
    // Once a second: these are health counters, not a playhead. The playhead
    // has its own path (a per-frame read of the shared position cell).
    _statusTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      try {
        final status = await _bridge.status();
        if (_disposed) {
          return;
        }
        if (status == null) {
          _statusTimer?.cancel();
          _statusTimer = null;
          state = state.copyWith(clearStatus: true);
        } else {
          state = state.copyWith(status: status);
        }
      } catch (_) {
        // A throwing status read would otherwise repeat as an unhandled
        // error every second. Stop polling; the stream status on screen is
        // the last good one, and the user can restart the engine.
        _statusTimer?.cancel();
        _statusTimer = null;
      }
    });
  }
}

/// The audio engine controller.
final audioEngineProvider =
    NotifierProvider<AudioEngineController, AudioEngineState>(
      () => AudioEngineController(),
    );
