import 'chord_type_database.dart';
import 'scale.dart';

/// The process-wide chord-type database and scale library.
///
/// The tables are data files (ADR 0006), so something has to load them before
/// a chord can be parsed. Threading a database argument through every call site
/// — every chord in every bar of every song, plus every test — buys nothing:
/// the tables are constant for the life of the process, and there is exactly
/// one of each.
///
/// So they live here, installed once at startup by
/// `lib/io/harmony_assets.dart`, and every API that needs them takes an
/// optional override so a test can pass its own.
///
/// The domain layer still imports nothing from Flutter: this holds objects, not
/// paths, and knows nothing about where they came from.
abstract final class Harmony {
  static ChordTypeDatabase? _chordTypes;
  static ScaleLibrary? _scales;

  /// Install the tables. Called once at startup, and again by tests.
  static void install({
    required ChordTypeDatabase chordTypes,
    required ScaleLibrary scales,
  }) {
    _chordTypes = chordTypes;
    _scales = scales;
  }

  /// Whether [install] has been called.
  static bool get isInstalled => _chordTypes != null && _scales != null;

  /// The chord-type database.
  ///
  /// Throws [StateError] if the tables have not been installed — which is a
  /// startup bug, and better as a loud failure than a chord that will not
  /// parse.
  static ChordTypeDatabase get chordTypes =>
      _chordTypes ??
      (throw StateError(
        'the chord-type database has not been installed; call '
        'installHarmonyAssets() during startup, or Harmony.install() in a test',
      ));

  /// The scale library.
  ///
  /// Throws [StateError] if the tables have not been installed.
  static ScaleLibrary get scales =>
      _scales ??
      (throw StateError(
        'the scale library has not been installed; call '
        'installHarmonyAssets() during startup, or Harmony.install() in a test',
      ));

  /// Forget the installed tables. Tests only.
  static void reset() {
    _chordTypes = null;
    _scales = null;
  }
}
