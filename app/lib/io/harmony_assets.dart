import 'package:bandstand/domain/harmony/diagrams/chord_diagram_library.dart';
import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Where the chord-type table is bundled.
const String chordTypesAssetPath = 'assets/chord_types.json';

/// Where the scale table is bundled.
const String scalesAssetPath = 'assets/scales.json';

/// Where the fretboard shapes are bundled.
const String chordDiagramsAssetPath = 'assets/chord_diagrams.json';

/// Load the harmony data files and install them for the whole process.
///
/// This is the only code that knows the tables are Flutter assets; the domain
/// layer takes their contents, never their paths (ADR 0006). Called once from
/// `main`, before any chord is parsed.
///
/// Throws [FormatException] if a table is malformed — a corrupt chord-type
/// table means nothing can be read, and failing at startup is far better than
/// failing on the first chord of the first tune.
Future<void> installHarmonyAssets() async {
  final chordTypesSource = await rootBundle.loadString(chordTypesAssetPath);
  final scalesSource = await rootBundle.loadString(scalesAssetPath);
  Harmony.install(
    chordTypes: ChordTypeDatabase.fromJson(chordTypesSource),
    scales: ScaleLibrary.fromJson(scalesSource),
  );
}

/// The fretboard shapes (`docs/rules/chord-diagrams.md`).
///
/// Loaded on demand rather than at startup: nothing needs a diagram until the
/// chord reference screen is opened, and a table of shapes is not on the path
/// to the first note.
final chordDiagramsProvider = FutureProvider<ChordDiagramLibrary>((ref) async {
  final source = await rootBundle.loadString(chordDiagramsAssetPath);
  return ChordDiagramLibrary.fromJson(source);
});
