import 'key_signature.dart';
import 'natural.dart';
import 'pitch_spelling.dart';
import 'spelling_preference.dart';

/// The key an instrument reads in.
///
/// A global, render-time-only setting (§9): the stored song is never mutated,
/// and turning the setting off restores exactly what was written.
///
/// The numbers are the direction that is correct, and getting them backwards is
/// the classic bug. A Bb trumpet sounds a major second *below* what it reads,
/// so to sound concert C it must read D — the chart moves **up** two semitones.
/// See `docs/rules/pitch-and-spelling.md` §8.
enum InstrumentTransposition {
  /// Concert pitch: piano, guitar, bass, voice.
  concert('C', 0),

  /// Trumpet, tenor and soprano sax, clarinet.
  bFlat('Bb', 2),

  /// Alto and baritone sax.
  eFlat('Eb', 9),

  /// French horn, english horn.
  f('F', 7),

  /// Alto flute, and treble-clef instruments reading in G.
  g('G', 5);

  const InstrumentTransposition(this.label, this.semitones);

  /// How the setting is shown in the UI.
  final String label;

  /// Semitones the written chart moves up from concert pitch.
  final int semitones;

  /// Whether this setting changes anything.
  bool get isConcert => semitones == 0;

  /// The key a concert-pitch [key] is written in for this instrument.
  ///
  /// This is what drives spelling: a chart in concert Eb read by an alto player
  /// is written in C, and its chords spell accordingly.
  KeySignature writtenKey(KeySignature key) {
    if (isConcert) {
      return key;
    }
    final target = (key.tonic.pitchClass + semitones) % 12;
    // Try every letter that can name the target pitch class and keep the one
    // with the simplest signature, breaking ties towards flats. An alto reading
    // concert Db (five flats) then gets Bb (two flats), not A# (ten sharps,
    // which is not a key).
    KeySignature? best;
    for (final natural in Natural.values) {
      var accidental = (target - natural.semitones) % 12;
      if (accidental > 6) {
        accidental -= 12;
      }
      if (accidental.abs() > 1) {
        continue;
      }
      final KeySignature candidate;
      try {
        candidate = KeySignature(PitchSpelling(natural, accidental), key.mode);
      } on ArgumentError {
        continue;
      }
      if (best == null ||
          candidate.sharpCount.abs() < best.sharpCount.abs() ||
          (candidate.sharpCount.abs() == best.sharpCount.abs() &&
              candidate.sharpCount < best.sharpCount)) {
        best = candidate;
      }
    }
    // Every pitch class is nameable with at most one accidental, so this is
    // total; the fallback keeps the expression so.
    return best ?? key;
  }

  /// The spelling preference a chart in this instrument's key should use, given
  /// the song's concert key.
  SpellingPreference preferenceFor(KeySignature concertKey) =>
      SpellingPreference.key(writtenKey(concertKey));
}
