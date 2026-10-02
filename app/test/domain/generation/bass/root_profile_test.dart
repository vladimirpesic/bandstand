import 'package:bandstand/domain/generation/bass/root_profile.dart';
import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../harmony/harmony_test_support.dart';

void main() {
  installTestHarmony();

  RootProfile profile(List<String> symbols) =>
      RootProfile.ofChords(symbols.map(ExtChordSymbol.parse));

  group('RootProfile', () {
    test('reduces a sequence to intervals from the first root', () {
      expect(profile(<String>['Dm7', 'G7']).toString(), '+0m7 +57');
    });

    test('the same progression in two keys has the same profile', () {
      // This is the whole reason a corpus of fifty phrases covers a repertoire
      // of hundreds of tunes (§2).
      expect(profile(<String>['Dm7', 'G7']), profile(<String>['Fm7', 'Bb7']));
      expect(profile(<String>['Dm7', 'G7']), profile(<String>['Bm7', 'E7']));
    });

    test('two profiles that agree are equal by hash as well', () {
      final a = profile(<String>['Cmaj7', 'A7', 'Dm7', 'G7']);
      final b = profile(<String>['Ebmaj7', 'C7', 'Fm7', 'Bb7']);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(<RootProfile, int>{a: 1}[b], 1);
    });

    test('a different quality is a different profile', () {
      expect(
        profile(<String>['Dm7', 'G7']),
        isNot(profile(<String>['Dm7b5', 'G7'])),
      );
    });

    test('a different interval is a different profile', () {
      expect(
        profile(<String>['Dm7', 'G7']),
        isNot(profile(<String>['Dm7', 'Ab7'])),
      );
    });

    test('two spellings of one quality are the same entry', () {
      // ChordType is equal by degree set, and transposition needs that: a
      // corpus written with "C-7" must match a chart written "Cm7".
      expect(profile(<String>['Cm7']), profile(<String>['C-7']));
    });

    test('order matters — a profile is a sequence, not a set', () {
      expect(
        profile(<String>['Dm7', 'G7']),
        isNot(profile(<String>['G7', 'Dm7'])),
      );
    });

    test('an empty sequence has no profile', () {
      expect(
        () => RootProfile.of(const <BassChordSpan>[]),
        throwsArgumentError,
      );
    });

    test('a descending root is measured upwards, so it stays in 0..11', () {
      // Bbmaj7 is a whole tone below C, which is +10 above it.
      expect(profile(<String>['Cmaj7', 'Bbmaj7']).toString(), '+0maj7 +10maj7');
      for (final entry in profile(<String>['Cmaj7', 'Bbmaj7']).entries) {
        expect(entry.semitonesFromFirst, inInclusiveRange(0, 11));
      }
    });
  });

  group('BassChordSpan', () {
    test('knows what is sounding when', () {
      final span = BassChordSpan(4, 4, ExtChordSymbol.parse('G7'));
      expect(span.endBeat, 8);
      expect(span.contains(4), isTrue);
      expect(span.contains(7.9), isTrue);
      expect(span.contains(8), isFalse);
      expect(span.contains(3.9), isFalse);
    });
  });
}
