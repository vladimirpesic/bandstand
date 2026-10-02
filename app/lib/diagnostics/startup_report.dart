import 'dart:io';

/// How long the app took to become usable, reported when asked.
///
/// §3 budgets one second from launch to a visible library, three at the
/// outside. Measuring that honestly needs the real binary: process exec,
/// dynamic linking, the Flutter engine's own boot and the asset install all
/// happen before `main` runs, so a `Stopwatch` started in Dart would miss most
/// of what the user waits for. The clock therefore starts from the kernel's
/// record of when the process began.
///
/// Nothing is measured unless [environmentVariable] is set, so this costs a
/// single map lookup in normal use. See `docs/benchmarks.md`.
abstract final class StartupReport {
  /// Set this in the environment to have the app print its startup time.
  static const environmentVariable = 'BANDSTAND_STARTUP_REPORT';

  /// The kernel reports process start times in `USER_HZ`, which the Linux
  /// userspace ABI fixes at 100 regardless of the kernel's own tick rate.
  static const _userHz = 100.0;

  static var _reported = false;

  /// Whether a report was asked for.
  static bool get wanted =>
      Platform.environment.containsKey(environmentVariable);

  /// Print how long the process has been alive, once.
  ///
  /// Called from the first frame that shows the library. Repeat calls do
  /// nothing: the library list rebuilds on every search keystroke, and only the
  /// first one is a cold start.
  static void libraryVisible() {
    if (_reported || !wanted) {
      return;
    }
    _reported = true;
    final seconds = processAgeSeconds();
    if (seconds == null) {
      stdout.writeln('STARTUP unavailable on ${Platform.operatingSystem}');
      return;
    }
    stdout.writeln('STARTUP library visible ${seconds.toStringAsFixed(3)} s');
  }

  /// How long this process has been running, in seconds, or null where the
  /// platform does not say.
  ///
  /// Linux only, which is where the desktop budget is measured. Reading
  /// `/proc` rather than asking a library keeps this dependency-free, and the
  /// two files together are good to a hundredth of a second — ample against a
  /// one-second budget.
  static double? processAgeSeconds() {
    if (!Platform.isLinux && !Platform.isAndroid) {
      return null;
    }
    try {
      final stat = File('/proc/self/stat').readAsStringSync();
      // Field 2 is the executable name in parentheses and may itself contain
      // spaces and brackets, so the fields are only unambiguous after the last
      // closing parenthesis. Field 3 is the first one after it, which puts
      // field 22 — the start time, in ticks since boot — at index 19.
      final tail = stat.substring(stat.lastIndexOf(')') + 1).trim();
      final fields = tail.split(RegExp(r'\s+'));
      if (fields.length < 20) {
        return null;
      }
      final startTicks = double.tryParse(fields[19]);
      final uptime = double.tryParse(
        File('/proc/uptime').readAsStringSync().split(' ').first,
      );
      if (startTicks == null || uptime == null) {
        return null;
      }
      final age = uptime - startTicks / _userHz;
      return age.isFinite && age >= 0 ? age : null;
    } on FileSystemException {
      return null;
    }
  }
}
