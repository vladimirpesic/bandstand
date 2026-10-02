import 'dart:convert';

import '../../harmony/ext_chord_symbol.dart';
import 'bass_corpus.dart';
import 'root_profile.dart';
import 'wbp_source.dart';

/// The schema version this build understands.
const int bassCorpusSchemaVersion = 1;

/// Reads `bass_corpus.json`.
///
/// Format: `docs/format/bass-corpus.md`. The domain owns the parse and the IO
/// layer only supplies the string, so nothing here knows the corpus is a
/// Flutter asset (ADR 0006).
///
/// Every failure names the phrase and the field. A corpus is edited by hand
/// (ADR 0008) and a typo in it must say where it is, not surface months later
/// as a hole in a bass line.
abstract final class BassCorpusCodec {
  /// Parse a corpus.
  ///
  /// Throws [FormatException] on anything malformed.
  static BassCorpus decode(String source) {
    final Object? decoded = jsonDecode(source);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('a bass corpus must be a JSON object');
    }
    final version = decoded['schemaVersion'];
    if (version != bassCorpusSchemaVersion) {
      throw FormatException(
        'the bass corpus is schema version $version; this build understands '
        '$bassCorpusSchemaVersion',
      );
    }

    final name = decoded['name'];
    if (name is! String || name.trim().isEmpty) {
      throw const FormatException('the bass corpus needs a name');
    }

    final range = _readRange(decoded['instrument']);

    final rawPhrases = decoded['phrases'];
    if (rawPhrases is! List || rawPhrases.isEmpty) {
      throw const FormatException('the bass corpus has no phrases');
    }

