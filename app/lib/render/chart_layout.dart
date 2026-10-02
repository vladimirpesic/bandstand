import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:bandstand/domain/song/chord_leadsheet.dart';
import 'package:bandstand/domain/song/lead_sheet_item.dart';
import 'package:bandstand/domain/song/section.dart';

import 'chart_style.dart';

/// A chord placed inside a bar.
class LaidOutChord {
  /// Create a laid-out chord.
  const LaidOutChord({
    required this.chord,
    required this.beat,
    required this.text,
    required this.left,
    required this.width,
  });

  /// The chord itself.
  final ExtChordSymbol chord;

  /// Where it sits in the bar, in the meter's own beats.
  final double beat;

  /// What is drawn: the formatted symbol, or `N.C.`.
  final String text;

  /// Offset from the bar's left edge.
  final double left;

  /// How wide the symbol measured.
  final double width;

  /// One past its right edge.
  double get right => left + width;
}

/// A bar of the written page, with a place on the canvas.
class LaidOutBar {
  /// Create a laid-out bar.
  const LaidOutBar({
    required this.sourceBar,
    required this.rect,
    required this.timeSignature,
    required this.chords,
    required this.section,
    required this.startsSection,
    required this.repeatStart,
    required this.repeatEnd,
    required this.repeatPlayCount,
    required this.ending,
    required this.endingIsFirstBar,
    required this.marks,
    required this.annotations,
    required this.isPickup,
    required this.showsTimeSignature,
  });

  /// The bar on the written page this draws.
  final int sourceBar;

  /// Where it sits on the canvas.
  final Rect rect;

  /// The meter in this bar.
  final TimeSignature timeSignature;

  /// The chords in it, left to right.
  final List<LaidOutChord> chords;

  /// The section governing it, if any.
  final Section? section;

  /// Whether the section starts here — the letter is drawn above this bar.
  final bool startsSection;

  /// Whether a repeat opens on this bar's left edge.
  final bool repeatStart;

  /// Whether a repeat closes on this bar's right edge.
  final bool repeatEnd;

  /// How many times the repeat closing here is played, if one does.
  final int repeatPlayCount;

  /// The ending bracket covering this bar, if any.
  final CliEnding? ending;

  /// Whether this is the bracket's first bar — where its numbers are drawn.
  final bool endingIsFirstBar;

  /// Navigation marks on this bar.
  final List<NavigationMark> marks;

  /// Annotations under this bar.
  final List<String> annotations;

  /// Whether this is the pickup bar, drawn narrow.
  final bool isPickup;

  /// Whether the meter is written here — the first bar, and any change.
  final bool showsTimeSignature;

  /// The bar number a chart would print: one-based, with a pickup as 0.
  int get displayNumber => isPickup ? 0 : sourceBar + 1;
}

/// One row of bars.
class LaidOutLine {
  /// Create a line.
  const LaidOutLine({
    required this.index,
    required this.bars,
    required this.rect,
  });

  /// Which row this is, from the top.
  final int index;

  /// The bars in it, left to right.
  final List<LaidOutBar> bars;

  /// The row's bounds, marks and annotations included.
  final Rect rect;

  /// The first written bar on this line.
  int get firstSourceBar => bars.first.sourceBar;

  /// The last written bar on this line.
  int get lastSourceBar => bars.last.sourceBar;
}

/// A whole chart, placed on a canvas.
///
/// Pure geometry: no colours, no selection, no playback. The same layout serves
/// the reading mode, the editor and the PDF export.
class ChartLayout {
  /// Create a layout.
  ChartLayout({
    required List<LaidOutLine> lines,
    required this.size,
    required this.style,
    required this.barsPerLine,
  }) : lines = List<LaidOutLine>.unmodifiable(lines);

  /// The rows, top to bottom.
  final List<LaidOutLine> lines;

  /// How much canvas the chart needs.
  final ({double width, double height}) size;

  /// The style it was laid out with.
  final ChartStyle style;

  /// How many bars each full line holds.
  final int barsPerLine;

  /// Every bar, in written order.
  Iterable<LaidOutBar> get bars => lines.expand((line) => line.bars);

  /// Where written bar [sourceBar] was drawn, or null if it is not on the page.
  LaidOutBar? barFor(int sourceBar) {
    for (final line in lines) {
      if (sourceBar >= line.firstSourceBar && sourceBar <= line.lastSourceBar) {
        for (final bar in line.bars) {
          if (bar.sourceBar == sourceBar) {
            return bar;
          }
        }
      }
    }
    return null;
  }

