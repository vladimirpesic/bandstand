import 'dart:io';

import 'package:bandstand/domain/generation/bass/bass_corpus_codec.dart';
import 'package:bandstand/domain/generation/bass/walking_bass_generator.dart';
import 'package:bandstand/domain/generation/comping/comping_cells.dart';
import 'package:bandstand/domain/generation/comping/comping_generator.dart';
import 'package:bandstand/domain/generation/drum_generator.dart';
import 'package:bandstand/domain/generation/drum_patterns.dart';
import 'package:bandstand/domain/generation/ensemble_generator.dart';
import 'package:bandstand/domain/generation/generation_context.dart';
import 'package:bandstand/domain/generation/music_generator.dart';
import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:bandstand/domain/phrase/float_range.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harmony/harmony_test_support.dart';

/// The fastest of `runs` timings of `work`, in milliseconds.
///
/// Best-of rather than a single shot. These run inside a suite that Flutter
/// executes concurrently, and one scheduler hiccup on the single iteration
/// that happens to be measured turns a 48 ms benchmark into a failure against
/// a 300 ms bound — which is what happened. The fastest run is the machine's
/// actual capability, it is the number `docs/benchmarks.md` should carry, and
/// it is the one a contended core cannot fake.
double fastestMillis(void Function() work, {int runs = 5}) {
  var best = double.infinity;
  for (var i = 0; i < runs; i++) {
    final watch = Stopwatch()..start();
    work();
    watch.stop();
    final millis = watch.elapsedMicroseconds / 1000;
    if (millis < best) {
      best = millis;
    }
  }
  return best;
}

