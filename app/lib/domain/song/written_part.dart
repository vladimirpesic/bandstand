import '../harmony/time_signature.dart';

/// One note of a written part, positioned on the written page.
///
/// See `docs/rules/written-parts.md` §1 for why the position is a bar and a
/// beat inside it rather than beats from the start of the song.
class WrittenNote implements Comparable<WrittenNote> {
  /// Create a written note.
  ///
  /// Throws [ArgumentError] if the bar is negative, the beat or the duration is
  /// not finite and non-negative, the key is outside 0–127, or the velocity is
  /// outside 1–127.
  WrittenNote({
    required this.bar,
    required this.beat,
    required this.key,
    required this.durationBeats,
    this.velocity = 80,
  }) {
    if (bar < 0) {
      throw ArgumentError.value(bar, 'bar', 'must not be negative');
    }
    if (!beat.isFinite || beat < 0) {
      throw ArgumentError.value(
        beat,
        'beat',
        'must be finite and non-negative',
      );
    }
    if (!durationBeats.isFinite || durationBeats <= 0) {
      throw ArgumentError.value(
        durationBeats,
        'durationBeats',
        'must be finite and positive',
      );
    }
    if (key < 0 || key > 127) {
      throw ArgumentError.value(key, 'key', 'must be a MIDI key, 0–127');
    }
    if (velocity < 1 || velocity > 127) {
      throw ArgumentError.value(velocity, 'velocity', 'must be 1–127');
    }
  }

  /// The written bar it sits in, zero-based.
  final int bar;

  /// How far into that bar it starts, in the bar's own beats.
  final double beat;

  /// MIDI key, 0–127. Concert pitch: what sounds, not what is written for a
  /// transposing instrument (§5).
  final int key;

  /// How long it sounds, in beats. May run past the end of its bar — a note
  /// tied over the bar line is one note, and cutting it at the line would be
  /// wrong (§2).
  final double durationBeats;

  /// MIDI velocity, 1–127.
  final int velocity;

  /// A copy with some fields replaced.
  WrittenNote copyWith({
    int? bar,
    double? beat,
    int? key,
    double? durationBeats,
    int? velocity,
  }) => WrittenNote(
    bar: bar ?? this.bar,
    beat: beat ?? this.beat,
    key: key ?? this.key,
    durationBeats: durationBeats ?? this.durationBeats,
    velocity: velocity ?? this.velocity,
  );

  /// Ordered by position, then by pitch so a chord is stable.
  @override
  int compareTo(WrittenNote other) {
    final byBar = bar.compareTo(other.bar);
    if (byBar != 0) {
      return byBar;
    }
    final byBeat = beat.compareTo(other.beat);
    if (byBeat != 0) {
      return byBeat;
    }
    return key.compareTo(other.key);
  }

  @override
  bool operator ==(Object other) =>
      other is WrittenNote &&
      other.bar == bar &&
      other.beat == beat &&
      other.key == key &&
      other.durationBeats == durationBeats &&
      other.velocity == velocity;

  @override
  int get hashCode => Object.hash(bar, beat, key, durationBeats, velocity);

  @override
  String toString() =>
      'WrittenNote(bar ${bar + 1} beat $beat, key $key, '
      '$durationBeats beats, vel $velocity)';
}

