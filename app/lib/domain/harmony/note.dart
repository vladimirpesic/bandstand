import 'key_signature.dart';
import 'pitch_spelling.dart';

/// Lowest MIDI pitch.
const int minPitch = 0;

/// Highest MIDI pitch.
const int maxPitch = 127;

/// Lowest MIDI velocity that still sounds.
const int minVelocity = 1;

/// Highest MIDI velocity.
const int maxVelocity = 127;

/// A note: an absolute pitch, a length and a velocity.
///
/// A pitch is a number, not a spelling — see `docs/rules/pitch-and-spelling.md`
/// §1. Generators emit these; the synth plays them; nothing about them is
/// written on a chart.
class Note implements Comparable<Note> {
  /// Create a note.
  ///
  /// Throws [ArgumentError] if the pitch or velocity is out of MIDI range, or
  /// the duration is not positive and finite.
  Note(this.pitch, {this.beatDuration = 1.0, this.velocity = 64}) {
    if (pitch < minPitch || pitch > maxPitch) {
      throw ArgumentError.value(pitch, 'pitch', 'must be $minPitch–$maxPitch');
    }
    if (velocity < minVelocity || velocity > maxVelocity) {
      throw ArgumentError.value(
        velocity,
        'velocity',
        'must be $minVelocity–$maxVelocity',
      );
    }
    if (!beatDuration.isFinite || beatDuration <= 0) {
      throw ArgumentError.value(
        beatDuration,
        'beatDuration',
        'must be finite and positive',
      );
    }
  }

  /// MIDI pitch, 60 = C4.
  final int pitch;

  /// Length in beats.
  final double beatDuration;

  /// MIDI velocity, 1–127.
  final int velocity;

  /// Pitch class, 0–11.
  int get pitchClass => pitch % 12;

  /// Octave in scientific pitch notation: MIDI 60 is C4.
  int get octave => pitch ~/ 12 - 1;

  /// How this note is spelled in [key].
  PitchSpelling spellingIn(KeySignature key) => key.spell(pitchClass);

  /// The note's name in [key], with its octave: `Eb3`, `F#4`.
  String nameIn(KeySignature key) => '${spellingIn(key)}$octave';

  /// This note moved by [semitones], clamped into MIDI range.
  ///
  /// Clamped rather than thrown: transposing a whole part by an octave should
  /// not fail because one note was near the end of the keyboard, and a note
  /// pinned to the last octave is audible as a mistake in a way an exception in
  /// the middle of generation is not.
  Note transposed(int semitones) => Note(
    (pitch + semitones).clamp(minPitch, maxPitch),
    beatDuration: beatDuration,
    velocity: velocity,
  );

  /// A copy with some fields replaced.
  Note copyWith({int? pitch, double? beatDuration, int? velocity}) => Note(
    pitch ?? this.pitch,
    beatDuration: beatDuration ?? this.beatDuration,
    velocity: velocity ?? this.velocity,
  );

  /// Notes order by pitch, then by length, then by velocity.
  @override
  int compareTo(Note other) {
    final byPitch = pitch.compareTo(other.pitch);
    if (byPitch != 0) {
      return byPitch;
    }
    final byDuration = beatDuration.compareTo(other.beatDuration);
    return byDuration != 0 ? byDuration : velocity.compareTo(other.velocity);
  }

  @override
  String toString() =>
      'Note($pitch, ${beatDuration.toStringAsFixed(3)} beats, v$velocity)';

  @override
  bool operator ==(Object other) =>
      other is Note &&
      other.pitch == pitch &&
      other.beatDuration == beatDuration &&
      other.velocity == velocity;

  @override
  int get hashCode => Object.hash(pitch, beatDuration, velocity);
}
