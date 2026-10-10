import '../../domain/song/rhythm_ids.dart';

/// The rhythm an iReal Pro style name implies, or null when the swing band is
/// the honest answer.
///
/// The companion of `IRealStyleTempo`: the style field is the only clue most
/// iReal exports carry, and it says which *band* a tune wants as surely as it
/// says which tempo. "Blue Bossa" arriving arranged for a swing ride was the
/// same bug as every ballad arriving at 120.
///
/// The rules are keyword-based and deliberately conservative. Only styles with
/// a shipped rhythm of their own claim one — bossa and samba map to the latin
/// band, the straight-eighth styles to the straight band — and everything else
/// falls back to the swing band, which is what an unlabelled jazz chart means
/// anyway. Waltz styles claim nothing: a chart in three gets the waltz
/// vocabulary through its meter, not through its style name.
abstract final class IRealStyleRhythm {
  /// The rhythm id [style] implies, or null for the swing band.
  static String? infer(String style) {
    final s = style.toLowerCase();
    for (final rule in _rules) {
      if (s.contains(rule.$1)) {
        return rule.$2;
      }
    }
    return null;
  }

  /// Keyword to rhythm id, first match wins.
  ///
  /// Ordered so that a specific word beats a generic one: "Bossa Nova" is the
  /// latin band before "Nova" could mean anything, and "Even 8ths" is straight
  /// before any later mention of a swing-ish word.
  static const List<(String, String)> _rules = <(String, String)>[
    ('bossa', bossaRhythmId),
    ('samba', bossaRhythmId),
    ('even 8th', straightRhythmId),
    ('even8', straightRhythmId),
    ('even 16th', straightRhythmId),
    ('even16', straightRhythmId),
    ('sixteenth', straightRhythmId),
    ('fusion', straightRhythmId),
    ('funk', straightRhythmId),
    ('smooth', straightRhythmId),
    ('rock', straightRhythmId),
    ('pop', straightRhythmId),
  ];
}
