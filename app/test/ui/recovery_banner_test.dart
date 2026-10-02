import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/io/song_library.dart';
import 'package:bandstand/ui/theme/bandstand_theme.dart';
import 'package:bandstand/ui/widgets/recovery_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../domain/harmony/harmony_test_support.dart';

void main() {
  installTestHarmony();

  Widget harness(
    JournalRecovery recovery, {
    required VoidCallback onRestore,
    required VoidCallback onDiscard,
  }) => MaterialApp(
    theme: BandstandTheme.dark(),
    home: Scaffold(
      body: RecoveryRow(
        recovery: recovery,
        onRestore: onRestore,
        onDiscard: onDiscard,
      ),
    ),
  );

  testWidgets('names the song and offers both choices', (tester) async {
    var restored = 0;
    var discarded = 0;
    final song = Song.blank(id: 'x', title: 'Interrupted');
    await tester.pumpWidget(
      harness(
        JournalRecovery(song, DateTime.utc(2026, 2), DateTime.utc(2026)),
        onRestore: () => restored++,
        onDiscard: () => discarded++,
      ),
    );
    await tester.pump();

    expect(
      find.textContaining('Unsaved changes to "Interrupted"'),
      findsOneWidget,
    );
    expect(find.textContaining('Edited after the last save'), findsOneWidget);

    await tester.tap(find.text('Restore'));
    await tester.pump();
    expect(restored, 1);

    await tester.tap(find.text('Discard'));
    await tester.pump();
    expect(discarded, 1);
  });

  testWidgets('says so when the song was never saved at all', (tester) async {
    await tester.pumpWidget(
      harness(
        JournalRecovery(
          Song.blank(id: 'y', title: 'Brand new'),
          DateTime.utc(2026),
          null,
        ),
        onRestore: () {},
        onDiscard: () {},
      ),
    );
    await tester.pump();
    expect(find.textContaining('never saved'), findsOneWidget);
  });
}
