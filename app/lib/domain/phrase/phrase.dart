import '../harmony/time_signature.dart';
import 'float_range.dart';
import 'note_event.dart';

/// An ordered collection of notes on one channel (§4.2).
///
/// Immutable and always sorted. Every operation returns a new phrase, which is
/// what lets the post-processing chain be a composition of pure functions.
class Phrase {
  Phrase._({
    required this.channel,
    required this.isDrums,
    required List<NoteEvent> notes,
  }) : notes = List<NoteEvent>.unmodifiable(notes);

  /// Create a phrase, sorting the notes.
  ///
  /// Throws [ArgumentError] if the channel is not a MIDI channel.
  factory Phrase({
    required int channel,
    bool isDrums = false,
    Iterable<NoteEvent> notes = const <NoteEvent>[],
  }) {
    if (channel < 0 || channel > 15) {
      throw ArgumentError.value(channel, 'channel', 'must be a MIDI channel');
    }
    return Phrase._(
      channel: channel,
      isDrums: isDrums,
      notes: notes.toList()..sort(),
    );
  }

  /// An empty phrase on a channel.
  factory Phrase.empty({required int channel, bool isDrums = false}) =>
      Phrase(channel: channel, isDrums: isDrums);

  /// The MIDI channel it plays on.
  final int channel;

  /// Whether this is a drum part.
  ///
  /// A drum part's "pitch" is an instrument, so it must never be transposed —
  /// which is why this is on the phrase and not left to the caller to remember.
  final bool isDrums;

  /// The notes, in time order.
  final List<NoteEvent> notes;

  /// How many notes there are.
  int get length => notes.length;

  /// Whether there are none.
  bool get isEmpty => notes.isEmpty;

  /// Whether there are any.
  bool get isNotEmpty => notes.isNotEmpty;

  /// The beat the first note starts on, or zero.
  double get startBeat => notes.isEmpty ? 0 : notes.first.positionInBeats;

  /// One beat past the last note's end, or zero.
  double get endBeat => notes.isEmpty
      ? 0
      : notes.map((n) => n.endInBeats).reduce((a, b) => a > b ? a : b);

  /// The span the notes actually occupy.
  FloatRange get extent => FloatRange(startBeat, endBeat);

  /// A copy with `note` added.
  Phrase withNote(NoteEvent note) => Phrase(
    channel: channel,
    isDrums: isDrums,
    notes: <NoteEvent>[...notes, note],
  );

  /// A copy with every note in `added`.
  Phrase withNotes(Iterable<NoteEvent> added) => Phrase(
    channel: channel,
    isDrums: isDrums,
    notes: <NoteEvent>[...notes, ...added],
  );

  /// A copy with the notes replaced.
  Phrase withOnly(Iterable<NoteEvent> replacement) =>
      Phrase(channel: channel, isDrums: isDrums, notes: replacement);

  /// A copy on a different channel.
  Phrase onChannel(int newChannel, {bool? drums}) =>
      Phrase(channel: newChannel, isDrums: drums ?? isDrums, notes: notes);

  /// A copy moved by `semitones`.
  ///
  /// A drum phrase is returned unchanged: its pitches are instruments.
  Phrase transposed(int semitones) {
    if (isDrums || semitones == 0) {
      return this;
    }
    return withOnly(<NoteEvent>[
      for (final note in notes) note.transposedBy(semitones),
    ]);
  }

  /// A copy moved by `beats`.
  Phrase shifted(double beats) {
    if (beats == 0) {
      return this;
    }
    return withOnly(<NoteEvent>[for (final note in notes) note.shifted(beats)]);
  }

  /// A copy with every note passed through `map`, keeping only those `keep`
  /// accepts.
  ///
  /// The one operation the post-processing chain is built from (§6.1).
  Phrase processed({
    bool Function(NoteEvent note)? keep,
    NoteEvent Function(NoteEvent note)? map,
  }) => withOnly(<NoteEvent>[
    for (final note in notes)
      if (keep == null || keep(note)) map == null ? note : map(note),
  ]);

  /// The notes inside `range`.
  ///
  /// With `cutNotes`, a note that starts inside the range but runs past its end
  /// is shortened to fit; without it, such a note is kept whole.
  Phrase sliced(FloatRange range, {bool cutNotes = false}) {
    final kept = <NoteEvent>[];
    for (final note in notes) {
      if (!range.contains(note.positionInBeats)) {
        continue;
      }
      if (cutNotes && note.endInBeats > range.end) {
        final shortened = range.end - note.positionInBeats;
        if (shortened <= 0) {
          continue;
        }
        kept.add(note.copyWith(beatDuration: shortened));
      } else {
        kept.add(note);
      }
    }
    return withOnly(kept);
  }

  /// The notes sounding at `beat`.
  List<NoteEvent> notesAt(double beat) =>
      notes.where((note) => note.soundsAt(beat)).toList();

  /// The highest pitch, or null when empty.
  int? get highestPitch => notes.isEmpty
      ? null
      : notes.map((n) => n.pitch).reduce((a, b) => a > b ? a : b);

  /// The lowest pitch, or null when empty.
  int? get lowestPitch => notes.isEmpty
      ? null
      : notes.map((n) => n.pitch).reduce((a, b) => a < b ? a : b);

