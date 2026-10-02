import 'dart:io';

import 'package:bandstand/domain/generation/bass/bass_corpus.dart';
import 'package:bandstand/domain/generation/bass/bass_corpus_codec.dart';
import 'package:bandstand/domain/generation/bass/walking_bass_generator.dart';
import 'package:bandstand/domain/generation/generation_context.dart';
import 'package:bandstand/domain/generation/music_generator.dart';
import 'package:bandstand/domain/harmony/chord_type_database.dart';
import 'package:bandstand/domain/harmony/ext_chord_symbol.dart';
import 'package:bandstand/domain/harmony/harmony_registry.dart';
import 'package:bandstand/domain/harmony/scale.dart';
import 'package:bandstand/domain/harmony/time_signature.dart';
import 'package:bandstand/domain/phrase/float_range.dart';
import 'package:bandstand/domain/phrase/note_event.dart';
import 'package:bandstand/io/midi/midi_writer.dart';

/// `audition` — play the corpus and write what came out (§10 M6).
///
/// The acceptance for M6 is a listening test, and a listening test needs
/// something to listen to. This runs the real [WalkingBassGenerator] over a
/// progression and writes a MIDI file, so the judgement is made on what the app
/// actually plays rather than on a number in a report.
///
/// It prints the tiling alongside, because "does it repeat" is answered faster
/// by reading the phrase names than by listening three times.
Future<void> main(List<String> arguments) async {
  // Dart discards whatever `main` returns; the status has to be set. See the
  // same note in `corpus_import.dart`.
  exitCode = await _run(arguments);
}

Future<int> _run(List<String> arguments) async {
  final options = _Options.parse(arguments);
  if (options == null) {
    stderr.writeln(_usage);
    return 2;
  }

  final BassCorpus corpus;
  try {
    Harmony.install(
      chordTypes: ChordTypeDatabase.fromJson(
        File(options.chordTypes).readAsStringSync(),
      ),
      scales: ScaleLibrary.fromJson(File(options.scales).readAsStringSync()),
    );
    corpus = BassCorpusCodec.decode(File(options.corpus).readAsStringSync());
  } on FileSystemException catch (error) {
    stderr.writeln('${error.path ?? "a file"}: ${error.message}');
    return 1;
  } on FormatException catch (error) {
    stderr.writeln('${options.corpus}: ${error.message}');
    return 1;
  }
  final generator = WalkingBassGenerator(corpus);

  final List<ExtChordSymbol> oneChorus;
  try {
    oneChorus = options.progression
        .split(RegExp(r'[|\s]+'))
        .where((token) => token.isNotEmpty)
        .map(ExtChordSymbol.parse)
        .toList();
  } on FormatException catch (error) {
    stderr.writeln('--progression: ${error.message}');
    return 1;
  }
  if (oneChorus.isEmpty) {
    stderr.writeln('--progression names no chords');
    return 1;
  }
  final bars = <ExtChordSymbol>[
    for (var chorus = 0; chorus < options.choruses; chorus++) ...oneChorus,
  ];

  final started = DateTime.now();
  final result = generator.generate(
    GenerationContext(
      chords: <ContextChord>[
        for (final (index, chord) in bars.indexed)
          ContextChord(
            chord: chord,
            startBeat: index * 4.0,
            endBeat: (index + 1) * 4.0,
          ),
      ],
      beatRange: FloatRange(0, bars.length * 4.0),
      timeSignature: TimeSignature.fourFour,
      tempo: options.tempo,
      randomSeed: options.seed,
      parameterValues: const <String, Object>{},
    ),
  );
  final elapsed = DateTime.now().difference(started);

  final phrase = result[WalkingBassGenerator.bass];
  if (phrase == null || phrase.isEmpty) {
    stderr.writeln('nothing was generated');
    return 1;
  }

  _report(result, bars, options, elapsed);
  _writeMidi(options, phrase.notes.toList());
  return 0;
}

