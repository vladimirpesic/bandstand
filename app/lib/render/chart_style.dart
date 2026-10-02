import 'package:flutter/material.dart';

/// How many bars a line holds before measurement gets a say.
enum ChartDensity {
  /// Two bars to a line: a phone in portrait, or a chart with many chords.
  dense(2, 'Dense'),

  /// Four bars to a line: what an ordinary chart looks like.
  normal(4, 'Normal'),

  /// Eight bars to a line: a simple tune on a wide screen.
  wide(8, 'Wide');

  const ChartDensity(this.preferredBarsPerLine, this.label);

  /// The starting point, before the minimum bar width is applied.
  final int preferredBarsPerLine;

  /// What the setting is called in the UI.
  final String label;
}

/// Type sizes, spacing and colours for the chart painter.
///
/// Everything scales from [chordSize]: the constraint is legibility at two
/// metres (§8.1), so the chord type is chosen first and the rest follows from
/// it. Nothing here is a magic number that has to be re-tuned when the type
/// changes.
@immutable
class ChartStyle {
  /// Create a style.
  const ChartStyle({
    required this.chordSize,
    required this.density,
    required this.foreground,
    required this.muted,
    required this.accent,
    required this.gridLine,
    required this.cursor,
    this.showBarNumbers = true,
  });

  /// A style for reading on a stand: large type, high contrast.
  factory ChartStyle.reading(ColorScheme scheme, {double chordSize = 46}) =>
      ChartStyle(
        chordSize: chordSize,
        density: ChartDensity.normal,
        foreground: scheme.onSurface,
        muted: scheme.onSurfaceVariant,
        accent: scheme.primary,
        gridLine: scheme.outlineVariant,
        cursor: scheme.primary,
      );

  /// A style for editing at a desk: smaller type, bar numbers on every bar.
  factory ChartStyle.editing(ColorScheme scheme, {double chordSize = 26}) =>
      ChartStyle(
        chordSize: chordSize,
        density: ChartDensity.normal,
        foreground: scheme.onSurface,
        muted: scheme.onSurfaceVariant,
        accent: scheme.primary,
        gridLine: scheme.outlineVariant,
        cursor: scheme.primary,
      );

  /// A style for paper: black on white, at print size.
  ///
  /// Takes no `ColorScheme`, because paper has none. A chart is printed on
  /// white whatever the app's theme is, and a dark-theme chart rendered to a
  /// PDF would be a page of ink (`docs/rules/exporters.md` §4).
  factory ChartStyle.printed({double chordSize = 34}) => ChartStyle(
    chordSize: chordSize,
    density: ChartDensity.normal,
    foreground: const Color(0xFF000000),
    muted: const Color(0xFF555555),
    accent: const Color(0xFF000000),
    gridLine: const Color(0xFF999999),
    // Never drawn on paper — the cursor is a playback artefact — but the field
    // is required, and leaving it a theme colour would be a trap for whoever
    // next passes a cursor in.
    cursor: const Color(0x00000000),
  );

  /// Height of a chord symbol's type, in logical pixels.
  final double chordSize;

  /// How many bars a line prefers.
  final ChartDensity density;

  /// Colour of chord symbols and bar lines.
  final Color foreground;

  /// Colour of bar numbers and annotations.
  final Color muted;

  /// Colour of section letters and structural marks.
  final Color accent;

  /// Colour of the bar grid.
  final Color gridLine;

  /// Colour of the playback cursor.
  final Color cursor;

  /// Whether bar numbers are drawn.
  final bool showBarNumbers;

  /// Narrowest a bar may be before the line takes fewer bars (§8.1 §2).
  ///
  /// Four chord characters' worth: enough for `Bbm7b5` to fit without the bar
  /// looking crowded.
  double get minimumBarWidth => chordSize * 4.4;

  /// Height of the chord row.
  double get chordRowHeight => chordSize * 1.35;

  /// Height reserved above a bar for section letters, endings and marks.
  double get markRowHeight => chordSize * 0.95;

  /// Height reserved below a bar for annotations.
  double get annotationRowHeight => chordSize * 0.55;

  /// Space between lines.
  double get lineGap => chordSize * 0.55;

  /// Padding around the whole chart.
  double get pagePadding => chordSize * 0.6;

  /// Padding inside a bar, left and right.
  double get barPadding => chordSize * 0.22;

  /// Thickness of an ordinary bar line.
  double get barLineWidth => (chordSize * 0.05).clamp(1.0, 3.0);

  /// Thickness of a repeat barline's heavy stroke.
  double get repeatLineWidth => barLineWidth * 3;

  /// Size of a section letter.
  double get sectionSize => chordSize * 0.72;

  /// Size of a bar number.
  double get barNumberSize => chordSize * 0.36;

  /// Size of a structural mark's label.
  double get markSize => chordSize * 0.42;

  /// Size of an annotation.
  double get annotationSize => chordSize * 0.42;

  /// Height of one line of chart, marks and annotations included.
  double get lineHeight => markRowHeight + chordRowHeight + annotationRowHeight;

  /// A copy with some fields replaced.
  ChartStyle copyWith({
    double? chordSize,
    ChartDensity? density,
    Color? foreground,
    Color? muted,
    Color? accent,
    Color? gridLine,
    Color? cursor,
    bool? showBarNumbers,
  }) => ChartStyle(
    chordSize: chordSize ?? this.chordSize,
    density: density ?? this.density,
    foreground: foreground ?? this.foreground,
    muted: muted ?? this.muted,
    accent: accent ?? this.accent,
    gridLine: gridLine ?? this.gridLine,
    cursor: cursor ?? this.cursor,
    showBarNumbers: showBarNumbers ?? this.showBarNumbers,
  );

  @override
  bool operator ==(Object other) =>
      other is ChartStyle &&
      other.chordSize == chordSize &&
      other.density == density &&
      other.foreground == foreground &&
      other.muted == muted &&
      other.accent == accent &&
      other.gridLine == gridLine &&
      other.cursor == cursor &&
      other.showBarNumbers == showBarNumbers;

  @override
  int get hashCode => Object.hash(
    chordSize,
    density,
    foreground,
    muted,
    accent,
    gridLine,
    cursor,
    showBarNumbers,
  );
}
