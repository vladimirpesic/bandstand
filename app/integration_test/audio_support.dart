import 'dart:io';

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

/// Where a General MIDI bank can be found on this machine, or null.
///
/// The dev box keeps one in `/usr/share/sounds/sf2/`; a phone has no such
/// place, so the path is passed in:
///
/// ```sh
/// adb push bank.sf2 /sdcard/Android/data/dev.bandstand/files/bank.sf2
/// flutter test integration_test/synth_test.dart -d emulator-5554 \
///   --dart-define=BANDSTAND_SOUNDFONT=/sdcard/Android/data/dev.bandstand/files/bank.sf2
/// ```
///
/// `just android-test` does both. Without it the sampler suites skip on
/// Android, which means the sampler is not exercised there at all — and the
/// sampler is the part most likely to behave differently on another
/// architecture.
String? findSoundbank({bool preferLargest = false}) {
  const fromEnvironment = String.fromEnvironment('BANDSTAND_SOUNDFONT');
  const candidates = <String>[
    '/usr/share/sounds/sf2/TimGM6mb.sf2',
    '/usr/share/sounds/sf2/default-GM.sf2',
    '/usr/share/soundfonts/default.sf2',
    '/usr/share/sounds/sf2/FluidR3_GM.sf2',
  ];
  final available = <String>[
    for (final path in <String>[
      if (fromEnvironment.isNotEmpty) fromEnvironment,
      ...candidates,
    ])
      if (File(path).existsSync()) File(path).resolveSymbolicLinksSync(),
  ];
  if (available.isEmpty) {
    return null;
  }
  if (!preferLargest) {
    return available.first;
  }
  // The memory suite wants the biggest bank on the box: a 6 MB one cannot
  // tell a mapping from a read.
  available.sort(
    (a, b) => File(b).lengthSync().compareTo(File(a).lengthSync()),
  );
  return available.first;
}
