import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/ui/screens/practice_screen.dart';
import 'package:bandstand/ui/theme/bandstand_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../domain/harmony/harmony_test_support.dart';

/// The loop defaults (bars 1–8) must land inside whatever form the song has.
void main() {
  installTestHarmony();

  testWidgets('the loop defaults stay inside a short form', (tester) async {
    final song = Song.blank(id: 'shorty', title: 'Shorty', barCount: 6);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: BandstandTheme.dark(),
          home: PracticeScreen(song: song),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Loop a section'));
    await tester.pump();

    // The "to bar" stepper shows the form's last bar, not the 8-bar default.
    expect(find.text('8'), findsNothing);
    expect(find.text('6'), findsOneWidget);
  });
}