  /// Two phrases merged, keeping this one's channel.
  Phrase merged(Phrase other) => withNotes(other.notes);

  @override
  String toString() =>
      'Phrase(channel $channel${isDrums ? ' drums' : ''}, '
      '${notes.length} notes)';

  @override
  bool operator ==(Object other) {
    if (other is! Phrase ||
        other.channel != channel ||
        other.isDrums != isDrums ||
        other.notes.length != notes.length) {
      return false;
    }
    for (var i = 0; i < notes.length; i++) {
      if (notes[i] != other.notes[i]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(channel, isDrums, Object.hashAll(notes));
}

/// A phrase with a fixed span and a meter — the unit a generator returns.
class SizedPhrase extends Phrase {
  SizedPhrase._({
    required super.channel,
    required super.isDrums,
    required super.notes,
    required this.beatRange,
    required this.timeSignature,
  }) : super._();

  /// Create a sized phrase.
  ///
  /// Notes outside `beatRange` are dropped: a generator that writes past the
  /// end of its own span has made a mistake, and carrying it forward turns one
  /// bug into an overlap three stages later.
  factory SizedPhrase({
    required int channel,
    required FloatRange beatRange,
    required TimeSignature timeSignature,
    bool isDrums = false,
    Iterable<NoteEvent> notes = const <NoteEvent>[],
  }) {
    if (channel < 0 || channel > 15) {
      throw ArgumentError.value(channel, 'channel', 'must be a MIDI channel');
    }
    final kept = <NoteEvent>[
      for (final note in notes)
        if (beatRange.contains(note.positionInBeats)) note,
    ]..sort();
    return SizedPhrase._(
      channel: channel,
      isDrums: isDrums,
      notes: kept,
      beatRange: beatRange,
      timeSignature: timeSignature,
    );
  }

  /// The span this phrase covers, whether or not it has notes throughout.
  final FloatRange beatRange;

  /// The meter it was written in.
  final TimeSignature timeSignature;

  /// How many bars it covers.
  double get barCount => beatRange.length / timeSignature.upper;

  /// This phrase moved by `beats`, span and notes together.
  ///
  /// A sized phrase's range moves with its notes. Moving only the notes would
  /// push them outside the range, and the constructor drops notes outside the
  /// range — so the phrase would silently empty itself.
  @override
  SizedPhrase shifted(double beats) => movedTo(beatRange.start + beats);

  @override
  SizedPhrase processed({
    bool Function(NoteEvent note)? keep,
    NoteEvent Function(NoteEvent note)? map,
  }) => super.processed(keep: keep, map: map) as SizedPhrase;

  @override
  SizedPhrase sliced(FloatRange range, {bool cutNotes = false}) =>
      super.sliced(range, cutNotes: cutNotes) as SizedPhrase;

  @override
  SizedPhrase withOnly(Iterable<NoteEvent> replacement) => SizedPhrase(
    channel: channel,
    beatRange: beatRange,
    timeSignature: timeSignature,
    isDrums: isDrums,
    notes: replacement,
  );

  // The four below would otherwise come from `Phrase` and quietly return a
  // plain phrase, dropping `beatRange` and the protection it carries (L-S1).
  // The constructor drops notes outside the range, exactly as it does
  // everywhere else: a caller adding past the span has made the same mistake
  // a generator writing past its own span has.

  @override
  SizedPhrase withNote(NoteEvent note) => SizedPhrase(
    channel: channel,
    beatRange: beatRange,
    timeSignature: timeSignature,
    isDrums: isDrums,
    notes: <NoteEvent>[...notes, note],
  );

  @override
  SizedPhrase withNotes(Iterable<NoteEvent> added) => SizedPhrase(
    channel: channel,
    beatRange: beatRange,
    timeSignature: timeSignature,
    isDrums: isDrums,
    notes: <NoteEvent>[...notes, ...added],
  );

  @override
  SizedPhrase merged(Phrase other) => withNotes(other.notes);

  @override
  SizedPhrase onChannel(int newChannel, {bool? drums}) => SizedPhrase(
    channel: newChannel,
    beatRange: beatRange,
    timeSignature: timeSignature,
    isDrums: drums ?? isDrums,
    notes: notes,
  );

  /// This phrase moved to start at `beat`, keeping its length.
  ///
  /// Throws [ArgumentError] if `beat` is negative. Moving a sized phrase
  /// before the start of the song is a crop, not a move: [NoteEvent.shifted]
  /// clamps negative positions onto beat 0, which would pile distinct notes
  /// onto one onset instead of dropping them.
  SizedPhrase movedTo(double beat) {
    if (beat < 0) {
      throw ArgumentError.value(
        beat,
        'beat',
        'a phrase cannot start before the song',
      );
    }
    final delta = beat - beatRange.start;
    return SizedPhrase(
      channel: channel,
      beatRange: beatRange.shifted(delta),
      timeSignature: timeSignature,
      isDrums: isDrums,
      notes: <NoteEvent>[for (final note in notes) note.shifted(delta)],
    );
  }

  @override
  String toString() =>
      'SizedPhrase(channel $channel, $beatRange, ${notes.length} notes)';
}
