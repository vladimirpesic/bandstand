import 'dart:io';
import 'dart:typed_data';

import 'package:bandstand/io/library/library_settings.dart';
import 'package:bandstand/state/library.dart';
import 'package:bandstand/ui/screens/library_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../io/mega/fake_mega.dart';

Uint8List pattern(int size, int offset) =>
    Uint8List.fromList(List<int>.generate(size, (i) => (offset + i) % 251));

/// One running app against a fake MEGA and a temp home: the link pasted,
/// the library loaded, the settings dialog one tap away. Everything that
/// touches sockets or disks — the server, the home folder, the link's
/// fetch — runs inside `runAsync`, where the real event loop turns; the
/// frames pump outside it.
class _Harness {
  _Harness(this.tester, this.mega, this.home, this.container);

  final WidgetTester tester;
  final FakeMega mega;
  final Directory home;
  final ProviderContainer container;

  File get settingsFile =>
      File('${home.path}${Platform.pathSeparator}${LibrarySettings.fileName}');

  Directory get cacheRoot =>
      Directory('${home.path}${Platform.pathSeparator}cache');

  /// The fake tree the library will load from.
  static Future<_Harness> pump(
    WidgetTester tester, {
    Map<String, Map<String, Uint8List>> tree = const {},
  }) async {
    late final FakeMega mega;
    late final Directory home;
    late final http.Client client;
    await tester.runAsync(() async {
      mega = await FakeMega(tree: tree).start();
      home = await Directory.systemTemp.createTemp('library-settings-test');
      // The widget-test binding mocks every HttpClient into a 400 — for
      // the whole suite, this file included. A real client for the real
      // server: the override aside; each test file is its own isolate, so
      // this file is the only one that ever notices.
      HttpOverrides.global = null;
      client = http.Client();
    });
    await tester.pumpWidget(
      // The scope outside the app, as `main()` wears it — dialogs ride the
      // root navigator, above any scope buried in `home`.
      ProviderScope(
        overrides: [
          libraryServicesProvider.overrideWithValue(
            LibraryServices(
              settingsFile: File(
                '${home.path}${Platform.pathSeparator}'
                '${LibrarySettings.fileName}',
              ),
              defaultCacheRoot: Directory(
                '${home.path}${Platform.pathSeparator}cache',
              ),
              httpClient: client,
              megaApiBaseUri: mega.apiBaseUri,
              megaRetryDelay: Duration.zero,
            ),
          ),
        ],
        child: const MaterialApp(home: LibraryScreen()),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(LibraryScreen)),
    );
    // Real sockets to the fake MEGA, so real async: the link, the fetch,
    // and the settle happen inside `runAsync`, where the event loop turns.
    await tester.runAsync(() async {
      await container.read(libraryProvider.notifier).linkLibrary(mega.linkText);
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (container.read(libraryProvider) is! LibraryReady &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    final phaseNow = container.read(libraryProvider);
    expect(phaseNow, isA<LibraryReady>(), reason: 'phase was $phaseNow');
    await tester.pumpAndSettle();
    return _Harness(tester, mega, home, container);
  }

  Future<void> openSettings() async {
    await tester.tap(find.byTooltip('Library settings'));
    await tester.pumpAndSettle();
  }

  /// Wait for a finder across two event loops: the fake zone runs the
  /// widget's await chains (flushed by `pump`), the real one runs the
  /// sockets and disks they await (turned by `runAsync`). One of each,
  /// until the finder finds.
  Future<void> until(Finder finder) async {
    for (var i = 0; i < 250 && finder.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(finder, findsWidgets);
  }

  /// Real I/O again: shut the server down and drop the temp home.
  Future<void> shutdown() async {
    await tester.runAsync(() async {
      await mega.close();
      try {
        await home.delete(recursive: true);
      } on FileSystemException {
        // Not the test's point.
      }
    });
  }
}

Map<String, Map<String, Uint8List>> treeWithPatternedTrack() =>
    <String, Map<String, Uint8List>>{
      '001_how_to_play': <String, Uint8List>{
        '001_track_a.wav': pattern(5000, 1),
      },
    };

void main() {
  testWidgets('the location is a sentence to read, not a path to type', (
    tester,
  ) async {
    final harness = await _Harness.pump(tester, tree: treeWithPatternedTrack());

    await harness.openSettings();

    expect(find.byType(TextField), findsNothing);
    expect(find.text('Where the library lives'), findsOneWidget);
    expect(find.textContaining(harness.cacheRoot.path), findsOneWidget);
    expect(find.textContaining('left as it was'), findsOneWidget);
    expect(find.textContaining('starts empty'), findsOneWidget);
    expect(find.textContaining('on disk'), findsOneWidget);
    expect(find.textContaining('0 kept (0.0 B)'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Move…'), findsOneWidget);
    expect(
      find.widgetWithText(OutlinedButton, 'Sweep leftover files'),
      findsOneWidget,
    );
    await harness.shutdown();
  });

  testWidgets('Move browses the real tree and applies the choice', (
    tester,
  ) async {
    final harness = await _Harness.pump(tester, tree: treeWithPatternedTrack());
    final target = Directory(
      '${harness.home.path}${Platform.pathSeparator}target',
    );
    await tester.runAsync(target.create);

    await harness.openSettings();
    await tester.tap(find.text('Move…'));
    await tester.pumpAndSettle();

    // Opens where the library lives now, and can walk up…
    expect(find.text('Choose a folder'), findsOneWidget);
    expect(find.textContaining(harness.cacheRoot.path), findsWidgets);
    await tester.tap(find.text('Up one level'));
    await tester.pumpAndSettle();
    expect(find.textContaining(harness.home.path), findsWidgets);
    // …into a sibling folder, which is the choice.
    await tester.tap(find.text('target'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose this folder'));
    await tester.pumpAndSettle();
    await harness.until(find.textContaining('now lives at'));

    expect(find.textContaining('now lives at'), findsOneWidget);
    expect(find.textContaining(target.path), findsWidgets);
    expect(
      LibrarySettings.load(harness.settingsFile).cacheRootOverride,
      target.path,
    );
    await harness.shutdown();
  });

  testWidgets('the sweep names its leftovers before deleting them', (
    tester,
  ) async {
    final harness = await _Harness.pump(tester, tree: treeWithPatternedTrack());
    final orphan =
        File(
            '${harness.cacheRoot.path}${Platform.pathSeparator}'
            'volumes${Platform.pathSeparator}9_gone_volume'
            '${Platform.pathSeparator}leftover.wav',
          )
          ..createSync(recursive: true)
          ..writeAsBytesSync(pattern(300, 7));

    await harness.openSettings();
    await tester.tap(find.text('Sweep leftover files'));
    await harness.until(find.text('Sweep leftover files?'));

    expect(find.text('Sweep leftover files?'), findsOneWidget);
    expect(find.textContaining('One leftover file'), findsOneWidget);
    expect(find.textContaining('300 B'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await harness.until(find.textContaining('Removed 1 file'));
    expect(find.textContaining('Removed 1 file'), findsOneWidget);
    expect(orphan.existsSync(), isFalse);
    await harness.shutdown();
  });
}