void _report(
  GeneratedPart result,
  List<ExtChordSymbol> bars,
  _Options options,
  Duration elapsed,
) {
  final phrase = result[WalkingBassGenerator.bass]!;
  final pitches = phrase.notes.map((note) => note.pitch).toList();
  stdout
    ..writeln('corpus:   ${options.corpus}')
    ..writeln(
      'form:     ${bars.length} bars, ${options.choruses} chorus(es) '
      'at ${options.tempo} bpm',
    )
    ..writeln('notes:    ${phrase.length}')
    ..writeln(
      'range:    ${pitches.reduce((a, b) => a < b ? a : b)}'
      '..${pitches.reduce((a, b) => a > b ? a : b)}',
    )
    ..writeln(
      'generated in ${elapsed.inMicroseconds / 1000} ms '
      '(§3 allows 100 ms for a whole song)',
    );
  for (final problem in result.problems) {
    stdout.writeln('  ! $problem');
  }
}

void _writeMidi(_Options options, List<NoteEvent> notes) {
  const ppq = 480;
  final events = <MidiWriteEvent>[
    MidiWriteEvent.trackName('bandstand walking bass'),
    MidiWriteEvent.tempo(0, options.tempo.toDouble()),
    MidiWriteEvent.timeSignature(0, 4, 4),
    // 33 = acoustic bass, so a General MIDI bank plays it as one.
    MidiWriteEvent.program(0, 0, 32),
  ];
  for (final note in notes) {
    final start = (note.positionInBeats * ppq).round();
    final end = (note.endInBeats * ppq).round();
    events
      ..add(MidiWriteEvent.noteOn(start, 0, note.pitch, note.velocity))
      ..add(MidiWriteEvent.noteOff(end, 0, note.pitch));
  }
  File(options.output).writeAsBytesSync(
    MidiFileWriter.write(
      ticksPerQuarter: ppq,
      tracks: <List<MidiWriteEvent>>[events],
    ),
  );
  stdout.writeln('wrote ${options.output}');
  stdout.writeln(
    'render it with:\n'
    '  fluidsynth -ni -F ${options.output.replaceAll('.mid', '.wav')} '
    '-r 48000 <soundfont.sf2> ${options.output}',
  );
}

const String _usage = '''
audition — generate a bass line and write it to MIDI, to be listened to (§10 M6).

  dart run bin/audition.dart --out LINE.mid
      [--progression "Dm7 G7 Cmaj7 Cmaj7"]  the form, one chord per bar
      [--choruses 3]  [--tempo 160]  [--seed 0]
      [--corpus PATH] [--chord-types PATH] [--scales PATH]
''';

class _Options {
  const _Options({
    required this.output,
    required this.progression,
    required this.choruses,
    required this.tempo,
    required this.seed,
    required this.corpus,
    required this.chordTypes,
    required this.scales,
  });

  final String output;
  final String progression;
  final int choruses;
  final int tempo;
  final int seed;
  final String corpus;
  final String chordTypes;
  final String scales;

  static _Options? parse(List<String> arguments) {
    final values = <String, String>{};
    for (var i = 0; i < arguments.length; i += 2) {
      if (!arguments[i].startsWith('--') || i + 1 >= arguments.length) {
        return null;
      }
      values[arguments[i].substring(2)] = arguments[i + 1];
    }
    final out = values['out'];
    if (out == null) {
      return null;
    }
    // Falling back to the default on unparseable input would audition
    // something other than what was asked for and say nothing about it, so a
    // bad value is a usage error rather than a silent substitution. A tempo or
    // a chorus count of zero is bad input too: it writes an empty file.
    final choruses = int.tryParse(values['choruses'] ?? '3');
    final tempo = int.tryParse(values['tempo'] ?? '160');
    final seed = int.tryParse(values['seed'] ?? '0');
    if (choruses == null || choruses < 1) {
      return null;
    }
    if (tempo == null || tempo < 1) {
      return null;
    }
    if (seed == null) {
      return null;
    }
    return _Options(
      output: out,
      progression: values['progression'] ?? 'Dm7 G7 Cmaj7 Cmaj7',
      choruses: choruses,
      tempo: tempo,
      seed: seed,
      corpus: values['corpus'] ?? '../../app/assets/bass_corpus.json',
      chordTypes: values['chord-types'] ?? '../../app/assets/chord_types.json',
      scales: values['scales'] ?? '../../app/assets/scales.json',
    );
  }
}
