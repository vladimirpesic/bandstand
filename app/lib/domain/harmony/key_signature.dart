import 'natural.dart';
import 'pitch_spelling.dart';

/// Major or minor. Enough for a chart; modes are a scale concern, not a key
/// signature concern.
enum KeyMode {
  /// Major.
  major('', <int>[0, 2, 4, 5, 7, 9, 11]),

  /// Natural minor. A minor key's signature is its relative major's.
  minor('m', <int>[0, 2, 3, 5, 7, 8, 10]);

  const KeyMode(this.suffix, this.semitones);

  /// How the mode is written after the tonic.
  final String suffix;

  /// Semitones above the tonic, one per letter step.
  final List<int> semitones;
}

/// A key signature: a tonic spelling and a mode.
///
/// What it is *for* is deciding, for each of the twelve pitch classes, which
/// spelling to use. See `docs/rules/pitch-and-spelling.md` §5.
class KeySignature {
  /// Create a key signature.
  ///
  /// Throws [ArgumentError] if the key would need more than seven sharps or
  /// flats — those keys are always a spelling error upstream, and no chart is
  /// written in them.
  KeySignature(this.tonic, this.mode) {
    final count = _sharpCountFor(tonic, mode);
    if (count == null) {
      throw ArgumentError.value(
        '$tonic${mode.suffix}',
        'key',
        'needs more than seven sharps or flats',
      );
    }
    sharpCount = count;
    _spellings = _buildSpellings();
  }

  /// C major, the key of a chart that has not said otherwise.
  factory KeySignature.cMajor() =>
      KeySignature(PitchSpelling(Natural.c), KeyMode.major);

  /// This key moved by `semitones`, spelled the way the destination wants.
  ///
  /// The spelling is the whole difficulty and it is why this cannot be
  /// arithmetic on a pitch class: F# major and Gb major are the same twelve
  /// notes and a chart in one is unreadable written as the other. The key
  /// spells its own new tonic, which is what
  /// `docs/rules/pitch-and-spelling.md` §5 is for.
  KeySignature transposed(int semitones) =>
      KeySignature(spell(tonic.pitchClass + semitones), mode);

  /// Parse `C`, `Bb`, `F#m`, `Ebmaj`, `Am`.
  ///
  /// Throws [FormatException] on anything else.
  factory KeySignature.parse(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw FormatException('not a key', text);
    }
    var body = trimmed;
    var mode = KeyMode.major;
    for (final suffix in <String>['minor', 'min', 'm', '-']) {
      if (body.length > 1 && body.endsWith(suffix)) {
        body = body.substring(0, body.length - suffix.length);
        mode = KeyMode.minor;
        break;
      }
    }
    if (mode == KeyMode.major) {
      for (final suffix in <String>['major', 'maj', 'M']) {
        if (body.length > 1 && body.endsWith(suffix)) {
          body = body.substring(0, body.length - suffix.length);
          break;
        }
      }
    }
    final tonic = PitchSpelling.tryParse(body);
    if (tonic == null) {
      throw FormatException('not a key', text);
    }
    return KeySignature(tonic, mode);
  }

  /// Parse, or null if `text` is not a key.
  static KeySignature? tryParse(String text) {
    try {
      return KeySignature.parse(text);
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
  }

  /// The tonic.
  final PitchSpelling tonic;

  /// Major or minor.
  final KeyMode mode;

  /// Position on the circle of fifths: −7 (seven flats) to +7 (seven sharps).
  late final int sharpCount;

  late final List<PitchSpelling> _spellings;

  /// Whether the signature is written with sharps.
  bool get usesSharps => sharpCount > 0;

  /// Whether the signature is written with flats.
  ///
  /// C major and A minor have neither; they are treated as flat-side, which is
  /// the jazz convention.
  bool get usesFlats => sharpCount <= 0;

  /// The seven diatonic spellings, from the tonic upwards.
  List<PitchSpelling> get scaleSpellings {
    return <PitchSpelling>[
      for (var step = 0; step < 7; step++)
        _diatonic(step) ??
            PitchSpelling.simplestFor(
              (tonic.pitchClass + mode.semitones[step]) % 12,
              preferSharps: usesSharps,
            ),
    ];
  }

  /// How this key spells [pitchClass].
  PitchSpelling spell(int pitchClass) =>
      _spellings[((pitchClass % 12) + 12) % 12];

  /// The relative major of a minor key, or the key itself if it is major.
  KeySignature get relativeMajor {
    if (mode == KeyMode.major) {
      return this;
    }
    final target = (tonic.pitchClass + 3) % 12;
    // A minor key inside ±7 accidentals always has a spellable relative major;
    // the fallback exists so the expression is total, not because it is reached.
    final spelling =
        tonic.steppedTo(2, target) ??
        PitchSpelling.simplestFor(target, preferSharps: usesSharps);
    return KeySignature(spelling, KeyMode.major);
  }

  PitchSpelling? _diatonic(int step) =>
      tonic.steppedTo(step, (tonic.pitchClass + mode.semitones[step]) % 12);

  List<PitchSpelling> _buildSpellings() {
    final byPitchClass = <int, PitchSpelling>{};
    for (var step = 0; step < 7; step++) {
      final spelling = _diatonic(step);
      if (spelling != null) {
        byPitchClass[spelling.pitchClass] = spelling;
      }
    }
    return <PitchSpelling>[
      for (var pitchClass = 0; pitchClass < 12; pitchClass++)
        byPitchClass[pitchClass] ??
            PitchSpelling.simplestFor(pitchClass, preferSharps: usesSharps),
    ];
  }

  /// Sharps in the signature of `tonic mode`, or null if it needs more than
  /// seven of either.
  static int? _sharpCountFor(PitchSpelling tonic, KeyMode mode) {
    // Circle of fifths from C: F C G D A E B, with the accidental adding seven
    // per step. A minor key sits three semitones — three fifths — below its
    // relative major.
    const naturalFifths = <Natural, int>{
      Natural.f: -1,
      Natural.c: 0,
      Natural.g: 1,
      Natural.d: 2,
      Natural.a: 3,
      Natural.e: 4,
      Natural.b: 5,
    };
    final count =
        naturalFifths[tonic.natural]! +
        tonic.alteration * 7 +
        (mode == KeyMode.minor ? -3 : 0);
    return count >= -7 && count <= 7 ? count : null;
  }

  @override
  String toString() => '$tonic${mode.suffix}';

  @override
  bool operator ==(Object other) =>
      other is KeySignature && other.tonic == tonic && other.mode == mode;

  @override
  int get hashCode => Object.hash(tonic, mode);
}
