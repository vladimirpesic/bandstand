import 'package:bandstand/domain/generation/voicing/voicing.dart';
import 'package:bandstand/domain/generation/voicing/voicing_constraints.dart';
import 'package:bandstand/domain/generation/voicing/voicing_engine.dart';
import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../harmony/harmony_test_support.dart';

/// §10 M7: *"voicings pass a music-theory test suite (no root doubling in
/// rootless voicings, voice movement under 4 semitones between successive
/// chords, no interval clashes)"*.
void main() {
  installTestHarmony();

  const engine = VoicingEngine();

  List<ExtChordSymbol> chords(List<String> symbols) =>
      symbols.map(ExtChordSymbol.parse).toList();

  /// Every key, so a rule cannot pass by luck of C major.
  const allRoots = <String>[
    'C', 'Db', 'D', 'Eb', 'E', 'F', 'Gb', 'G', 'Ab', 'A', 'Bb', 'B', //
  ];

  group('the acceptance criteria of §10 M7', () {
    test('no root doubling in rootless voicings', () {
      for (final root in allRoots) {
        for (final quality in <String>['m7', '7', 'maj7', 'm7b5']) {
          final chord = ExtChordSymbol.parse('$root$quality');
          final choice = engine.choose(chord);
          expect(choice, isNotNull, reason: '$root$quality');
          final voicing = choice!.voicing;
          if (voicing.family.isRootless) {
            expect(
              voicing.hasRoot,
              isFalse,
              reason: '$root$quality voiced as $voicing sounds its own root',
            );
          }
        }
      }
    });

    test('voice movement stays under 4 semitones between chords', () {
      // A ii-V-I round the cycle of fourths: twelve keys, three chords each,
      // led continuously so every join is measured.
      const cycle = <String>[
        'C', 'F', 'Bb', 'Eb', 'Ab', 'Db', 'Gb', 'B', 'E', 'A', 'D', 'G', //
      ];
      for (final key in cycle) {
        final tonic = ExtChordSymbol.parse('${key}maj7');
        final two = tonic.transposed(2);
        final five = tonic.transposed(7);
        final sequence = <ExtChordSymbol>[
          ExtChordSymbol.parse('${two.root.toString()}m7'),
          ExtChordSymbol.parse('${five.root.toString()}7'),
          tonic,
        ];
        final choices = engine.voiceSequence(sequence);
        for (var i = 1; i < choices.length; i++) {
          final choice = choices[i];
          expect(choice, isNotNull, reason: '$key chord $i');
          expect(
            choice!.largestMove,
            lessThan(VoicingConstraints.maximumVoiceMovement),
            reason:
                'in $key, ${sequence[i].format()} moved a voice '
                '${choice.largestMove} semitones: ${choice.voicing}',
          );
        }
      }
    });

    test('no interval clashes', () {
      for (final root in allRoots) {
        for (final quality in <String>[
          'm7', '7', 'maj7', 'm7b5', '7b9', '6', 'm6', 'maj9', 'm9', //
        ]) {
          final choice = engine.choose(ExtChordSymbol.parse('$root$quality'));
          if (choice == null) {
            continue;
          }
          final voicing = choice.voicing;
          final pitches = voicing.pitches;

          // No minor ninth between any two voices, in any octave: 13
          // semitones is the clash, and 25 or 37 are the same rub an octave
          // or two up.
          for (var i = 0; i < pitches.length; i++) {
            for (var j = i + 1; j < pitches.length; j++) {
              final interval = pitches[j] - pitches[i];
              expect(
                interval % 12 == 1 && interval > 12,
                isFalse,
                reason: 'minor ninth in $root$quality: $voicing',
              );
            }
          }
          // No doubled pitch class.
          expect(
            voicing.pitchClasses.length,
            voicing.length,
            reason: 'doubled note in $root$quality: $voicing',
          );
          // No interval below its low limit.
          for (var i = 1; i < pitches.length; i++) {
            final interval = pitches[i] - pitches[i - 1];
            final limit = VoicingConstraints.lowIntervalLimits[interval % 12];
            if (limit != null) {
              expect(
                pitches[i - 1],
                greaterThanOrEqualTo(limit),
                reason: 'muddy $interval-semitone interval in $voicing',
              );
            }
          }
        }
      }
    });
  });

  group('guide tones', () {
    test('every voicing states the third and the seventh', () {
      // Semitones above the root, written out rather than derived from the
      // symbol: "maj7" begins with an m, and a prefix test quietly demanded a
      // minor third from every major seventh.
      const guideTones = <String, ({int third, int seventh})>{
        'm7': (third: 3, seventh: 10),
        '7': (third: 4, seventh: 10),
        'maj7': (third: 4, seventh: 11),
        'm7b5': (third: 3, seventh: 10),
      };
      for (final root in allRoots) {
        for (final entry in guideTones.entries) {
          final chord = ExtChordSymbol.parse('$root${entry.key}');
          final choice = engine.choose(chord);
          expect(choice, isNotNull, reason: '$root${entry.key}');
          final classes = choice!.voicing.pitchClasses;
          expect(
            classes,
            contains((chord.root.pitchClass + entry.value.third) % 12),
            reason: '$root${entry.key} third, voiced ${choice.voicing}',
          );
          expect(
            classes,
            contains((chord.root.pitchClass + entry.value.seventh) % 12),
            reason: '$root${entry.key} seventh, voiced ${choice.voicing}',
          );
        }
      }
    });
  });

  group('voice leading', () {
    test('a ii-V moves one voice by one semitone', () {
      // The textbook alternation: `Dm7` with the seventh at the bottom into
      // `G7` with the third, and only the C moves, down to B.
      final choices = engine.voiceSequence(
        chords(<String>['Dm7', 'G7', 'Cmaj7']),
      );
      expect(choices.every((choice) => choice != null), isTrue);
      expect(choices[1]!.movement, 1);
      expect(choices[1]!.largestMove, 1);
      expect(choices[2]!.largestMove, lessThanOrEqualTo(2));
    });

    test('a I-VI turnaround needs the inversion the textbook does not name', () {
      // `Cmaj7` as E G B D into `A7`: the set with the fifth, starting on the
      // fifth, holds three voices and moves D to C#. Neither type A nor type B
      // can do better than four, which is over the cap.
      final choices = engine.voiceSequence(
        chords(<String>['Cmaj7', 'A7', 'Dm7', 'G7']),
      );
      for (final choice in choices) {
        expect(choice, isNotNull);
        expect(
          choice!.relaxation,
          VoicingRelaxation.none,
          reason: 'a plain turnaround should need no relaxation: $choice',
        );
        expect(
          choice.largestMove,
          lessThan(VoicingConstraints.maximumVoiceMovement),
        );
      }
      expect(choices[1]!.movement, 1);
    });

    test(
      'the first chord has nothing to lead from, so it reports no movement',
      () {
        final choice = engine.choose(ExtChordSymbol.parse('Dm7'));
        expect(choice!.movement, 0);
        expect(choice.largestMove, 0);
      },
    );

    test('a chord that cannot be voiced does not reset the hand', () {
      // `N.C.` yields nothing, and the chord after it still leads from the
      // chord before it (`comping.md` §5).
      final choices = engine.voiceSequence(
        chords(<String>['Dm7', 'N.C.', 'G7']),
      );
      expect(choices[1], isNull);
      expect(choices[2], isNotNull);
      expect(
        choices[2]!.largestMove,
        lessThan(VoicingConstraints.maximumVoiceMovement),
      );
    });

    test('it is deterministic', () {
      List<String> run() => engine
          .voiceSequence(chords(<String>['Cmaj7', 'A7', 'Dm7', 'G7']))
          .map((choice) => choice!.voicing.pitches.join(','))
          .toList();
      expect(run(), run());
    });
  });

  group('seeds', () {
    test('a seed that breaks a rule is not reported clean', () {
      // Seeds from `VoicingBuilder.candidates` are deliberately unfiltered.
      // `Csus` has no rootless shape in the tables of §3.1 — a sus chord
      // names no third to build one from — so with a bass in the band every
      // candidate is turned away at `none`, `movementCap` or `shell` for
      // family reasons, and only the `root` step (triads) or the `shell`
      // step (quartals, drop2s) will take one. Whichever seed wins, the
      // first choice of the chain must carry that relaxation rather than
      // claim `isClean`.
      final choices = engine.voiceSequence(chords(<String>['Csus4']));
      expect(choices.single, isNotNull);
      expect(
        choices.single!.isClean,
        isFalse,
        reason: 'every seed for Csus4 bends the family rule: ${choices.single}',
      );
    });

    test('a chain seeded cleanly still reports no relaxation', () {
      // The same seeding search, on harmony the tables cover: nothing bent,
      // nothing to report.
      final choices = engine.voiceSequence(
        chords(<String>['Dm7', 'G7', 'Cmaj7']),
      );
      for (final choice in choices) {
        expect(choice, isNotNull);
        expect(choice!.isClean, isTrue, reason: '$choice');
      }
    });
  });

  group('register', () {
    test('everything lands inside the comping band', () {
      for (final root in allRoots) {
        final choice = engine.choose(ExtChordSymbol.parse('${root}m7'));
        expect(choice, isNotNull);
        expect(
          choice!.voicing.lowest,
          greaterThanOrEqualTo(VoicingConstraints.lowestPitch),
        );
        expect(
          choice.voicing.highest,
          lessThanOrEqualTo(VoicingConstraints.highestPitch),
        );
      }
    });

    test('a rootless voicing sits in the narrower rootless band', () {
      for (final root in allRoots) {
        final choice = engine.choose(ExtChordSymbol.parse('${root}m7'));
        final voicing = choice!.voicing;
        if (voicing.family.isRootless) {
          expect(
            voicing.lowest,
            greaterThanOrEqualTo(VoicingConstraints.rootlessLowest),
          );
          expect(
            voicing.highest,
            lessThanOrEqualTo(VoicingConstraints.rootlessHighest),
          );
        }
      }
    });
  });

  group('solo piano', () {
    test('without a bass player the root comes back', () {
      const solo = VoicingEngine(preferRootless: false);
      final choice = solo.choose(ExtChordSymbol.parse('Dm7'));
      expect(choice, isNotNull);
      expect(choice!.voicing.hasRoot, isTrue);
      expect(choice.voicing.family, VoicingFamily.shell);
    });
  });

  group('Voicing itself', () {
    test('it refuses a stack that does not ascend', () {
      expect(
        () => Voicing(
          pitches: <int>[60, 60],
          chord: ExtChordSymbol.parse('Cmaj7'),
          family: VoicingFamily.shell,
        ),
        throwsArgumentError,
      );
      expect(
        () => Voicing(
          pitches: <int>[64, 60],
          chord: ExtChordSymbol.parse('Cmaj7'),
          family: VoicingFamily.shell,
        ),
        throwsArgumentError,
      );
    });

    test('it reports its own shape', () {
      final voicing = Voicing(
        pitches: <int>[53, 57, 60, 64],
        chord: ExtChordSymbol.parse('Dm7'),
        family: VoicingFamily.rootless,
      );
      expect(voicing.span, 11);
      expect(voicing.intervals, <int>[4, 3, 4]);
      expect(voicing.centre, 58.5);
      expect(voicing.hasRoot, isFalse);
      expect(voicing.transposed(12).pitches, <int>[65, 69, 72, 76]);
    });
  });
}
