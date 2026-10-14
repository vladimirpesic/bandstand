import 'package:bandstand/bridge/api/audio.dart';

/// Shared by the integration suites that measure the transport's clock.
///
/// The largest buffer a real-time audio path uses, in frames.
///
/// 8192 frames is 170 ms at 48 kHz — already far past anything a person can
/// play along with, and comfortably above every real device. The Android
/// emulator asks for 34 880.
const int realTimeBufferLimit = 8192;

/// Whether this device's audio path can be timed at all.
///
/// §3's budget — 20 ms over 5 minutes — is 0.0067%, the order of crystal drift,
/// and it is a statement about real hardware. A simulated path cannot meet it
/// and no measurement from one means anything: the Android emulator negotiates
/// a 34 880-frame buffer, delivers it in bursts (358 ms of music arriving 13 ms
/// after the previous callback), and its software audio clock was measured
/// drifting 0.53% against the system clock over thirty seconds — eighty times
/// the budget.
///
/// Call this *after* starting the stream, so there is a buffer size to read.
Future<bool> isRealTimeAudioPath() async {
  final status = await audioStatus();
  final frames = status?.bufferFrames ?? 0;
  return frames > 0 && frames <= realTimeBufferLimit;
}

/// Why a clock test was skipped, for the report.
Future<String> notRealTimeReason() async {
  final status = await audioStatus();
  return 'this device buffers ${status?.bufferFrames ?? 0} frames, which is '
      'not a real-time audio path; §3 clock drift needs real hardware';
}
