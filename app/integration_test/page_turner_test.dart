import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/ui/screens/reading_mode_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bandstand/bridge/frb_generated.dart';
import 'package:bandstand/io/harmony_assets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// §9's page-turner support, which is `docs/rules/page-turner.md`: a pedal is a
/// Bluetooth keyboard with two keys on it, so it is tested as a keyboard.
/// In `integration_test/` rather than `test/`: reading mode reads the
/// transport, and the transport is Rust. `testWidgets` cannot initialise the
/// bridge, which is the same split M2 established for screens that touch the
/// disk.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await installHarmonyAssets();
    await RustLib.init();
  });

  /// Long enough that there is somewhere to scroll to.
  Song longSong() =>
      Song.blank(id: 'paging', title: 'Long tune', barCount: 128);

  var opened = 0;

  Future<void> open(WidgetTester tester) async {
    // A distinct key each time: `pumpWidget` reuses the `State` of a widget of
    // the same type at the same position, so without one the scroll offset
    // carries over from the previous case and the next assertion is against
    // wherever the last one left it.
    opened++;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: ReadingModeScreen(key: ValueKey<int>(opened), song: longSong()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// How far the chart has been scrolled.
  ///
  /// Read from the `Transform.translate` reading mode applies, rather than
  /// from a field added to the screen for the test's benefit: the offset is
  /// already observable, and a test-only getter on production code is a worse
  /// trade than a slightly indirect assertion.
  double offsetOf(WidgetTester tester) {
    final transform = tester.widget<Transform>(
      find
          .descendant(
            of: find.byType(ClipRect),
            matching: find.byType(Transform),
          )
          .first,
    );
    return -transform.transform.getTranslation().y;
  }

  group('a pedal turns the page', () {
    testWidgets('every forward convention goes forward', (tester) async {
      // Which keystroke a pedal sends is a setting on the pedal, already made
      // for some other app, so all four conventions are honoured (§1).
      for (final key in <LogicalKeyboardKey>[
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.pageDown,
        LogicalKeyboardKey.space,
      ]) {
        await open(tester);
        expect(offsetOf(tester), 0);
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
        expect(
          offsetOf(tester),
          greaterThan(0),
          reason: '${key.debugName} did not turn the page',
        );
      }
    });

    testWidgets('every backward convention goes back', (tester) async {
      for (final key in <LogicalKeyboardKey>[
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.pageUp,
        LogicalKeyboardKey.backspace,
      ]) {
        await open(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        await tester.pumpAndSettle();
        final forward = offsetOf(tester);
        expect(forward, greaterThan(0));

        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
        expect(
          offsetOf(tester),
          lessThan(forward),
          reason: '${key.debugName} did not go back',
        );
      }
    });

    testWidgets('it does not go back past the first page', (tester) async {
      await open(tester);
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
        await tester.pumpAndSettle();
      }
      expect(offsetOf(tester), 0);
    });

    testWidgets('a key that is not a pedal is left alone', (tester) async {
      await open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.pumpAndSettle();
      expect(offsetOf(tester), 0);
    });
  });
}
