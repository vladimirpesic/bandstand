# ADR 0011 — MusicXML is read with the `xml` package, not by hand

**Status:** accepted · **Date:** 2026-09-05 · **Milestone:** M9

## Context

§5.2 item 2 is a MusicXML importer. Bandstand had no XML parser: the *exporter*
(`docs/rules/exporters.md` §5) builds its output by writing strings, which is
sound for a document whose shape we control, and useless for reading one we do
not.

## Decision

**Add `xml` (pure Dart) and parse with it.**

## Why not hand-roll it

The same reasoning that rejected a hand-written PDF in ADR 0010, and it applies
harder here, because reading is where a format's edges live:

- **Character entities and numeric references.** A composer called `Saint-Saëns`
  arrives as `Saint-Sa&#235;ns` from some software and as UTF-8 from others.
- **Encodings.** MusicXML files are UTF-8 by declaration and Latin-1 in
  practice, and the declaration is inside the document being decoded.
- **Namespaces.** The specification does not use one; `.mxl` container files
  do, and software adds them anyway.
- **CDATA, comments, processing instructions, DOCTYPE with an external subset.**
  Every real file has the DOCTYPE; a parser that chokes on it imports nothing.

Each of those is a file that fails to import for a reason the user cannot see.
Writing XML by hand is a hundred lines; reading it correctly is a library, and
this one is 2 KB of API over a well-tested implementation.

§15 prefers owning the stack. It does not prefer owning XML.

## Why `xml` specifically

Pure Dart, no platform channels, no native code, no transitive dependency on
anything with an audio or filesystem opinion. It resolves against the
constraints already in the pubspec — which `pdf` did not, and which cost
`archive` a minor version (ADR 0010).

## Consequences

- **One dependency, on the Flutter side only.** The Rust workspace and the
  domain layer are untouched; `xml` is used in `lib/io/importers/` and nowhere
  else.
- **The exporter still writes strings.** Symmetry would be tidier, but the
  exporter works, is tested, and produces exactly the elements it means to.
  Rewriting working output code to use a parser is churn.
- **`.mxl` archives** are read with `archive`, which is already a dependency for
  the library's own import and export.
