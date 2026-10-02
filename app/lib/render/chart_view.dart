import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:bandstand/domain/song/chord_leadsheet.dart';
import 'package:flutter/material.dart';

import 'chart_layout.dart';
import 'chart_painter.dart';
import 'chart_style.dart';
import 'chord_measurer.dart';

/// Where the playback cursor is, on the written page.
class ChartCursor {
  /// Create a cursor position.
  const ChartCursor({required this.sourceBar, required this.beatFraction});

  /// The cursor is not shown.
  static const ChartCursor hidden = ChartCursor(
    sourceBar: null,
    beatFraction: 0,
  );

  /// The written bar the cursor is in, or null to hide it.
  ///
  /// A *written* bar, not a playback bar: a tune with repeats highlights one
  /// place on the page for several bars of music, which is where the player's
  /// eye is (§8.1 §6).
  final int? sourceBar;

  /// How far through the bar, 0 to 1.
  final double beatFraction;

  @override
  bool operator ==(Object other) =>
      other is ChartCursor &&
      other.sourceBar == sourceBar &&
      other.beatFraction == beatFraction;

  @override
  int get hashCode => Object.hash(sourceBar, beatFraction);
}

/// Draws a chart, reflowing to whatever width it is given.
///
/// Two layers behind a [RepaintBoundary]: the chart, which repaints when the
/// song or the width changes, and the cursor, which repaints every frame while
/// playing (§8.1 §6).
class ChartView extends StatefulWidget {
  /// Create a chart view.
  const ChartView({
    required this.sheet,
    required this.style,
    this.cursor = ChartCursor.hidden,
    this.transposition = 0,
    this.preference,
    this.numbersIn,
    this.selectedBar,
    this.onBarTapped,
    this.padding = EdgeInsets.zero,
    super.key,
  });

  /// The written page.
  final ChordLeadSheet sheet;

  /// Type sizes, spacing and colours.
  final ChartStyle style;

  /// Where the playback cursor is.
  final ChartCursor cursor;

  /// Semitones to shift the chords by, for display only (§9).
  final int transposition;

  /// How the shifted chords are spelled.
  final SpellingPreference? preference;

  /// Draw the chart in Nashville numbers counted from this key, rather than in
  /// letters. Null draws the letters. See `docs/rules/chart-layout.md` §6b.
  final KeySignature? numbersIn;

  /// A written bar to outline, for the editor.
  final int? selectedBar;

  /// Called when a bar is tapped, with the written bar and the beat.
  final void Function(int sourceBar, double beat)? onBarTapped;

  /// Space around the chart.
  final EdgeInsets padding;

  @override
  State<ChartView> createState() => ChartViewState();
}

/// The state of a [ChartView]. Public so a test can reach [layout].
class ChartViewState extends State<ChartView> {
  final TextPainterChordMeasurer _measurer = TextPainterChordMeasurer();
  ChartLayout? _layout;
  double _laidOutWidth = 0;

  /// The geometry currently drawn, or null before the first layout.
  ChartLayout? get layout => _layout;

  ChartLayout _layoutFor(double width) {
    final existing = _layout;
    if (existing != null &&
        _laidOutWidth == width &&
        existing.style == widget.style) {
      return existing;
    }
    final built = ChartLayoutEngine.layout(
      sheet: widget.sheet,
      width: width,
      style: widget.style,
      measurer: _measurer,
      transposition: widget.transposition,
      numbersIn: widget.numbersIn,
      preference: widget.preference,
    );
    _layout = built;
    _laidOutWidth = width;
    return built;
  }

  @override
  void didUpdateWidget(ChartView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sheet != widget.sheet ||
        oldWidget.style != widget.style ||
        oldWidget.transposition != widget.transposition ||
        oldWidget.preference != widget.preference ||
        oldWidget.numbersIn != widget.numbersIn) {
      _layout = null;
    }
  }

  void _handleTap(TapUpDetails details, ChartLayout layout) {
    final handler = widget.onBarTapped;
    if (handler == null) {
      return;
    }
    final point = details.localPosition;
    final bar = layout.barAt(point.dx, point.dy);
    if (bar != null) {
      handler(bar.sourceBar, layout.beatAt(bar, point.dx));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: widget.padding,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          if (!width.isFinite || width <= 0) {
            return const SizedBox.shrink();
          }
          final layout = _layoutFor(width);
          final size = Size(width, layout.size.height);

          return SingleChildScrollView(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (details) => _handleTap(details, layout),
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: Stack(
                  children: <Widget>[
                    RepaintBoundary(
                      child: CustomPaint(
                        size: size,
                        painter: ChartPainter(
                          layout: layout,
                          measurer: _measurer,
                          selectedBar: widget.selectedBar,
                        ),
                      ),
                    ),
                    RepaintBoundary(
                      child: CustomPaint(
                        size: size,
                        painter: CursorPainter(
                          layout: layout,
                          sourceBar: widget.cursor.sourceBar,
                          beatFraction: widget.cursor.beatFraction,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
