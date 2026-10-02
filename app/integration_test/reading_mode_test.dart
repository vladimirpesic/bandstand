import 'package:bandstand/bridge/frb_generated.dart';
import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:bandstand/domain/song/chord_leadsheet.dart';
import 'package:bandstand/domain/song/lead_sheet_item.dart';
import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/io/harmony_assets.dart';
import 'package:bandstand/render/chart_view.dart';
import 'package:bandstand/ui/screens/reading_mode_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Reading the chart in Nashville numbers, which is `docs/rules/chart-layout.md`
/// §6b.
///
/// In `integration_test/` rather than `test/` for the same reason the page
/// turner is: reading mode reads the transport, and the transport is Rust.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await installHarmonyAssets();
    await RustLib.init();
  });

  /// A ii–V–I in F, so the tune is not in the key the numbers are trivially
  /// equal to.
  Song tune() =>
      Song.blank(id: 'numbers', title: 'Blues in F', barCount: 4).copyWith(
        key: KeySignature.parse('F'),
        leadSheet: ChordLeadSheet(
          barCount: 4,
          items: <LeadSheetItem>[
            CliChordSymbol(Position(0), ExtChordSymbol.parse('Gm7')),
            CliChordSymbol(Position(1), ExtChordSymbol.parse('C7')),
            CliChordSymbol(Position(2), ExtChordSymbol.parse('Fmaj7')),
            CliChordSymbol(Position(3), ExtChordSymbol.parse('Fmaj7')),
          ],
        ),
      );

  var opened = 0;

  Future<void> open(WidgetTester tester, {int transposition = 0}) async {
    opened++;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: ReadingModeScreen(
            key: ValueKey<int>(opened),
            song: tune(),
            transposition: transposition,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// What the chart is being drawn from — read off the widget rather than
  /// through a test-only getter, the way the page turner reads its offset.
  KeySignature? numbersIn(WidgetTester tester) =>
      tester.widget<ChartView>(find.byType(ChartView)).numbersIn;

  Finder toggle() => find.byTooltip('Read the chart in Nashville numbers');

  testWidgets('the chart starts in letters', (tester) async {
    await open(tester);
    expect(numbersIn(tester), isNull);
    expect(toggle(), findsOneWidget);
  });

  testWidgets('the toggle switches the chart to numbers and back', (
    tester,
  ) async {
    await open(tester);

    await tester.tap(toggle());
    await tester.pumpAndSettle();
    expect(
      numbersIn(tester),
      KeySignature.parse('F'),
      reason: 'the numbers should count from the song\'s own written key',
    );

    // The tooltip flips too, so the control says what it will do next rather
    // than what it did.
    final back = find.byTooltip('Read the chart in letters');
    expect(back, findsOneWidget);
    await tester.tap(back);
    await tester.pumpAndSettle();
    expect(numbersIn(tester), isNull);
  });

  testWidgets('the banner says the chart is in numbers, and in which key', (
    tester,
  ) async {
    await open(tester);
    expect(find.textContaining('numbers in'), findsNothing);

    await tester.tap(toggle());
    await tester.pumpAndSettle();
    // Said explicitly because the numbers do not move when the transposition
    // does; without it that looks like a bug rather than the point.
    expect(find.textContaining('numbers in F'), findsOneWidget);
  });

  testWidgets('numbers count from the written key even when transposed', (
    tester,
  ) async {
    // A player reading up a tone still reads the same numbers — that is what
    // the system is for. The key handed to the chart must be the written one,
    // not the transposed one.
    await open(tester, transposition: 2);
    await tester.tap(toggle());
    await tester.pumpAndSettle();

    expect(numbersIn(tester), KeySignature.parse('F'));
    // Both facts are on the banner at once, and neither cancels the other: the
    // band is playing it up a tone, and the reader is reading numbers.
    expect(find.textContaining('reading +2'), findsOneWidget);
    expect(find.textContaining('numbers in F'), findsOneWidget);
  });

  testWidgets('paging stops at the end of the chart', (tester) async {
    opened++;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: ReadingModeScreen(
            key: ValueKey<int>(opened),
            song: Song.blank(id: 'long', title: 'Long Tune', barCount: 40),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // How far the chart has been pushed up, read off the widget the way the
    // page turner reads its offset.
    double offset() => tester
        .widgetList<Transform>(
          find.ancestor(
            of: find.byType(ChartView),
            matching: find.byType(Transform),
          ),
        )
        .single
        .transform
        .getTranslation()
        .y;

    final offsets = <double>[];
    for (var i = 0; i < 12; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pump();
      offsets.add(offset());
    }

    // The last pages move nothing: the chart's end is already at the bottom
    // of the screen. Without the cap the offset grows without bound and the
    // chart scrolls clean off.
    expect(offsets.last, offsets[offsets.length - 2]);
    expect(offsets.last, lessThan(0));
  });
}
