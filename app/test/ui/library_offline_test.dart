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

/// Wait for [finder] to leave the screen across the two event loops: the
/// toast's five seconds run on the real clock, so real time has to pass
/// inside `runAsync` while the frames pump outside it.
Future<void> gone(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 250 && finder.evaluate().isNotEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(finder, findsNothing);
}

/// The offline story against the real screen: a dead sync speaks once, as
/// a five-second toast at the bottom of the screen — never a strip of it —
/// and the app bar's sync button trades its icon for the offline one until
/// a sync succeeds again.
void main() {
  testWidgets('a dead sync is one toast, and the bar says offline', (
    tester,
  ) async {
    late final FakeMega mega;
    late final Directory home;
    late final http.Client client;
    await tester.runAsync(() async {
      mega = await FakeMega(
        tree: <String, Map<String, Uint8List>>{
          '001_how_to_play': <String, Uint8List>{
            '001_track_a.wav': pattern(5000, 1),
          },
        },
      ).start();
      home = await Directory.systemTemp.createTemp('library-offline-test');
      // The widget-test binding mocks every HttpClient into a 400 — for
      // the whole suite, this file included. A real client for the real
      // server: this file is its own isolate, so no one else notices.
      HttpOverrides.global = null;
      client = http.Client();
    });
    await tester.pumpWidget(
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
    // Real sockets to the fake MEGA, so real async: the link and the
    // settle happen inside `runAsync`, where the event loop turns.
    await tester.runAsync(() async {
      await container.read(libraryProvider.notifier).linkLibrary(mega.linkText);
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (container.read(libraryProvider) is! LibraryReady &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    expect(container.read(libraryProvider), isA<LibraryReady>());
    await tester.pumpAndSettle();

    // Online: the sync button, and nothing said.
    expect(find.byIcon(Icons.sync), findsOneWidget);
    expect(find.byIcon(Icons.cloud_off), findsNothing);

    // The network goes away, and the button is tapped to find out.
    await tester.runAsync(mega.close);
    await tester.tap(find.byIcon(Icons.sync));
    await tester.pump();

    // The message is a toast — one widget's worth of it — and the button
    // now says offline. Wait across the two event loops: the fake zone
    // runs the widget's await chains, the real one the sockets.
    final toast = find.textContaining('You are offline');
    for (var i = 0; i < 250 && toast.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(toast, findsOneWidget);
    expect(find.byIcon(Icons.cloud_off), findsOneWidget);
    expect(find.byIcon(Icons.sync), findsNothing);

    // Five seconds later the toast is gone on its own — and nothing is
    // left sitting on the screen saying it. The five seconds run on the
    // real clock (the toast is shown from the real event loop the socket
    // failure rode in on), so real time has to pass while frames pump.
    await gone(tester, toast);

    // Tapping the offline button retries: still offline, the same toast
    // comes back for another five seconds.
    await tester.tap(find.byIcon(Icons.cloud_off));
    await tester.pump();
    for (var i = 0; i < 250 && toast.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(toast, findsOneWidget);
    await gone(tester, toast);

    await tester.runAsync(() async {
      await mega.close();
      try {
        await home.delete(recursive: true);
      } on FileSystemException {
        // Not the test's point.
      }
    });
  });
}
