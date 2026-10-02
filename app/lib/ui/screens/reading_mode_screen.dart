import 'dart:async';
import 'dart:math' as math;

import 'package:bandstand/audio/playhead.dart';
import 'package:bandstand/bridge/api/audio.dart';
import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/state/platform_audio.dart';
import 'package:bandstand/render/chart_style.dart';
import 'package:bandstand/render/chart_view.dart';
import 'package:bandstand/render/playback_cursor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// The chart, full screen, for playing from (§8.1).
///
/// No chrome, the largest type that fits, and tap zones only at the far edges
/// so a hand resting on the middle of the screen does nothing. The transport
/// overlay appears on a tap in the centre and hides itself again.
///
/// Nothing here can edit or delete anything: the library is opened read-only
/// for reading mode, so it is not a matter of this screen being careful.
class ReadingModeScreen extends StatefulWidget {
  const ReadingModeScreen({
    required this.song,
    this.transposition = 0,
    this.preference,
    super.key,
  });

  /// The tune, with any set overrides already applied.
  final Song song;

  /// Semitones to read it in, for a transposing instrument (§9).
  final int transposition;

  /// How the transposed chords are spelled.
  final SpellingPreference? preference;

  @override
  State<ReadingModeScreen> createState() => _ReadingModeScreenState();
}

class _ReadingModeScreenState extends State<ReadingModeScreen>
    with SingleTickerProviderStateMixin {
  /// How long the transport overlay stays up before hiding itself.
  static const Duration overlayLinger = Duration(seconds: 4);

  late final PlaybackCursorResolver _resolver = PlaybackCursorResolver(
    widget.song,
  );
  late final Ticker _ticker = createTicker(_onFrame);
  Timer? _overlayTimer;
  Timer? _idlePoll;

  ChartCursor _cursor = ChartCursor.hidden;
  bool _showOverlay = true;

  /// Whether the chart is drawn in Nashville numbers rather than letters.
  ///
  /// Off by default and not remembered between songs: this is a way of reading
  /// one chart, usually because the band is playing it in the singer's key, and
  /// coming back to a tune in numbers you did not ask for would be a surprise
  /// on stage. See `docs/rules/chart-layout.md` §6b.
  bool _numbers = false;
  double _scrollOffset = 0;

  /// The chart, so a page can measure how far it actually goes.
  final GlobalKey<ChartViewState> _chartKey = GlobalKey<ChartViewState>();

  @override
  void initState() {
    super.initState();
    unawaited(WakelockPlus.enable());
    _read(notify: false);
    _showOverlayBriefly();
  }

  @override
  void dispose() {
    _overlayTimer?.cancel();
    _idlePoll?.cancel();
    _ticker.dispose();
    unawaited(WakelockPlus.disable());
    unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
    super.dispose();
  }

  void _onFrame(Duration _) => _read(notify: true);

  void _read({required bool notify}) {
    final reading = Playhead.resolve(transportPosition());
    final playing = reading.state == TransportState.playing;
    if (playing) {
      _idlePoll?.cancel();
      _idlePoll = null;
      if (!_ticker.isActive) {
        _ticker.start();
      }
    } else {
      if (_ticker.isActive) {
        _ticker.stop();
      }
      _idlePoll ??= Timer.periodic(
        const Duration(milliseconds: 200),
        (_) => _read(notify: true),
      );
    }

    final cursor = _resolver.resolve(reading);
    if (cursor == _cursor) {
      return;
    }
    if (notify && mounted) {
      setState(() => _cursor = cursor);
    } else {
      _cursor = cursor;
    }
  }

  void _showOverlayBriefly() {
    _overlayTimer?.cancel();
    setState(() => _showOverlay = true);
    _overlayTimer = Timer(overlayLinger, () {
      if (mounted) {
        setState(() => _showOverlay = false);
      }
    });
  }

  void _page(int direction, double viewportHeight) {
    setState(() {
      _scrollOffset = (_scrollOffset + direction * viewportHeight * 0.9).clamp(
        0.0,
        _maxScrollOffset(viewportHeight),
      );
    });
  }

  /// How far the chart may move up: enough to bring its end to the bottom of
  /// the screen, and no further — paging past the end leaves the chart
  /// scrolled off entirely.
  double _maxScrollOffset(double viewportHeight) {
    final content = _chartKey.currentState?.layout?.size.height ?? 0;
    return math.max(
      0,
      content + _ChartPage.verticalPadding * 2 - viewportHeight,
    );
  }

  /// The keys a page turner sends (`docs/rules/page-turner.md` §1).
  ///
  /// A pedal is a Bluetooth keyboard with two keys on it, and which keystroke
  /// it sends is a setting on the pedal that a player has already made for some
  /// other app. All four conventions are honoured rather than asking them to
  /// change it.
  static final Set<LogicalKeyboardKey> _forward = <LogicalKeyboardKey>{
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.pageDown,
    LogicalKeyboardKey.space,
  };

  static final Set<LogicalKeyboardKey> _back = <LogicalKeyboardKey>{
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.pageUp,
    LogicalKeyboardKey.backspace,
  };

  /// Turn a page from a key, and say whether the key was ours.
  ///
  /// Deliberately not transport control: a pedal that started the band would
  /// start it when a player shifted their weight, and on stage that costs far
  /// more than the convenience (§3).
  KeyEventResult _onKey(KeyEvent event, double viewportHeight) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_forward.contains(event.logicalKey)) {
      _page(1, viewportHeight);
      return KeyEventResult.handled;
    }
    if (_back.contains(event.logicalKey)) {
      _page(-1, viewportHeight);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = ChartStyle.reading(scheme).copyWith(showBarNumbers: true);

    return Scaffold(
      backgroundColor: scheme.surface,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final height = constraints.maxHeight;
          return Focus(
            autofocus: true,
            onKeyEvent: (node, event) => _onKey(event, height),
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: _ChartPage(
                    song: widget.song,
                    style: style,
                    cursor: _cursor,
                    transposition: widget.transposition,
                    preference: widget.preference,
                    numbersIn: _numbers ? widget.song.key : null,
                    offset: _scrollOffset,
                    chartKey: _chartKey,
                  ),
                ),
                // Tap zones: far edges page, the middle shows the transport.
                // Nothing else is a gesture, so the chart cannot be disturbed.
                Positioned.fill(
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        flex: 15,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _page(-1, height),
                          child: const SizedBox.expand(),
                        ),
                      ),
                      Expanded(
                        flex: 70,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _showOverlayBriefly,
                          child: const SizedBox.expand(),
                        ),
                      ),
                      Expanded(
                        flex: 15,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _page(1, height),
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ],
                  ),
                ),
                AnimatedOpacity(
                  opacity: _showOverlay ? 1 : 0,
                  duration: const Duration(milliseconds: 220),
                  child: IgnorePointer(
                    ignoring: !_showOverlay,
                    child: _TransportOverlay(
                      song: widget.song,
                      transposition: widget.transposition,
                      numbers: _numbers,
                      onToggleNumbers: () {
                        _showOverlayBriefly();
                        setState(() => _numbers = !_numbers);
                      },
                      onInteraction: _showOverlayBriefly,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ChartPage extends StatelessWidget {
  const _ChartPage({
    required this.song,
    required this.style,
    required this.cursor,
    required this.transposition,
    required this.preference,
    required this.numbersIn,
    required this.offset,
    required this.chartKey,
  });

  /// Vertical padding above and below the chart.
  static const double verticalPadding = 12;

  final Song song;
  final ChartStyle style;
  final ChartCursor cursor;
  final int transposition;
  final SpellingPreference? preference;
  final KeySignature? numbersIn;
  final double offset;
  final GlobalKey<ChartViewState> chartKey;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: Transform.translate(
        offset: Offset(0, -offset),
        child: ChartView(
          key: chartKey,
          sheet: song.leadSheet,
          style: style,
          cursor: cursor,
          transposition: transposition,
          preference: preference,
          numbersIn: numbersIn,
          padding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: verticalPadding,
          ),
        ),
      ),
    );
  }
}

