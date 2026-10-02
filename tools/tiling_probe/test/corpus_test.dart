import 'package:test/test.dart';
import 'package:tiling_probe/corpus.dart';
import 'package:tiling_probe/tiler.dart';

void main() {
  final corpus = probeCorpus();

  test('the corpus is the size M0.5 asks for', () {
    expect(corpus.length, greaterThanOrEqualTo(15));
    expect(corpus.length, lessThanOrEqualTo(24));
  });

  test('phrase names are unique — the tiler keys reuse on them', () {
    final names = corpus.map((p) => p.name).toSet();
    expect(names.length, corpus.length);
  });

  group('every phrase obeys the constraints of §5', () {
    for (final phrase in corpus) {
      test(phrase.name, () {
        expect(phrase.startsOnRoot, isTrue, reason: 'must open on the root');
        expect(
          phrase.endsOnChordTone,
          isTrue,
          reason: 'must close on a chord tone',
        );
        expect(phrase.lowestPitch, greaterThanOrEqualTo(lowestBassPitch));
        expect(phrase.highestPitch, lessThanOrEqualTo(highestBassPitch));
      });
    }
  });

  test('every phrase is four quarter notes to the bar', () {
    for (final phrase in corpus) {
      expect(phrase.notes.length, phrase.lengthBars * 4, reason: phrase.name);
      for (var i = 0; i < phrase.notes.length; i++) {
        expect(phrase.notes[i].beat, i.toDouble(), reason: phrase.name);
      }
    }
  });

  test('no phrase repeats a pitch across two adjacent notes', () {
    for (final phrase in corpus) {
      for (var i = 1; i < phrase.notes.length; i++) {
        expect(
          phrase.notes[i].pitch,
          isNot(phrase.notes[i - 1].pitch),
          reason: '${phrase.name} repeats a note at beat $i',
        );
      }
    }
  });

  test('harmonic fit is high across the corpus', () {
    for (final phrase in corpus) {
      expect(
        Tiler.harmonicFit(phrase, 0),
        greaterThan(0.8),
        reason: '${phrase.name} is harmonically weak as written',
      );
    }
  });

  test('harmonic fit is invariant under transposition', () {
    for (final phrase in corpus) {
      final base = Tiler.harmonicFit(phrase, 0);
      for (var semitones = -12; semitones <= 12; semitones++) {
        expect(
          Tiler.harmonicFit(phrase, semitones),
          closeTo(base, 1e-12),
          reason: '${phrase.name} at $semitones',
        );
      }
    }
  });

  test('the corpus covers the five root profiles it claims to', () {
    final profiles = corpus.map((p) => p.rootProfile.toString()).toSet();
    expect(profiles.length, 5);
    for (final profile in profiles) {
      final count = corpus
          .where((p) => p.rootProfile.toString() == profile)
          .length;
      expect(count, greaterThanOrEqualTo(2), reason: '$profile has $count');
    }
  });
}