    return BassCorpus(
      name: name,
      range: range,
      phrases: <WbpSource>[
        for (final raw in rawPhrases) _readPhrase(raw, range),
      ],
    );
  }

  static BassRange _readRange(Object? raw) {
    if (raw == null) {
      return const BassRange();
    }
    if (raw is! Map<String, Object?>) {
      throw const FormatException('"instrument" must be an object');
    }
    final lowest = raw['lowestPitch'];
    final highest = raw['highestPitch'];
    if (lowest is! int || highest is! int) {
      throw const FormatException(
        '"instrument" needs integer lowestPitch and highestPitch',
      );
    }
    if (lowest < 0 || highest > 127 || lowest >= highest) {
      throw FormatException(
        'the instrument range $lowest..$highest is not a MIDI range',
      );
    }
    return BassRange(lowest: lowest, highest: highest);
  }

  static WbpSource _readPhrase(Object? raw, BassRange range) {
    if (raw is! Map<String, Object?>) {
      throw const FormatException('every phrase must be an object');
    }
    final name = raw['name'];
    if (name is! String || name.trim().isEmpty) {
      throw const FormatException('every phrase needs a name');
    }

    final rawChords = raw['chords'];
    if (rawChords is! List || rawChords.isEmpty || rawChords.length > 4) {
      throw FormatException('phrase "$name" needs 1 to 4 chords');
    }
    final chords = <ExtChordSymbol>[
      for (final symbol in rawChords)
        if (symbol is String)
          ExtChordSymbol.parse(symbol)
        else
          throw FormatException('phrase "$name" has a non-string chord'),
    ];

    final beatsPerBar = raw['beatsPerBar'] ?? 4;
    if (beatsPerBar is! int || beatsPerBar < 1 || beatsPerBar > 16) {
      throw FormatException('phrase "$name" has a bad beatsPerBar');
    }

    final harmony = <BassChordSpan>[
      for (final (index, chord) in chords.indexed)
        BassChordSpan(
          (index * beatsPerBar).toDouble(),
          beatsPerBar.toDouble(),
          chord,
        ),
    ];

    final rawNotes = raw['notes'];
    if (rawNotes is! List || rawNotes.isEmpty) {
      throw FormatException('phrase "$name" has no notes');
    }
    final notes = rawNotes.first is int
        ? _readShortNotes(name, rawNotes, beatsPerBar, chords.length)
        : _readLongNotes(name, rawNotes, beatsPerBar);
    try {
      return WbpSource(
        name: name,
        harmony: harmony,
        notes: notes,
        tags: _readTags(name, raw['tags']),
        tempoRange: _readTempoRange(name, raw['tempoRange']),
        range: range,
      );
    } on ArgumentError catch (error) {
      throw FormatException('phrase "$name": ${error.message}');
    }
  }

  /// The short form: a pitch per beat, which is what a walking line is.
  static List<BassNoteSpec> _readShortNotes(
    String name,
    List<Object?> raw,
    int beatsPerBar,
    int barCount,
  ) {
    final expected = beatsPerBar * barCount;
    if (raw.length != expected) {
      throw FormatException(
        'phrase "$name" has ${raw.length} pitches for $barCount bars of '
        '$beatsPerBar; expected $expected',
      );
    }
    return <BassNoteSpec>[
      for (final (index, pitch) in raw.indexed)
        if (pitch is int)
          _shortNote(name, index, pitch, beatsPerBar)
        else
          throw FormatException('phrase "$name" has a non-integer pitch'),
    ];
  }

  static BassNoteSpec _shortNote(
    String name,
    int index,
    int pitch,
    int beatsPerBar,
  ) {
    try {
      return BassNoteSpec(
        beat: index.toDouble(),
        pitch: pitch,
        // The downbeat of each bar is where a walking line leans.
        velocity: index % beatsPerBar == 0 ? 94 : 82,
      );
    } on ArgumentError catch (error) {
      throw FormatException('phrase "$name": ${error.message}');
    }
  }

  /// The long form: anything that is not four to the bar.
  static List<BassNoteSpec> _readLongNotes(
    String name,
    List<Object?> raw,
    int beatsPerBar,
  ) => <BassNoteSpec>[
    for (final note in raw) _readLongNote(name, note, beatsPerBar),
  ];

  static BassNoteSpec _readLongNote(String name, Object? raw, int beatsPerBar) {
    if (raw is! Map<String, Object?>) {
      throw FormatException(
        'phrase "$name" mixes plain pitches and note objects; a phrase must '
        'use one form or the other',
      );
    }
    final beat = raw['beat'];
    final pitch = raw['pitch'];
    if (beat is! num || pitch is! int) {
      throw FormatException(
        'phrase "$name" has a note without a beat or pitch',
      );
    }
    final duration = raw['duration'] ?? 0.92;
    if (duration is! num) {
      throw FormatException('phrase "$name" has a non-numeric duration');
    }
    final velocity = raw['velocity'] ?? (beat % beatsPerBar == 0 ? 94 : 82);
    if (velocity is! int) {
      throw FormatException('phrase "$name" has a non-integer velocity');
    }
    try {
      return BassNoteSpec(
        beat: beat.toDouble(),
        pitch: pitch,
        durationBeats: duration.toDouble(),
        velocity: velocity,
      );
    } on ArgumentError catch (error) {
      throw FormatException('phrase "$name": ${error.message}');
    }
  }

  static Set<String> _readTags(String name, Object? raw) {
    if (raw == null) {
      return const <String>{};
    }
    if (raw is! List) {
      throw FormatException('phrase "$name" has non-list tags');
    }
    return <String>{
      for (final tag in raw)
        if (tag is String)
          tag
        else
          throw FormatException('phrase "$name" has a non-string tag'),
    };
  }

  static TempoRange? _readTempoRange(String name, Object? raw) {
    if (raw == null) {
      return null;
    }
    if (raw is! List || raw.length != 2 || raw[0] is! int || raw[1] is! int) {
      throw FormatException(
        'phrase "$name" needs a tempoRange of two integers, low first',
      );
    }
    try {
      return TempoRange(raw[0]! as int, raw[1]! as int);
    } on ArgumentError catch (error) {
      throw FormatException('phrase "$name": ${error.message}');
    }
  }

  /// Write a corpus back out, for the importer of §6.4.
  static String encode(BassCorpus corpus) {
    final encoder = const JsonEncoder.withIndent('  ');
    return encoder.convert(<String, Object?>{
      'schemaVersion': bassCorpusSchemaVersion,
      'name': corpus.name,
      'instrument': <String, Object?>{
        'lowestPitch': corpus.range.lowest,
        'highestPitch': corpus.range.highest,
      },
      'phrases': <Object?>[
        for (final phrase in corpus.phrases) _encodePhrase(phrase),
      ],
    });
  }

  static Map<String, Object?> _encodePhrase(WbpSource phrase) {
    final beatsPerBar = (phrase.lengthBeats / phrase.lengthBars).round();
    // The short form when the phrase really is a pitch per beat, because that
    // is the form a person can read in a diff (ADR 0008). Velocities must
    // match the accent pattern the short form implies too — a legally
    // accented phrase (the downbeat dug into, a ghost note let go) would
    // otherwise re-encode as a bare pitch array and lose its accents.
    final isWalking =
        phrase.notes.length == beatsPerBar * phrase.lengthBars &&
        phrase.notes.indexed.every(
          (entry) =>
              entry.$2.beat == entry.$1 &&
              entry.$2.durationBeats == 0.92 &&
              entry.$2.velocity == (entry.$1 % beatsPerBar == 0 ? 94 : 82),
        );
    return <String, Object?>{
      'name': phrase.name,
      'chords': <String>[
        for (final span in phrase.harmony) span.chord.format(),
      ],
      if (beatsPerBar != 4) 'beatsPerBar': beatsPerBar,
      'notes': isWalking
          ? <int>[for (final note in phrase.notes) note.pitch]
          : <Object?>[
              for (final note in phrase.notes)
                <String, Object?>{
                  'beat': note.beat,
                  'pitch': note.pitch,
                  'duration': note.durationBeats,
                  'velocity': note.velocity,
                },
            ],
      if (phrase.tags.isNotEmpty) 'tags': phrase.tags.toList()..sort(),
      if (phrase.tempoRange.lowest != TempoRange.any.lowest ||
          phrase.tempoRange.highest != TempoRange.any.highest)
        'tempoRange': <int>[
          phrase.tempoRange.lowest,
          phrase.tempoRange.highest,
        ],
    };
  }
}
