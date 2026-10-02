import '../harmony/time_signature.dart';

/// What kind of value a rhythm parameter takes.
enum RhythmParameterKind {
  /// A whole number in a range: intensity 0–100.
  integer,

  /// A fraction in a range.
  decimal,

  /// One of a fixed list: variation A, B, C, D.
  choice,

  /// On or off: fill, ending.
  toggle,
}

/// A knob a rhythm offers per song part: intensity, variation, fill (§4.3).
///
/// A specification, not a value. Values live on the [SongPart] that uses them,
/// keyed by [id], because the same part outlives any particular rhythm plugin.
class RhythmParameterSpec {
  /// Create a parameter specification.
  ///
  /// Throws [ArgumentError] if the id is empty, a numeric range is inverted, or
  /// a choice has no options.
  RhythmParameterSpec({
    required this.id,
    required this.displayName,
    required this.kind,
    required this.defaultValue,
    this.minimum,
    this.maximum,
    List<String> choices = const <String>[],
  }) : choices = List<String>.unmodifiable(choices) {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'a parameter needs an id');
    }
    if (minimum != null && maximum != null && minimum! > maximum!) {
      throw ArgumentError.value(id, 'range', 'minimum is above maximum');
    }
    if (kind == RhythmParameterKind.choice && this.choices.isEmpty) {
      throw ArgumentError.value(id, 'choices', 'a choice needs options');
    }
  }

  /// Stable identifier, stored in the song file.
  final String id;

  /// What the UI calls it.
  final String displayName;

  /// What kind of value it takes.
  final RhythmParameterKind kind;

  /// The value used when a song part says nothing.
  final Object defaultValue;

  /// Lowest accepted value, for numeric kinds.
  final num? minimum;

  /// Highest accepted value, for numeric kinds.
  final num? maximum;

  /// The options, for [RhythmParameterKind.choice].
  final List<String> choices;

  /// Whether [value] is one this parameter accepts.
  bool accepts(Object? value) => switch (kind) {
    RhythmParameterKind.integer => value is int && _inRange(value),
    RhythmParameterKind.decimal =>
      value is num && value.isFinite && _inRange(value),
    RhythmParameterKind.choice => value is String && choices.contains(value),
    RhythmParameterKind.toggle => value is bool,
  };

  /// [value] if this parameter accepts it, else [defaultValue].
  Object coerce(Object? value) => accepts(value) ? value! : defaultValue;

  bool _inRange(num value) =>
      (minimum == null || value >= minimum!) &&
      (maximum == null || value <= maximum!);

  @override
  String toString() => '$id (${kind.name})';

  @override
  bool operator ==(Object other) =>
      other is RhythmParameterSpec && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// One instrument a rhythm generates for: bass, drums, piano, guitar.
class RhythmVoice {
  /// Create a voice.
  ///
  /// Throws [ArgumentError] if the id is empty or the MIDI channel is outside
  /// 0–15.
  RhythmVoice({
    required this.id,
    required this.displayName,
    required this.isDrums,
    this.preferredChannel,
  }) {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'a voice needs an id');
    }
    if (preferredChannel != null &&
        (preferredChannel! < 0 || preferredChannel! > 15)) {
      throw ArgumentError.value(
        preferredChannel,
        'preferredChannel',
        'must be a MIDI channel, 0–15',
      );
    }
  }

  /// Stable identifier, stored in the mixer settings.
  final String id;

  /// What the mixer calls it.
  final String displayName;

  /// Whether the voice plays a drum kit rather than pitches.
  final bool isDrums;

  /// The MIDI channel the voice would like, or null for "any".
  final int? preferredChannel;

  @override
  String toString() => id;

  @override
  bool operator ==(Object other) => other is RhythmVoice && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// A style: what generates the backing for a song part.
