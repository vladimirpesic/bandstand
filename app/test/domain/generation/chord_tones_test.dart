import 'package:bandstand/domain/generation/chord_tones.dart';
import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harmony/harmony_test_support.dart';

void main() {
  installTestHarmony();

  group('the default scale table', () {
    test('a power chord asserts nothing beyond itself', () {
      // `C5` names a root and a fifth. The ninth and the fourth are not in
      // a power chord's scale — they are chromatic, and §4.1's weak-beat
      // scoring treats chromatic notes generously, which is where that
      // generosity belongs.
      final tones = ChordTones.of(ExtChordSymbol.parse('C5'));
      expect(tones.chordTones, <int>{0, 7});
      expect(tones.scaleTones, tones.chordTones);
      expect(tones.isScaleTone(62), isFalse, reason: 'D is chromatic over C5');
      expect(tones.isScaleTone(65), isFalse, reason: 'F is chromatic over C5');
      expect(tones.isScaleTone(69), isFalse, reason: 'A is chromatic over C5');
    });

    test('an ordinary minor seventh still gets Dorian', () {
      final tones = ChordTones.of(ExtChordSymbol.parse('Dm7'));
      expect(tones.scaleTones, <int>{0, 2, 4, 5, 7, 9, 11});
      expect(
        tones.isScaleTone(62),
        isTrue,
        reason: 'the ninth is a scale tone',
      );
    });
  });
}