void main() {
  installTestHarmony();

  final drums = DrumGenerator(
    DrumPatternSet.fromJson(
      File('assets/drum_patterns.json').readAsStringSync(),
    ),
  );
  final bass = WalkingBassGenerator(
    BassCorpusCodec.decode(File('assets/bass_corpus.json').readAsStringSync()),
  );
  final band = EnsembleGenerator(
    id: 'swing',
    displayName: 'Swing',
    members: <MusicGenerator>[drums, bass],
  );
  final trio = EnsembleGenerator(
    id: 'swing-trio',
    displayName: 'Swing trio',
    members: <MusicGenerator>[
      drums,
      bass,
      CompingGenerator(
        CompingCellSet.fromJson(
          File('assets/comping_cells.json').readAsStringSync(),
        ),
      ),
    ],
  );

  GenerationContext context({Map<String, Object> parameters = const {}}) =>
      GenerationContext(
        chords: <ContextChord>[
          for (final (index, symbol) in <String>[
            'Dm7',
            'G7',
            'Cmaj7',
            'Cmaj7',
          ].indexed)
            ContextChord(
              chord: ExtChordSymbol.parse(symbol),
              startBeat: index * 4.0,
              endBeat: (index + 1) * 4.0,
            ),
        ],
        beatRange: FloatRange(0, 16),
        timeSignature: TimeSignature.fourFour,
        tempo: 160,
        randomSeed: 7,
        parameterValues: parameters,
      );

  group('the band', () {
    test('it plays the voices of every member', () {
      expect(band.voices.map((voice) => voice.id), <String>['drums', 'bass']);
      final result = band.generate(context());
      expect(result.voices.map((voice) => voice.id).toSet(), <String>{
        'drums',
        'bass',
      });
      for (final voice in result.voices) {
        expect(result[voice]!.isNotEmpty, isTrue, reason: voice.id);
      }
    });

    test('parameters are namespaced, so two intensities stay apart', () {
      final ids = band.parameters.map((parameter) => parameter.id).toList();
      expect(ids, contains('drums.intensity'));
      expect(ids, contains('walking-bass.intensity'));
      expect(ids.toSet().length, ids.length);
    });

    test('a member sees its own parameters, without the namespace', () {
      // Turn the bass down and the drums up; only the bass should move.
      int meanVelocity(Map<String, Object> parameters, String voiceId) {
        final result = band.generate(context(parameters: parameters));
        final voice = result.voices.firstWhere((voice) => voice.id == voiceId);
        final phrase = result[voice]!;
        return phrase.notes
                .map((note) => note.velocity)
                .reduce((a, b) => a + b) ~/
            phrase.length;
      }

      const loud = <String, Object>{
        'drums.intensity': 50,
        'walking-bass.intensity': 95,
      };
      const quiet = <String, Object>{
        'drums.intensity': 50,
        'walking-bass.intensity': 5,
      };
      expect(
        meanVelocity(loud, 'bass'),
        greaterThan(meanVelocity(quiet, 'bass')),
      );
      expect(meanVelocity(loud, 'drums'), meanVelocity(quiet, 'drums'));
    });

    test('problems from every member reach the caller, named', () {
      final lonely = EnsembleGenerator(
        id: 'meterless',
        displayName: 'Meterless',
        members: <MusicGenerator>[drums, bass],
      );
      final result = lonely.generate(
        GenerationContext(
          chords: <ContextChord>[
            ContextChord(
              chord: ExtChordSymbol.parse('C7#5'),
              startBeat: 0,
              endBeat: 8,
            ),
          ],
          beatRange: FloatRange(0, 8),
          timeSignature: TimeSignature.fourFour,
          tempo: 160,
          randomSeed: 1,
          parameterValues: const <String, Object>{},
        ),
      );
      expect(result.problems, isNotEmpty);
      expect(result.problems.first, contains('Walking bass'));
    });

    test('it is deterministic, like every generator (§6.2)', () {
      List<int> run() {
        final result = band.generate(context());
        return <int>[
          for (final voice in result.voices)
            for (final note in result[voice]!.notes) note.pitch,
        ];
      }

      expect(run(), run());
    });

    test('changing one member does not reroll the other', () {
      // The seed is mixed with the member id, so the drums are the same drums
      // whatever the bass is doing.
      List<int> drumPitches(int bassIntensity) {
        final result = band.generate(
          context(
            parameters: <String, Object>{
              'walking-bass.intensity': bassIntensity,
            },
          ),
        );
        final voice = result.voices.firstWhere((voice) => voice.id == 'drums');
        return result[voice]!.notes.map((note) => note.pitch).toList();
      }

      expect(drumPitches(10), drumPitches(90));
    });
  });

  group('the §3 budget', () {
    test('the whole trio stays inside the budget over a long song', () {
      // What a user actually presses play on: drums, walking bass and comping
      // piano over 192 bars.
      const chorus = <String>[
        'Cmaj7', 'A7', 'Dm7', 'G7', 'Cmaj7', 'A7', 'Dm7', 'G7', //
        'Cmaj7', 'Cmaj7', 'Dm7', 'G7', 'Cmaj7', 'A7', 'Dm7', 'G7', //
        'Cmaj7', 'A7', 'Dm7', 'G7', 'Cmaj7', 'A7', 'Dm7', 'G7', //
        'Cmaj7', 'A7', 'Dm7', 'G7', 'Cmaj7', 'A7', 'Dm7', 'G7', //
      ];
      final bars = <String>[for (var i = 0; i < 6; i++) ...chorus];
      final long = GenerationContext(
        chords: <ContextChord>[
          for (final (index, symbol) in bars.indexed)
            ContextChord(
              chord: ExtChordSymbol.parse(symbol),
              startBeat: index * 4.0,
              endBeat: (index + 1) * 4.0,
            ),
        ],
        beatRange: FloatRange(0, bars.length * 4.0),
        timeSignature: TimeSignature.fourFour,
        tempo: 160,
        randomSeed: 7,
        parameterValues: const <String, Object>{},
      );

      for (var i = 0; i < 3; i++) {
        trio.generate(long);
      }
      expect(trio.generate(long).voices, hasLength(3));
      final millis = fastestMillis(() => trio.generate(long));
      // ignore: avoid_print
      print('BENCH 192-bar trio: $millis ms');
      // §3: 100 ms target, 300 ms hard limit.
      expect(millis, lessThan(300), reason: '$millis ms for 192 bars');
    });
  });

  group('it refuses a band that cannot work', () {
    test('two members writing the same voice', () {
      expect(
        () => EnsembleGenerator(
          id: 'twice',
          displayName: 'Twice',
          members: <MusicGenerator>[bass, bass],
        ),
        throwsArgumentError,
      );
    });

    test('no members at all', () {
      expect(
        () => EnsembleGenerator(
          id: 'empty',
          displayName: 'Empty',
          members: const <MusicGenerator>[],
        ),
        throwsArgumentError,
      );
    });
  });
}
