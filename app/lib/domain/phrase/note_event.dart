import '../harmony/note.dart';

/// A note with a place in a phrase (§4.2).
///
/// Positions are in beats **from the start of the phrase**, never from the
/// start of the song: a generator that has to know where it sits in the song is
/// one that cannot be tested on its own.
class NoteEvent extends Note {
  /// Create a note event.
  ///
  /// Throws [ArgumentError] if the position is not finite and non-negative, or
  /// if the underlying note is invalid.
  NoteEvent({
    required int pitch,
    required this.positionInBeats,
    double beatDuration = 1.0,
    int velocity = 64,
    Map<String, Object> clientProperties = const <String, Object>{},
  }) : clientProperties = Map<String, Object>.unmodifiable(clientProperties),
       super(pitch, beatDuration: beatDuration, velocity: velocity) {
    if (!positionInBeats.isFinite || positionInBeats < 0) {
      throw ArgumentError.value(
        positionInBeats,
        'positionInBeats',
        'must be finite and non-negative',
      );
    }
  }

  /// Where the note starts, in beats from the phrase's start.
  final double positionInBeats;

  /// Tags a generator attaches while working, and a later stage reads.
  ///
  /// Free-form on purpose: "this is the target of an approach", "this hit is
  /// part of a fill". Never serialised, and never leaves the pipeline.
  final Map<String, Object> clientProperties;

  /// One beat past the end of the note.
  double get endInBeats => positionInBeats + beatDuration;

  /// Whether this note is still sounding at `beat`.
  bool soundsAt(double beat) => beat >= positionInBeats && beat < endInBeats;

  /// A copy with some fields replaced.
  @override
  NoteEvent copyWith({
    int? pitch,
    double? positionInBeats,
    double? beatDuration,
    int? velocity,
    Map<String, Object>? clientProperties,
  }) => NoteEvent(
    pitch: pitch ?? this.pitch,
    positionInBeats: positionInBeats ?? this.positionInBeats,
    beatDuration: beatDuration ?? this.beatDuration,
    velocity: velocity ?? this.velocity,
    clientProperties: clientProperties ?? this.clientProperties,
  );

  /// This note moved by `beats`, clamped at the start of the phrase.
  NoteEvent shifted(double beats) => copyWith(
    positionInBeats: (positionInBeats + beats).clamp(0, double.maxFinite),
  );

  /// This note moved by `semitones`, clamped into MIDI range.
  NoteEvent transposedBy(int semitones) =>
      copyWith(pitch: (pitch + semitones).clamp(minPitch, maxPitch));

  /// This note with a tag added.
  NoteEvent tagged(String key, Object value) => copyWith(
    clientProperties: <String, Object>{...clientProperties, key: value},
  );

  /// Whether this note carries `key`.
  bool hasTag(String key) => clientProperties.containsKey(key);

  @override
  int compareTo(Note other) {
    if (other is NoteEvent) {
      final byPosition = positionInBeats.compareTo(other.positionInBeats);
      if (byPosition != 0) {
        return byPosition;
      }
    }
    return super.compareTo(other);
  }

  @override
  String toString() =>
      'NoteEvent($pitch @${positionInBeats.toStringAsFixed(3)} '
      'for ${beatDuration.toStringAsFixed(3)}, v$velocity)';

  @override
  bool operator ==(Object other) =>
      other is NoteEvent &&
      other.pitch == pitch &&
      other.positionInBeats == positionInBeats &&
      other.beatDuration == beatDuration &&
      other.velocity == velocity;

  @override
  int get hashCode =>
      Object.hash(pitch, positionInBeats, beatDuration, velocity);
}
