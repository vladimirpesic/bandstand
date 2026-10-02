import 'package:bandstand/domain/harmony/natural.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the seven letters have the right numbers and semitones', () {
    expect(Natural.values.map((n) => n.letter).toList(), <String>[
      'C', 'D', 'E', 'F', 'G', 'A', 'B', //
    ]);
    expect(Natural.values.map((n) => n.degreeNumber).toList(), <int>[
      1, 2, 3, 4, 5, 6, 7, //
    ]);
    expect(Natural.values.map((n) => n.semitones).toList(), <int>[
      0, 2, 4, 5, 7, 9, 11, //
    ]);
  });

  test('letters are read case-insensitively, and nothing else is a letter', () {
    expect(Natural.fromLetter('C'), Natural.c);
    expect(Natural.fromLetter('c'), Natural.c);
    expect(Natural.fromLetter('B'), Natural.b);
    expect(Natural.fromLetter('H'), isNull);
    expect(Natural.fromLetter('Cb'), isNull);
    expect(Natural.fromLetter(''), isNull);
  });

  test('numbers wrap in seven, in both directions', () {
    expect(Natural.fromDegreeNumber(1), Natural.c);
    expect(Natural.fromDegreeNumber(8), Natural.c);
    expect(Natural.fromDegreeNumber(15), Natural.c);
    expect(Natural.fromDegreeNumber(0), Natural.b);
    expect(Natural.fromDegreeNumber(-6), Natural.c);
  });

  test('stepping wraps past B to C', () {
    expect(Natural.b.stepped(1), Natural.c);
    expect(Natural.c.stepped(-1), Natural.b);
    expect(Natural.c.stepped(7), Natural.c);
    expect(Natural.f.stepped(4), Natural.c);
  });

  test('stepping and measuring are inverses', () {
    for (final from in Natural.values) {
      for (final to in Natural.values) {
        expect(from.stepped(from.stepsTo(to)), to, reason: '$from -> $to');
      }
    }
  });

  test('the distance between two letters is always 0-6', () {
    for (final from in Natural.values) {
      for (final to in Natural.values) {
        expect(from.stepsTo(to), inInclusiveRange(0, 6));
      }
    }
  });
}
