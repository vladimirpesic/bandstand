import 'dart:io';

import 'package:bandstand/domain/generation/drum_generator.dart';
import 'package:bandstand/domain/generation/drum_patterns.dart';
import 'package:bandstand/domain/generation/generation_context.dart';
import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:bandstand/domain/phrase/float_range.dart';
import 'package:bandstand/domain/phrase/phrase.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harmony/harmony_test_support.dart';

DrumPatternSet loadPatterns() => DrumPatternSet.fromJson(
  File('assets/drum_patterns.json').readAsStringSync(),
);

void main() {
  installTestHarmony();
  final patterns = loadPatterns();
  final generator = DrumGenerator(patterns);

  GenerationContext context({
    double beats = 16,
    TimeSignature meter = TimeSignature.fourFour,
    int intensity = 50,
    int seed = 1,
    bool fills = true,
    int partIndex = 0,
    int partCount = 1,
  }) => GenerationContext(
    chords: <ContextChord>[
      ContextChord(
        chord: ExtChordSymbol.parse('Cmaj7'),
        startBeat: 0,
        endBeat: beats,
      ),
    ],
    beatRange: FloatRange(0, beats),
    timeSignature: meter,
    tempo: 140,
    randomSeed: seed,
    parameterValues: <String, Object>{
      DrumGenerator.intensityParameter: intensity,
      DrumGenerator.fillParameter: fills,
    },
    partIndex: partIndex,
    partCount: partCount,
    isFirstPart: partIndex == 0,
    isLastPart: partIndex == partCount - 1,
  );

  SizedPhrase drumsOf(GenerationContext c) =>
      generator.generate(c)[DrumGenerator.drums]!;

  group('the pattern file', () {
    test('loads, and every pattern is well formed', () {
      expect(patterns.patterns.length, greaterThanOrEqualTo(8));
      expect(patterns.instruments, isNotEmpty);
      for (final pattern in patterns.patterns) {
        expect(pattern.hits, isNotEmpty, reason: pattern.id);
        for (final hit in pattern.hits) {
          expect(patterns.keyFor(hit.instrument), isNotNull);
          expect(hit.beat, lessThan(pattern.lengthBeats));
          expect(hit.velocity, inInclusiveRange(1, 127));
        }
      }
    });

    test(
      'covers the meters it claims, with a groove, a fill and an ending',
      () {
        for (final meter in patterns.meters) {
          expect(
            patterns.matching(meter, PatternRole.groove),
            isNotEmpty,
            reason: '$meter has no groove',
          );
        }
        expect(
          patterns.matching(TimeSignature.fourFour, PatternRole.fill),
          isNotEmpty,
        );
        expect(
          patterns.matching(TimeSignature.fourFour, PatternRole.ending),
          isNotEmpty,
        );
      },
    );

    test('refuses a malformed file rather than half-loading it', () {
      expect(
        () => DrumPatternSet.fromJson('{"schemaVersion": 99}'),
        throwsFormatException,
      );
      // `throwsA(isA<Object>())` matches literally anything thrown, including
      // the `TypeError` a half-written parser would raise, so it asserted
      // nothing at all. The contract is a `FormatException`.
      expect(() => DrumPatternSet.fromJson('nonsense'), throwsFormatException);
      expect(
        () => DrumPatternSet.fromJson(
          '{"schemaVersion":1,"instruments":{"kick":36},"patterns":['
          '{"id":"a","meter":"4/4","bars":1,"hits":['
          '{"instrument":"nosuch","beat":0,"velocity":80}]}]}',
        ),
        throwsFormatException,
      );
      expect(
        () => DrumPatternSet.fromJson(
          '{"schemaVersion":1,"instruments":{"kick":36},"patterns":['
          '{"id":"a","meter":"4/4","bars":1,"hits":['
          '{"instrument":"kick","beat":9,"velocity":80}]}]}',
        ),
        throwsFormatException,
      );
    });
  });

  group('generating', () {
    test('four bars of 4/4 produce drums', () {
      final drums = drumsOf(context());
      expect(drums.isNotEmpty, isTrue);
      expect(drums.isDrums, isTrue);
      expect(drums.channel, drumChannel);
      expect(drums.beatRange, FloatRange(0, 16));
    });

    test('every note lands inside the part and on a real drum key', () {
      final drums = drumsOf(context(beats: 32));
      final keys = patterns.instruments.values.toSet();
      for (final note in drums.notes) {
        expect(note.positionInBeats, inInclusiveRange(0, 32));
        expect(keys.contains(note.pitch), isTrue, reason: '${note.pitch}');
        expect(note.velocity, inInclusiveRange(1, 127));
      }
    });

    test('the same seed gives the same drums, every time', () {
      final first = drumsOf(context(seed: 7, beats: 64));
      final second = drumsOf(context(seed: 7, beats: 64));
      expect(first, second);
    });

    test('a different seed gives a different take', () {
      final first = drumsOf(context(seed: 1, beats: 64));
      final second = drumsOf(context(seed: 2, beats: 64));
      expect(first, isNot(second));
      // But both are still drums.
      expect(first.isNotEmpty && second.isNotEmpty, isTrue);
    });

    test('a bar edited late does not change what came before it', () {
      // The seed is mixed with the bar, so bar 2 is stable when bar 30 moves.
      // Compare a stretch that neither part's *ending* falls in: where the
      // form ends legitimately changes where the fills go.
      final short = drumsOf(context(beats: 32, seed: 5));
      final long = drumsOf(context(beats: 128, seed: 5));
      final firstFour = long.sliced(FloatRange(0, 16));
      expect(
        firstFour.notes.map((n) => '${n.positionInBeats}:${n.pitch}').toList(),
        short
            .sliced(FloatRange(0, 16))
            .notes
            .map((n) => '${n.positionInBeats}:${n.pitch}')
            .toList(),
      );
    });

    test('a louder part is louder', () {
      double meanVelocity(SizedPhrase phrase) =>
          phrase.notes.map((n) => n.velocity).reduce((a, b) => a + b) /
          phrase.length;
      final quiet = drumsOf(context(intensity: 10, beats: 64));
      final loud = drumsOf(context(intensity: 100, beats: 64));
      expect(meanVelocity(loud), greaterThan(meanVelocity(quiet)));
    });

    test('fills land where §6.6 says, and can be turned off', () {
      final withFills = drumsOf(context(beats: 64));
      final fillNotes = withFills.notes
          .where((n) => n.clientProperties['role'] == 'fill')
          .toList();
      expect(fillNotes, isNotEmpty, reason: 'no fill in sixteen bars');

      final without = drumsOf(context(beats: 64, fills: false));
      expect(
        without.notes.where((n) => n.clientProperties['role'] == 'fill'),
        isEmpty,
      );
    });

    test('the last part ends rather than just stopping', () {
      final last = drumsOf(context(beats: 32, partIndex: 2, partCount: 3));
      expect(
        last.notes.any((n) => n.clientProperties['role'] == 'ending'),
        isTrue,
      );
      final middle = drumsOf(context(beats: 32, partIndex: 1, partCount: 3));
      expect(
        middle.notes.any((n) => n.clientProperties['role'] == 'ending'),
        isFalse,
      );
    });

    test('beat one is heavier than the offbeats', () {
      final drums = drumsOf(context(beats: 16, seed: 3));
      final downbeats = drums.notes
          .where((n) => n.positionInBeats % 4 < 0.1)
          .map((n) => n.velocity);
      final offbeats = drums.notes
          .where((n) => (n.positionInBeats % 1) > 0.2)
          .map((n) => n.velocity);
      // Asserted, not guarded. Wrapping the comparison in
      // `if (both are non-empty)` meant a generator that stopped writing
      // offbeats — or stopped writing anything — passed this test silently,
      // which is the one failure it exists to catch.
      expect(downbeats, isNotEmpty, reason: 'nothing landed on a downbeat');
      expect(offbeats, isNotEmpty, reason: 'nothing landed off the beat');
      final heaviest = downbeats.reduce((a, b) => a > b ? a : b);
      final lightest = offbeats.reduce((a, b) => a < b ? a : b);
      expect(heaviest, greaterThan(lightest));
    });

    test('3/4 gets waltz patterns, not 4/4 squeezed in', () {
      final waltz = drumsOf(context(beats: 12, meter: TimeSignature.threeFour));
      expect(waltz.isNotEmpty, isTrue);
      // `beatRange.length` is the 12 beats the context was *given*, so
      // asserting it said nothing about the meter — a 4/4 pattern squeezed
      // into a 3/4 part passed just as happily. What distinguishes a waltz is
      // where the accents fall: on the downbeat of every three-beat bar, and
      // never on a beat 4 that does not exist.
      final byBar = <int, List<int>>{};
      for (final note in waltz.notes) {
        byBar
            .putIfAbsent((note.positionInBeats / 3).floor(), () => <int>[])
            .add(note.velocity);
      }
      expect(byBar.keys.toList()..sort(), <int>[0, 1, 2, 3]);

      final downbeats = waltz.notes
          .where((note) => note.positionInBeats % 3 < 0.1)
          .map((note) => note.velocity);
      expect(downbeats, isNotEmpty, reason: 'no waltz bar began with a hit');
      // Every bar's heaviest hit is its first: the accent pattern is three
      // beats long, not four.
      for (final bar in byBar.keys) {
        final hits = waltz.notes
            .where((note) => (note.positionInBeats / 3).floor() == bar)
            .toList();
        final first = hits.reduce(
          (a, b) => a.positionInBeats <= b.positionInBeats ? a : b,
        );
        expect(
          first.positionInBeats % 3,
          lessThan(0.1),
          reason: 'bar $bar did not begin on its own downbeat',
        );
      }
    });

    test(
      'a meter with no patterns generates nothing and says nothing false',
      () {
        // §4.6: meter coverage is a corpus decision. 7/4 has no patterns, so it
        // produces silence rather than 4/4 played over it.
        final seven = drumsOf(
          context(beats: 14, meter: TimeSignature.sevenFour),
        );
        expect(seven.isEmpty, isTrue);
        expect(seven.beatRange.length, 14);
      },
    );

    test('an empty part generates an empty phrase, not an error', () {
      final nothing = drumsOf(context(beats: 0));
      expect(nothing.isEmpty, isTrue);
    });

    test(
      'a meter with patterns but no groove is reported, not left silent',
      () {
        // §4.6 keeps a meter with no patterns silent, with a problem. A meter
        // with *some* patterns but none for a bar's role is different: the
        // part stops mid-way, and a silent rest of the part with no word said
        // is a gap nobody can diagnose.
        final fillsOnly = DrumPatternSet.fromJson(
          '{"schemaVersion":1,"instruments":{"kick":36},"patterns":['
          '{"id":"fill","meter":"4/4","bars":1,"role":"fill",'
          '"hits":[{"instrument":"kick","beat":0,"velocity":80}]}]}',
        );
        final result = DrumGenerator(fillsOnly).generate(context(beats: 8));
        expect(result[DrumGenerator.drums]!.isEmpty, isTrue);
        expect(
          result.problems.any((problem) => problem.contains('no drum pattern')),
          isTrue,
          reason: 'the unplayed bars must be named: ${result.problems}',
        );
      },
    );
  });

  group('what the generator declares', () {
    test('names its voice, its parameters and its meter', () {
      expect(generator.id, 'drums');
      expect(generator.voices.single.isDrums, isTrue);
      expect(generator.voices.single.preferredChannel, 9);
      expect(
        generator.parameters.map((p) => p.id),
        contains(DrumGenerator.intensityParameter),
      );
      expect(generator.supportedMeters, contains(TimeSignature.fourFour));
    });

    test('its parameters accept what they say they accept', () {
      final intensity = generator.parameters.firstWhere(
        (p) => p.id == DrumGenerator.intensityParameter,
      );
      expect(intensity.accepts(50), isTrue);
      expect(intensity.accepts(-1), isFalse);
      expect(intensity.accepts(101), isFalse);
      expect(intensity.accepts('loud'), isFalse);
      expect(intensity.coerce('loud'), 50);
    });
  });
}
