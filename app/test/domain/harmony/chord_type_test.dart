import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:flutter_test/flutter_test.dart';

/// The invariants of the ChordType degree set: what may coexist and what may
/// not. See `docs/rules/chord-symbols.md` §4.
void main() {
  ChordType build(List<String> degreeSymbols) => ChordType(
    degrees: <Degree>[for (final symbol in degreeSymbols) Degree.parse(symbol)],
    name: 'test',
    family: ChordFamily.other,
  );

  test('the same degree twice is rejected, wherever it is written', () {
    expect(() => build(<String>['1', '3', '3', '5']), throwsArgumentError);
  });

  test('a degree and its extension spelling cannot coexist', () {
    // 2° and 9° compare equal — the asExtension flag is presentation only —
    // so accepting both would emit the same pitch class twice while ChordType.==
    // insists the two lists are different. One rule, applied here: they are
    // the same degree, and it may not be listed twice.
    expect(() => build(<String>['1', '2', '9', '5']), throwsArgumentError);
    expect(() => build(<String>['1', '4', '11', '5']), throwsArgumentError);
    expect(() => build(<String>['1', '6', '13', '5']), throwsArgumentError);
  });

  test('degrees that share a semitone count but not a letter coexist', () {
    // b5 and #11 are different spellings of the same note, and the voicing
    // engine needs both — pitchClassesFrom is allowed to name a class twice.
    final type = build(<String>['1', '3', 'b5', '#11']);
    expect(type.pitchClassesFrom(0), <int>[0, 4, 6, 6]);
  });

  test('altered degrees on one letter coexist', () {
    // An altered dominant carries both b9 and #9.
    final type = build(<String>['1', '3', '5', 'b7', 'b9', '#9']);
    expect(type.degrees, hasLength(6));
  });
}
