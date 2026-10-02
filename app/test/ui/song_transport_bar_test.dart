import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/state/generation_state.dart';
import 'package:bandstand/ui/theme/bandstand_theme.dart';
import 'package:bandstand/ui/widgets/song_transport_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The play button must not start the transport when regeneration failed:
/// the engine may still hold a different song's sequence.
void main() {
  Widget harness(Song song) => ProviderScope(
    overrides: [
      generatorsProvider.overrideWith(
        (ref) async => throw StateError('no generators'),
      ),
    ],
    child: MaterialApp(
      theme: BandstandTheme.dark(),
      home: Scaffold(body: SongTransportBar(song: song)),
    ),
  );

  testWidgets('generation failure is shown and playback does not start', (
    tester,
  ) async {
    final song = Song.blank(id: 'song-1', title: 'Broken');
    await tester.pumpWidget(harness(song));
    await tester.pump();

    await tester.tap(find.text('Generate and play'));
    await tester.pump();

    // The error from the failed generation is on screen…
    expect(find.textContaining('no generators'), findsOneWidget);
    // …and no seek or play was attempted — before the fix those ran straight
    // into the uninitialized FFI and failed the test as an unhandled error.
  });
}
