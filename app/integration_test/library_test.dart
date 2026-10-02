import 'dart:io';

import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/bridge/frb_generated.dart';
import 'package:bandstand/io/harmony_assets.dart';
import 'package:bandstand/io/song_library.dart';
import 'package:bandstand/io/uuid.dart';
import 'package:bandstand/state/library_state.dart';
import 'package:bandstand/ui/app.dart';
import 'package:bandstand/render/chart_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// The library, the editor and the sets, driven through the real app on a real
/// event loop.
///
/// This is the half the widget tests cannot reach: `testWidgets` runs in a
/// fake-async zone where a future backed by the filesystem never completes, so
/// a screen that reads the disk can only be exercised here.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late SongLibrary library;

  setUpAll(() async {
    await installHarmonyAssets();
    // Reading mode reads the transport, which needs the Rust side up.
    await RustLib.init();
  });

  setUp(() async {
    root = Directory.systemTemp.createTempSync('bandstand-integration');
    library = SongLibrary(root);
    await library.ensureLayout();
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  /// Pump until [finder] matches something, or give up.
  ///
  /// `pumpAndSettle` returns as soon as no frame is scheduled, which can be
  /// before a future backed by the filesystem has completed — the caveat this
  /// file opens with. Adding a fixed delay hides that most of the time and
  /// fails on a loaded machine; waiting on the widget itself is quick when the
  /// disk is quick and patient when it is not.
  ///
  /// This is what a set entry needed: `ensureVisible` on a row that had not
  /// been read back from disk yet threw "Bad state: No element", roughly one
  /// run in six, and only when the integration suites ran back to back.
  Future<void> pumpUntil(
    WidgetTester tester,
    Finder finder, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 50));
      if (finder.evaluate().isNotEmpty) {
        return;
      }
    }
    throw StateError('timed out after $timeout waiting for $finder');
  }

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [songLibraryProvider.overrideWith((ref) async => library)],
        child: const BandstandApp(),
      ),
    );
    // Two providers resolve off the disk — the scan and the crash journal —
    // and `pumpAndSettle` returns as soon as no frame is scheduled, which can
    // be before the second lands.
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
  }

  testWidgets('the app opens on the library', (tester) async {
    await pumpApp(tester);
    expect(find.text('Library'), findsWidgets);
    expect(find.textContaining('The library is empty'), findsOneWidget);
  });

  testWidgets('a song written to the folder appears in the list', (
    tester,
  ) async {
    await library.saveSong(Song.blank(id: newUuid(), title: 'Blue Bossa'));
    await pumpApp(tester);
    expect(find.text('Blue Bossa'), findsOneWidget);
    expect(find.text('1 songs'), findsOneWidget);
  });

  testWidgets('creating a song opens it, and editing it survives a save', (
    tester,
  ) async {
    await pumpApp(tester);

    await tester.tap(find.widgetWithText(FloatingActionButton, 'New song'));
    await tester.pumpAndSettle();
    expect(find.text('Untitled'), findsWidgets);

    await tester.enterText(find.widgetWithText(TextField, 'Untitled'), 'Solar');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    final scan = await library.scan();
    expect(scan.songs.single.title, 'Solar');

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Solar'), findsOneWidget);
  });

  testWidgets('undo puts back what an edit changed', (tester) async {
    await library.saveSong(Song.blank(id: newUuid(), title: 'Undoable'));
    await pumpApp(tester);

    await tester.tap(find.text('Undoable'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Undoable'),
      'Changed',
    );
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Changed'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.undo));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Undoable'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.redo));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Changed'), findsOneWidget);
  });

  testWidgets('the form panel reports what will actually play', (tester) async {
    await library.saveSong(Song.blank(id: newUuid(), title: 'Form'));
    await pumpApp(tester);
    await tester.tap(find.text('Form'));
    await tester.pumpAndSettle();

    // The chart is drawn above the form panel, so scroll down to it.
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(find.text('WRITTEN'), findsOneWidget);
    expect(find.text('PLAYED'), findsOneWidget);
    expect(find.text('32 bars'), findsNWidgets(2));
  });

  testWidgets('an unsaved edit is offered back on the next start', (
    tester,
  ) async {
    final song = Song.blank(id: newUuid(), title: 'Interrupted');
    await library.saveSong(song);
    await library.writeJournal(
      song.copyWith(
        title: 'Never saved',
        modifiedAt: song.modifiedAt.add(const Duration(minutes: 1)),
      ),
    );

    await pumpApp(tester);
    expect(
      find.textContaining('Unsaved changes to "Never saved"'),
      findsOneWidget,
    );

    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Unsaved changes'), findsNothing);
    expect((await library.loadSong(song.id)).title, 'Never saved');
  });

  testWidgets('the chart is drawn, and the editor writes chords into it', (
    tester,
  ) async {
    await library.saveSong(Song.blank(id: newUuid(), title: 'To edit'));
    await pumpApp(tester);
    await tester.tap(find.text('To edit'));
    await tester.pumpAndSettle();

    // The details screen draws the chart.
    expect(find.byType(ChartView), findsOneWidget);

    await tester.tap(find.byIcon(Icons.edit_note));
    await tester.pumpAndSettle();
    expect(find.textContaining('Bar 1'), findsOneWidget);

    // Type a chord and place it; the caret moves on to the next bar.
    await tester.enterText(find.byType(TextField).last, 'Dm7');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.textContaining('Bar 2'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, 'G7');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    final scan = await library.scan();
    final saved = await library.loadSong(scan.songs.single.id);
    expect(saved.leadSheet.chordItems.map((c) => c.chord.format()), <String>[
      'Dm7',
      'G7',
    ]);
  });

  testWidgets('an iReal URL brings in a whole book', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byIcon(Icons.download_outlined));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField).last,
      'irealbook://Blue Bossa=Dorham Kenny=Medium Bossa=Cm=n='
      '*A{|Cm7 |Cm7 |Fm7 |Fm7 }===Solar=Davis Miles=Medium Swing=Cm=n='
      '*A|Cm6 |Cm6 |Gm7 |C7 |===My Book',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Import'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Imported 2 charts'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Done'));
    await tester.pumpAndSettle();

    expect(find.text('Blue Bossa'), findsOneWidget);
    expect(find.text('Solar'), findsOneWidget);
    final scan = await library.scan();
    expect(scan.songs, hasLength(2));
    final bossa = await library.loadSong(
      scan.songs.firstWhere((s) => s.title == 'Blue Bossa').id,
    );
    expect(bossa.composer, 'Kenny Dorham');
    expect(bossa.leadSheet.barCount, 4);
  });

  testWidgets('reading mode shows the chart full screen', (tester) async {
    await library.saveSong(Song.blank(id: newUuid(), title: 'On the stand'));
    await pumpApp(tester);
    await tester.tap(find.text('On the stand'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.fullscreen));
    await tester.pumpAndSettle();

    expect(find.byType(ChartView), findsOneWidget);
    expect(find.text('On the stand'), findsWidgets);
    // The transport is there, and leaving is one tap.
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    // Back on the song screen, which is identified by the button that opened
    // reading mode rather than by the absence of a play button: the song
    // screen has a transport of its own, and whether it is on screen depends
    // on the window's height. On a phone in portrait it is, and asserting
    // otherwise passed on a short desktop window and failed on the emulator.
    expect(find.byIcon(Icons.fullscreen), findsOneWidget);
    expect(find.byIcon(Icons.close), findsNothing);
  });

  testWidgets('a set can be made, and a song put in it', (tester) async {
    await library.saveSong(Song.blank(id: newUuid(), title: 'Take Five'));
    await pumpApp(tester);

    await tester.tap(find.text('Sets').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('No sets yet'), findsOneWidget);

    await tester.tap(find.widgetWithText(FloatingActionButton, 'New set'));
    await tester.pumpAndSettle();
    expect(find.text('New set'), findsWidgets);
    expect(find.textContaining('This set is empty'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Add song'));
    await tester.pumpAndSettle();
    // Same hazard as the override test below: the picker reads the library.
    await pumpUntil(tester, find.textContaining('Take Five'));
    await tester.tap(find.textContaining('Take Five'));
    await tester.pumpAndSettle();

    expect(find.text('Take Five'), findsOneWidget);
    final playlists = await library.loadPlaylists();
    expect(playlists.single.entries.single.songId, isNotEmpty);
  });

  testWidgets('a set override never touches the song in the library', (
    tester,
  ) async {
    final song = Song.blank(id: newUuid(), title: 'Overridden');
    await library.saveSong(song);
    await pumpApp(tester);

    await tester.tap(find.text('Sets').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FloatingActionButton, 'New set'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Add song'));
    await tester.pumpAndSettle();
    // The picker lists the library, which it reads from disk.
    await pumpUntil(tester, find.textContaining('Overridden'));
    await tester.tap(find.textContaining('Overridden'));
    await tester.pumpAndSettle();

    // The overrides button sits at the end of the entry row, which can be off
    // screen at a narrow window width — and the row itself only exists once
    // the set has been written and read back.
    await pumpUntil(tester, find.byIcon(Icons.tune));
    await tester.ensureVisible(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    expect(find.textContaining('never changed'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
    await tester.pumpAndSettle();

    // Whatever the set says, the stored song is exactly as it was.
    expect(await library.loadSong(song.id), song);
  });
}
