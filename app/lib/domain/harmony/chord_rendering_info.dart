import 'scale.dart';
import 'time_signature.dart';

/// How hard the chord is hit.
enum ChordAccent {
  /// No accent: play it as the groove goes.
  none(''),

  /// Accent it.
  medium('>'),

  /// Accent it hard.
  strong('^');

  const ChordAccent(this.symbol);

  /// How the accent is written on a chart.
  final String symbol;

  /// The accent for a symbol, or null.
  static ChordAccent? fromSymbol(String symbol) {
    for (final accent in ChordAccent.values) {
      if (accent.symbol == symbol && symbol.isNotEmpty) {
        return accent;
      }
    }
    return null;
  }
}

/// What the rhythm section does with the chord.
enum ChordPlayStyle {
  /// Keep playing time.
  normal,

  /// Sustain it and stop the time until the next chord.
  hold,

  /// A short stab, then silence.
  shot,
}

/// Whether the chord is pushed ahead of the beat, and by how much.
///
/// §6.6: pushing a chord an eighth before the bar is one of the things that
/// stops generated backing sounding like a loop.
enum ChordAnticipation {
  /// On the beat.
  none(0),

  /// An eighth note early.
  eighth(0.5),

  /// A sixteenth note early.
  sixteenth(0.25);

  const ChordAnticipation(this.quarters);

  /// How far ahead of the beat, in **quarter notes**.
  ///
  /// Quarters, not beats: an eighth note is half a quarter whatever the meter
  /// is, while "half a beat" is an eighth in 4/4 and a sixteenth in 6/8. Use
  /// [beatsIn] to put it in a phrase's own beats.
  final double quarters;

  /// How far ahead of the beat, in the beats of [meter].
  double beatsIn(TimeSignature meter) =>
      quarters / meter.beatDurationInQuarters;
}

/// Everything about a chord that is a performance instruction rather than a
/// harmony (§4.1).
///
/// Immutable. `copyWith` is how the editor changes one field.
class ChordRenderingInfo {
  /// Create rendering information.
  const ChordRenderingInfo({
    this.accent = ChordAccent.none,
    this.playStyle = ChordPlayStyle.normal,
    this.anticipation = ChordAnticipation.none,
    this.pedalBass = false,
    this.noChord = false,
    this.scale,
  });

  /// Nothing marked: what a plain chord symbol means.
  static const ChordRenderingInfo plain = ChordRenderingInfo();

  /// The chord is not played at all.
  static const ChordRenderingInfo silence = ChordRenderingInfo(noChord: true);

  /// How hard the chord is hit.
  final ChordAccent accent;

  /// What the rhythm section does with it.
  final ChordPlayStyle playStyle;

  /// Whether it is pushed ahead of the beat.
  final ChordAnticipation anticipation;

  /// Whether the bass holds its previous note instead of following the root.
  final bool pedalBass;

  /// Whether this is `N.C.` — no chord, everybody lays out.
  final bool noChord;

  /// A scale the player is told to use over the chord, if the chart says so.
  final StandardScaleInstance? scale;

  /// Whether anything at all is marked.
  bool get isPlain =>
      accent == ChordAccent.none &&
      playStyle == ChordPlayStyle.normal &&
      anticipation == ChordAnticipation.none &&
      !pedalBass &&
      !noChord &&
      scale == null;

  /// A copy with some fields replaced.
  ChordRenderingInfo copyWith({
    ChordAccent? accent,
    ChordPlayStyle? playStyle,
    ChordAnticipation? anticipation,
    bool? pedalBass,
    bool? noChord,
    StandardScaleInstance? scale,
    bool clearScale = false,
  }) {
    return ChordRenderingInfo(
      accent: accent ?? this.accent,
      playStyle: playStyle ?? this.playStyle,
      anticipation: anticipation ?? this.anticipation,
      pedalBass: pedalBass ?? this.pedalBass,
      noChord: noChord ?? this.noChord,
      scale: clearScale ? null : (scale ?? this.scale),
    );
  }

  @override
  String toString() {
    if (isPlain) {
      return 'plain';
    }
    return <String>[
      if (accent != ChordAccent.none) accent.name,
      if (playStyle != ChordPlayStyle.normal) playStyle.name,
      if (anticipation != ChordAnticipation.none) anticipation.name,
      if (pedalBass) 'pedalBass',
      if (noChord) 'noChord',
      if (scale != null) '$scale',
    ].join(' ');
  }

  @override
  bool operator ==(Object other) =>
      other is ChordRenderingInfo &&
      other.accent == accent &&
      other.playStyle == playStyle &&
      other.anticipation == anticipation &&
      other.pedalBass == pedalBass &&
      other.noChord == noChord &&
      other.scale == scale;

  @override
  int get hashCode =>
      Object.hash(accent, playStyle, anticipation, pedalBass, noChord, scale);
}
