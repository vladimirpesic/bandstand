import 'dart:io';

import 'package:bandstand/domain/harmony/harmony.dart';

/// Load the chord-type table straight from disk.
///
/// The domain layer takes the file's *contents* (ADR 0006), so a test needs no
/// Flutter binding and no asset bundle — it reads the same file the app ships
/// and gets the same objects.
ChordTypeDatabase loadChordTypes() => ChordTypeDatabase.fromJson(
  File('assets/chord_types.json').readAsStringSync(),
);

/// Load the scale table straight from disk.
ScaleLibrary loadScales() =>
    ScaleLibrary.fromJson(File('assets/scales.json').readAsStringSync());

/// Install both tables for the process, as `main` does at startup.
void installTestHarmony() =>
    Harmony.install(chordTypes: loadChordTypes(), scales: loadScales());
