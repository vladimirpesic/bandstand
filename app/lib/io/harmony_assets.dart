import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:flutter/services.dart' show rootBundle;

/// Where the chord-type table is bundled.
const String chordTypesAssetPath = 'assets/chord_types.json';

/// Where the scale table is bundled.
const String scalesAssetPath = 'assets/scales.json';

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
