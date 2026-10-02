import 'dart:io';

import 'package:bandstand/domain/generation/bass/bass_corpus.dart';
import 'package:bandstand/domain/generation/bass/bass_corpus_codec.dart';
import 'package:bandstand/domain/generation/bass/wbp_source.dart';
import 'package:bandstand/domain/harmony/chord_type_database.dart';
import 'package:bandstand/domain/harmony/harmony_registry.dart';
import 'package:bandstand/domain/harmony/scale.dart';
import 'package:bandstand/io/midi/midi_file.dart';
import 'package:corpus_import/annotation.dart';
import 'package:corpus_import/slicer.dart';

/// `corpus_import` — the ingest tool of §6.4.
///
/// Takes a MIDI take and a chord annotation, slices at bar boundaries, checks
/// every window against `docs/rules/corpus-tiling.md` §5, and writes the corpus
/// JSON of `docs/format/bass-corpus.md`.
///
/// It reports what it rejected and why. A take that yields three phrases from
/// thirty-two bars almost always means the annotation is a bar out of step with
/// the recording, and that is the kind of thing a tool must say out loud.
Future<void> main(List<String> arguments) async {
  // Dart discards whatever `main` returns, so the status has to be *set*: a
  // tool that prints an error and exits 0 is worse than one that crashes,
  // because the script driving it carries on as though the import worked.
  exitCode = await _run(arguments);
}

Future<int> _run(List<String> arguments) async {
  final options = _Options.parse(arguments);
  if (options == null) {
    stderr.writeln(_usage);
    return 2;
  }

  // The domain parses chords through the process-wide tables, so a tool has to
  // install them just as the app does at startup.
  try {
    Harmony.install(
      chordTypes: ChordTypeDatabase.fromJson(
        File(options.chordTypes).readAsStringSync(),
      ),
      scales: ScaleLibrary.fromJson(File(options.scales).readAsStringSync()),
    );
  } on FileSystemException catch (error) {
    stderr.writeln('${error.path ?? "a table"}: ${error.message}');
    return 1;
  } on FormatException catch (error) {
    stderr.writeln('the harmony tables are unreadable: ${error.message}');
    return 1;
  }

  final ChordAnnotation annotation;
  try {
    annotation = ChordAnnotation.parse(
      File(options.annotation).readAsStringSync(),
    );
  } on FileSystemException catch (error) {
    // A typo'd path is the commonest failure of all, and it arrives as a
    // `FileSystemException` rather than a `FormatException`: catching only the
    // latter turned the most ordinary mistake into a stack trace.
    stderr.writeln('${options.annotation}: ${error.message}');
    return 1;
  } on FormatException catch (error) {
    stderr.writeln('${options.annotation}: ${error.message}');
    return 1;
  }

  final MidiFileData midi;
  try {
    midi = MidiFileReader.read(File(options.midi).readAsBytesSync());
  } on FileSystemException catch (error) {
    stderr.writeln('${options.midi}: ${error.message}');
    return 1;
  } on FormatException catch (error) {
    stderr.writeln('${options.midi}: ${error.message}');
    return 1;
  }

  final result = const CorpusSlicer().slice(midi, annotation);
  _report(result, annotation, midi);

  if (result.corpus.isEmpty) {
    stderr.writeln(
      '\nNothing was harvested. The usual cause is an annotation that is a bar '
      'out of step with the recording — check that the first chord lands on '
      'the first note.',
    );
    return 1;
  }

  final BassCorpus merged;
  if (options.merge == null) {
    merged = result.corpus;
  } else {
    // Every failure here lands after the whole take has been sliced, so it has
    // to be reported rather than thrown: a stack trace at this point throws
    // away all the work and tells the player nothing about what to fix.
    try {
      merged = _merge(
        BassCorpusCodec.decode(File(options.merge!).readAsStringSync()),
        result.corpus,
      );
    } on FileSystemException catch (error) {
      stderr.writeln('${options.merge}: ${error.message}');
      return 1;
    } on FormatException catch (error) {
      stderr.writeln('${options.merge}: ${error.message}');
      return 1;
    }
  }

  try {
    File(options.output)
        .writeAsStringSync('${BassCorpusCodec.encode(merged)}\n');
  } on FileSystemException catch (error) {
    stderr.writeln('${options.output}: ${error.message}');
    return 1;
  }
  stdout.writeln('\nwrote ${merged.length} phrases to ${options.output}');
  return 0;
}

