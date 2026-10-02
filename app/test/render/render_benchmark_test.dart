import 'dart:io';
import 'dart:ui' as ui;

import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:bandstand/domain/song/chord_leadsheet.dart';
import 'package:bandstand/domain/song/lead_sheet_item.dart';
import 'package:bandstand/render/chart_layout.dart';
import 'package:bandstand/render/chart_painter.dart';
import 'package:bandstand/render/chart_style.dart';
import 'package:bandstand/render/chord_measurer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../domain/harmony/harmony_test_support.dart';

/// The §3 budgets for the chart renderer, and §11.3's *"layout time per
/// 100 bars"*.
///
/// | Metric | Target | Hard limit |
/// | --- | --- | --- |
/// | Chart repaint, cursor frame | 4 ms | 8 ms |
///
/// The cursor budget is the one that matters at 60 fps: §8.1 caches the chart
/// and repaints only the cursor layer, and `ChartView` puts each in its own
/// `RepaintBoundary` so that is what actually happens. This measures the layer
/// alone, which is what a frame costs.
///
/// With `BANDSTAND_ENFORCE_BENCHMARKS` in the environment the targets are
/// asserted exactly. Without it — a developer's machine, a CI container
/// sharing a host — only §3's hard limits are enforced, so the numbers still
/// get printed and compared while a scheduler hiccup on a busy box cannot fail
/// the suite.
///
/// One name, shared with `test/io/importers/musicxml_suite_test.dart` and
/// exported by `benchmarks/run.sh`. There used to be two — this file gated on
/// `BANDSTAND_BENCHMARK` and the importer suite on
/// `BANDSTAND_ENFORCE_BENCHMARKS` — and the runner set neither, so no budget
/// was ever actually enforced.
final bool benchmarksEnabled = Platform.environment.containsKey(
  'BANDSTAND_ENFORCE_BENCHMARKS',
);
void main() {
  installTestHarmony();

  /// A chart of `bars` bars with a chord in every one.
  ChordLeadSheet sheetOf(int bars) {
    const symbols = <String>['Dm7', 'G7', 'Cmaj7', 'A7', 'Fm7', 'Bb7'];
    var sheet = ChordLeadSheet.empty(barCount: bars);
    for (var bar = 0; bar < bars; bar++) {
      sheet = sheet.withItem(
        CliChordSymbol(
          Position(bar),
          ExtChordSymbol.parse(symbols[bar % symbols.length]),
        ),
      );
    }
    return sheet;
  }

  /// The fastest of several runs, in milliseconds.
  ///
  /// Best-of rather than a single shot, for the reason the generation
  /// benchmarks use it: this suite runs concurrently with others and one
  /// scheduler hiccup would turn a 1 ms measurement into a failure.
  double fastestMillis(void Function() work, {int runs = 10}) {
    var best = double.infinity;
    for (var i = 0; i < runs; i++) {
      final watch = Stopwatch()..start();
      work();
      watch.stop();
      final millis = watch.elapsedMicroseconds / 1000;
      if (millis < best) {
        best = millis;
      }
    }
    return best;
  }

  group('the §3 render budgets', () {
    test('laying out 100 bars', () {
      // §11.3 names this one. The engine measures each chord symbol once per
      // size and caches it, so a window drag reflows without re-measuring —
      // which is why the first call is the expensive one and is warmed here.
      final sheet = sheetOf(100);
      final style = ChartStyle.printed();
      final measurer = TextPainterChordMeasurer();
      ChartLayoutEngine.layout(
        sheet: sheet,
        width: 1200,
        style: style,
        measurer: measurer,
      );

      final millis = fastestMillis(
        () => ChartLayoutEngine.layout(
          sheet: sheet,
          width: 1200,
          style: style,
          measurer: measurer,
        ),
      );
      // ignore: avoid_print
      print('BENCH layout, 100 bars: ${millis.toStringAsFixed(2)} ms');
      // Not a §3 budget of its own, but a reflow happens on every resize and
      // must not be felt. A frame is 16 ms.
      expect(
        millis,
        lessThan(benchmarksEnabled ? 16 : 250),
        reason: '$millis ms to lay out 100 bars',
      );
    });

    test('a cursor frame stays inside 4 ms', () {
      // The §3 budget: 4 ms target, 8 ms hard limit. `ChartView` gives the
      // cursor its own RepaintBoundary, so this is what a playing frame costs.
      final sheet = sheetOf(100);
      final measurer = TextPainterChordMeasurer();
      final layout = ChartLayoutEngine.layout(
        sheet: sheet,
        width: 1200,
        style: ChartStyle.printed(),
        measurer: measurer,
      );
      final size = Size(1200, layout.size.height);

      var beat = 0.0;
      final millis = fastestMillis(() {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        beat = (beat + 0.25) % 1.0;
        CursorPainter(
          layout: layout,
          sourceBar: 42,
          beatFraction: beat,
        ).paint(canvas, size);
        recorder.endRecording().dispose();
      });
      // ignore: avoid_print
      print('BENCH cursor frame, 100 bars: ${millis.toStringAsFixed(3)} ms');
      expect(
        millis,
        lessThan(benchmarksEnabled ? 4 : 8),
        reason: '$millis ms a frame against a 4 ms budget (8 ms hard limit)',
      );
    });

    test('a full chart repaint stays inside a frame', () {
      // §3's 4/8 ms row is qualified "cursor frame", and that is the test
      // above. This is the other cost: redrawing the whole chart layer, which
      // happens when the song or the width changes and never per frame — the
      // layer is cached behind its own RepaintBoundary. The bar for it is one
      // frame at 60 fps, because editing a chord must not drop two.
      final sheet = sheetOf(100);
      final measurer = TextPainterChordMeasurer();
      final layout = ChartLayoutEngine.layout(
        sheet: sheet,
        width: 1200,
        style: ChartStyle.printed(),
        measurer: measurer,
      );
      final size = Size(1200, layout.size.height);

      final millis = fastestMillis(() {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        ChartPainter(layout: layout, measurer: measurer).paint(canvas, size);
        recorder.endRecording().dispose();
      });
      // ignore: avoid_print
      print(
        'BENCH full chart repaint, 100 bars: ${millis.toStringAsFixed(2)} ms',
      );
      expect(
        millis,
        lessThan(benchmarksEnabled ? 16 : 250),
        reason: '$millis ms against one 16 ms frame',
      );
    });

    test('a long chart scales sanely', () {
      // The engine must be linear in bars rather than quadratic — a layout
      // that squares is invisible at 32 bars and unusable at 200. It *was*
      // quadratic: every bar asked the sheet which endings covered it by
      // scanning every item on it, so an 800-bar chart took 19.6 ms to lay
      // out, past a frame. This test existed and did not catch it, because
      // comparing 100 bars with 400 leaves only 4× between linear and 16×
      // quadratic, and the slack in the bound covered the difference.
      //
      // 100 against 800 is the discriminating span: linear is 8×, quadratic
      // is 64×, and there is no bound that passes one and fails the other by
      // accident.
      final measurer = TextPainterChordMeasurer();
      final style = ChartStyle.printed();
      final small = sheetOf(100);
      final large = sheetOf(800);
      void layout(ChordLeadSheet sheet) => ChartLayoutEngine.layout(
        sheet: sheet,
        width: 1200,
        style: style,
        measurer: measurer,
      );
      double millisOf(void Function() work) {
        final watch = Stopwatch()..start();
        work();
        watch.stop();
        return watch.elapsedMicroseconds / 1000;
      }

      // Warm both, so neither pays for the measurement cache.
      layout(small);
      layout(large);

      // Interleaved, not one size after the other. The assertion compares two
      // measurements against each other, so they have to see the same
      // machine: measuring all of one and then all of the other let a
      // scheduler hiccup land entirely on the second and fail a linear
      // layout. Taking the best of each round means a hiccup would have to
      // hit every round of one size and none of the other.
      var hundred = double.infinity;
      var eightHundred = double.infinity;
      for (var round = 0; round < 5; round++) {
        final one = millisOf(() => layout(small));
        final eight = millisOf(() => layout(large));
        hundred = one < hundred ? one : hundred;
        eightHundred = eight < eightHundred ? eight : eightHundred;
      }
      // ignore: avoid_print
      print(
        'BENCH layout scaling: 100 bars ${hundred.toStringAsFixed(2)} ms, '
        '800 bars ${eightHundred.toStringAsFixed(2)} ms '
        '(${(eightHundred / hundred).toStringAsFixed(1)}x for 8x the bars)',
      );
      // Eight times the bars, so linear is 8x. 20x is far above anything
      // linear and far below the 64x a quadratic layout would cost.
      expect(
        eightHundred,
        lessThan(hundred * 20 + 2),
        reason: 'layout looks worse than linear in bar count',
      );
      // And the absolute number, because "linear" is no comfort if the
      // constant is enormous: a very long chart still has to lay out inside
      // a frame.
      expect(
        eightHundred,
        lessThan(benchmarksEnabled ? 16 : 250),
        reason: '$eightHundred ms to lay out 800 bars',
      );
    });
  });
}
