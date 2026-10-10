import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harmony_test_support.dart';

void main() {
  tearDown(installTestHarmony);

  test('parsing before the tables are installed fails loudly', () {
    Harmony.reset();
    expect(Harmony.isInstalled, isFalse);
    expect(() => Harmony.chordTypes, throwsStateError);
    expect(() => Harmony.scales, throwsStateError);
    expect(() => ChordSymbol.parse('C7'), throwsStateError);
  });

  test('an explicit database overrides the installed one', () {
    Harmony.reset();
    final database = loadChordTypes();
    // No tables installed, but an explicit one still works — which is what lets
    // a test drive the parser without touching process-wide state.
    expect(ChordSymbol.parse('Cm7b5', database: database).format(), 'Cm7b5');
  });

  test('installing twice replaces the tables', () {
    installTestHarmony();
    final first = Harmony.chordTypes;
    installTestHarmony();
    expect(Harmony.chordTypes, isNot(same(first)));
    expect(Harmony.isInstalled, isTrue);
  });
}
