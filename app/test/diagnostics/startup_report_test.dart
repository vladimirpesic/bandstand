import 'dart:io';

import 'package:bandstand/diagnostics/startup_report.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('the startup clock', () {
    test('reads a plausible process age', () {
      if (!Platform.isLinux) {
        // Skipped rather than returned. A bare `return` made the whole suite
        // *pass* on macOS and Windows having measured nothing at all, which
        // reads as coverage it does not have.
        markTestSkipped('/proc is Linux only');
        return;
      }
      final age = StartupReport.processAgeSeconds();
      expect(age, isNotNull, reason: '/proc should be readable on Linux');
      // The test process has just started and cannot have been running for an
      // hour; anything outside that says the fields were misread.
      expect(age, greaterThanOrEqualTo(0));
      expect(age, lessThan(3600));
    });

    test('the age advances with the wall clock', () {
      if (!Platform.isLinux) {
        // Skipped rather than returned. A bare `return` made the whole suite
        // *pass* on macOS and Windows having measured nothing at all, which
        // reads as coverage it does not have.
        markTestSkipped('/proc is Linux only');
        return;
      }
      final first = StartupReport.processAgeSeconds();
      sleep(const Duration(milliseconds: 120));
      final second = StartupReport.processAgeSeconds();
      expect(first, isNotNull);
      expect(second, isNotNull);
      // Both files are good to a hundredth of a second, so 120 ms of sleep has
      // to show up. This is what catches a unit mix-up: reading start time in
      // ticks as seconds would make the age constant, or wildly negative.
      expect(
        second! - first!,
        greaterThan(0.05),
        reason: 'the clock did not advance across a real sleep',
      );
      expect(second - first, lessThan(2.0));
    });

    test('stays quiet unless the environment asks', () {
      // The report is opt-in, and this suite does not set the variable, so
      // nothing should be printed. `libraryVisible` is called on the first
      // frame of a screen users see constantly.
      expect(StartupReport.wanted, isFalse);
      expect(StartupReport.libraryVisible, returnsNormally);
    });
  });
}
