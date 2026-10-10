import 'dart:math' as math;

import 'package:bandstand/domain/song/lead_sheet_item.dart';
import 'package:flutter/material.dart';

import 'chart_layout.dart';
import 'chart_style.dart';
import 'chord_measurer.dart';

/// Draws the chart: bars, chords, sections, repeats, endings and marks.
///
/// Everything it needs is in the [ChartLayout] it is given, so it repaints only
/// when the layout changes — the cursor is a separate layer (§8.1 §6).
class ChartPainter extends CustomPainter {
  /// Create a painter.
  ChartPainter({
    required this.layout,
    required this.measurer,
    this.selectedBar,
  });

  /// The geometry to draw.
  final ChartLayout layout;

  /// The measurer whose text style the chords were measured with.
  final TextPainterChordMeasurer measurer;

  /// A written bar to outline, for the editor's selection.
  final int? selectedBar;

  ChartStyle get _style => layout.style;

  @override
  void paint(Canvas canvas, Size size) {
    for (final line in layout.lines) {
      for (final bar in line.bars) {
        _paintBar(canvas, bar, isLast: bar == line.bars.last);
      }
    }
  }

  void _paintBar(Canvas canvas, LaidOutBar bar, {required bool isLast}) {
    final style = _style;
    final chordTop = bar.rect.top + style.markRowHeight;
    final chordBottom = chordTop + style.chordRowHeight;

    if (selectedBar == bar.sourceBar) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(
            bar.rect.left,
            chordTop,
            bar.rect.right,
            chordBottom,
          ).deflate(1),
          Radius.circular(style.chordSize * 0.12),
        ),
        Paint()
          ..color = style.accent.withValues(alpha: 0.16)
          ..style = PaintingStyle.fill,
      );
    }

    final grid = Paint()
      ..color = style.gridLine
      ..strokeWidth = style.barLineWidth
      ..style = PaintingStyle.stroke;

    // The bar's own left line, and the closing line of the last bar on a row.
    canvas.drawLine(
      Offset(bar.rect.left, chordTop),
      Offset(bar.rect.left, chordBottom),
      grid,
    );
    if (isLast) {
      canvas.drawLine(
        Offset(bar.rect.right, chordTop),
        Offset(bar.rect.right, chordBottom),
        grid,
      );
    }

    if (bar.repeatStart) {
      _paintRepeat(
        canvas,
        bar.rect.left,
        chordTop,
        chordBottom,
        opensRight: true,
      );
    }
    if (bar.repeatEnd) {
      _paintRepeat(
        canvas,
        bar.rect.right,
        chordTop,
        chordBottom,
        opensRight: false,
      );
    }

    _paintChords(canvas, bar, chordTop);
    _paintMarks(canvas, bar);
    _paintAnnotations(canvas, bar, chordBottom);
  }

  void _paintRepeat(
    Canvas canvas,
    double x,
    double top,
    double bottom, {
    required bool opensRight,
  }) {
    final style = _style;
    final heavy = Paint()
      ..color = style.foreground
      ..strokeWidth = style.repeatLineWidth
      ..style = PaintingStyle.stroke;
    final offset = opensRight
        ? style.repeatLineWidth * 0.5
        : -style.repeatLineWidth * 0.5;
    canvas.drawLine(Offset(x + offset, top), Offset(x + offset, bottom), heavy);

    final dot = Paint()..color = style.foreground;
    final dotX = opensRight
        ? x + style.repeatLineWidth * 2.2
        : x - style.repeatLineWidth * 2.2;
    final radius = style.repeatLineWidth * 0.55;
    final middle = (top + bottom) / 2;
    final spread = (bottom - top) * 0.16;
    canvas
      ..drawCircle(Offset(dotX, middle - spread), radius, dot)
      ..drawCircle(Offset(dotX, middle + spread), radius, dot);
  }

  void _paintChords(Canvas canvas, LaidOutBar bar, double chordTop) {
    final style = _style;
    for (final chord in bar.chords) {
      final size = _fittedSize(chord.text, chord.width);
      _text(
        canvas,
        chord.text,
        measurer.textStyle(size).copyWith(color: style.foreground),
        Offset(
          bar.rect.left + chord.left,
          chordTop + (style.chordRowHeight - size) / 2,
        ),
      );
    }
  }

  /// Recover the size a chord was measured at, so what is drawn matches.
  double _fittedSize(String text, double width) {
    var size = _style.chordSize;
    final floor = _style.chordSize * 0.55;
    while (size > floor && measurer.measure(text, size) > width + 0.5) {
      size = math.max(floor, size * 0.92);
    }
    return size;
  }

  void _paintMarks(Canvas canvas, LaidOutBar bar) {
    final style = _style;
    final markTop = bar.rect.top;
    final section = bar.section;

    if (bar.startsSection && section != null) {
      _text(
        canvas,
        section.name,
        TextStyle(
          fontSize: style.sectionSize,
          fontWeight: FontWeight.w700,
          color: style.accent,
          height: 1,
        ),
        Offset(bar.rect.left + style.barPadding, markTop),
      );
    }

    if (style.showBarNumbers) {
      _text(
        canvas,
        '${bar.displayNumber}',
        TextStyle(fontSize: style.barNumberSize, color: style.muted, height: 1),
        Offset(
          bar.rect.left + style.barPadding,
          markTop + style.markRowHeight - style.barNumberSize * 1.15,
        ),
      );
    }

    if (bar.showsTimeSignature) {
      _text(
        canvas,
        '${bar.timeSignature}',
        TextStyle(
          fontSize: style.markSize,
          fontWeight: FontWeight.w600,
          color: style.muted,
          height: 1,
        ),
        Offset(
          bar.rect.left + style.barPadding + style.sectionSize * 1.6,
          markTop + style.markRowHeight - style.markSize * 1.15,
        ),
      );
    }

    final ending = bar.ending;
    if (ending != null) {
      final bracket = Paint()
        ..color = style.accent
        ..strokeWidth = style.barLineWidth
        ..style = PaintingStyle.stroke;
      final y = markTop + style.markRowHeight * 0.18;
      canvas.drawLine(
        Offset(bar.rect.left, y),
        Offset(bar.rect.right, y),
        bracket,
      );
      if (bar.endingIsFirstBar) {
        canvas.drawLine(
          Offset(bar.rect.left, y),
          Offset(bar.rect.left, y + style.markRowHeight * 0.45),
          bracket,
        );
        _text(
          canvas,
          '${ending.passNumbers.join(', ')}.',
          TextStyle(
            fontSize: style.markSize,
            fontWeight: FontWeight.w600,
            color: style.accent,
            height: 1,
          ),
          Offset(
            bar.rect.left + style.barPadding * 1.4,
            y + style.markRowHeight * 0.08,
          ),
        );
      }
    }

    if (bar.marks.isNotEmpty) {
      final label = bar.marks.map(markLabel).join('  ');
      final painter = _painterFor(
        label,
        TextStyle(
          fontSize: style.markSize,
          fontWeight: FontWeight.w600,
          color: style.accent,
          height: 1,
        ),
      );
      final headMark = bar.marks.any((m) => m.anchor == BarAnchor.head);
      final x = headMark
          ? bar.rect.left + style.barPadding
          : bar.rect.right - style.barPadding - painter.width;
      painter.paint(
        canvas,
        Offset(x, markTop + style.markRowHeight - style.markSize * 1.15),
      );
      painter.dispose();
    }
  }

  /// How a navigation mark is written on the chart.
  ///
  /// The segno and coda glyphs are outside the basic plane; they are written as
  /// escapes so this file stays readable in every editor.
  static String markLabel(NavigationMark mark) => switch (mark) {
    NavigationMark.segno => '\u{1D10B}',
    NavigationMark.coda => '\u{1D10C}',
    NavigationMark.toCoda => 'To \u{1D10C}',
    _ => mark.label,
  };

  void _paintAnnotations(Canvas canvas, LaidOutBar bar, double chordBottom) {
    if (bar.annotations.isEmpty) {
      return;
    }
    _text(
      canvas,
      bar.annotations.join(' - '),
      TextStyle(
        fontSize: _style.annotationSize,
        color: _style.muted,
        fontStyle: FontStyle.italic,
        height: 1,
      ),
      Offset(
        bar.rect.left + _style.barPadding,
        chordBottom + _style.annotationRowHeight * 0.15,
      ),
    );
  }

  TextPainter _painterFor(String text, TextStyle style) => TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();

  void _text(Canvas canvas, String text, TextStyle style, Offset at) {
    _painterFor(text, style)
      ..paint(canvas, at)
      ..dispose();
  }

  @override
  bool shouldRepaint(ChartPainter old) =>
      old.layout != layout || old.selectedBar != selectedBar;
}

