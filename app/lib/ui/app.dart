import 'dart:ui' show AppExitResponse;

import 'package:bandstand/state/library.dart';
import 'package:bandstand/ui/screens/library_screen.dart';
import 'package:bandstand/ui/theme/bandstand_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The navigator under the shell, so the closing question (which fires from
/// outside the widget tree, in the lifecycle listener) can still show a
/// dialog over whatever screen is up.
final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

/// The application shell.
///
/// The home is the MEGA-backed play-along library (ADR 0012, transport per
/// ADR 0013); the player and the reader land on top of it as the next work
/// items. The one thing the shell owns itself is the closing question:
/// session downloads are offered once, keep or discard, per §6 of
/// `docs/rules/mega-library.md`.
class BandstandApp extends ConsumerStatefulWidget {
  const BandstandApp({super.key});

  @override
  ConsumerState<BandstandApp> createState() => _BandstandAppState();
}

class _BandstandAppState extends ConsumerState<BandstandApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onExitRequested: () => _askAboutSessionFiles(),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bandstand',
      navigatorKey: _navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: BandstandTheme.light(),
      darkTheme: BandstandTheme.dark(),
      // Dark by default: the app is read on a stand, in a dark room, from two
      // metres away (§8.1). The light theme is the exception, not the default.
      themeMode: ThemeMode.dark,
      home: const LibraryScreen(),
    );
  }

  /// §6: closing with session downloads on disk is a decision, not an
  /// accident. No session files — or no library at all — and closing is
  /// closing.
  Future<AppExitResponse> _askAboutSessionFiles() async {
    final controller = ref.read(libraryProvider.notifier);
    final summary = await controller.sessionSummary();
    final context = _navigatorKey.currentContext;
    if (context == null || !context.mounted || summary.count == 0) {
      return AppExitResponse.exit;
    }
    final choice = await showDialog<_ExitChoice>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Session downloads'),
        content: Text(
          '${summary.count} download(s) from this session — '
          '${LibraryController.describeBytes(summary.bytes)} — '
          'are on this device. Keep them, or delete them?',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(_ExitChoice.cancel),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(context).pop(_ExitChoice.discard),
            child: const Text('Delete'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(_ExitChoice.keep),
            child: const Text('Keep'),
          ),
        ],
      ),
    );
    return switch (choice) {
      _ExitChoice.keep => () async {
        await controller.keepAllSessionFiles();
        return AppExitResponse.exit;
      }(),
      _ExitChoice.discard => () async {
        await controller.discardAllSessionFiles();
        return AppExitResponse.exit;
      }(),
      _ => AppExitResponse.cancel,
    };
  }
}

enum _ExitChoice { keep, discard, cancel }
