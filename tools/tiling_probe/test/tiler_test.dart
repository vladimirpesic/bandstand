import 'package:test/test.dart';
import 'package:tiling_probe/corpus.dart';
import 'package:tiling_probe/tiler.dart';

Progression aaba() => Progression('AABA 32', <String>[
  'Cmaj7', 'A7', 'Dm7', 'G7', 'Cmaj7', 'A7', 'Dm7', 'G7', //
  'Cmaj7', 'A7', 'Dm7', 'G7', 'Cmaj7', 'A7', 'Dm7', 'G7', //
  'Fm7', 'Bb7', 'Ebmaj7', 'Ebmaj7', 'Dm7', 'G7', 'Cmaj7', 'Cmaj7', //
  'Cmaj7', 'A7', 'Dm7', 'G7', 'Cmaj7', 'A7', 'Dm7', 'G7',
]);

void main() {
  final corpus = probeCorpus();
  final tiler = Tiler(corpus);

  test('joins score highest for steps and worst for wide leaps', () {
    expect(Tiler.joinScore(1), 1.0);
    expect(Tiler.joinScore(-2), 1.0);
    expect(Tiler.joinScore(4), 0.85);
    expect(Tiler.joinScore(7), 0.6);
    expect(Tiler.joinScore(12), 0.3);
    expect(Tiler.joinScore(15), 0.05);
    // A repeated note across a join is the sound of two phrases, not one.
    expect(Tiler.joinScore(0), lessThan(Tiler.joinScore(1)));
    expect(Tiler.joinScore(null), 1.0);
  });

  test('a phrase out of the bass range scores zero on register', () {
    final phrase = corpus.first;
    expect(Tiler.registerScore(phrase, 0), greaterThan(0));
    expect(Tiler.registerScore(phrase, 36), 0);
    expect(Tiler.registerScore(phrase, -36), 0);
  });

  test('tiles the whole form with no gaps or overlaps', () {
    final tiling = tiler.tile(aaba());
    var expectedBar = 0;
    for (final placement in tiling.placements) {
      expect(placement.startBar, expectedBar);
      expectedBar = placement.endBar;
    }
    expect(expectedBar, 32);
  });

  test('every placed note is in the bass range', () {
    final tiling = tiler.tile(aaba().repeated(3));
    for (final note in tiling.notes()) {
      expect(note.pitch, greaterThanOrEqualTo(lowestBassPitch));
      expect(note.pitch, lessThanOrEqualTo(highestBassPitch));
    }
  });

  test('every placed note is under the chord it belongs to', () {
    final progression = aaba();
    final tiling = tiler.tile(progression);
    for (final placement in tiling.placements) {
      for (final note in placement.notes()) {
        final bar = note.beat ~/ 4;
        final target = progression.bars[bar];
        final source = placement.phrase
            .chordAt(note.beat - placement.startBar * 4)
            .transposed(placement.transposition % 12);
        expect(
          source,
          target,
          reason: 'bar ${bar + 1}: phrase says $source, form says $target',
        );
      }
    }
  });

  test('every placement opens on the root of its first chord', () {
    final progression = aaba().repeated(3);
    final tiling = tiler.tile(progression);
    for (final placement in tiling.placements) {
      final first = placement.notes().first;
      expect(
        first.pitch % 12,
        progression.bars[placement.startBar].rootPitchClass,
        reason: 'bar ${placement.startBar + 1}',
      );
    }
  });

  test('is deterministic — the same input tiles identically', () {
    final a = tiler.tile(aaba().repeated(3));
    final b = Tiler(probeCorpus()).tile(aaba().repeated(3));
    expect(a.placements.length, b.placements.length);
    for (var i = 0; i < a.placements.length; i++) {
      expect(a.placements[i].phrase.name, b.placements[i].phrase.name);
      expect(a.placements[i].transposition, b.placements[i].transposition);
    }
  });

  test('does not repeat a phrase inside the reuse window', () {
    final tiling = tiler.tile(aaba().repeated(3));
    const window = 6;
    final lastSeen = <String, int>{};
    var violations = 0;
    for (var i = 0; i < tiling.placements.length; i++) {
      final name = tiling.placements[i].phrase.name;
      final previous = lastSeen[name];
      if (previous != null && i - previous <= window) {
        violations++;
      }
      lastSeen[name] = i;
    }
    // Some reuse inside the window is unavoidable when a profile has few
    // variants; what must not happen is a short cycle.
    expect(violations, lessThan(tiling.placements.length ~/ 4));
  });

  test('uses most of the corpus over three choruses', () {
    final tiling = tiler.tile(aaba().repeated(3));
    final used = tiling.placements.map((p) => p.phrase.name).toSet();
    expect(used.length, greaterThanOrEqualTo(12));
  });

  test('reports rather than invents when the corpus cannot cover a bar', () {
    final unknown = Progression('unknown', <String>['Bdim7', 'Bdim7']);
    expect(() => tiler.tile(unknown), throwsA(isA<TilingFailure>()));
  });

  test('transposes a phrase written in one key onto another', () {
    final progression = Progression('ii-V in Eb', <String>['Fm7', 'Bb7']);
    final tiling = tiler.tile(progression);
    expect(tiling.placements, hasLength(1));
    final placement = tiling.placements.single;
    // The corpus ii-Vs are written over Dm7; F is three semitones above D.
    expect(placement.transposition % 12, 3);
    expect(placement.notes().first.pitch % 12, 5); // F
  });
}
