import 'package:bandstand/domain/generation/voicing/chord_degrees.dart';
import 'package:bandstand/domain/generation/voicing/voicing.dart';
import 'package:bandstand/domain/generation/voicing/voicing_constraints.dart';
import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../harmony/harmony_test_support.dart';

void main() {
  installTestHarmony();

  group('§6.5, the low minor second', () {
    test(
      'a minor second under the colour floor is named, not called register',
      () {
        // C#3 (49) a semitone under D3 (50), both inside the band. The §4
        // interval-1 limit (E3) fires for exactly this condition, so a check
        // that reads only "some interval is too low" reports `outOfRegister`
        // and the mud's real name — a low minor second — is never spoken.
        final chord = ExtChordSymbol.parse('C7');
        final voicing = Voicing(
          pitches: <int>[50, 51, 63],
          chord: chord,
          family: VoicingFamily.shell,
        );
        expect(
          VoicingConstraints.check(voicing, ChordDegrees.of(chord)),
          VoicingRejection.lowMinorSecond,
        );
      },
    );

    test('the same minor second an octave up passes', () {
      // A minor second is a colour from E3 up; only the low one is mud.
      final chord = ExtChordSymbol.parse('C7');
      final voicing = Voicing(
        pitches: <int>[62, 63, 67],
        chord: chord,
        family: VoicingFamily.shell,
      );
      expect(
        VoicingConstraints.check(voicing, ChordDegrees.of(chord)),
        isNot(VoicingRejection.lowMinorSecond),
      );
    });
  });

  group('checkAll', () {
    test('a clash beside an excused root rule is still reported', () {
      // A shell of C7 with the seventh replaced by the note a minor ninth
      // above the third: the *first* failure is the missing guide tone,
      // which the engine's `root` relaxation forgives. A guard that reads
      // only the first failure would admit the voicing, clash and all — the
      // full list refuses it.
      final chord = ExtChordSymbol.parse('C7');
      final clashing = Voicing(
        pitches: <int>[48, 52, 65],
        chord: chord,
        family: VoicingFamily.shell,
      );
      final failures = VoicingConstraints.checkAll(
        clashing,
        ChordDegrees.of(chord),
      );
      expect(failures, contains(VoicingRejection.missingGuideTone));
      expect(failures, contains(VoicingRejection.minorNinth));
    });

    test('a voicing that fails only root rules lists nothing else', () {
      // A rootless shape that sounds the root: the one failure is
      // `doublesTheRoot`, and it is the failure the `root` step excuses —
      // this is the candidate that relaxation exists for.
      final chord = ExtChordSymbol.parse('Dm7');
      final rooted = Voicing(
        pitches: <int>[53, 57, 60, 62],
        chord: chord,
        family: VoicingFamily.rootless,
      );
      expect(
        VoicingConstraints.checkAll(rooted, ChordDegrees.of(chord)),
        <VoicingRejection>[VoicingRejection.doublesTheRoot],
      );
    });

    test('a clean voicing has no failures, with or without a predecessor', () {
      final chord = ExtChordSymbol.parse('Dm7');
      final clean = Voicing(
        pitches: <int>[53, 57, 60, 64],
        chord: chord,
        family: VoicingFamily.rootless,
      );
      expect(
        VoicingConstraints.checkAll(clean, ChordDegrees.of(chord)),
        isEmpty,
      );
      final before = Voicing(
        pitches: <int>[55, 59, 62, 65],
        chord: ExtChordSymbol.parse('G7'),
        family: VoicingFamily.rootless,
      );
      expect(
        VoicingConstraints.checkAll(
          clean,
          ChordDegrees.of(chord),
          previous: before,
        ),
        isEmpty,
      );
    });
  });
}
