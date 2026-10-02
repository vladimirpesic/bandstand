import 'dart:io';

import 'package:tiling_probe/corpus.dart';
import 'package:tiling_probe/render.dart';
import 'package:tiling_probe/tiler.dart';

/// A 32-bar AABA form, built entirely from progressions the corpus covers.
///
/// This is the shape M0.5 asks for: something long enough that repetition would
/// become audible over three choruses, and made of the changes the corpus was
/// written over — a ii-V, a I-VI-ii-V turnaround, a held major, and a ii-V-I
/// into a bridge in a different key so transposition is actually exercised.
Progression standardForm() => Progression('AABA 32', <String>[
  // A
  'Cmaj7', 'A7', 'Dm7', 'G7', 'Cmaj7', 'A7', 'Dm7', 'G7',
  // A
  'Cmaj7', 'A7', 'Dm7', 'G7', 'Cmaj7', 'A7', 'Dm7', 'G7',
  // B — ii-V into Eb, then home
  'Fm7', 'Bb7', 'Ebmaj7', 'Ebmaj7', 'Dm7', 'G7', 'Cmaj7', 'Cmaj7',
  // A
  'Cmaj7', 'A7', 'Dm7', 'G7', 'Cmaj7', 'A7', 'Dm7', 'G7',
]);

void main(List<String> arguments) {
  final _Arguments options;
  try {
    options = _Arguments.parse(arguments);
  } on FormatException catch (error) {
    stderr
      ..writeln(error.message)
      ..writeln(_usage);
    exitCode = 1;
    return;
  }
  if (options.showHelp) {
    stdout.writeln(_usage);
    return;
  }

  final corpus = probeCorpus();
  final problems = <String>[
    for (final phrase in corpus)
      if (!phrase.startsOnRoot)
        '${phrase.name}: does not start on the root'
      else if (!phrase.endsOnChordTone)
        '${phrase.name}: does not end on a chord tone'
      else if (phrase.lowestPitch < lowestBassPitch ||
          phrase.highestPitch > highestBassPitch)
        '${phrase.name}: out of the bass range as written',
  ];
  if (problems.isNotEmpty) {
    stderr
      ..writeln('The corpus violates its own constraints:')
      ..writeAll(problems.map((p) => '  - $p\n'));
    exitCode = 1;
    return;
  }

  final form = standardForm();
  final full = form.repeated(options.choruses);

  final Tiling tiling;
  try {
    tiling = Tiler(corpus).tile(full);
  } on TilingFailure catch (failure) {
    stderr.writeln(failure);
    exitCode = 1;
    return;
  }

  final file = renderTiling(
    tiling: tiling,
    progression: full,
    formBars: form.barCount,
    options: RenderOptions(
      tempoBpm: options.tempo,
      guideChords: !options.noGuide,
      click: options.click,
      humanize: options.humanize,
      seed: options.seed,
    ),
  );

  final output = File(options.outputPath);
  output.parent.createSync(recursive: true);
  output.writeAsBytesSync(file.encode());

  _report(corpus.length, form, full, tiling, options, output);
}

void _report(
  int corpusSize,
  Progression form,
  Progression full,
  Tiling tiling,
  _Arguments options,
  File output,
) {
  final usage = <String, int>{};
  for (final placement in tiling.placements) {
    usage[placement.phrase.name] = (usage[placement.phrase.name] ?? 0) + 1;
  }
  final ranked = usage.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));

  stdout
    ..writeln('Bandstand — M0.5 corpus tiling probe')
    ..writeln('')
    ..writeln('  form            ${form.name}, ${form.barCount} bars')
    ..writeln(
      '  choruses        ${options.choruses} '
      '(${full.barCount} bars, ${_minutes(full.barCount, options.tempo)})',
    )
    ..writeln('  tempo           ${options.tempo.toStringAsFixed(0)} bpm')
    ..writeln('  corpus          $corpusSize phrases')
    ..writeln('  placements      ${tiling.placements.length}')
    ..writeln('  mean score      ${tiling.meanScore.toStringAsFixed(3)}')
    ..writeln('  widest join     ${tiling.widestJoin} semitones')
    ..writeln('  humanised       ${options.humanize ? 'yes' : 'no'}')
    ..writeln('  written to      ${output.path}')
    ..writeln('')
    ..writeln('Phrase usage (a flat distribution is what we want):');
  for (final entry in ranked) {
    stdout.writeln('  ${entry.value.toString().padLeft(3)}  ${entry.key}');
  }
  final unused = corpusSize - ranked.length;
  if (unused > 0) {
    stdout.writeln('  $unused phrase(s) never chosen');
  }

  stdout
    ..writeln('')
    ..writeln('Tiling, bar by bar:');
  for (final placement in tiling.placements) {
    final join = placement.joinInterval;
    final joinText = join == null
        ? '   start'
        : '${join >= 0 ? '+' : ''}$join'.padLeft(8);
    stdout.writeln(
      '  bar ${(placement.startBar + 1).toString().padLeft(3)}'
      '  ${placement.phrase.lengthBars} bar'
      '  join $joinText'
      '  score ${placement.score.toStringAsFixed(3)}'
      '  ${placement.phrase.name}',
    );
  }
}

