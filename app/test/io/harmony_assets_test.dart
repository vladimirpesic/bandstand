import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:bandstand/io/harmony_assets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(Harmony.reset);

  test(
    'the tables load from the bundled assets and install themselves',
    () async {
      await installHarmonyAssets();
      expect(Harmony.isInstalled, isTrue);
      expect(ChordSymbol.parse('Cmaj7#11').format(), 'Cmaj7#11');
      expect(Harmony.scales.byName('Lydian dominant'), isNotNull);
    },
  );

  test('the asset paths are the ones pubspec declares', () {
    expect(chordTypesAssetPath, 'assets/chord_types.json');
    expect(scalesAssetPath, 'assets/scales.json');
  });
}