///
/// The *implementations* arrive at M5 (drums) and M6 (bass). What exists now is
/// the description a song file stores and the arrangement screen shows, so a
/// song written today still names its style when the generators land.
class Rhythm {
  /// Create a rhythm description.
  ///
  /// Throws [ArgumentError] if the id is empty or two voices or parameters
  /// share an id.
  Rhythm({
    required this.id,
    required this.displayName,
    required this.timeSignature,
    List<RhythmVoice> voices = const <RhythmVoice>[],
    List<RhythmParameterSpec> parameters = const <RhythmParameterSpec>[],
    this.tempoRange,
  }) : voices = List<RhythmVoice>.unmodifiable(voices),
       parameters = List<RhythmParameterSpec>.unmodifiable(parameters) {
    if (id.trim().isEmpty) {
      throw ArgumentError.value(id, 'id', 'a rhythm needs an id');
    }
    if (this.voices.map((v) => v.id).toSet().length != this.voices.length) {
      throw ArgumentError.value(id, 'voices', 'two voices share an id');
    }
    if (this.parameters.map((p) => p.id).toSet().length !=
        this.parameters.length) {
      throw ArgumentError.value(id, 'parameters', 'two parameters share an id');
    }
  }

  /// Stable identifier, stored in the song file.
  final String id;

  /// What the arrangement screen calls it.
  final String displayName;

  /// The meter this rhythm is written for. Meter coverage is a corpus decision
  /// (§4.6), which is why it belongs to the rhythm rather than to the model.
  final TimeSignature timeSignature;

  /// The instruments it generates for.
  final List<RhythmVoice> voices;

  /// The knobs it offers.
  final List<RhythmParameterSpec> parameters;

  /// The tempo range it was written for, in bpm, or null for "any".
  final ({int lowest, int highest})? tempoRange;

  /// The parameter with this id, or null.
  RhythmParameterSpec? parameter(String parameterId) {
    for (final parameter in parameters) {
      if (parameter.id == parameterId) {
        return parameter;
      }
    }
    return null;
  }

  /// The voice with this id, or null.
  RhythmVoice? voice(String voiceId) {
    for (final candidate in voices) {
      if (candidate.id == voiceId) {
        return candidate;
      }
    }
    return null;
  }

  /// Every parameter at its default.
  Map<String, Object> get defaultParameterValues => <String, Object>{
    for (final parameter in parameters) parameter.id: parameter.defaultValue,
  };

  /// [values] with unknown keys dropped and bad values replaced by defaults.
  Map<String, Object> sanitise(Map<String, Object?> values) => <String, Object>{
    for (final parameter in parameters)
      parameter.id: parameter.coerce(values[parameter.id]),
  };

  @override
  String toString() => id;

  @override
  bool operator ==(Object other) => other is Rhythm && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// The rhythms this build knows about.
///
/// Empty until the generators land (§6.5): a song part stores a *rhythm id*, and
/// resolving it is the registry's job. A song whose style is not installed still
/// opens, still displays and still edits — it just has nothing to play, which is
/// exactly what it should do.
class RhythmRegistry {
  /// Create a registry.
  RhythmRegistry([Iterable<Rhythm> rhythms = const <Rhythm>[]]) {
    for (final rhythm in rhythms) {
      register(rhythm);
    }
  }

  final Map<String, Rhythm> _byId = <String, Rhythm>{};

  /// Add a rhythm, replacing any with the same id.
  void register(Rhythm rhythm) => _byId[rhythm.id] = rhythm;

  /// The rhythm with this id, or null.
  Rhythm? operator [](String id) => _byId[id];

  /// Every registered rhythm, in id order.
  List<Rhythm> get all =>
      _byId.values.toList()..sort((a, b) => a.id.compareTo(b.id));

  /// Every rhythm written for [signature].
  List<Rhythm> forTimeSignature(TimeSignature signature) =>
      all.where((rhythm) => rhythm.timeSignature == signature).toList();

  /// How many rhythms are installed.
  int get length => _byId.length;
}
