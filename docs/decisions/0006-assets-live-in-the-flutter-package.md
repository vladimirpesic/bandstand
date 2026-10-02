# ADR 0006 — Bundled assets live in `app/assets/`, not at the repo root

**Status:** accepted · **Date:** 2026-09-01 · **Milestone:** M1

## Context

§12 puts `assets/` at the repo root, holding `chord_types.json`, `corpora/` and
`fonts/`.

Flutter's asset bundler resolves every path in `pubspec.yaml`'s `flutter.assets`
list **relative to the package root**, and rejects paths containing `..`. An
asset directory outside `app/` therefore cannot be bundled into the application
at all. The alternatives are a symlink (fragile on Windows, and invisible in a
diff) or a build step that copies the tree (a second source of truth, and a
stale-copy bug waiting to happen).

## Decision

**Bundled assets live in `app/assets/`.** The repo-root `assets/` directory does
not exist; keeping an empty one would only invite someone to put a file in it
that never reaches the app.

`app/assets/` currently holds:

- `chord_types.json` — the chord-type database of §4.1
- `scales.json` — the standard scales of §4.1

`corpora/` and `fonts/` join it when they exist.

## The domain layer still does not import Flutter

This is the constraint that actually matters, and it is unaffected. The domain
layer never reads a file:

- `ChordTypeDatabase.fromJson(String)` and `ScaleLibrary.fromJson(String)` are
  pure Dart and take the file's *contents*.
- `app/lib/io/harmony_assets.dart` is the only code that knows the assets are
  assets. It calls `rootBundle` and hands the string to the domain.
- Tests read the same file from disk with `dart:io` and get the same objects, so
  the data is tested without a Flutter binding.

## Consequences

- One copy of the data, bundled into every platform build for free.
- `docs/format/` describes the schema of each data file, so the file is
  documented independently of the code that loads it.