  /// The line containing written bar [sourceBar], or null.
  LaidOutLine? lineFor(int sourceBar) {
    for (final line in lines) {
      if (sourceBar >= line.firstSourceBar && sourceBar <= line.lastSourceBar) {
        return line;
      }
    }
    return null;
  }

  /// The bar under a point on the canvas, or null.
  ///
  /// What a tap in the editor resolves to. The bar's whole row counts, not just
  /// its chord line, so a tap near the top of a bar still lands in it.
  LaidOutBar? barAt(double x, double y) {
    for (final line in lines) {
      if (y < line.rect.top || y > line.rect.bottom) {
        continue;
      }
      for (final bar in line.bars) {
        if (x >= bar.rect.left && x <= bar.rect.right) {
          return bar;
        }
      }
      // Past the last bar of a short line: take the last bar, so a tap in the
      // empty space after a six-bar section still selects something. A tap
      // left of the first bar (or between the bars) is outside the chart, not
      // an invitation to grab the last bar.
      final last = line.bars.last;
      return x > last.rect.right ? last : null;
    }
    return null;
  }

  /// The beat a point falls on within [bar], rounded to the nearest half beat.
  ///
  /// Half a beat is as fine as chord entry needs, and rounding stops a tap
  /// producing a chord at beat 1.037.
  double beatAt(LaidOutBar bar, double x) {
    final inset =
        style.barPadding + (bar.repeatStart ? repeatClearance(style) : 0);
    final trailing =
        style.barPadding + (bar.repeatEnd ? repeatClearance(style) : 0);
    final usable = bar.rect.width - inset - trailing;
    if (usable <= 0) {
      return 0;
    }
    final fraction = ((x - bar.rect.left - inset) / usable).clamp(0.0, 1.0);
    final beats = fraction * bar.timeSignature.upper;
    // A tap at the trailing edge lands one-past-the-last half beat, which is
    // not a beat in this bar at all — clamp to the last half beat.
    return math.min((beats * 2).round() / 2, bar.timeSignature.upper - 0.5);
  }

  @override
  String toString() =>
      'ChartLayout(${lines.length} lines, $barsPerLine bars per line)';
}

/// How much room a repeat barline needs beside a bar's chords.
///
/// The heavy stroke plus its two dots. Shared by the layout and the hit test,
/// so a tap on a repeated bar lands on the beat the chord was drawn at.
double repeatClearance(ChartStyle style) => style.repeatLineWidth * 3.4;

/// Measures a chord symbol, so the engine can lay one out.
///
/// An interface rather than a `TextPainter` directly, so the layout can be
/// tested with a known metric and so the PDF exporter can supply its own.
abstract interface class ChordMeasurer {
  /// The width of [text] drawn at [size].
  double measure(String text, double size);
}

/// Turns a lead sheet into geometry.
///
/// Rules: `docs/rules/chart-layout.md`.
abstract final class ChartLayoutEngine {
  /// Lay [sheet] out into [width] logical pixels.
  ///
  /// [transposition] and [preference] shift the chords for display only; the
  /// stored song is never touched (§9).
  ///
  /// [numbersIn] draws the chart in Nashville numbers counted from that key
  /// instead of in letters. Pass the song's *written* key: a number is an
  /// interval above the tonic, so transposing moves the tonic and every chord
  /// together and the numbers do not change. See `docs/rules/chart-layout.md`
  /// §6b.
  static ChartLayout layout({
    required ChordLeadSheet sheet,
    required double width,
    required ChartStyle style,
    required ChordMeasurer measurer,
    int transposition = 0,
    SpellingPreference? preference,
    KeySignature? numbersIn,
  }) {
    final barsPerLine = _barsPerLine(width, style);
    final groups = _breakIntoLines(sheet, barsPerLine);
    // Which endings cover each bar, resolved once for the whole chart.
    // `_layOutBar` used to answer this by scanning every item on the sheet,
    // once per bar, which made layout quadratic in bar count: a 100-bar chart
    // laid out in 0.35 ms and an 800-bar one in 19.6 ms, past a frame.
    final endingsByBar = _endingsByBar(sheet);

    final usableWidth = width - style.pagePadding * 2;
    final barWidth = usableWidth / barsPerLine;

    final lines = <LaidOutLine>[];
    var y = style.pagePadding;

    for (var lineIndex = 0; lineIndex < groups.length; lineIndex++) {
      final group = groups[lineIndex];
      final bars = <LaidOutBar>[];
      var x = style.pagePadding;

      for (final sourceBar in group) {
        final isPickup = sourceBar == 0 && sheet.hasPickup;
        final signature = sheet.timeSignatureAt(sourceBar);
        final thisWidth = isPickup
            ? barWidth * (sheet.pickupBeats / signature.upper).clamp(0.25, 1.0)
            : barWidth;
        final rect = Rect.fromLTWH(x, y, thisWidth, style.lineHeight);
        bars.add(
          _layOutBar(
            sheet: sheet,
            sourceBar: sourceBar,
            endings: endingsByBar[sourceBar] ?? const <CliEnding>[],
            rect: rect,
            style: style,
            measurer: measurer,
            isPickup: isPickup,
            transposition: transposition,
            preference: preference,
            numbersIn: numbersIn,
          ),
        );
        x += thisWidth;
      }

      lines.add(
        LaidOutLine(
          index: lineIndex,
          bars: bars,
          rect: Rect.fromLTWH(
            style.pagePadding,
            y,
            x - style.pagePadding,
            style.lineHeight,
          ),
        ),
      );
      y += style.lineHeight + style.lineGap;
    }

    return ChartLayout(
      lines: lines,
      size: (
        width: width,
        height: lines.isEmpty
            ? style.pagePadding * 2
            : y - style.lineGap + style.pagePadding,
      ),
      style: style,
      barsPerLine: barsPerLine,
    );
  }

