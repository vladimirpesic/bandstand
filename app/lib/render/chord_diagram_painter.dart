import 'dart:ui' as ui;

import 'package:bandstand/domain/harmony/diagrams/chord_diagram.dart';
import 'package:flutter/material.dart';

/// How a fretboard diagram is drawn.
///
/// `docs/rules/chord-diagrams.md` §5. Sized for reading at arm's length rather
/// than at 2 m: a diagram is something a player looks down at while working a
/// tune out, unlike the chart itself.
class ChordDiagramStyle {
  /// Create a style.
  const ChordDiagramStyle({
    required this.line,
    required this.dot,
    required this.text,
    required this.muted,
    this.stringSpacing = 14,
    this.fretSpacing = 18,
    this.fretCount = 5,
    this.dotRadius = 5,
  });

  /// From a colour scheme, which is how the app builds one.
  factory ChordDiagramStyle.of(ColorScheme scheme) => ChordDiagramStyle(
    line: scheme.onSurfaceVariant,
    dot: scheme.primary,
    text: scheme.onSurface,
    muted: scheme.onSurfaceVariant.withValues(alpha: 0.6),
  );

  /// The grid.
  final Color line;

  /// Stopped strings.
  final Color dot;

  /// Labels.
  final Color text;

  /// The cross over an unplayed string.
  final Color muted;

  /// Between strings.
  final double stringSpacing;

  /// Between frets.
  final double fretSpacing;

  /// How many fret rows to draw.
  final int fretCount;

  /// A fingertip.
  final double dotRadius;

  /// The size a diagram needs, for a given string count.
  ///
  /// Two-digit base frets write a wider label beside the grid, so they get
  /// more left margin; at the nut nothing is written and the margin is the
  /// smaller one.
  Size sizeFor(int strings, {int baseFret = 1}) => Size(
    (strings - 1) * stringSpacing + 34 + (baseFret.toString().length - 1) * 12,
    fretCount * fretSpacing + 30,
  );

  @override
  bool operator ==(Object other) =>
      other is ChordDiagramStyle &&
      other.line == line &&
      other.dot == dot &&
      other.text == text &&
      other.muted == muted &&
      other.stringSpacing == stringSpacing &&
      other.fretSpacing == fretSpacing &&
      other.fretCount == fretCount &&
      other.dotRadius == dotRadius;

  @override
  int get hashCode => Object.hash(
    line,
    dot,
    text,
    muted,
    stringSpacing,
    fretSpacing,
    fretCount,
    dotRadius,
  );
}

/// Draws one chord shape.
///
/// A `CustomPainter` for the same reason the chart is one (§8.1): this is a
/// grid with dots on it, and no library is smaller than the code that draws it.
class ChordDiagramPainter extends CustomPainter {
  /// Create a painter.
  ChordDiagramPainter({required this.shape, required this.style, this.label});

  /// The shape to draw.
  final ChordShape shape;

  /// How to draw it.
  final ChordDiagramStyle style;

  /// What to write above it, usually the chord symbol.
  final String? label;

  @override
  void paint(Canvas canvas, Size size) {
    final strings = shape.stringCount;
    final width = (strings - 1) * style.stringSpacing;
    final left = (size.width - width) / 2;
    final top = 20.0;

    final grid = Paint()
      ..color = style.line
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    _paintLabel(canvas, size);

    // The nut is heavier, but only when the diagram starts at the nut.
    if (shape.baseFret == 1) {
      canvas.drawLine(
        Offset(left - 0.5, top),
        Offset(left + width + 0.5, top),
        Paint()
          ..color = style.line
          ..strokeWidth = 3,
      );
    } else {
      _paintBaseFret(canvas, left, top);
    }

    for (var string = 0; string < strings; string++) {
      final x = left + string * style.stringSpacing;
      canvas.drawLine(
        Offset(x, top),
        Offset(x, top + style.fretCount * style.fretSpacing),
        grid,
      );
    }
    for (var fret = 0; fret <= style.fretCount; fret++) {
      final y = top + fret * style.fretSpacing;
      canvas.drawLine(Offset(left, y), Offset(left + width, y), grid);
    }

    // Under the dots, so a barred fingertip still reads as a fingertip.
    _paintBarre(canvas, left, top);

    for (var string = 0; string < strings; string++) {
      final fret = shape.frets[string];
      final x = left + string * style.stringSpacing;
      if (fret < 0) {
        _paintCross(canvas, x, top - 9);
      } else if (fret == 0) {
        _paintOpen(canvas, x, top - 9);
      } else if (fret <= style.fretCount) {
        canvas.drawCircle(
          Offset(x, top + (fret - 0.5) * style.fretSpacing),
          style.dotRadius,
          Paint()..color = style.dot,
        );
      }
    }
  }

