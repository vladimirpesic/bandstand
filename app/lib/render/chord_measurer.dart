import 'package:flutter/painting.dart';

import 'chart_layout.dart';

/// Measures chord symbols with Flutter's text engine, and remembers what it
/// measured.
///
/// Laying out a 32-bar chart measures a few dozen symbols, and a reflow
/// measures them again at a new size. The cache makes reflow free, which is
/// what keeps a window drag smooth.
///
/// The cache never needs invalidating: the font family and weight are fixed
/// at construction, so a cached width stays correct for the life of the
/// object, and each [ChartView] owns its measurer — a new font means a new
/// view, not a cleared cache.
class TextPainterChordMeasurer implements ChordMeasurer {
  /// Create a measurer.
  TextPainterChordMeasurer({
    this.fontFamily,
    this.fontWeight = FontWeight.w600,
  });

  /// The family chord symbols are drawn in, or null for the platform default.
  final String? fontFamily;

  /// The weight they are drawn at.
  final FontWeight fontWeight;

  final Map<String, double> _cache = <String, double>{};

  @override
  double measure(String text, double size) {
    final key = '$size $text';
    final cached = _cache[key];
    if (cached != null) {
      return cached;
    }
    final painter = TextPainter(
      text: TextSpan(text: text, style: textStyle(size)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    _cache[key] = width;
    return width;
  }

  /// The style a chord symbol is drawn in at [size].
  ///
  /// Shared with the painter, so what is measured is what is drawn.
  TextStyle textStyle(double size) => TextStyle(
    fontFamily: fontFamily,
    fontSize: size,
    fontWeight: fontWeight,
    height: 1,
  );
}
