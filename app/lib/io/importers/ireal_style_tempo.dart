/// A tempo implied by an iReal Pro style name.
///
/// iReal exports most charts with `=0=0` — "no tempo set" — so a library of
/// 1,460 charts imports with nothing to distinguish a ballad from a burner
/// unless the style is read too. iReal's own player does exactly this: the
/// style picks the tempo until the player sets one.
///
/// The rules are ordered, keyword-based and deliberately coarse. A style is a
/// vibe, not a metronome mark: "Medium Up Swing" is 150 because that is where
/// medium-up lives, not because anyone wrote 150 on a chart. Modifiers win
/// over styles — "Slow Waltz" is a slow tune that happens to be in three, so
/// *slow* (88) is matched before *waltz* (132).
///
/// Unknown styles answer null and the caller keeps its own default.
abstract final class IRealStyleTempo {
  /// The tempo [style] implies, or null when nothing in it is recognised.
  static int? infer(String style) {
    final s = style.toLowerCase();
    for (final rule in _rules) {
      if (s.contains(rule.$1)) {
        return rule.$2;
      }
    }
    return null;
  }

  /// Keyword to tempo, first match wins.
  ///
  /// Modifiers first (ballad, up tempo, fast, medium up, medium, slow), then
  /// feels (bossa, samba, waltz), then genres, then the jazz defaults — so
  /// "Slow Blues" lands on the slow rule, not the blues rule.
  static const List<(String, int)> _rules = <(String, int)>[
    ('ballad', 72),
    ('up tempo', 200),
    ('up-tempo', 200),
    ('fast', 200),
    ('medium up', 150),
    ('medium-up', 150),
    ('medium', 120),
    ('slow', 88),
    ('bossa', 132),
    ('samba', 130),
    ('waltz', 132),
    ('blues', 100),
    ('funk', 100),
    ('bop', 180),
    ('latin', 120),
    ('rumba', 120),
    ('rhumba', 120),
    ('mambo', 120),
    ('songo', 120),
    ('cha cha', 120),
    ('cha-cha', 120),
    ('tango', 120),
    ('salsa', 120),
    ('stride', 130),
    ('dixieland', 130),
    ('dixie', 130),
    ('fusion', 130),
    ('gospel', 100),
    ('rock', 120),
    ('pop', 100),
    ('smooth', 90),
    ('soul', 96),
    ('r&b', 96),
    ('rhythm and blues', 96),
    ('swing', 120),
    ('jazz', 120),
  ];
}
