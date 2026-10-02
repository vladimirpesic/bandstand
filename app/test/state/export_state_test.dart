import 'dart:io';

import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/io/song_library.dart';
import 'package:bandstand/state/export_state.dart';
import 'package:bandstand/state/generation_state.dart';
import 'package:bandstand/state/library_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// What happens when regeneration fails and the engine still holds an old
/// sequence: the export must refuse, not bounce the stale take.
void main() {
  late Directory root;
  late SongLibrary library;
  late ProviderContainer container;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('bandstand-export-test');
    library = SongLibrary(root);
    await library.ensureLayout();
    container = ProviderContainer(
      overrides: [
        songLibraryProvider.overrideWith((ref) async => library),
        generatorsProvider.overrideWith(
          (ref) async => throw StateError('no generators'),
        ),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  test('a failed regeneration is surfaced, not exported', () async {
    final song = Song.blank(id: 'song-1', title: 'Broken');

    await container
        .read(exportProvider.notifier)
        .export(song, ExportFormat.audio);

    final state = container.read(exportProvider);
    expect(state.lastPath, isNull, reason: 'nothing was written');
    expect(state.errorMessage, contains('no generators'));
  });
}