String _minutes(int bars, double tempo) {
  final totalSeconds = (bars * 4 * 60 / tempo).round();
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

const String _usage = '''
Bandstand M0.5 probe — does corpus tiling produce a musical walking bass line?

Usage: dart run tiling_probe [options]

  --out <path>      output MIDI file, relative to the working directory
                    (default renders/tiling-probe.mid)
  --tempo <bpm>     tempo, default 132
  --choruses <n>    how many times through the form, default 3
  --seed <n>        RNG seed for humanisation, default 1
  --click           add a hi-hat on every beat
  --humanize        apply seeded timing and velocity jitter
  --no-guide        leave out the guide-chord track
  -h, --help        this message
''';

class _Arguments {
  _Arguments({
    required this.outputPath,
    required this.tempo,
    required this.choruses,
    required this.seed,
    required this.click,
    required this.humanize,
    required this.noGuide,
    required this.showHelp,
  });

  factory _Arguments.parse(List<String> arguments) {
    var outputPath = 'renders/tiling-probe.mid';
    var tempo = 132.0;
    var choruses = 3;
    var seed = 1;
    var click = false;
    var humanize = false;
    var noGuide = false;
    var showHelp = false;

    for (var i = 0; i < arguments.length; i++) {
      // The value of the option at `i`, failing with a usage-shaped message
      // rather than a RangeError when the option is the last argument.
      String value(String option) {
        if (i + 1 >= arguments.length) {
          throw FormatException('missing value for $option');
        }
        i++;
        return arguments[i];
      }

      switch (arguments[i]) {
        case '--out':
          outputPath = value('--out');
        case '--tempo':
          final raw = value('--tempo');
          // `double.tryParse` accepts "NaN" and "Infinity", and neither
          // survives the microseconds-per-beat conversion the MIDI writer
          // does — it throws "Infinity or NaN toInt". Zero and negatives get
          // that far and write a corrupt tempo instead, so the whole
          // non-positive range is rejected here rather than downstream.
          final parsedTempo = double.tryParse(raw);
          if (parsedTempo == null ||
              !parsedTempo.isFinite ||
              parsedTempo <= 0) {
            throw FormatException(
              '"$raw" is not a tempo — --tempo takes beats per minute '
              'above zero',
            );
          }
          tempo = parsedTempo;
        case '--choruses':
          final raw = value('--choruses');
          // Zero or fewer writes an empty MIDI file and a report of zeros,
          // which looks like a successful run that found nothing.
          final parsedChoruses = int.tryParse(raw);
          if (parsedChoruses == null || parsedChoruses < 1) {
            throw FormatException(
              '"$raw" is not a chorus count — --choruses takes a whole '
              'number of at least one',
            );
          }
          choruses = parsedChoruses;
        case '--seed':
          final raw = value('--seed');
          seed =
              int.tryParse(raw) ??
              (throw FormatException(
                '"$raw" is not a whole number — --seed takes a count',
              ));
        case '--click':
          click = true;
        case '--humanize':
          humanize = true;
        case '--no-guide':
          noGuide = true;
        case '-h':
        case '--help':
          showHelp = true;
        default:
          throw FormatException('unknown option "${arguments[i]}"');
      }
    }

    return _Arguments(
      outputPath: outputPath,
      tempo: tempo,
      choruses: choruses,
      seed: seed,
      click: click,
      humanize: humanize,
      noGuide: noGuide,
      showHelp: showHelp,
    );
  }

  final String outputPath;
  final double tempo;
  final int choruses;
  final int seed;
  final bool click;
  final bool humanize;
  final bool noGuide;
  final bool showHelp;
}
