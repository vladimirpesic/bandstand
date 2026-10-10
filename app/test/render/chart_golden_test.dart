import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:bandstand/domain/song/chord_leadsheet.dart';
import 'package:bandstand/domain/song/lead_sheet_item.dart';
import 'package:bandstand/domain/song/section.dart';
import 'package:bandstand/render/chart_style.dart';
import 'package:bandstand/render/chart_view.dart';
import 'package:bandstand/ui/theme/bandstand_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../domain/harmony/harmony_test_support.dart';

/// Golden images for the chart painter (§11.2).
///
/// These catch layout regressions instantly and cost nothing to keep. They use
/// the test font, so they are stable across machines; what they assert is the
/// *arrangement* of the chart, not its typography.
void main() {
  installTestHarmony();

  CliChordSymbol chord(int bar, double beat, String symbol) =>
      CliChordSymbol(Position(bar, beat), ExtChordSymbol.parse(symbol));

  Widget frame(ChordLeadSheet sheet, {double width = 900, ChartStyle? style}) {
    final scheme = ColorScheme.fromSeed(
      seedColor: BandstandTheme.accent,
      brightness: Brightness.dark,
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: scheme.surface,
        body: Center(
          child: SizedBox(
            width: width,
            child: ChartView(
              sheet: sheet,
              style: style ?? ChartStyle.editing(scheme),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('a plain sixteen-bar chart', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final sheet = ChordLeadSheet(
      barCount: 16,
      items: <LeadSheetItem>[
        CliSection(Section(name: 'A', startBar: 0)),
        CliSection(Section(name: 'B', startBar: 8)),
        chord(0, 0, 'Cmaj7'),
        chord(1, 0, 'A7'),
        chord(2, 0, 'Dm7'),
        chord(3, 0, 'G7'),
        chord(4, 0, 'Cmaj7'),
        chord(5, 0, 'A7'),
        chord(6, 0, 'Dm7'),
        chord(7, 0, 'G7'),
        chord(8, 0, 'Fm7'),
        chord(9, 0, 'Bb7'),
        chord(10, 0, 'Ebmaj7'),
        chord(12, 0, 'Dm7'),
        chord(12, 2, 'G7'),
        chord(13, 0, 'Cmaj7'),
      ],
    );

    await tester.pumpWidget(frame(sheet));
    await tester.pump();
    await expectLater(
      find.byType(ChartView),
      matchesGoldenFile('goldens/chart_plain.png'),
    );
  });

  testWidgets('repeats, endings and navigation marks', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 320));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final sheet = ChordLeadSheet(
      barCount: 8,
      items: <LeadSheetItem>[
        CliSection(Section(name: 'A', startBar: 0)),
        CliRepeat(Position(0), isStart: true),
        CliRepeat(Position(5), isStart: false, playCount: 3),
        CliEnding(Position(4), <int>{1}, barCount: 2),
        CliEnding(Position(6), <int>{2}, barCount: 2),
        CliNavigation(Position(2), NavigationMark.segno),
        CliNavigation(Position(7), NavigationMark.dalSegnoAlCoda),
        CliAnnotation(Position(3), 'solo break'),
        chord(0, 0, 'Bbmaj7'),
        chord(1, 0, 'Gm7'),
        chord(2, 0, 'Cm7'),
        chord(3, 0, 'F7'),
        chord(4, 0, 'Bb6'),
        chord(6, 0, 'Bb6'),
        chord(7, 0, 'N.C.'),
      ],
    );

    await tester.pumpWidget(frame(sheet));
    await tester.pump();
    await expectLater(
      find.byType(ChartView),
      matchesGoldenFile('goldens/chart_structure.png'),
    );
  });

  testWidgets('a crowded bar and a pickup', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 220));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final sheet = ChordLeadSheet(
      barCount: 5,
      pickupBeats: 2,
      items: <LeadSheetItem>[
        CliSection(Section(name: 'A', startBar: 0)),
        chord(0, 0, 'G7'),
        chord(1, 0, 'Cmaj7'),
        chord(2, 0, 'Bbm7b5'),
        chord(2, 1, 'Eb7b9'),
        chord(2, 2, 'Abmaj7'),
        chord(2, 3, 'Db13'),
        chord(3, 0, 'Em7'),
        chord(3, 2, 'A7alt'),
      ],
    );

    await tester.pumpWidget(frame(sheet));
    await tester.pump();
    await expectLater(
      find.byType(ChartView),
      matchesGoldenFile('goldens/chart_crowded.png'),
    );
  });

  testWidgets('the same chart reflowed onto a narrow screen', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final sheet = ChordLeadSheet(
      barCount: 8,
      items: <LeadSheetItem>[
        CliSection(Section(name: 'A', startBar: 0)),
        chord(0, 0, 'Cmaj7'),
        chord(1, 0, 'A7'),
        chord(2, 0, 'Dm7'),
        chord(3, 0, 'G7'),
        chord(4, 0, 'Em7'),
        chord(5, 0, 'A7'),
        chord(6, 0, 'Dm7'),
        chord(7, 0, 'G7'),
      ],
    );

    await tester.pumpWidget(frame(sheet, width: 360));
    await tester.pump();
    await expectLater(
      find.byType(ChartView),
      matchesGoldenFile('goldens/chart_narrow.png'),
    );
  });

  testWidgets('reading mode type, at stage size', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1024, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final scheme = ColorScheme.fromSeed(
      seedColor: BandstandTheme.accent,
      brightness: Brightness.dark,
    );
    final sheet = ChordLeadSheet(
      barCount: 8,
      items: <LeadSheetItem>[
        CliSection(Section(name: 'A', startBar: 0)),
        chord(0, 0, 'Cm7'),
        chord(2, 0, 'Fm7'),
        chord(4, 0, 'Dm7b5'),
        chord(5, 0, 'G7alt'),
        chord(6, 0, 'Cm7'),
      ],
    );

    await tester.pumpWidget(
      frame(sheet, width: 1024, style: ChartStyle.reading(scheme)),
    );
    await tester.pump();
    await expectLater(
      find.byType(ChartView),
      matchesGoldenFile('goldens/chart_reading.png'),
    );
  });
}
