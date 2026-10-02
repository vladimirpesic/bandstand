import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/render/chart_layout.dart';
import 'package:bandstand/render/chart_painter.dart';
import 'package:bandstand/render/chart_style.dart';
import 'package:bandstand/render/chord_measurer.dart';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Writes a chart as a PDF page.
///
/// Rules: `docs/rules/exporters.md` §4. Architecture: **ADR 0010** — the chart
/// is painted by the same `CustomPainter` the screen uses, at print resolution,
/// and the result is embedded as an image.
///
/// The *layout* is genuinely shared, which was the point of §8.1 choosing a
/// painter: `ChartLayoutEngine` reflows to the page exactly as it reflows to a
/// phone, so this is a typeset chart rather than a screenshot of one.
abstract final class PdfExporter {
  /// Dots per inch to raster at.
  ///
  /// Higher makes the file bigger and changes nothing a person can see at
  /// reading distance; lower is visible (ADR 0010).
  static const double dpi = 300;

  /// A4, in points.
  static const double pageWidthPoints = 595.28;

  /// A4 height, in points.
  static const double pageHeightPoints = 841.89;

  /// Margin, in points — about 12 mm.
  static const double marginPoints = 34;

  /// How far the heading (title and composer) reaches, in raster pixels.
  ///
  /// Measured by laying the heading's lines out, not guessed: a constant
  /// reservation came up ~30 px short of a two-line heading, and the chart
  /// drew on top of the composer. Async for the same reason [export] is —
  /// text layout runs on the engine.
  static Future<double> headingHeight(
    Song song,
    double width,
    double scale,
  ) async {
    var y = 0.0;
    for (final line in _headingLines(song, scale)) {
      final painter = _headingPainter(line, width);
      y += painter.height + 6 * scale;
    }
    return y;
  }

  /// Render `song` as a one-page PDF.
  ///
  /// Async because rasterising goes through the engine, which is the same
  /// reason a golden test is async.
  static Future<Uint8List> export(Song song, {int transposition = 0}) async {
    const scale = dpi / 72;
    final contentPoints = pageWidthPoints - marginPoints * 2;
    final pixelWidth = contentPoints * scale;

    // Print-sized type, not screen-sized: the style is built for the page.
    final style = ChartStyle.printed().copyWith(showBarNumbers: true);
    final measurer = TextPainterChordMeasurer();
    final layout = ChartLayoutEngine.layout(
      sheet: song.leadSheet,
      width: pixelWidth,
      style: style,
      measurer: measurer,
      transposition: transposition,
      preference: null,
    );

    final image = await _raster(
      song: song,
      layout: layout,
      measurer: measurer,
      width: pixelWidth,
      scale: scale,
    );

    // The title and composer are *drawn* into the raster rather than written
    // as PDF text. The package's built-in Helvetica has no Unicode, so a tune
    // called `Blues in B♭` or a composer with an accent in their name would
    // come out wrong — and embedding a font to fix that would ship a megabyte
    // to render two lines the app can already draw. This way the page carries
    // no text objects at all and uses the app's own typeface throughout.
    //
    // The title still goes in the document *metadata*, which is a string in
    // the info dictionary and needs no font.
    final document = pw.Document(title: song.title, author: song.composer);
    final chart = pw.MemoryImage(image);
    document.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(
          pageWidthPoints,
          pageHeightPoints,
          marginAll: marginPoints,
        ),
        build: (context) => pw.FittedBox(
          alignment: pw.Alignment.topLeft,
          fit: pw.BoxFit.scaleDown,
          child: pw.Image(chart),
        ),
      ),
    );
    return Uint8List.fromList(await document.save());
  }

  /// Paint the chart and take the pixels.
  ///
  /// The cursor is not drawn: it is a playback artefact and has no place on a
  /// printed page (§4).
  /// The title and composer, drawn in the app's own typeface.
  static List<({String text, double size, Color colour})> _headingLines(
    Song song,
    double scale,
  ) => <({String text, double size, Color colour})>[
    (text: song.title, size: 20 * scale, colour: const Color(0xFF000000)),
    if (song.composer.trim().isNotEmpty)
      (text: song.composer, size: 11 * scale, colour: const Color(0xFF555555)),
  ];

  static TextPainter _headingPainter(
    ({String text, double size, Color colour}) line,
    double width,
  ) => TextPainter(
    text: TextSpan(
      text: line.text,
      style: TextStyle(
        color: line.colour,
        fontSize: line.size,
        fontWeight: FontWeight.w600,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: width);

  static void _heading(Canvas canvas, Song song, double width, double scale) {
    var y = 0.0;
    for (final line in _headingLines(song, scale)) {
      final painter = _headingPainter(line, width);
      painter.paint(canvas, Offset(0, y));
      y += painter.height + 6 * scale;
    }
  }

  static Future<Uint8List> _raster({
    required Song song,
    required ChartLayout layout,
    required TextPainterChordMeasurer measurer,
    required double width,
    required double scale,
  }) async {
    // Lay the heading out first and measure it: the chart starts below what
    // the heading actually takes, whatever the title's length made it.
    final headingHeight = await PdfExporter.headingHeight(song, width, scale);
    final height = layout.size.height + headingHeight;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    // A white ground: a chart is printed on paper, whatever the app's theme is.
    canvas.drawRect(
      Rect.fromLTWH(0, 0, width, height),
      Paint()..color = const Color(0xFFFFFFFF),
    );

    _heading(canvas, song, width, scale);
    canvas
      ..save()
      ..translate(0, headingHeight);
    ChartPainter(
      layout: layout,
      measurer: measurer,
    ).paint(canvas, Size(width, layout.size.height));
    canvas.restore();

    final picture = recorder.endRecording();
    final image = await picture.toImage(width.ceil(), height.ceil());
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) {
        throw StateError('the chart could not be rasterised');
      }
      return data.buffer.asUint8List();
    } finally {
      image.dispose();
      picture.dispose();
    }
  }
}
