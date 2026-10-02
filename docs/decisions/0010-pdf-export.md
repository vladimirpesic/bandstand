# ADR 0010 — PDF export rasters the chart painter

**Status:** accepted · **Date:** 2026-09-04 · **Milestone:** M9

## Context

§5.3 asks for a *"PDF chart (via Flutter's `printing`/`pdf` packages, reusing
the same `CustomPainter` layout)"*, and §8.1 built the chart renderer as a
`CustomPainter` partly so this would be possible: a painter draws to any canvas,
and a PDF page is a canvas.

Except it is not the *same* canvas. Flutter's `Canvas` and the `pdf` package's
graphics context are unrelated types. "Reusing the layout" needs a decision
about how.

## Decision

**Paint the chart to a Flutter `Canvas` at print resolution, raster it, and
embed the image in a PDF page.**

```plaintext
ChartLayoutEngine → ChartPainter → PictureRecorder → Image → PNG → PdfPage
```

One new dependency: `pdf`. Not `printing` — see below.

## Why raster rather than a vector adapter

A vector export would need an adapter implementing Flutter's `Canvas` over the
`pdf` package's graphics, including its text layout. That is a large surface
(`drawParagraph` alone pulls in the whole text stack) and every gap in it is a
chart that prints subtly wrong — a missing accidental, a shifted chord.

Against that, what is actually being printed: a grid of lines with large text on
it. At 300 dpi an A4 page is 2480 × 3508 pixels, chord symbols are 40 pixels
tall, and the result is indistinguishable from vector at reading distance. The
one thing raster loses — infinite zoom — is not a thing anyone does to a chord
chart.

So the trade is a large, fragile adapter against a file that is a few hundred
kilobytes larger. That is not a close call.

**The layout is still shared, which was the point.** `ChartLayoutEngine` reflows
to the page exactly as it reflows to a phone, so the PDF is a *typeset chart*
and not a screenshot of one — the same engine, a different target size.

## Why `pdf` and not `printing`

`printing` is the platform-channel half: print dialogues, share sheets, printer
discovery. Bandstand writes a file to `<library>/exports/`
(`docs/rules/exporters.md` §6) and the platform's own viewer takes it from
there. Adding `printing` would pull in native code on five platforms to do
something the file manager already does.

`pdf` is pure Dart and writes bytes.

## Why not hand-write the PDF

A PDF containing one image is genuinely small — an object table, a page tree,
an image XObject. Writing it would keep the dependency count at zero, which §15
values.

Rejected because the failure mode is bad: a subtly malformed PDF opens in one
reader and not another, and the reader that fails will be the one at the venue.
Object offsets, stream lengths and the cross-reference table are exactly the
kind of arithmetic that is right until it is not. §15 prefers owning the stack;
it does not prefer owning a file format specification.

## Consequences

- **One dependency, pure Dart, no platform code.** It does not affect the audio
  path, the domain layer, or any build but the Flutter one.
- **Exported PDFs are raster.** Text in them is not selectable or searchable.
  For a chord chart, nobody was going to do either.
- **Resolution is a constant**, 300 dpi, chosen once. Higher makes the file
  bigger and changes nothing a person can see; lower is visible.
- **The renderer stays the single source of truth for layout.** A change to bar
  breaking shows up in print without a second implementation to keep in step —
  which is the whole reason §8.1 chose a painter.