  /// How many bars fit on a line (`docs/rules/chart-layout.md` §2).
  ///
  /// The preferred count, halved until the bars are wide enough to read. Never
  /// below one: a single bar too narrow for its chords is still a bar, and the
  /// chords shrink instead.
  static int _barsPerLine(double width, ChartStyle style) {
    final usable = width - style.pagePadding * 2;
    var count = style.density.preferredBarsPerLine;
    while (count > 1 && usable / count < style.minimumBarWidth) {
      count = count > 4 ? count ~/ 2 : count - 1;
    }
    return math.max(1, count);
  }

  /// Group bars into lines, breaking at every section start (§3).
  /// The narrowest a bar's chord area is allowed to get.
  ///
  /// Enough for one symbol to be drawn at all. Below this the layout is
  /// already unreadable, and what matters is that the chords are still there.
  static const double _minimumUsableWidth = 1;

  static List<List<int>> _breakIntoLines(
    ChordLeadSheet sheet,
    int barsPerLine,
  ) {
    final sectionStarts = <int>{
      for (final section in sheet.sections) section.startBar,
    };
    final lines = <List<int>>[];
    var current = <int>[];

    for (var bar = 0; bar < sheet.barCount; bar++) {
      final breaksHere =
          current.isNotEmpty &&
          (sectionStarts.contains(bar) || current.length >= barsPerLine);
      if (breaksHere) {
        lines.add(current);
        current = <int>[];
      }
      current.add(bar);
    }
    if (current.isNotEmpty) {
      lines.add(current);
    }
    return lines;
  }

  /// The endings covering each bar, by bar.
  ///
  /// An ending spans bars, so this walks each one's span once rather than
  /// asking every bar which endings contain it.
  static Map<int, List<CliEnding>> _endingsByBar(ChordLeadSheet sheet) {
    final byBar = <int, List<CliEnding>>{};
    for (final ending in sheet.items.whereType<CliEnding>()) {
      for (var bar = ending.bar; bar < ending.endBar; bar++) {
        (byBar[bar] ??= <CliEnding>[]).add(ending);
      }
    }
    return byBar;
  }

  static LaidOutBar _layOutBar({
    required ChordLeadSheet sheet,
    required int sourceBar,
    required Rect rect,
    required ChartStyle style,
    required ChordMeasurer measurer,
    required bool isPickup,
    required int transposition,
    required SpellingPreference? preference,
    required KeySignature? numbersIn,
    required List<CliEnding> endings,
  }) {
    final signature = sheet.timeSignatureAt(sourceBar);
    final section = sheet.sectionAt(sourceBar);
    final repeats = sheet.itemsInBarOfType<CliRepeat>(sourceBar);
    final repeatEndItem = repeats.where((r) => !r.isStart).firstOrNull;

    final previousSignature = sourceBar == 0
        ? null
        : sheet.timeSignatureAt(sourceBar - 1);

    final repeatStart = repeats.any((r) => r.isStart);

    return LaidOutBar(
      sourceBar: sourceBar,
      rect: rect,
      timeSignature: signature,
      chords: _layOutChords(
        sheet: sheet,
        sourceBar: sourceBar,
        rect: rect,
        style: style,
        measurer: measurer,
        signature: signature,
        transposition: transposition,
        preference: preference,
        numbersIn: numbersIn,
        repeatStart: repeatStart,
        repeatEnd: repeatEndItem != null,
      ),
      section: section,
      startsSection: section != null && section.startBar == sourceBar,
      repeatStart: repeatStart,
      repeatEnd: repeatEndItem != null,
      repeatPlayCount: repeatEndItem?.playCount ?? 0,
      ending: endings.firstOrNull,
      endingIsFirstBar: endings.any((ending) => ending.bar == sourceBar),
      marks: <NavigationMark>[
        for (final item in sheet.itemsInBarOfType<CliNavigation>(sourceBar))
          item.mark,
      ],
      annotations: <String>[
        for (final item in sheet.itemsInBarOfType<CliAnnotation>(sourceBar))
          item.text,
      ],
      isPickup: isPickup,
      showsTimeSignature:
          sourceBar == 0 ||
          (previousSignature != null && previousSignature != signature),
    );
  }

