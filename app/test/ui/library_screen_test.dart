import 'package:bandstand/domain/song/song_library_model.dart';
import 'package:bandstand/io/song_library.dart';
import 'package:bandstand/state/library_state.dart';
import 'package:bandstand/ui/screens/library_screen.dart';
import 'package:bandstand/ui/theme/bandstand_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Rendering, searching, sorting and filtering — everything the screen decides
/// for itself, given a library scan.
///
/// The scan is injected rather than read from disk. `testWidgets` runs in a
/// fake-async zone where a future backed by real file I/O never completes, so a
/// screen that reads the disk while under test cannot resolve. That is not a
/// limitation worth designing around: what the disk does is already covered by
/// `test/io/song_library_test.dart`, what the controller does by
/// `test/state/library_controller_test.dart`, and the two meeting on a real
/// event loop by `integration_test/library_test.dart`.
void main() {
  SongSummary summary({
    required String title,
    String composer = '',
    int tempo = 120,
    String key = 'C',
    int barCount = 32,
    Set<String> tags = const <String>{},
    DateTime? modifiedAt,
  }) => SongSummary(
    id: title.toLowerCase().replaceAll(' ', '-'),
    title: title,
    composer: composer,
    tempo: tempo,
    keyName: key,
    barCount: barCount,
    tags: tags,
    modifiedAt: modifiedAt ?? DateTime.utc(2026),
  );

  Widget harness(LibraryScan scan) => ProviderScope(
    overrides: [libraryScanProvider.overrideWith((ref) => scan)],
    child: MaterialApp(
      theme: BandstandTheme.dark(),
      home: const LibraryScreen(),
    ),
  );

  LibraryScan scanOf(
    List<SongSummary> songs, {
    List<LoadFailure> failures = const <LoadFailure>[],
  }) => LibraryScan(songs: songs, failures: failures);

  List<String> titlesOn(WidgetTester tester) => tester
      .widgetList<ListTile>(find.byType(ListTile))
      .map((tile) => (tile.title! as Text).data!)
      .toList();

  testWidgets('an empty library says so, and offers a way to start', (
    tester,
  ) async {
    await tester.pumpWidget(harness(scanOf(const <SongSummary>[])));
    await tester.pump();
    expect(find.textContaining('The library is empty'), findsOneWidget);
    expect(find.text('0 songs'), findsOneWidget);
    expect(
      find.widgetWithText(FloatingActionButton, 'New song'),
      findsOneWidget,
    );
  });

  testWidgets('songs appear with their headline facts', (tester) async {
    await tester.pumpWidget(
      harness(
        scanOf(<SongSummary>[
          summary(
            title: 'Blue Bossa',
            composer: 'Kenny Dorham',
            tempo: 148,
            key: 'Cm',
            barCount: 16,
          ),
        ]),
      ),
    );
    await tester.pump();

    expect(find.text('Blue Bossa'), findsOneWidget);
    expect(find.textContaining('Kenny Dorham'), findsOneWidget);
    expect(find.textContaining('16 bars'), findsOneWidget);
    expect(find.textContaining('Cm'), findsOneWidget);
    expect(find.textContaining('148 bpm'), findsOneWidget);
    expect(find.text('1 songs'), findsOneWidget);
  });

  testWidgets('the list is sorted by title by default', (tester) async {
    await tester.pumpWidget(
      harness(
        scanOf(<SongSummary>[
          summary(title: 'Zoot Suite'),
          summary(title: 'Ana Maria'),
          summary(title: 'Milestones'),
        ]),
      ),
    );
    await tester.pump();
    expect(titlesOn(tester), <String>['Ana Maria', 'Milestones', 'Zoot Suite']);
  });

  testWidgets('the sort can be changed', (tester) async {
    await tester.pumpWidget(
      harness(
        scanOf(<SongSummary>[
          // Three orders that differ under every sort, so each assert says
          // something: title B<F<M, tempo Ballad<Medium<Fast, composer
          // Adderley<Monk<Zawinul.
          summary(title: 'Fast', tempo: 240, composer: 'Adderley'),
          summary(title: 'Ballad', tempo: 60, composer: 'Monk'),
          summary(title: 'Medium', tempo: 120, composer: 'Zawinul'),
        ]),
      ),
    );
    await tester.pump();
    expect(titlesOn(tester), <String>['Ballad', 'Fast', 'Medium']);

    await tester.tap(find.byType(DropdownButton<SongSortOrder>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tempo').last);
    await tester.pumpAndSettle();
    expect(titlesOn(tester), <String>['Ballad', 'Medium', 'Fast']);

    await tester.tap(find.byType(DropdownButton<SongSortOrder>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Composer').last);
    await tester.pumpAndSettle();
    expect(titlesOn(tester), <String>['Fast', 'Ballad', 'Medium']);
  });

  testWidgets('the search box filters on title, composer and tag', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        scanOf(<SongSummary>[
          summary(
            title: 'Blue Monk',
            composer: 'Thelonious Monk',
            tags: const <String>{'blues'},
          ),
          summary(title: 'Autumn Leaves', composer: 'Kosma'),
        ]),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'monk');
    await tester.pump();
    expect(titlesOn(tester), <String>['Blue Monk']);
    expect(find.text('1 of 2 songs'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'kosma');
    await tester.pump();
    expect(titlesOn(tester), <String>['Autumn Leaves']);

    await tester.enterText(find.byType(TextField), 'blues');
    await tester.pump();
    expect(titlesOn(tester), <String>['Blue Monk']);

    // Every word has to match something, so this finds neither.
    await tester.enterText(find.byType(TextField), 'monk kosma');
    await tester.pump();
    expect(titlesOn(tester), isEmpty);
  });

  testWidgets('a search that matches nothing offers a way back', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(scanOf(<SongSummary>[summary(title: 'Blue Monk')])),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'coltrane');
    await tester.pump();
    expect(find.textContaining('Nothing here matches'), findsOneWidget);

    await tester.tap(find.text('Show all 1'));
    await tester.pump();
    expect(titlesOn(tester), <String>['Blue Monk']);
    // The field itself is back to empty too, not just the filter.
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );
  });

  testWidgets('the clear button empties the search box', (tester) async {
    await tester.pumpWidget(
      harness(
        scanOf(<SongSummary>[summary(title: 'One'), summary(title: 'Two')]),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'one');
    await tester.pump();
    expect(titlesOn(tester), <String>['One']);

    await tester.tap(find.byIcon(Icons.clear));
    await tester.pump();
    expect(titlesOn(tester), <String>['One', 'Two']);
  });

  testWidgets('tags become filter chips that narrow the list', (tester) async {
    await tester.pumpWidget(
      harness(
        scanOf(<SongSummary>[
          summary(title: 'One', tags: const <String>{'bossa'}),
          summary(title: 'Two', tags: const <String>{'swing'}),
          summary(title: 'Three', tags: const <String>{'bossa', 'ballad'}),
        ]),
      ),
    );
    await tester.pump();
    expect(find.byType(FilterChip), findsNWidgets(3));

    await tester.tap(find.widgetWithText(FilterChip, 'bossa'));
    await tester.pump();
    expect(titlesOn(tester), <String>['One', 'Three']);
    expect(find.text('2 of 3 songs'), findsOneWidget);

    // Tapping it again clears the filter.
    await tester.tap(find.widgetWithText(FilterChip, 'bossa'));
    await tester.pump();
    expect(titlesOn(tester), hasLength(3));
  });

  testWidgets('a recovered song is reported without alarm', (tester) async {
    await tester.pumpWidget(
      harness(
        scanOf(
          <SongSummary>[summary(title: 'Recoverable')],
          failures: const <LoadFailure>[
            LoadFailure(
              'recoverable',
              'not valid JSON',
              recoveredFromBackup: '2026-01-01.song.json',
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('recovered from a backup'), findsOneWidget);
    expect(find.text('Recoverable'), findsOneWidget);
  });

  testWidgets('a song that could not be read at all is reported loudly', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        scanOf(
          const <SongSummary>[],
          failures: const <LoadFailure>[LoadFailure('lost', 'not valid JSON')],
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('could not be read'), findsOneWidget);
    // §5.4: never silently show an empty library — it says which song, and why.
    expect(find.textContaining('not valid JSON'), findsOneWidget);
  });

  testWidgets('deleting asks before it does anything', (tester) async {
    await tester.pumpWidget(
      harness(scanOf(<SongSummary>[summary(title: 'Doomed')])),
    );
    await tester.pump();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Delete "Doomed"?'), findsOneWidget);
    expect(find.textContaining('backups are kept'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Doomed'), findsOneWidget);
  });

  testWidgets('the library folder failing to open is not a blank screen', (
    tester,
  ) async {
    // §5.4: "there is nowhere to keep anything" and "there is nothing here yet"
    // must not look the same.
    await tester.pumpWidget(
      MaterialApp(
        theme: BandstandTheme.dark(),
        home: Scaffold(
          body: LibraryErrorView(
            message: '${const SongLibraryUnavailable('no permission')}',
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('could not be opened'), findsWidgets);
    expect(find.textContaining('no permission'), findsOneWidget);
    expect(find.byIcon(Icons.folder_off_outlined), findsOneWidget);
  });
}
