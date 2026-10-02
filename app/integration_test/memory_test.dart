import 'dart:io';

import 'package:bandstand/bridge/api/audio.dart';
import 'package:bandstand/bridge/frb_generated.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'audio_support.dart';

/// §3's memory budget, and the claim ADR 0007 rests on.
///
/// *"Mobile memory: a full bank cannot be resident"* (§7.2). The answer was to
/// memory-map the sample data so the OS page cache is the LRU — which is only
/// worth anything if a large bank really does stay out of the heap. This
/// measures that rather than assuming it.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  /// Resident set size in bytes, from the kernel.
  ///
  /// `VmRSS` counts the pages actually in memory, mapped file pages included —
  /// which is the number that matters, because it is what the OOM killer reads.
  int? residentBytes() {
    final status = File('/proc/self/status');
    if (!status.existsSync()) {
      return null;
    }
    for (final line in status.readAsLinesSync()) {
      if (line.startsWith('VmRSS:')) {
        final kb = int.tryParse(line.split(RegExp(r'\s+')).elementAt(1));
        return kb == null ? null : kb * 1024;
      }
    }
    return null;
  }

  testWidgets('a large bank does not become resident', (tester) async {
    final path = findSoundbank(preferLargest: true);
    if (path == null) {
      markTestSkipped('no soundfont');
      return;
    }
    final bankBytes = File(path).lengthSync();
    if (bankBytes <= 20 * 1000 * 1000) {
      // A small bank fits the page cache whole either way, so this test
      // cannot tell a mapping from a read. Say so instead of passing for
      // nothing.
      markTestSkipped(
        'the largest bank (${(bankBytes / 1e6).toStringAsFixed(0)} MB) is '
        'too small to distinguish a mapping from a read',
      );
      return;
    }
    final before = residentBytes();
    if (before == null) {
      markTestSkipped('no /proc on this platform');
      return;
    }

    final info = await loadSoundbank(path: path);
    expect(info.presetCount, greaterThan(0));

    final after = residentBytes();
    if (after == null) {
      markTestSkipped('no /proc on this platform');
      return;
    }
    final grewBy = after - before;
    // ignore: avoid_print
    print(
      'BENCH bank ${(bankBytes / 1e6).toStringAsFixed(1)} MB: '
      'RSS ${(before / 1e6).toStringAsFixed(1)} -> '
      '${(after / 1e6).toStringAsFixed(1)} MB '
      '(+${(grewBy / 1e6).toStringAsFixed(1)} MB)',
    );

    // The claim of ADR 0007: loading a bank maps it rather than reading it, so
    // the process does not grow by the size of the file. A 148 MB bank that
    // added 148 MB of RSS would mean the mapping was being faulted in whole,
    // and the mobile budget would be unmeetable.
    expect(
      grewBy,
      lessThan(bankBytes ~/ 2),
      reason:
          'loading a ${(bankBytes / 1e6).toStringAsFixed(0)} MB bank grew the '
          'process by ${(grewBy / 1e6).toStringAsFixed(0)} MB, which is not '
          'a mapping',
    );

    // §3: 400 MB on a desktop, 250 MB on an Android tablet — and that is a
    // budget for the *shipping* app. An integration test runs a debug build,
    // which carries the Dart VM in JIT mode, the test harness and the service
    // extensions: 312 MB of baseline on Linux and 374 MB on Android before a
    // single byte of soundfont is touched. Asserting the budget against that
    // measures Flutter's debug overhead rather than Bandstand's footprint —
    // the same error as timing the audio clock on an emulator.
    //
    // So the growth above is the assertion, because it is the claim ADR 0007
    // actually makes and it holds in any build. The absolute figure is
    // asserted only where it means something.
    final budget = Platform.isAndroid ? 250 : 400;
    // ignore: avoid_print
    print(
      'BENCH resident ${(after / 1e6).toStringAsFixed(0)} MB against a '
      '$budget MB budget (${kReleaseMode ? "release" : "debug"} build)',
    );
    if (kReleaseMode) {
      expect(
        after / 1e6,
        lessThan(budget),
        reason:
            '${(after / 1e6).toStringAsFixed(0)} MB resident against a '
            '$budget MB budget',
      );
    }
  });

  testWidgets('warming a preset brings in a preset, not a bank', (
    tester,
  ) async {
    final path = findSoundbank(preferLargest: true);
    if (path == null || residentBytes() == null) {
      markTestSkipped('no soundfont, or no /proc');
      return;
    }
    final bankBytes = File(path).lengthSync();
    if (bankBytes <= 20 * 1000 * 1000) {
      markTestSkipped(
        'the largest bank (${(bankBytes / 1e6).toStringAsFixed(0)} MB) is '
        'too small to distinguish a mapping from a read',
      );
      return;
    }
    await loadSoundbank(path: path);
    final before = residentBytes()!;

    // Loading a sequence warms the presets it names
    // (`docs/rules/sf2-sampler.md` §9), so this is warming through the path a
    // user actually takes.
    await loadSequence(
      events: <MidiEvent>[
        MidiEvent(
          tick: BigInt.zero,
          channel: 0,
          kind: MidiEventKind.program,
          data1: 0,
          data2: 0,
        ),
        MidiEvent(
          tick: BigInt.zero,
          channel: 0,
          kind: MidiEventKind.noteOn,
          data1: 60,
          data2: 100,
        ),
        MidiEvent(
          tick: BigInt.from(960),
          channel: 0,
          kind: MidiEventKind.noteOff,
          data1: 60,
          data2: 0,
        ),
      ],
      ppq: 960,
      lengthTicks: BigInt.from(1920),
      tempoMarkers: <TempoMarker>[TempoMarker(tick: BigInt.zero, bpm: 120)],
    );

    final after = residentBytes()!;
    final grewBy = after - before;
    // ignore: avoid_print
    print('BENCH warming one preset: +${(grewBy / 1e6).toStringAsFixed(1)} MB');

    // Warming is per preset, not per bank — that distinction is the whole
    // reason it is affordable and prefaulting the file is not.
    expect(grewBy, lessThan(bankBytes ~/ 4));
  });
}
