import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// §15: *"Domain code has no Flutter imports. Audio code has no UI concepts.
/// Enforce with a lint."*
///
/// This is that enforcement. A lint rule would need a custom analyzer plugin;
/// a test that reads the source is simpler, runs on every save, and fails with
/// the offending file and line — which is what anyone actually wants from it.
void main() {
  final domain = Directory('lib/domain');

  test('the domain directory exists and has code in it', () {
    expect(domain.existsSync(), isTrue);
    expect(
      domain
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart')),
      isNotEmpty,
    );
  });

  test('no domain file imports or re-exports Flutter, or anything above the domain', () {
    final offences = <String>[];
    final forbidden = <RegExp>[
      RegExp(r'''^\s*(?:import|export)\s+['"]package:flutter/'''),
      RegExp(r'''^\s*(?:import|export)\s+['"]package:flutter_riverpod/'''),
      RegExp(r'''^\s*(?:import|export)\s+['"]package:flutter_rust_bridge/'''),
      RegExp(r'''^\s*(?:import|export)\s+['"]package:bandstand/ui/'''),
      RegExp(r'''^\s*(?:import|export)\s+['"]package:bandstand/io/'''),
      RegExp(r'''^\s*(?:import|export)\s+['"]package:bandstand/render/'''),
      RegExp(r'''^\s*(?:import|export)\s+['"]package:bandstand/bridge/'''),
      RegExp(r'''^\s*(?:import|export)\s+['"]package:bandstand/audio/'''),
      RegExp(r'''^\s*(?:import|export)\s+['"]dart:io'''),
      RegExp(r'''^\s*(?:import|export)\s+['"]dart:ui'''),
    ];

    // A relative import or export that climbs out of `domain/` reaches the
    // same places by another road: `../../io/midi/...` is exactly as
    // forbidden as `package:bandstand/io/midi/...`. Counting `../` will not
    // do — the bass generator lives two directories deep and reaches the
    // harmony core with exactly that many — so the path is resolved and its
    // destination checked.
    final relative = RegExp(r'''^\s*(?:import|export)\s+['"](\.[^'"]*)['"]''');

    for (final file
        in domain
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        for (final pattern in forbidden) {
          if (pattern.hasMatch(lines[i])) {
            offences.add('${file.path}:${i + 1}: ${lines[i].trim()}');
          }
        }
        final climb = relative.firstMatch(lines[i]);
        if (climb != null) {
          final target = p.normalize(
            p.join(p.dirname(file.path), climb.group(1)!),
          );
          if (!p.isWithin(domain.path, target)) {
            offences.add('${file.path}:${i + 1}: ${lines[i].trim()}');
          }
        }
      }
    }

    expect(
      offences,
      isEmpty,
      reason:
          'the domain layer must stay framework-free (§8.3, §15):\n'
          '${offences.join('\n')}',
    );
  });

  test('no domain file reads a file or an asset', () {
    final offences = <String>[];
    for (final file
        in domain
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))) {
      final source = file.readAsStringSync();
      for (final needle in <String>['rootBundle', 'File(', 'Directory(']) {
        if (source.contains(needle)) {
          offences.add('${file.path}: mentions $needle');
        }
      }
    }
    expect(
      offences,
      isEmpty,
      reason:
          'the domain layer takes data, never paths (ADR 0006):\n'
          '${offences.join('\n')}',
    );
  });
}