class _TransportOverlay extends ConsumerWidget {
  const _TransportOverlay({
    required this.song,
    required this.transposition,
    required this.numbers,
    required this.onToggleNumbers,
    required this.onInteraction,
  });

  final Song song;
  final int transposition;
  final bool numbers;
  final VoidCallback onToggleNumbers;
  final VoidCallback onInteraction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: <Widget>[
        Container(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          color: scheme.surface.withValues(alpha: 0.92),
          child: SafeArea(
            bottom: false,
            child: Row(
              children: <Widget>[
                IconButton(
                  tooltip: 'Leave reading mode',
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        song.title,
                        style: Theme.of(context).textTheme.titleLarge,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        <String>[
                          if (song.composer.isNotEmpty) song.composer,
                          '${song.key}',
                          '${song.tempo} bpm',
                          if (transposition != 0)
                            'reading ${transposition > 0 ? '+' : ''}'
                                '$transposition',
                          // Said explicitly because the numbers do not change
                          // when the transposition does — that is the point of
                          // the system, and it would otherwise look like the
                          // transposition had stopped working.
                          if (numbers) 'numbers in ${song.key}',
                        ].join('  ·  '),
                        style: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: numbers
                      ? 'Read the chart in letters'
                      : 'Read the chart in Nashville numbers',
                  isSelected: numbers,
                  onPressed: onToggleNumbers,
                  icon: const Icon(Icons.looks_one_outlined),
                  selectedIcon: const Icon(Icons.looks_one),
                ),
              ],
            ),
          ),
        ),
        const Spacer(),
        Container(
          padding: const EdgeInsets.all(12),
          color: scheme.surface.withValues(alpha: 0.92),
          child: SafeArea(
            top: false,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                IconButton.filledTonal(
                  iconSize: 34,
                  tooltip: 'Back to the top',
                  onPressed: () {
                    onInteraction();
                    unawaited(transportSeek(tick: 0));
                  },
                  icon: const Icon(Icons.skip_previous),
                ),
                const SizedBox(width: 16),
                IconButton.filled(
                  iconSize: 42,
                  tooltip: 'Play',
                  onPressed: () {
                    onInteraction();
                    // Through the platform controller: on Android this takes
                    // audio focus and starts the foreground service, so a
                    // locked screen does not stop the band mid-set.
                    unawaited(
                      ref
                          .read(platformAudioProvider.notifier)
                          .play(title: song.title),
                    );
                  },
                  icon: const Icon(Icons.play_arrow),
                ),
                const SizedBox(width: 16),
                IconButton.filledTonal(
                  iconSize: 34,
                  tooltip: 'Pause',
                  onPressed: () {
                    onInteraction();
                    unawaited(ref.read(platformAudioProvider.notifier).pause());
                  },
                  icon: const Icon(Icons.pause),
                ),
                const SizedBox(width: 16),
                IconButton.filledTonal(
                  iconSize: 34,
                  tooltip: 'Stop',
                  onPressed: () {
                    onInteraction();
                    unawaited(ref.read(platformAudioProvider.notifier).stop());
                  },
                  icon: const Icon(Icons.stop),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
