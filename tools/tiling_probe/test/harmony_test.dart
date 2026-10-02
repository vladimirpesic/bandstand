import 'package:test/test.dart';
import 'package:tiling_probe/harmony.dart';

void main() {
  group('Chord.parse', () {
    test('reads naturals, flats and sharps', () {
      expect(Chord.parse('Cmaj7'), const Chord(0, Quality.major7));
      expect(Chord.parse('Bbmaj7'), const Chord(10, Quality.major7));
      expect(Chord.parse('F#m7b5'), const Chord(6, Quality.halfDiminished));
      expect(Chord.parse('A7'), const Chord(9, Quality.dominant7));
      expect(Chord.parse('Cb7'), const Chord(11, Quality.dominant7));
    });

    test('round-trips through toString', () {
      for (final symbol in <String>[
        'Cmaj7',
        'Dm7',
        'G7',
        'Abm7b5',
        'Bdim7',
        'Eb6',
        'Fm6',
      ]) {
        expect(Chord.parse(symbol).toString(), symbol);
      }
    });

    test('rejects nonsense', () {
      expect(() => Chord.parse('H7'), throwsFormatException);
      expect(() => Chord.parse('Cwobble'), throwsFormatException);
    });
  });

  group('chord tones', () {
    test('a dominant seventh has a flat seventh, not a major one', () {
      final g7 = Chord.parse('G7');
      expect(g7.isChordTone(65), isTrue); // F
      expect(g7.isChordTone(66), isFalse); // F#
    });

    test('scale tones include the ninth', () {
      expect(Chord.parse('Cmaj7').isScaleTone(62), isTrue); // D
      expect(Chord.parse('Cmaj7').isScaleTone(61), isFalse); // Db
    });
  });

  group('RootProfile', () {
    ChordSpan span(double start, String symbol) =>
        ChordSpan(start, 4, Chord.parse(symbol));

    test('two ii-Vs a fourth apart share a profile', () {
      final dToG = RootProfile.of(<ChordSpan>[span(0, 'Dm7'), span(4, 'G7')]);
      final fToBb = RootProfile.of(<ChordSpan>[span(0, 'Fm7'), span(4, 'Bb7')]);
      expect(dToG, fToBb);
    });

    test('quality is part of the profile', () {
      final major = RootProfile.of(<ChordSpan>[
        span(0, 'Cmaj7'),
        span(4, 'A7'),
      ]);
      final minor = RootProfile.of(<ChordSpan>[span(0, 'Cm7'), span(4, 'A7')]);
      expect(major, isNot(minor));
    });

    test('rhythm is part of the profile', () {
      final wide = RootProfile.of(<ChordSpan>[
        ChordSpan(0, 4, Chord.parse('Dm7')),
        ChordSpan(4, 4, Chord.parse('G7')),
      ]);
      final narrow = RootProfile.of(<ChordSpan>[
        ChordSpan(0, 2, Chord.parse('Dm7')),
        ChordSpan(2, 2, Chord.parse('G7')),
      ]);
      expect(wide, isNot(narrow));
    });

    test('needs at least one chord', () {
      expect(() => RootProfile.of(<ChordSpan>[]), throwsArgumentError);
    });
  });
}