  void _paintBarre(Canvas canvas, double left, double top) {
    final barre = shape.barre;
    if (barre == null || barre.fret > style.fretCount) {
      return;
    }
    final from = left + barre.fromString * style.stringSpacing;
    final to = left + barre.toString_ * style.stringSpacing;
    final y = top + (barre.fret - 0.5) * style.fretSpacing;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(
          from - style.dotRadius,
          y - style.dotRadius,
          to + style.dotRadius,
          y + style.dotRadius,
        ),
        Radius.circular(style.dotRadius),
      ),
      Paint()..color = style.dot,
    );
  }

  void _paintOpen(Canvas canvas, double x, double y) {
    canvas.drawCircle(
      Offset(x, y),
      4,
      Paint()
        ..color = style.line
        ..strokeWidth = 1.2
        ..style = PaintingStyle.stroke,
    );
  }

  void _paintCross(Canvas canvas, double x, double y) {
    final pen = Paint()
      ..color = style.muted
      ..strokeWidth = 1.4;
    canvas.drawLine(Offset(x - 3.5, y - 3.5), Offset(x + 3.5, y + 3.5), pen);
    canvas.drawLine(Offset(x + 3.5, y - 3.5), Offset(x - 3.5, y + 3.5), pen);
  }

  void _paintLabel(Canvas canvas, Size size) {
    final text = label;
    if (text == null) {
      return;
    }
    final painter = _text(text, style.text, 13, FontWeight.w600);
    painter.paint(canvas, Offset((size.width - painter.width) / 2, 0));
    painter.dispose();
  }

  /// The fret the diagram starts at, written beside it when it is not 1.
  void _paintBaseFret(Canvas canvas, double left, double top) {
    final painter = _text('${shape.baseFret}', style.text, 11, FontWeight.w400);
    painter.paint(
      canvas,
      Offset(
        left - painter.width - 6,
        top + style.fretSpacing * 0.5 - painter.height / 2,
      ),
    );
    painter.dispose();
  }

  TextPainter _text(
    String value,
    Color colour,
    double size,
    FontWeight weight,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(color: colour, fontSize: size, fontWeight: weight),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    return painter;
  }

  @override
  bool shouldRepaint(ChordDiagramPainter old) =>
      old.shape != shape || old.label != label || old.style != style;
}

/// One diagram, sized for its instrument.
class ChordDiagramView extends StatelessWidget {
  /// Create a view.
  const ChordDiagramView({
    required this.shape,
    this.label,
    this.style,
    super.key,
  });

  /// The shape.
  final ChordShape shape;

  /// What to write above it.
  final String? label;

  /// How to draw it, or the theme's own.
  final ChordDiagramStyle? style;

  @override
  Widget build(BuildContext context) {
    final drawing =
        style ?? ChordDiagramStyle.of(Theme.of(context).colorScheme);
    // A shape reaching past the drawn rows would lose dots (or its whole
    // barre) to clipping, silently. Say so instead of drawing a diagram that
    // is missing fingers.
    final overflow =
        shape.highestFret > drawing.fretCount ||
        (shape.barre != null && shape.barre!.fret > drawing.fretCount);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        CustomPaint(
          size: drawing.sizeFor(shape.stringCount, baseFret: shape.baseFret),
          painter: ChordDiagramPainter(
            shape: shape,
            style: drawing,
            label: label,
          ),
        ),
        if (overflow)
          Icon(
            Icons.keyboard_arrow_down,
            key: const ValueKey<String>('chord-diagram-overflow'),
            size: 14,
            color: drawing.text,
          ),
      ],
    );
  }
}