/// Draws the playback cursor, and nothing else.
///
/// A separate layer so moving it does not redraw the chart: §3 budgets 4 ms for
/// a cursor frame.
class CursorPainter extends CustomPainter {
  /// Create a cursor painter.
  CursorPainter({
    required this.layout,
    required this.sourceBar,
    required this.beatFraction,
  });

  /// The chart the cursor moves over.
  final ChartLayout layout;

  /// The written bar the cursor is in, or null to draw nothing.
  final int? sourceBar;

  /// How far through the bar, 0 to 1.
  final double beatFraction;

  @override
  void paint(Canvas canvas, Size size) {
    final wanted = sourceBar;
    final bar = wanted == null ? null : layout.barFor(wanted);
    if (bar == null) {
      return;
    }
    final style = layout.style;
    final top = bar.rect.top + style.markRowHeight;
    final bottom = top + style.chordRowHeight;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(bar.rect.left, top, bar.rect.right, bottom).deflate(1),
        Radius.circular(style.chordSize * 0.12),
      ),
      Paint()..color = style.cursor.withValues(alpha: 0.18),
    );

    final x = bar.rect.left + bar.rect.width * beatFraction.clamp(0.0, 1.0);
    canvas.drawLine(
      Offset(x, top),
      Offset(x, bottom),
      Paint()
        ..color = style.cursor
        ..strokeWidth = style.barLineWidth * 1.6,
    );
  }

  @override
  bool shouldRepaint(CursorPainter old) =>
      old.layout != layout ||
      old.sourceBar != sourceBar ||
      old.beatFraction != beatFraction;
}
