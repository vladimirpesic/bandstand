import 'package:bandstand/domain/harmony/position.dart';
import 'package:bandstand/domain/harmony/time_signature.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const fourFour = TimeSignature.fourFour;
  const threeFour = TimeSignature.threeFour;
  const sixEight = TimeSignature.sixEight;

  group('construction', () {
    test('rejects positions that are not places', () {
      expect(() => Position(-1), throwsArgumentError);
      expect(() => Position(0, -1), throwsArgumentError);
      expect(() => Position(0, double.nan), throwsArgumentError);
      expect(() => Position(0, double.infinity), throwsArgumentError);
    });
  });

  test('the model counts from zero and the chart counts from one', () {
    final position = Position(0, 0);
    expect(position.displayBar, 1);
    expect(position.displayBeat, 1);
    expect(Position(31, 3).displayBar, 32);
    expect(Position(31, 3).displayBeat, 4);
    expect(position.toString(), 'bar 1 beat 1.000');
  });

  group('quarter-note conversion', () {
    test('round-trips in simple meters', () {
      for (final signature in <TimeSignature>[fourFour, threeFour, sixEight]) {
        for (var bar = 0; bar < 8; bar++) {
          for (var beat = 0; beat < signature.upper; beat++) {
            final position = Position(bar, beat.toDouble());
            final quarters = position.toQuarters(signature);
            expect(
              Position.fromQuarters(quarters, signature),
              position,
              reason: '$position in $signature',
            );
          }
        }
      }
    });

    test('places bars where the meter puts them', () {
      expect(Position(1).toQuarters(fourFour), 4);
      expect(Position(1).toQuarters(threeFour), 3);
      expect(Position(1).toQuarters(sixEight), 3);
      expect(Position(0, 3).toQuarters(sixEight), 1.5);
      expect(Position(2, 2).toQuarters(fourFour), 10);
    });

    test('refuses to place a negative amount of time', () {
      expect(() => Position.fromQuarters(-1, fourFour), throwsArgumentError);
      expect(
        () => Position.fromQuarters(double.nan, fourFour),
        throwsArgumentError,
      );
    });
  });

  group('shifting', () {
    test('carries into the next bar and back into the previous one', () {
      expect(Position(0, 3).shifted(1, fourFour), Position(1, 0));
      expect(Position(1, 0).shifted(-1, fourFour), Position(0, 3));
      expect(Position(0, 0).shifted(9, fourFour), Position(2, 1));
      expect(Position(2, 1).shifted(-9, fourFour), Position(0, 0));
    });

    test('stops at the start of the song', () {
      expect(Position(0, 0).shifted(-4, fourFour), Position(0, 0));
      expect(Position(0, 1).shifted(-8, fourFour), Position(0, 0));
    });

    test('respects the meter', () {
      expect(Position(0, 2).shifted(1, threeFour), Position(1, 0));
      expect(Position(0, 5).shifted(1, sixEight), Position(1, 0));
    });
  });

  test('barStart drops the beat', () {
    expect(Position(4, 2.5).barStart, Position(4));
    expect(Position(4).isBarStart, isTrue);
    expect(Position(4, 0.5).isBarStart, isFalse);
  });

  test('positions compare in time order', () {
    expect(Position(0) < Position(1), isTrue);
    expect(Position(1, 2) > Position(1, 1), isTrue);
    expect(Position(1) <= Position(1), isTrue);
    expect(Position(1) >= Position(1), isTrue);
    expect(Position(2) < Position(1), isFalse);
    final sorted = <Position>[Position(2), Position(0, 3), Position(0, 1)]
      ..sort();
    expect(sorted, <Position>[Position(0, 1), Position(0, 3), Position(2)]);
  });

  test('equality is by bar and beat', () {
    expect(Position(1, 2), Position(1, 2));
    expect(Position(1, 2), isNot(Position(1, 2.5)));
    expect(<Position>{Position(1), Position(1)}, hasLength(1));
  });

  test('copyWith replaces one field at a time', () {
    expect(Position(1, 2).copyWith(bar: 5), Position(5, 2));
    expect(Position(1, 2).copyWith(beat: 0), Position(1, 0));
  });
}
