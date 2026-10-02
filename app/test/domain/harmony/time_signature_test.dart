import 'package:bandstand/domain/harmony/time_signature.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parsing', () {
    test('reads the meters charts use', () {
      expect(TimeSignature.parse('4/4'), TimeSignature.fourFour);
      expect(TimeSignature.parse('3/4'), TimeSignature.threeFour);
      expect(TimeSignature.parse('6/8'), TimeSignature.sixEight);
      expect(TimeSignature.parse('5/4'), TimeSignature.fiveFour);
      expect(TimeSignature.parse('7/4'), TimeSignature.sevenFour);
      expect(TimeSignature.parse(' 12 / 8 '), const TimeSignature(12, 8));
    });

    test('refuses meters that are not meters', () {
      for (final text in <String>[
        '', '4', '4/3', '0/4', '33/4', '4/64', '4/4/4', 'four/four', '-4/4', //
      ]) {
        expect(TimeSignature.tryParse(text), isNull, reason: text);
      }
      expect(() => TimeSignature.parse('4/3'), throwsFormatException);
    });

    test('round-trips through toString', () {
      for (final text in <String>['4/4', '3/4', '6/8', '5/4', '7/8', '2/2']) {
        expect(TimeSignature.parse(text).toString(), text);
      }
    });
  });

  group('bar length in quarter notes', () {
    test('is what the transport and every phrase use', () {
      expect(TimeSignature.fourFour.barDurationInQuarters, 4);
      expect(TimeSignature.threeFour.barDurationInQuarters, 3);
      // 6/8 is three quarter notes to the bar, not six.
      expect(TimeSignature.sixEight.barDurationInQuarters, 3);
      expect(const TimeSignature(2, 2).barDurationInQuarters, 4);
      expect(const TimeSignature(7, 8).barDurationInQuarters, 3.5);
    });

    test('one written beat is a fraction of a quarter note', () {
      expect(TimeSignature.fourFour.beatDurationInQuarters, 1);
      expect(TimeSignature.sixEight.beatDurationInQuarters, 0.5);
      expect(const TimeSignature(2, 2).beatDurationInQuarters, 2);
    });
  });

  group('how a meter is felt', () {
    test('compound meters are felt in threes', () {
      expect(TimeSignature.sixEight.isCompound, isTrue);
      expect(const TimeSignature(9, 8).isCompound, isTrue);
      expect(const TimeSignature(12, 8).isCompound, isTrue);
      expect(TimeSignature.fourFour.isCompound, isFalse);
      expect(TimeSignature.threeFour.isCompound, isFalse);
      expect(const TimeSignature(3, 8).isCompound, isFalse);
    });

    test('felt beats collapse compound meters', () {
      expect(TimeSignature.fourFour.feltBeats, 4);
      expect(TimeSignature.sixEight.feltBeats, 2);
      expect(const TimeSignature(12, 8).feltBeats, 4);
      expect(TimeSignature.fiveFour.feltBeats, 5);
    });
  });

  test('sorts and compares by value', () {
    expect(TimeSignature.fourFour, const TimeSignature(4, 4));
    expect(TimeSignature.fourFour, isNot(const TimeSignature(4, 8)));
    final sorted = <TimeSignature>[
      TimeSignature.sixEight,
      TimeSignature.threeFour,
      TimeSignature.fourFour,
    ]..sort();
    expect(sorted.map((s) => s.toString()).toList(), <String>[
      '3/4',
      '4/4',
      '6/8',
    ]);
  });
}
