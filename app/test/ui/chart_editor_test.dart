import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:bandstand/domain/song/chord_leadsheet.dart';
import 'package:bandstand/domain/song/lead_sheet_item.dart';
import 'package:bandstand/domain/song/section.dart';
import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/domain/song/song_structure.dart';
import 'package:bandstand/state/library_state.dart';
import 'package:bandstand/ui/screens/chart_editor_screen.dart';
import 'package:bandstand/ui/theme/bandstand_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../domain/harmony/harmony_test_support.dart';

/// Caret movement where the meter changes mid-chart (§4.6's general model):
/// the bar being landed in decides what its last beat is.
void main() {
  installTestHarmony();

  Song mixedMeterSong() {
    final sheet = ChordLeadSheet(
      barCount: 8,
      items: <LeadSheetItem>[
        CliSection(Section(name: 'A', startBar: 0)),
        CliSection(
          Section(
            name: 'B',
            startBar: 4,
            timeSignature: TimeSignature.threeFour,
          ),
        ),
      ],
    );
    return Song(
      id: 'mixed',
      title: 'Mixed Meter',
      leadSheet: sheet,
      structure: SongStructure.fromLeadSheet(sheet, rhythmId: 'swing'),
    );
  }

  Widget harness(Song song) => ProviderScope(
    overrides: [songEditorProvider.overrideWith(() => _EditorHolding(song))],
    child: MaterialApp(
      theme: BandstandTheme.dark(),
      home: const ChartEditorScreen(),
    ),
  );

  Future<void> arrow(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pump();
  }

  testWidgets('stepping across the meter change counts in each bar', (
    tester,
  ) async {
    await tester.pumpWidget(harness(mixedMeterSong()));
    await tester.pump();
    expect(find.text('Bar 1  beat 1'), findsOneWidget);

    // Whole-bar steps: bars 1–4 are 4/4, bar 5 is 3/4. The fifth step is
    // three beats wide — the 3/4 bar's width — and lands on bar 6's downbeat.
    // Arithmetic in a global 4/4 beat count would land mid-bar-5 instead.
    for (var i = 0; i < 5; i++) {
      await arrow(tester, LogicalKeyboardKey.arrowRight);
    }
    expect(find.text('Bar 6  beat 1'), findsOneWidget);
  });

  testWidgets('the caret stops at the last half beat of a short final bar', (
    tester,
  ) async {
    await tester.pumpWidget(harness(mixedMeterSong()));
    await tester.pump();

    // To the end of the chart: bars 1–4 in 4/4, bars 5–8 in 3/4.
    for (var i = 0; i < 7; i++) {
      await arrow(tester, LogicalKeyboardKey.arrowRight);
    }
    expect(find.text('Bar 8  beat 1'), findsOneWidget);

    // Half-bar steps to the last half beat (3.5 of 4 beats shown is the bar's
    // own 2.5), and one more step stays put: there is no beat 5 in this bar.
    await arrow(tester, LogicalKeyboardKey.tab);
    for (var i = 0; i < 3; i++) {
      await arrow(tester, LogicalKeyboardKey.arrowRight);
    }
    expect(find.text('Bar 8  beat 3.5'), findsOneWidget);

    // And the fourth press the comment promises (L-TQ8): at the last half
    // beat of the bar there is no beat 5 to step to, so the caret stays put.
    await arrow(tester, LogicalKeyboardKey.arrowRight);
    expect(find.text('Bar 8  beat 3.5'), findsOneWidget);
  });

  testWidgets('a bad chord shows its error as it is typed', (tester) async {
    // `entryIsBad` is computed in `build`, and a `TextField` typing into its
    // controller does not rebuild its parent — so the indicator only appeared
    // if something *else* happened to call `setState`, which is never while
    // the chord is still being typed. `import_dialog.dart` documents the same
    // trap and handles it; this field did not.
    await tester.pumpWidget(harness(mixedMeterSong()));
    await tester.pump();

    await tester.enterText(find.byType(TextField).first, 'Hqqq9');
    await tester.pump();
    expect(find.text('Not a chord symbol'), findsOneWidget);
  });

  testWidgets('a good chord shows no error', (tester) async {
    await tester.pumpWidget(harness(mixedMeterSong()));
    await tester.pump();

    await tester.enterText(find.byType(TextField).first, 'Dm7');
    await tester.pump();
    expect(find.text('Not a chord symbol'), findsNothing);
  });

  testWidgets('the error clears as the chord is corrected', (tester) async {
    await tester.pumpWidget(harness(mixedMeterSong()));
    await tester.pump();

    final field = find.byType(TextField).first;
    await tester.enterText(field, 'Dm7b');
    await tester.pump();
    expect(find.text('Not a chord symbol'), findsOneWidget);

    await tester.enterText(field, 'Dm7b5');
    await tester.pump();
    expect(find.text('Not a chord symbol'), findsNothing);
  });
}

/// An editor whose song is already open, so the screen has something to edit.
class _EditorHolding extends SongEditor {
  _EditorHolding(this.song);

  final Song song;

  @override
  Song? build() => song;
}
