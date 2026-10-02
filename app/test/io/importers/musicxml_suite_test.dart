import 'dart:io';

import 'package:bandstand/domain/song/lead_sheet_item.dart';
import 'package:bandstand/io/importers/musicxml_import.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../domain/harmony/harmony_test_support.dart';

/// §5.2's acceptance corpus for the MusicXML importer.
///
/// *"Test against the Unofficial MusicXML Test Suite (~130 files, originally
/// built for LilyPond's importer) — it is data, not code, so no licence
/// question, and it is a ready-made acceptance corpus."*
///
/// Fetched rather than vendored (`docs/rules/musicxml-import.md` §6):
/// `just fetch-musicxml-suite`. These skip when it is absent.
///
/// What the suite is *for* is not asserting that every file imports to
/// something specific — most are notation edge cases with no chords in them at
/// all. It is asserting that **no file breaks the importer**, and that the ones
/// carrying harmony produce the chords they name. A parser that survives 165
/// adversarial files will survive a user's library.
void main() {
  installTestHarmony();

  final suite = Directory('../build/musicxml-suite');
  final files = suite.existsSync()
      ? (suite
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.xml'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path)))
      : <File>[];

  group('the MusicXML test suite', () {
    test('the corpus is there', () {
      if (files.isEmpty) {
        markTestSkipped('run `just fetch-musicxml-suite` first');
        return;
      }
      expect(files.length, greaterThanOrEqualTo(100));
    });

    test('no file breaks the importer', () {
      if (files.isEmpty) {
        markTestSkipped('run `just fetch-musicxml-suite` first');
        return;
      }
      // A `FormatException` is a *result*: the file is not a partwise score, or
      // is not XML. Anything else — a range error, a null dereference, a state
      // error — is the importer failing, and is what this is looking for.
      final broken = <String>[];
      var imported = 0;
      for (final file in files) {
        final name = file.uri.pathSegments.last;
        try {
          MusicXmlImporter.read(file.readAsBytesSync(), id: name);
          imported++;
        } on FormatException {
          // A refusal with a reason. Fine.
        } catch (error) {
          broken.add('$name: $error');
        }
      }
      expect(broken, isEmpty);
      // And it must actually be importing them, not refusing them all.
      expect(imported, greaterThan(files.length ~/ 2));
    });

    test('every import produces a usable chart', () {
      if (files.isEmpty) {
        markTestSkipped('run `just fetch-musicxml-suite` first');
        return;
      }
      final wrong = <String>[];
      for (final file in files) {
        final name = file.uri.pathSegments.last;
        try {
          final result = MusicXmlImporter.read(
            file.readAsBytesSync(),
            id: name,
          );
          final song = result.song;
          if (song.leadSheet.barCount < 1) {
            wrong.add('$name has no bars');
          }
          if (song.title.trim().isEmpty) {
            wrong.add('$name has no title');
          }
          // A chart whose structure could not be built is one that would fail
          // on the first play, so it is caught here rather than there.
          if (song.structure.songParts.isEmpty) {
            wrong.add('$name has no song parts');
          }
        } on FormatException {
          continue;
        }
      }
      expect(wrong, isEmpty);
    });

    test('the files with harmony give up their chords', () {
      if (files.isEmpty) {
        markTestSkipped('run `just fetch-musicxml-suite` first');
        return;
      }
      final withHarmony = files
          .where((file) => file.readAsStringSync().contains('<harmony'))
          .toList();
      expect(
        withHarmony,
        isNotEmpty,
        reason: 'the suite should carry some harmony files',
      );

      final silent = <String>[];
      for (final file in withHarmony) {
        final name = file.uri.pathSegments.last;
        try {
          final result = MusicXmlImporter.read(
            file.readAsBytesSync(),
            id: name,
          );
          final chords = result.song.leadSheet.items
              .whereType<CliChordSymbol>()
              .length;
          if (chords == 0) {
            silent.add(name);
          }
        } on FormatException catch (error) {
          silent.add('$name refused: ${error.message}');
        }
      }
      expect(silent, isEmpty);
    });

    test('nothing takes an unreasonable time', () {
      if (files.isEmpty) {
        markTestSkipped('run `just fetch-musicxml-suite` first');
        return;
      }
      // A user importing a library imports hundreds at once. A file that takes
      // a second is a library that takes minutes.
      final watch = Stopwatch()..start();
      for (final file in files) {
        try {
          MusicXmlImporter.read(
            file.readAsBytesSync(),
            id: file.uri.pathSegments.last,
          );
        } on FormatException {
          continue;
        }
      }
      watch.stop();
      final perFile = watch.elapsedMilliseconds / files.length;
      // ignore: avoid_print
      print(
        'BENCH MusicXML import: ${files.length} files in '
        '${watch.elapsedMilliseconds} ms (${perFile.toStringAsFixed(1)} ms each)',
      );
      // Wall-clock under test-suite concurrency is information, not a
      // pass/fail: the number is always printed above for
      // `benchmarks/run.sh` and docs/benchmarks.md. Run with
      // BANDSTAND_ENFORCE_BENCHMARKS=1 to make the budget a hard failure,
      // as for a milestone sign-off.
      if (Platform.environment.containsKey('BANDSTAND_ENFORCE_BENCHMARKS')) {
        expect(perFile, lessThan(50));
      }
    });
  });
}
