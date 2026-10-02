import 'dart:io';

import 'package:test/test.dart';

/// Runs the probe CLI exactly as a user would, so argument handling and
/// report formatting are covered end to end.
Future<ProcessResult> runProbe(List<String> args) => Process.run(
  Platform.resolvedExecutable,
  <String>['run', 'bin/tiling_probe.dart', ...args],
  workingDirectory: Directory.current.path,
);

void main() {
  group('cli', () {
    test('bad --tempo value exits 1 with the usage message', () async {
      final result = await runProbe(<String>['--tempo', 'fast']);
      expect(result.exitCode, 1);
      expect(result.stderr, contains('not a tempo'));
      expect(result.stderr, contains('Usage: dart run tiling_probe'));
      expect(result.stderr, isNot(contains('Unhandled exception')));
    });

    // `double.tryParse` parses all four of these; none is a tempo. "NaN" and
    // "Infinity" used to reach the MIDI writer and throw "Infinity or NaN
    // toInt", and zero and negatives used to write a corrupt tempo and exit 0.
    for (final bad in <String>['NaN', 'Infinity', '-Infinity', '0', '-50']) {
      test('--tempo $bad is refused rather than written', () async {
        final result = await runProbe(<String>['--tempo', bad]);
        expect(result.exitCode, 1, reason: 'stderr: ${result.stderr}');
        expect(result.stderr, contains('not a tempo'));
        expect(result.stderr, isNot(contains('Unhandled exception')));
      });
    }

    // Zero or fewer choruses used to exit 0 having written an empty file and a
    // report full of zeros, which reads as "the corpus covered nothing".
    for (final bad in <String>['0', '-3', 'many']) {
      test('--choruses $bad is refused rather than writing nothing', () async {
        final result = await runProbe(<String>['--choruses', bad]);
        expect(result.exitCode, 1, reason: 'stderr: ${result.stderr}');
        expect(result.stderr, contains('not a chorus count'));
        expect(result.stderr, isNot(contains('Unhandled exception')));
      });
    }

    test(
      'a value option with no value exits 1 with the usage message',
      () async {
        final result = await runProbe(<String>['--tempo']);
        expect(result.exitCode, 1);
        expect(result.stderr, contains('missing value for --tempo'));
        expect(result.stderr, contains('Usage: dart run tiling_probe'));
        expect(result.stderr, isNot(contains('Unhandled exception')));
      },
    );

    test('unknown option exits 1 with the usage message', () async {
      final result = await runProbe(<String>['--bogus']);
      expect(result.exitCode, 1);
      expect(result.stderr, contains('unknown option "--bogus"'));
      expect(result.stderr, contains('Usage: dart run tiling_probe'));
      expect(result.stderr, isNot(contains('Unhandled exception')));
    });

    test('--help prints the usage and exits 0', () async {
      final result = await runProbe(<String>['--help']);
      expect(result.exitCode, 0);
      expect(result.stdout, contains('Usage: dart run tiling_probe'));
    });

    test('duration rounding carries into minutes (no ":60")', () async {
      // Three choruses of the 32-bar form at default settings is 96 bars;
      // this tempo puts the total at 359.6 s, which used to print 5:60.
      final out = File(
        '${Directory.systemTemp.path}/tiling_probe_cli_test.mid',
      );
      final tempo = 96 * 4 * 60 / 359.6;
      final result = await runProbe(<String>[
        '--tempo',
        '$tempo',
        '--out',
        out.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, contains('(96 bars, 6:00)'));
      expect(result.stdout, isNot(contains(':60')));
    });
  }, timeout: const Timeout(Duration(seconds: 120)));
}
