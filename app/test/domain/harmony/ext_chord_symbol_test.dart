import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harmony_test_support.dart';

void main() {
  setUpAll(installTestHarmony);

  group('N.C.', () {
    test('parses in the forms charts write', () {
      for (final text in <String>['N.C.', 'NC', 'n.c.', 'nc', ' N.C. ']) {
        final parsed = ExtChordSymbol.parse(text);
        expect(parsed.isNoChord, isTrue, reason: text);
        expect(parsed.format(), 'N.C.', reason: text);
      }
    });

    test('round-trips', () {
      final silence = ExtChordSymbol.noChord();
      expect(ExtChordSymbol.parse(silence.format()), silence);
    });

    test('is unmoved by transposition — there is nothing to move', () {
      final silence = ExtChordSymbol.noChord();
      expect(silence.transposed(5), same(silence));
      expect(silence.transposed(5).isNoChord, isTrue);
      expect(silence.respelled(SpellingPreference.sharps), same(silence));
    });

    test('an ordinary chord is not a no-chord', () {
      expect(ExtChordSymbol.parse('C7').isNoChord, isFalse);
    });

    test('caller-supplied rendering and scale are not dropped', () {
      // The N.C. text forces noChord — nothing plays — but the caller's other
      // instructions and the scale instruction still apply.
      final lydian = Harmony.scales.byName('Lydian')!;
      final scale = StandardScaleInstance(lydian, PitchSpelling.parse('C'));
      final parsed = ExtChordSymbol.parse(
        'N.C.',
        rendering: const ChordRenderingInfo(accent: ChordAccent.strong),
        scale: scale,
      );
      expect(parsed.isNoChord, isTrue);
      expect(parsed.rendering.accent, ChordAccent.strong);
      expect(parsed.scale, scale);
    });
  });

  group('rendering information', () {
    test('is plain unless something is marked', () {
      expect(ExtChordSymbol.parse('C7').rendering.isPlain, isTrue);
      expect(ChordRenderingInfo.plain.isPlain, isTrue);
      expect(ChordRenderingInfo.silence.isPlain, isFalse);
    });

    test('survives transposition', () {
      const marked = ChordRenderingInfo(
        accent: ChordAccent.strong,
        playStyle: ChordPlayStyle.hold,
        anticipation: ChordAnticipation.eighth,
        pedalBass: true,
      );
      final chord = ExtChordSymbol.parse('Dm7').withRendering(marked);
      final moved = chord.transposed(2);
      expect(moved.format(), 'Em7');
      expect(moved.rendering, marked);
    });

    test('copyWith replaces one field at a time', () {
      const info = ChordRenderingInfo();
      expect(
        info.copyWith(accent: ChordAccent.medium).accent,
        ChordAccent.medium,
      );
      expect(
        info.copyWith(accent: ChordAccent.medium).playStyle,
        ChordPlayStyle.normal,
      );
      expect(info.copyWith(pedalBass: true).pedalBass, isTrue);
    });

    test('accents know their chart symbols', () {
      expect(ChordAccent.medium.symbol, '>');
      expect(ChordAccent.strong.symbol, '^');
      expect(ChordAccent.fromSymbol('>'), ChordAccent.medium);
      expect(ChordAccent.fromSymbol(''), isNull);
      expect(ChordAccent.fromSymbol('?'), isNull);
    });

    test('anticipation is measured in quarter notes', () {
      expect(ChordAnticipation.none.quarters, 0);
      expect(ChordAnticipation.eighth.quarters, 0.5);
      expect(ChordAnticipation.sixteenth.quarters, 0.25);
    });

    test('an eighth early is an eighth in every meter', () {
      // The reason it counts quarters. "Half a beat" is an eighth in 4/4 and
      // a sixteenth in 6/8, where the beat already *is* an eighth — so a
      // 6/8 chart anticipated half as far as it asked for.
      expect(ChordAnticipation.eighth.beatsIn(TimeSignature.fourFour), 0.5);
      expect(ChordAnticipation.eighth.beatsIn(TimeSignature.threeFour), 0.5);
      expect(ChordAnticipation.eighth.beatsIn(TimeSignature.sixEight), 1.0);
      expect(ChordAnticipation.sixteenth.beatsIn(TimeSignature.sixEight), 0.5);
      expect(ChordAnticipation.none.beatsIn(TimeSignature.sixEight), 0);
    });
  });

  group('scale instructions', () {
    test('move with the chord', () {
      final lydian = Harmony.scales.byName('Lydian')!;
      final chord = ExtChordSymbol.parse('Cmaj7')
          .withScale(StandardScaleInstance(lydian, PitchSpelling.parse('C')));
      final moved = chord.transposed(2);
      expect(moved.format(), 'Dmaj7');
      expect(moved.scale!.root.toString(), 'D');
      expect(moved.scale!.scale, lydian);
    });

    test('are spelled by the same preference as the chord', () {
      final lydian = Harmony.scales.byName('Lydian')!;
      final chord = ExtChordSymbol.parse('Cmaj7')
          .withScale(StandardScaleInstance(lydian, PitchSpelling.parse('C')));
      final moved = chord.transposed(
        6,
        preference: SpellingPreference.key(KeySignature.parse('E')),
      );
      expect(moved.root.toString(), 'F#');
      expect(moved.scale!.root.toString(), 'F#');
    });
  });

  test('the plain harmony can be taken out from under the instructions', () {
    final chord = ExtChordSymbol.parse('Dm7/G')
        .withRendering(const ChordRenderingInfo(accent: ChordAccent.strong));
    expect(chord.plain, ChordSymbol.parse('Dm7/G'));
    expect(chord.plain.runtimeType, ChordSymbol);
  });

  test('equality includes the rendering information', () {
    final plain = ExtChordSymbol.parse('C7');
    final accented = plain.withRendering(
      const ChordRenderingInfo(accent: ChordAccent.strong),
    );
    expect(plain, isNot(accented));
    expect(plain, ExtChordSymbol.parse('C7'));
    expect(<ExtChordSymbol>{plain, ExtChordSymbol.parse('C7')}, hasLength(1));
  });
}
