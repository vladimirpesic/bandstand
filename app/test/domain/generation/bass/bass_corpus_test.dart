import 'dart:io';

import 'package:bandstand/domain/generation/bass/bass_corpus.dart';
import 'package:bandstand/domain/generation/bass/bass_corpus_codec.dart';
import 'package:bandstand/domain/generation/bass/root_profile.dart';
import 'package:bandstand/domain/generation/bass/wbp_source.dart';
import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../harmony/harmony_test_support.dart';

/// The invariants of `docs/format/bass-corpus.md` — properties of the *data*,
/// not of the loader. A bad phrase must fail here rather than surface months
/// later as a hole in a bass line.
void main() {
  installTestHarmony();

  final source = File('assets/bass_corpus.json').readAsStringSync();
  final corpus = BassCorpusCodec.decode(source);

  group('the shipped corpus', () {
    test('is at least the fifty phrases §6.4 asks for', () {
      expect(corpus.length, greaterThanOrEqualTo(50));
    });

    test(
      'every phrase is playable — starts on the root, ends on a chord tone',
      () {
        // Dead weight that looks like coverage: a phrase failing §5 constraints
        // 1 and 2 can never be placed at all.
        expect(corpus.unplayable.map((phrase) => phrase.name), isEmpty);
      },
    );

    test('every phrase reaches every root in at least one octave', () {
      // Otherwise its transposibility map is empty somewhere and the phrase
      // silently does not exist for a third of the keys (§8).
      final unreachable = <String>[];
      for (final phrase in corpus.phrases) {
        if (phrase.reachableRootCount != 12) {
          unreachable.add('${phrase.name}: ${phrase.reachableRootCount}/12');
        }
      }
      expect(unreachable, isEmpty);
    });

    test('every phrase fits the declared instrument as written', () {
      for (final phrase in corpus.phrases) {
        expect(
          phrase.lowestPitch,
          greaterThanOrEqualTo(corpus.range.lowest),
          reason: phrase.name,
        );
        expect(
          phrase.highestPitch,
          lessThanOrEqualTo(corpus.range.highest),
          reason: phrase.name,
        );
      }
    });

    test('no phrase is longer than the four bars §2 allows', () {
      for (final phrase in corpus.phrases) {
        expect(phrase.lengthBars, inInclusiveRange(1, 4), reason: phrase.name);
      }
    });

    test('every root profile has at least two phrases', () {
      // One phrase for a profile means the tiler has no choice there, and no
      // choice means the freshness rule of §6 cannot do its job.
      final thin = <String>[];
      for (final profile in corpus.profiles) {
        final count = corpus.phrases
            .where((phrase) => phrase.rootProfile == profile)
            .length;
        if (count < 2) {
          thin.add('$profile: $count');
        }
      }
      expect(thin, isEmpty);
    });

    test('it covers the segmentations a standard form asks for', () {
      // M0.5 finding 3: a corpus is not a bag of phrases, it has to be shaped
      // to the segmentations the tiler will actually ask for. These are the
      // profiles an AABA standard and a blues produce.
      const wanted = <List<String>>[
        <String>['Dm7', 'G7'], // ii-V
        <String>['G7', 'Cmaj7'], // V-I
        <String>['Cmaj7', 'A7'], // I-VI
        <String>['Dm7b5', 'G7'], // minor ii-V
        <String>['Cmaj7', 'Cmaj7'], // a held major
        <String>['C7', 'F7'], // the blues move to the four
        <String>['Cmaj7'], // one bar of each kind
        <String>['Dm7'],
        <String>['G7'],
        <String>['Cmaj7', 'A7', 'Dm7', 'G7'], // the four-bar turnaround
        <String>['Dm7', 'G7', 'Cmaj7', 'Cmaj7'], // the cadence
      ];
      final missing = <String>[];
      for (final symbols in wanted) {
        final profile = RootProfile.ofChords(symbols.map(ExtChordSymbol.parse));
        final count = corpus.phrases
            .where((phrase) => phrase.rootProfile == profile)
            .length;
        if (count < 2) {
          missing.add('${symbols.join(" | ")} -> $count');
        }
      }
      expect(missing, isEmpty);
    });

    test('two phrases never share a name', () {
      // The reuse window tracks phrases by name, so duplicates would be heard
      // as one phrase and silently defeat the freshness rule.
      final names = corpus.phrases.map((phrase) => phrase.name).toList();
      expect(names.toSet().length, names.length);
    });

    test('a declared tempo range is a band a real tune sits in', () {
      for (final phrase in corpus.phrases) {
        expect(phrase.tempoRange.lowest, greaterThan(0), reason: phrase.name);
        expect(
          phrase.tempoRange.lowest,
          lessThan(phrase.tempoRange.highest),
          reason: phrase.name,
        );
      }
    });
  });

  group('indexing', () {
    test('lengths are offered longest first, for the §6.2 walk', () {
      expect(corpus.lengthsLongestFirst, <int>[4, 2, 1]);
    });

    test('candidates are filtered by profile, tempo and reachability', () {
      final profile = RootProfile.ofChords(
        <String>['Dm7', 'G7'].map(ExtChordSymbol.parse),
      );
      final all = corpus.candidatesFor(profile, destinationRoot: 2, tempo: 160);
      expect(all, isNotEmpty);
      for (final phrase in all) {
        expect(phrase.rootProfile, profile);
        expect(phrase.canReach(2), isTrue);
        expect(phrase.tempoRange.admits(160), isTrue);
      }
    });

    test('a tempo outside a phrase band excludes it', () {
      final profile = RootProfile.ofChords(
        <String>['Dm7', 'G7'].map(ExtChordSymbol.parse),
      );
      final middling = corpus.candidatesFor(
        profile,
        destinationRoot: 2,
        tempo: 160,
      );
      final breakneck = corpus.candidatesFor(
        profile,
        destinationRoot: 2,
        tempo: 400,
      );
      expect(breakneck.length, lessThan(middling.length));
    });

    test('an unknown profile has no candidates rather than an error', () {
      final profile = RootProfile.ofChords(
        <String>['Co7', 'F#m7b5', 'B7', 'Eo7'].map(ExtChordSymbol.parse),
      );
      expect(
        corpus.candidatesFor(profile, destinationRoot: 0, tempo: 160),
        isEmpty,
      );
    });

    test('two phrases sharing a name are refused at construction', () {
      WbpSource phrase(String name) => WbpSource(
        name: name,
        harmony: <BassChordSpan>[
          BassChordSpan(0, 4, ExtChordSymbol.parse('Dm7')),
        ],
        notes: <BassNoteSpec>[BassNoteSpec(beat: 0, pitch: 38)],
      );
      expect(
        () => BassCorpus(
          name: 'clash',
          phrases: <WbpSource>[phrase('same'), phrase('same')],
        ),
        throwsArgumentError,
      );
    });

    test('an empty corpus is empty rather than broken', () {
      final empty = BassCorpus.empty();
      expect(empty.isEmpty, isTrue);
      expect(empty.length, 0);
      expect(empty.lengthsLongestFirst, isEmpty);
      expect(empty.profiles, isEmpty);
    });
  });
}