/// Add the harvested phrases to an existing corpus, renaming any clash.
///
/// The corpus is built up over many takes (§6.4), so appending has to be the
/// ordinary case rather than a special one.
BassCorpus _merge(BassCorpus existing, BassCorpus harvested) {
  final names = existing.phrases.map((phrase) => phrase.name).toSet();
  final added = <WbpSource>[];
  for (final phrase in harvested.phrases) {
    var name = phrase.name;
    var suffix = 2;
    while (!names.add(name)) {
      name = '${phrase.name} ($suffix)';
      suffix++;
    }
    added.add(
      WbpSource(
        name: name,
        harmony: phrase.harmony,
        notes: phrase.notes,
        tags: phrase.tags,
        tempoRange: phrase.tempoRange,
        // The harvested phrase's own range, not the existing corpus's: takes
        // recorded on different instruments carry different ranges, and
        // stamping the old one over them mislabels every phrase this run adds.
        range: phrase.range,
      ),
    );
  }
  return BassCorpus(
    name: existing.name,
    phrases: <WbpSource>[...existing.phrases, ...added],
    // The corpus-level range stays the existing one on purpose: a corpus is
    // one instrument's, and the tiler places every phrase inside it whatever
    // range the take was recorded against. Only the per-phrase ranges above
    // are preserved, because those record where the notes actually came from.
    range: existing.range,
  );
}

void _report(
  ImportResult result,
  ChordAnnotation annotation,
  MidiFileData midi,
) {
  stdout
    ..writeln('take:      ${annotation.name}')
    ..writeln(
      'annotated: ${annotation.barCount} bars of ${annotation.beatsPerBar}',
    )
    ..writeln(
      'midi:      ${midi.tracks.length} track(s), ppq '
      '${midi.ticksPerQuarter}',
    )
    ..writeln(
      'harvested: ${result.corpus.length} phrases across '
      '${result.corpus.profiles.length} root profiles',
    );

  final byLength = <int, int>{};
  for (final phrase in result.corpus.phrases) {
    byLength[phrase.lengthBars] = (byLength[phrase.lengthBars] ?? 0) + 1;
  }
  for (final length in byLength.keys.toList()..sort()) {
    stdout.writeln('  ${byLength[length]} of $length bar(s)');
  }

  if (result.rejections.isEmpty) {
    return;
  }
  stdout.writeln('rejected:  ${result.rejections.length} windows');
  final counts = result.rejectionCounts;
  for (final reason in RejectionReason.values) {
    final count = counts[reason];
    if (count != null) {
      stdout.writeln('  ${count.toString().padLeft(4)}  ${reason.name}');
    }
  }
}

const String _usage = '''
corpus_import — turn a bass take into corpus phrases (§6.4).

  dart run corpus_import --midi TAKE.mid --chords TAKE.chords --out CORPUS.json
                         [--merge EXISTING.json]
                         [--chord-types PATH] [--scales PATH]

  --midi         the recorded take
  --chords       the chord annotation; see lib/annotation.dart for the format
  --out          where to write the corpus JSON
  --merge        add to this corpus rather than starting a new one
  --chord-types  chord_types.json (default ../../app/assets/chord_types.json)
  --scales       scales.json      (default ../../app/assets/scales.json)
''';

class _Options {
  const _Options({
    required this.midi,
    required this.annotation,
    required this.output,
    required this.chordTypes,
    required this.scales,
    this.merge,
  });

  final String midi;
  final String annotation;
  final String output;
  final String chordTypes;
  final String scales;
  final String? merge;

  static _Options? parse(List<String> arguments) {
    final values = <String, String>{};
    for (var i = 0; i < arguments.length; i += 2) {
      if (!arguments[i].startsWith('--') || i + 1 >= arguments.length) {
        return null;
      }
      values[arguments[i].substring(2)] = arguments[i + 1];
    }
    final midi = values['midi'];
    final chords = values['chords'];
    final out = values['out'];
    if (midi == null || chords == null || out == null) {
      return null;
    }
    return _Options(
      midi: midi,
      annotation: chords,
      output: out,
      chordTypes: values['chord-types'] ?? '../../app/assets/chord_types.json',
      scales: values['scales'] ?? '../../app/assets/scales.json',
      merge: values['merge'],
    );
  }
}
