import 'chord_rendering_info.dart';
import 'chord_symbol.dart';
import 'chord_type_database.dart';
import 'harmony_registry.dart';
import 'natural.dart';
import 'pitch_spelling.dart';
import 'scale.dart';
import 'spelling_preference.dart';

/// How `N.C.` is written when a chart is formatted.
const String noChordSymbol = 'N.C.';

/// A chord symbol plus the performance instructions a chart carries with it
/// (§4.1): accent, hold, shot, anticipation, a scale instruction, `N.C.` and
/// pedal bass.
///
/// This is what a lead sheet stores. [ChordSymbol] is the harmony alone, and is
/// what the generators mostly want.
class ExtChordSymbol extends ChordSymbol {
  /// Create an extended chord symbol.
  const ExtChordSymbol(
    super.root,
    super.type, {
    super.bass,
    this.rendering = ChordRenderingInfo.plain,
    this.scale,
  });

  /// Wrap a plain chord symbol.
  ExtChordSymbol.from(
    ChordSymbol symbol, {
    this.rendering = ChordRenderingInfo.plain,
    this.scale,
  }) : super(symbol.root, symbol.type, bass: symbol.bass);

  /// Parse a chord symbol or `N.C.`.
  ///
  /// Throws [FormatException] on anything else.
  factory ExtChordSymbol.parse(
    String text, {
    ChordTypeDatabase? database,
    ChordRenderingInfo rendering = ChordRenderingInfo.plain,
    StandardScaleInstance? scale,
  }) {
    final symbol = ExtChordSymbol.tryParse(
      text,
      database: database,
      rendering: rendering,
      scale: scale,
    );
    if (symbol == null) {
      throw FormatException('not a chord symbol', text);
    }
    return symbol;
  }

  /// Parse, or null if `text` is neither a chord nor `N.C.`.
  ///
  /// The [rendering] and [scale] a caller supplies are applied to the result.
  /// For `N.C.` that means the scale is kept and the rendering is kept with
  /// [ChordRenderingInfo.noChord] forced: the text says everybody lays out,
  /// and no caller instruction overrides that.
  static ExtChordSymbol? tryParse(
    String text, {
    ChordTypeDatabase? database,
    ChordRenderingInfo rendering = ChordRenderingInfo.plain,
    StandardScaleInstance? scale,
  }) {
    final trimmed = text.trim();
    if (_noChordAliases.contains(trimmed.toUpperCase())) {
      return ExtChordSymbol(
        PitchSpelling(Natural.c),
        (database ?? Harmony.chordTypes).majorTriad,
        rendering: rendering.copyWith(noChord: true),
        scale: scale,
      );
    }
    final symbol = ChordSymbol.tryParse(trimmed, database: database);
    if (symbol == null) {
      return null;
    }
    return ExtChordSymbol.from(symbol, rendering: rendering, scale: scale);
  }

  /// The canonical `N.C.`.
  ///
  /// "No chord" is a *rendering* instruction in §4.1's model, so it needs a
  /// harmony to hang on. That harmony is never played and never displayed — the
  /// chart shows `N.C.` — but it keeps every consumer total: nothing downstream
  /// has to handle a chord symbol with no root.
  factory ExtChordSymbol.noChord({ChordTypeDatabase? database}) {
    final types = database ?? Harmony.chordTypes;
    return ExtChordSymbol(
      PitchSpelling(Natural.c),
      types.majorTriad,
      rendering: ChordRenderingInfo.silence,
    );
  }

  static const Set<String> _noChordAliases = <String>{
    'N.C.',
    'NC',
    'N.C',
    'NC.',
  };

  /// Performance instructions.
  final ChordRenderingInfo rendering;

  /// A scale the chart names for this chord, if any.
  ///
  /// Kept beside [rendering] because §4.1 models it that way: the scale is a
  /// harmonic fact the generators read, not only something to display.
  final StandardScaleInstance? scale;

  /// Whether this is `N.C.`.
  bool get isNoChord => rendering.noChord;

  /// The harmony alone, without the performance instructions.
  ChordSymbol get plain => ChordSymbol(root, type, bass: bass);

  @override
  ExtChordSymbol transposed(int semitones, {SpellingPreference? preference}) {
    if (isNoChord || semitones % 12 == 0) {
      return this;
    }
    return _movedTo(
      plain.transposed(semitones, preference: preference),
      semitones,
      preference ?? SpellingPreference.automatic,
    );
  }

  @override
  ExtChordSymbol respelled(SpellingPreference preference) =>
      isNoChord ? this : _movedTo(plain.respelled(preference), 0, preference);

  @override
  ExtChordSymbol respelledAt(int semitones, SpellingPreference preference) =>
      isNoChord
      ? this
      : _movedTo(
          plain.respelledAt(semitones, preference),
          semitones,
          preference,
        );

  ExtChordSymbol _movedTo(
    ChordSymbol moved,
    int semitones,
    SpellingPreference preference,
  ) {
    final currentScale = scale;
    return ExtChordSymbol.from(
      moved,
      rendering: rendering,
      scale: currentScale?.transposedTo(
        preference.spell(currentScale.root.pitchClass + semitones),
      ),
    );
  }

  /// A copy with different rendering information.
  ExtChordSymbol withRendering(ChordRenderingInfo newRendering) =>
      ExtChordSymbol(
        root,
        type,
        bass: bass,
        rendering: newRendering,
        scale: scale,
      );

  /// A copy with a different scale instruction, or none.
  ExtChordSymbol withScale(StandardScaleInstance? newScale) => ExtChordSymbol(
    root,
    type,
    bass: bass,
    rendering: rendering,
    scale: newScale,
  );

  @override
  String format() => isNoChord ? noChordSymbol : super.format();

  @override
  bool operator ==(Object other) =>
      other is ExtChordSymbol &&
      other.root == root &&
      other.type == type &&
      other.bass == bass &&
      other.rendering == rendering &&
      other.scale == scale;

  @override
  int get hashCode => Object.hash(root, type, bass, rendering, scale);
}
