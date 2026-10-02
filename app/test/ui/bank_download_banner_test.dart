import 'dart:io';
import 'dart:typed_data';

import 'package:bandstand/audio/soundbank_library.dart';
import 'package:bandstand/io/bank_download.dart';
import 'package:bandstand/io/song_library.dart';
import 'package:bandstand/state/bank_download_state.dart';
import 'package:bandstand/state/library_state.dart';
import 'package:bandstand/state/playback_state.dart';
import 'package:bandstand/ui/theme/bandstand_theme.dart';
import 'package:bandstand/ui/widgets/bank_download_banner.dart';
import 'package:bandstand/ui/widgets/playback_panel.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The widget tests for the download run the real controller against a real
/// loopback server — inside `tester.runAsync`, because sockets do not care
/// for fake time. What is under test here is what the user sees: the offer,
/// the three answers to it, and the controls under an empty picker.
final Uint8List _bytes = () {
  final bytes = Uint8List(2 * 1024 * 1024);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = (i * 23 + 11) & 0xff;
  }
  return bytes;
}();

void main() {
  late Directory root;
  late Uri mirror;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('bandstand_bank_ui');
    await SongLibrary(root).ensureLayout();
    // Bound here, not inside the test body: a `testWidgets` body runs in a
    // fake-async zone whose microtasks only advance on `pump`, and a server
    // whose handler awaits in that zone would stall the `runAsync` loop
    // below forever. Up here it lives on the real event loop.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.contentLength = _bytes.length;
      request.response.add(_bytes);
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));
    mirror = Uri.parse('http://127.0.0.1:${server.port}/FluidR3_GM.sf2');
  });

  tearDown(() async {
    if (root.existsSync()) {
      await root.delete(recursive: true);
    }
  });

  ProviderContainer makeContainer() {
    final bank = RecommendedBank(
      fileName: 'FluidR3_GM.sf2',
      displayName: 'Test bank',
      sizeBytes: _bytes.length,
      sha256: sha256.convert(_bytes).toString(),
      mirrors: <Uri>[mirror],
    );
    final container = ProviderContainer(
      overrides: [
        songLibraryProvider.overrideWith((ref) async => SongLibrary(root)),
        // The banner asks the machine whether it has *any* bank; the test
        // machine may well have system ones. Say it has none.
        soundbanksProvider.overrideWith((ref) async => <SoundbankFile>[]),
        bankOfferDeclinedProvider.overrideWith((ref) async => false),
        bankDownloaderProvider.overrideWith(
          (ref) =>
              (directory) => BankDownloader(directory: directory, bank: bank),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<void> pumpBanner(WidgetTester tester, ProviderContainer container) {
    return tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: BandstandTheme.dark(),
          home: const Scaffold(
            body: Column(children: <Widget>[BankDownloadBanner()]),
          ),
        ),
      ),
    );
  }

  testWidgets('offers the bank, downloads it, and leaves when done', (
    tester,
  ) async {
    final container = makeContainer();
    await pumpBanner(tester, container);
    await tester.pump();

    expect(find.text('No soundbank yet'), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);

    await tester.runAsync(() async {
      // flutter_test replaces dart:io's HttpClient with a mock that answers
      // every request with 400 — harmless for widget tests in general,
      // fatal for one that means to move real bytes. Cleared for this block
      // only; the server side is plain sockets and needs no such escape.
      final previous = HttpOverrides.current;
      HttpOverrides.global = null;
      try {
        await container.read(bankDownloadProvider.notifier).start();
      } finally {
        HttpOverrides.global = previous;
      }
    });
    await tester.pump();

    final target = File(
      '${root.path}${Platform.pathSeparator}soundbanks'
      '${Platform.pathSeparator}FluidR3_GM.sf2',
    );
    expect(target.existsSync(), isTrue);
    expect(
      find.text('No soundbank yet'),
      findsNothing,
      reason: 'the work is done; the banner has nothing left to say',
    );
  });

  testWidgets('"Not now" hides the offer for the session', (tester) async {
    final container = makeContainer();
    await pumpBanner(tester, container);
    await tester.pump();

    await tester.tap(find.text('Not now'));
    await tester.pump();

    expect(find.text('No soundbank yet'), findsNothing);
    expect(container.read(bankDownloadProvider).sessionDeclined, isTrue);
  });

  testWidgets('"Never ask again" is remembered on disk', (tester) async {
    final container = makeContainer();
    await pumpBanner(tester, container);
    await tester.pump();

    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Never ask again'));
    await tester.pump();

    // The banner leaves synchronously — the session refusal needs no disk.
    expect(find.text('No soundbank yet'), findsNothing);

    // The dot-file part is real file I/O. The tap fired this once in the
    // fake-async zone, but a widget test is a dishonest place to wait on
    // real I/O scheduled there — so the same, idempotent call is made here
    // on the real event loop, and its result read back.
    final declined = await tester.runAsync(() async {
      await container.read(bankDownloadProvider.notifier).neverAskAgain();
      return RecommendedBankChoice.isDeclined(
        SongLibrary(root).soundbanksDirectory,
      );
    });
    expect(declined, isTrue);
  });

  testWidgets('the offer card survives a narrow phone screen', (tester) async {
    // 320 logical pixels wide: the narrowest screen the card has to read
    // well on. Regression test for the release build, where the three
    // actions shared a row with the text and squeezed it into a strip one
    // word wide, stretching the card over most of the screen.
    tester.view.physicalSize = const Size(320, 570);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final container = makeContainer();
    await pumpBanner(tester, container);
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('No soundbank yet'), findsOneWidget);

    // The body text runs the width of the card, not a one-word column.
    final textWidth = tester
        .getSize(find.textContaining('Playing needs one'))
        .width;
    expect(textWidth, greaterThan(180));

    // And the card is a strip at the top, not most of the screen. The test
    // font renders wider than any real one, so the bound is generous — the
    // broken layout was taller than the viewport and tripped the exception
    // check above long before this one.
    final card = tester.getSize(
      find
          .descendant(
            of: find.byType(BankDownloadBanner),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(card.height, lessThan(500));
  });

  testWidgets('the empty picker offers the download where it is needed', (
    tester,
  ) async {
    final container = makeContainer();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: BandstandTheme.dark(),
          home: const Scaffold(body: PlaybackPanel()),
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('FluidR3 GM'), findsOneWidget);
    // The under-picker offer is the tonal one; the banner's prominent
    // non-tonal "Download" belongs to the library screen only.
    expect(find.widgetWithText(FilledButton, 'Download'), findsOneWidget);
  });
}