  /// Place a bar's chords proportionally to their beats, without overlap (§4).
  static List<LaidOutChord> _layOutChords({
    required ChordLeadSheet sheet,
    required int sourceBar,
    required Rect rect,
    required ChartStyle style,
    required ChordMeasurer measurer,
    required TimeSignature signature,
    required int transposition,
    required SpellingPreference? preference,
    required KeySignature? numbersIn,
    required bool repeatStart,
    required bool repeatEnd,
  }) {
    final items = sheet.itemsInBarOfType<CliChordSymbol>(sourceBar);
    if (items.isEmpty) {
      return const <LaidOutChord>[];
    }

    // A repeat barline is a heavy stroke and two dots; chords have to clear it,
    // or the first symbol of a repeated section sits on top of the dots.
    final inset = style.barPadding + (repeatStart ? repeatClearance(style) : 0);
    final trailing =
        style.barPadding + (repeatEnd ? repeatClearance(style) : 0);
    // Floored rather than abandoned. A bar narrower than its own repeat
    // clearance — a very narrow window, or a pickup bar beside two repeat
    // barlines — used to drop *every* chord in it and draw an empty bar,
    // which reads as "there is no harmony here". A cramped symbol is wrong
    // about position; a missing one is wrong about the music.
    final usable = (rect.width - inset - trailing).clamp(
      _minimumUsableWidth,
      double.infinity,
    );

    // Numbers are counted from the written key, so a transposed chart in
    // numbers reads identically to an untransposed one — which is the point of
    // the system, not an oversight (§6b).
    final texts = <String>[
      for (final item in items)
        if (numbersIn != null)
          Nashville.format(item.chord, numbersIn)
        else
          (transposition == 0
                  ? item.chord
                  : item.chord.transposed(
                      transposition,
                      preference: preference,
                    ))
              .format(),
    ];

    // Shrink the whole bar's chords together if they cannot fit side by side.
    var size = style.chordSize;
    var widths = <double>[
      for (final text in texts) measurer.measure(text, size),
    ];
    final gap = style.chordSize * 0.25;
    var total =
        widths.fold(0.0, (sum, w) => sum + w) + gap * (texts.length - 1);
    final floor = style.chordSize * 0.55;
    while (total > usable && size > floor) {
      size = math.max(floor, size * 0.92);
      widths = <double>[for (final text in texts) measurer.measure(text, size)];
      total = widths.fold(0.0, (sum, w) => sum + w) + gap * (texts.length - 1);
    }

    final placed = <LaidOutChord>[];
    var minimumLeft = 0.0;
    for (var i = 0; i < items.length; i++) {
      final beat = items[i].position.beat;
      final wanted = usable * (beat / signature.upper);
      var left = math.max(wanted, minimumLeft);
      // Pull a chord left when the rest of the bar would otherwise not fit —
      // but never past the chord before it, which would overlap them. If both
      // cannot hold, ordering wins: two symbols on top of each other is
      // unreadable, one hanging a little past the bar line is not.
      final remaining =
          widths.skip(i).fold(0.0, (sum, w) => sum + w) +
          gap * (items.length - i - 1);
      final latest = math.max(0.0, usable - remaining);
      if (latest > minimumLeft) {
        left = math.min(left, latest);
      }
      placed.add(
        LaidOutChord(
          chord: items[i].chord,
          beat: beat,
          text: texts[i],
          left: inset + left,
          width: widths[i],
        ),
      );
      minimumLeft = left + widths[i] + gap;
    }
    return placed;
  }
}