/// A part somebody already wrote, played exactly as it stands (§9).
///
/// The head, a horn part, a pit book cue. Everything else Bandstand plays is
/// written *for* you from the chords; this is the opposite, and the two coexist.
///
/// Rules: `docs/rules/written-parts.md`.
class WrittenPart {
  /// Create a written part.
  ///
  /// Notes are sorted. Throws [ArgumentError] if the id is blank, the display
  /// name is blank, or the program is outside 0–127.
  factory WrittenPart({
    required String id,
    required String displayName,
    required Iterable<WrittenNote> notes,
    int program = 73,
    bool muted = true,
  }) {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'a part needs an id');
    }
    if (displayName.trim().isEmpty) {
      throw ArgumentError.value(
        displayName,
        'displayName',
        'a part needs a name',
      );
    }
    if (program < 0 || program > 127) {
      throw ArgumentError.value(
        program,
        'program',
        'must be a General MIDI program, 0–127',
      );
    }
    return WrittenPart._(
      id: id,
      displayName: displayName,
      notes: notes.toList()..sort(),
      program: program,
      muted: muted,
    );
  }

  WrittenPart._({
    required this.id,
    required this.displayName,
    required List<WrittenNote> notes,
    required this.program,
    required this.muted,
  }) : notes = List<WrittenNote>.unmodifiable(notes);

  /// Stable identifier, used by the mixer and the song file.
  final String id;

  /// What the player calls it.
  final String displayName;

  /// The notes, in position order.
  final List<WrittenNote> notes;

  /// The General MIDI program it sounds with. Defaults to flute (73), which is
  /// a clear, unobtrusive melody voice.
  final int program;

  /// Whether it is silent.
  ///
  /// **True by default** (§4): a singer with the melody covered does not want a
  /// synthesised one doubling them, and learning a head is a deliberate act.
  final bool muted;

  /// Whether there is anything to play.
  bool get isEmpty => notes.isEmpty;

  /// The written bars notes *start* in, in order.
  Iterable<int> get bars => notes.map((note) => note.bar);

  /// One past the last bar a note starts in, or zero when empty.
  ///
  /// This counts written bars, not sounded ones: a note tied over the bar
  /// line starts in the bar [bars] reports and does not extend this, so a
  /// part whose last note sustains into the next bar still measures its
  /// length here from starts. Sounded length is [lengthInBeats], which takes
  /// the meter.
  int get barCount => notes.isEmpty ? 0 : notes.last.bar + 1;

  /// The notes written in [bar].
  ///
  /// Linear, because a part is walked bar by bar exactly once per playback and
  /// an index would cost more to build than the walk saves.
  List<WrittenNote> notesInBar(int bar) => <WrittenNote>[
    for (final note in notes)
      if (note.bar == bar) note,
  ];

  /// The notes bucketed by bar, for a caller that walks every bar.
  ///
  /// The flattener does exactly that, once per playback bar, and a tune with
  /// repeats asks for the same bar several times — which is [notesInBar] over
  /// the whole part per bar, and quadratic. The same lesson as
  /// `docs/rules/chart-layout.md` §6a.
  Map<int, List<WrittenNote>> get notesByBar {
    final byBar = <int, List<WrittenNote>>{};
    for (final note in notes) {
      (byBar[note.bar] ??= <WrittenNote>[]).add(note);
    }
    return byBar;
  }

  /// The highest and lowest keys, or null when empty. What a display of the
  /// part's range would use, and what tells you it imported sensibly.
  (int low, int high)? get range {
    if (notes.isEmpty) {
      return null;
    }
    var low = notes.first.key;
    var high = low;
    for (final note in notes) {
      if (note.key < low) {
        low = note.key;
      }
      if (note.key > high) {
        high = note.key;
      }
    }
    return (low, high);
  }

  /// A copy with some fields replaced.
  WrittenPart copyWith({
    String? id,
    String? displayName,
    Iterable<WrittenNote>? notes,
    int? program,
    bool? muted,
  }) => WrittenPart(
    id: id ?? this.id,
    displayName: displayName ?? this.displayName,
    notes: notes ?? this.notes,
    program: program ?? this.program,
    muted: muted ?? this.muted,
  );

  /// How long the part is in beats, given the meter of each bar.
  ///
  /// Takes a function rather than a time signature because a tune may change
  /// meter, and the caller — which has the song — is the only thing that knows.
  double lengthInBeats(TimeSignature Function(int bar) meterOf) {
    var total = 0.0;
    for (var bar = 0; bar < barCount; bar++) {
      total += meterOf(bar).upper;
    }
    return total;
  }

  @override
  bool operator ==(Object other) =>
      other is WrittenPart &&
      other.id == id &&
      other.displayName == displayName &&
      other.program == program &&
      other.muted == muted &&
      _sameNotes(other.notes, notes);

  @override
  int get hashCode =>
      Object.hash(id, displayName, program, muted, Object.hashAll(notes));

  static bool _sameNotes(List<WrittenNote> a, List<WrittenNote> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  @override
  String toString() =>
      'WrittenPart($displayName, ${notes.length} notes, '
      '${muted ? 'muted' : 'audible'})';
}
