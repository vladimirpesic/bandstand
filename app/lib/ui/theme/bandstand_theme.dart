import 'package:flutter/material.dart';

/// Bandstand's colour and type scheme.
///
/// Two constraints drive it (§8.1): the app is read from a music stand about
/// two metres away, and it is read in a dark room. So the dark theme is the
/// real one — high contrast, large type, no decorative low-contrast greys — and
/// the light theme exists for daylight and desktop editing.
abstract final class BandstandTheme {
  /// Amber on near-black: the colour of a stage light, and the one hue that
  /// stays legible at low brightness without wrecking night vision.
  static const Color accent = Color(0xFFFFB300);

  static const Color _darkSurface = Color(0xFF121212);
  static const Color _darkElevated = Color(0xFF1E1E1E);

  /// The dark theme, used on stage and by default.
  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.dark,
    ).copyWith(surface: _darkSurface, surfaceContainerHighest: _darkElevated);
    return _base(scheme);
  }

  /// The light theme, for daylight and desktop editing.
  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.light,
    );
    return _base(scheme);
  }

  static ThemeData _base(ColorScheme scheme) {
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      visualDensity: VisualDensity.comfortable,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 20,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 20),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 20),
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        isDense: true,
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1),
    );
  }

  /// Monospaced digits for anything that counts — playhead, bar numbers,
  /// sample counts. Proportional digits jitter as they change and are unusable
  /// for a moving readout.
  static const TextStyle numeric = TextStyle(
    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
    fontFamilyFallback: <String>['monospace'],
  );
}
