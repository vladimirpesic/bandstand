import 'dart:io';

import 'package:bandstand/io/library/library_settings.dart';
import 'package:bandstand/state/library.dart';
import 'package:bandstand/state/setlists.dart';
import 'package:bandstand/ui/screens/setlists_screen.dart';
import 'package:bandstand/ui/widgets/add_to_setlist_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// One running app against a temp home: no MEGA, no link — the library
/// sits on its "paste the link" phase, which is all the setlists screen
/// needs to know (Favorites counts zero), and the setlists run for
/// real, file and all. Sync file work is fine in the fake zone; every
/// save is real async, awaited the way the settings-dialog test taught:
/// [until] turns both event loops until the finder finds.
Future<ProviderContainer> pumpApp(WidgetTester tester, Widget child) async {
  final home = Directory.systemTemp.createTempSync('setlists-ui-test');
  addTearDown(() {
    try {
      home.deleteSync(recursive: true);
    } on FileSystemException {
      // Not the test's point.
    }
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
            httpClient: http.Client(),
          ),
        ),
      ],
      child: MaterialApp(home: child),
    ),
  );
  // The provider's first read of the file is one turn out; settle it.
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
}

/// Fake zone for the widget's await chains (flushed by `pump`), real
/// one for the disks they await (turned by `runAsync`). One of each,
/// until [finder] finds — then a few more of both, because the finding
/// usually lands before the real write behind it (a dialog cannot close
/// until its confirm has been saved), and the next gesture needs that
/// finished too.
Future<void> until(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 250 && finder.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(finder, findsWidgets);
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  testWidgets('Favorites is pinned; setlists come, rename, and go', (
    tester,
  ) async {
    await pumpApp(tester, const SetlistsScreen());

    expect(find.text('Favorites'), findsOneWidget);
    expect(find.textContaining('nothing bookmarked yet'), findsOneWidget);

    // Make one.
    await tester.tap(find.byIcon(Icons.playlist_add));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Gig Saturday');
    await tester.tap(find.text('Create'));
    // The field itself says "Gig Saturday" while the save runs; the
    // tile is the thing that only exists once it has.
    await until(tester, find.widgetWithText(ListTile, 'Gig Saturday'));
    // The dialog is still closing when the tile lands; settle before
    // the next thing expects the screen bare.
    await tester.pumpAndSettle();
    expect(find.text('empty'), findsOneWidget);

    // Rename it.
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'First Set');
    await tester.tap(find.text('Rename'));
    await until(tester, find.widgetWithText(ListTile, 'First Set'));
    await tester.pumpAndSettle();
    expect(find.text('Gig Saturday'), findsNothing);

    // A name already taken is refused, on the field, dialog open.
    await tester.tap(find.byIcon(Icons.playlist_add));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'first set');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(find.textContaining('There is already a setlist'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Delete it — confirmed once, and the empty state returns.
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await until(tester, find.textContaining('No setlists of your own yet'));
    expect(find.text('First Set'), findsNothing);
  });

  testWidgets('the sheet makes a setlist with the tune, and refuses a repeat', (
    tester,
  ) async {
    final container = await pumpApp(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showAddToSetlistSheet(
              context,
              trackName: 'Blues In Bb',
              entryId: 'a',
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Add "Blues In Bb" to…'), findsOneWidget);

    // No setlists yet: the new one is the whole offer.
    await tester.tap(find.text('New setlist…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Practice');
    await tester.tap(find.text('Create'));
    await until(tester, find.textContaining('Added to "Practice"'));
    expect(container.read(setlistsProvider).setlists.single.entryIds, <String>[
      'a',
    ]);

    // Reopened, the setlist is there and the tune is already in it:
    // checked, inert — a tune cannot be added twice.
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Practice'));
    await tester.pump();
    expect(container.read(setlistsProvider).setlists.single.entryIds, <String>[
      'a',
    ]);
  });
}
