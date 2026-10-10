import 'dart:async';

import 'package:bandstand/io/library/manifest.dart';
import 'package:bandstand/state/library.dart';
import 'package:bandstand/state/player.dart';
import 'package:bandstand/ui/screens/reader_screen.dart';
import 'package:bandstand/ui/widgets/centered_note.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// The track under the player's hands: position, transport, isolation and
/// cycle (ADR 0012, milestone 3).
///
/// The screen is a view on [playerProvider]; the volume and entry are
/// re-resolved from the library on every build, so a sync that removes the
/// track mid-session lands as a note, not a crash.
class PlayerScreen extends ConsumerStatefulWidget {
  /// Create the screen for one entry.
  const PlayerScreen({
    super.key,
    required this.volumeId,
    required this.entryId,
  });

  /// The volume the entry belongs to.
  final String volumeId;

  /// The entry to load and play.
  final String entryId;

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  /// The slider value while a scrub is in flight; null when the slider
  /// tracks the playhead.
  double? _scrubValue;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _open();
      _applyWakelock(ref.read(playerProvider).isPlaying);
    });
  }

  @override
  void dispose() {
    // Leaving the screen may leave the music running — that is the point of
    // a phone player — but it must not keep the screen awake.
    unawaited(WakelockPlus.disable());
    super.dispose();
  }

  /// Resolve the entry through the library and hand it to the player.
  void _open() {
    if (!mounted) {
      return;
    }
    final phase = ref.read(libraryProvider);
    if (phase is! LibraryReady) {
      return; // The library screen is the gate; there is nothing to resolve.
    }
    final volume = _resolveVolume(phase);
    final entry = _resolve(phase);
    if (volume != null && entry != null) {
      ref.read(playerProvider.notifier).open(volume, entry);
    }
  }

  /// Reading a chart from a stand while the track runs is exactly the moment
  /// the screen must not sleep — the reason `wakelock_plus` is a dependency.
  void _applyWakelock(bool playing) {
    unawaited(WakelockPlus.toggle(enable: playing));
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(playerProvider, (_, next) => _applyWakelock(next.isPlaying));

    final phase = ref.watch(libraryProvider);
    final player = ref.watch(playerProvider);

    // The manifest, not the arguments, is the truth: a track removed by a
    // sync while the screen is open shows a note. What is already decoded
    // keeps playing — the engine holds its own copy.
    final resolved = phase is LibraryReady && _resolve(phase) != null;

    final Widget body;
    if (player.loadError != null) {
      body = _DecodeFailure(
        message: player.loadError!,
        onRetry: resolved ? _open : null,
      );
    } else if (!resolved && player.info == null) {
      body = const CenteredNote(
        icon: Icons.music_off,
        message: 'This track left the library in the last sync.',
      );
    } else if (player.loading || player.info == null) {
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text('Decoding ${player.trackName}…'),
          ],
        ),
      );
    } else {
      body = _Controls(scrubValue: _scrubValue, onScrub: _onScrub);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(player.trackName),
        // The practice path: the book open beside the track, the player
        // running underneath it (ADR 0012 — the reader is concurrent by
        // design and never touches the audio path).
        actions: <Widget>[
          if (phase is LibraryReady && _resolveVolume(phase)?.book != null)
            IconButton(
              tooltip: 'Read the book while this plays',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) => ReaderScreen(volumeId: widget.volumeId),
                ),
              ),
              icon: const Icon(Icons.menu_book_outlined),
            ),
        ],
      ),
      body: body,
    );
  }

  LibraryVolume? _resolveVolume(LibraryReady phase) {
    final manifest = phase.manifest;
    // The library's own files resolve through the root; volumes through
    // themselves. The player never cares which kind of folder it was.
    if (manifest.rootFiles.isNotEmpty && manifest.rootId == widget.volumeId) {
      return manifest.rootVolume;
    }
    for (final volume in manifest.volumes) {
      if (volume.id == widget.volumeId) {
        return volume;
      }
    }
    return null;
  }

  LibraryEntry? _resolve(LibraryReady phase) {
    final volume = _resolveVolume(phase);
    if (volume == null) {
      return null;
    }
    for (final entry in volume.entries) {
      if (entry.id == widget.entryId) {
        return entry;
      }
    }
    return null;
  }

  void _onScrub(double? value, {bool ended = false}) {
    if (!ended) {
      setState(() => _scrubValue = value);
      return;
    }
    setState(() => _scrubValue = null);
    if (value != null) {
      ref.read(playerProvider.notifier).seekTo(value);
    }
  }
}

/// The decode could not be turned into a track: what went wrong, and — when
/// the entry is still in the library — the way back.
class _DecodeFailure extends StatelessWidget {
  const _DecodeFailure({required this.message, required this.onRetry});

  /// Why the decode failed, in words.
  final String message;

  /// Runs the decode again; null when there is nothing left to retry.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.error_outline,
              size: 48,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            if (onRetry != null) ...<Widget>[
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: onRetry,
                child: const Text('Try again'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The loaded track's controls: position and scrub, transport, isolation,
/// repeat and the loop.
class _Controls extends ConsumerWidget {
  const _Controls({required this.scrubValue, required this.onScrub});

  /// Where the scrub stands, or null when the slider tracks the playhead.
  final double? scrubValue;

  /// Reports a scrub move, and the release that commits it.
  final void Function(double? value, {bool ended}) onScrub;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final controller = ref.read(playerProvider.notifier);
    final duration = player.durationMs!;
    final position = scrubValue ?? player.positionMs;

    final cycleLabel = player.hasCycle
        ? 'Loop ${PlayerController.describeClock(player.cycleStartMs!)}'
              ' – ${PlayerController.describeClock(player.cycleEndMs!)}'
        : player.awaitingCycleEnd
        ? 'Set loop end'
        : 'Set loop start';

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Text(PlayerController.describeClock(position.round())),
                  Expanded(
                    child: Slider(
                      value: position < 0
                          ? 0
                          : (position > duration
                                ? duration.toDouble()
                                : position),
                      max: duration.toDouble(),
                      onChanged: (value) => onScrub(value),
                      onChangeEnd: (value) => onScrub(value, ended: true),
                    ),
                  ),
                  Text(PlayerController.describeClock(duration)),
                ],
              ),
              if (player.playError != null) ...<Widget>[
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    Icon(
                      Icons.error_outline,
                      size: 16,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        player.playError!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  SizedBox(
                    width: 72,
                    height: 72,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        shape: const CircleBorder(),
                      ),
                      onPressed: player.isPlaying
                          ? controller.pause
                          : controller.play,
                      child: Icon(
                        player.isPlaying ? Icons.pause : Icons.play_arrow,
                        size: 36,
                      ),
                    ),
                  ),
                  const SizedBox(width: 24),
                  IconButton(
                    tooltip: 'Stop and rewind',
                    onPressed: controller.stop,
                    icon: const Icon(Icons.stop),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              SegmentedButton<ChannelMode>(
                showSelectedIcon: false,
                segments: const <ButtonSegment<ChannelMode>>[
                  ButtonSegment<ChannelMode>(
                    value: ChannelMode.both,
                    label: Text('Trio'),
                  ),
                  ButtonSegment<ChannelMode>(
                    value: ChannelMode.left,
                    label: Text('Bass'),
                  ),
                  ButtonSegment<ChannelMode>(
                    value: ChannelMode.right,
                    label: Text('Piano'),
                  ),
                ],
                selected: <ChannelMode>{player.mix},
                onSelectionChanged: (selection) =>
                    controller.setMix(selection.first),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  IconButton(
                    tooltip: switch (player.repeatMode) {
                      TrackRepeat.off => 'Repeat: off — tap for one more pass',
                      TrackRepeat.once => 'Repeat: one more pass, then stop',
                      TrackRepeat.forever => 'Repeat: on until you tap it off',
                    },
                    isSelected: player.repeatMode != TrackRepeat.off,
                    onPressed: controller.cycleRepeatMode,
                    icon: Icon(switch (player.repeatMode) {
                      TrackRepeat.off => Icons.repeat,
                      TrackRepeat.once => Icons.repeat_one,
                      TrackRepeat.forever => Icons.repeat,
                    }),
                  ),
                  const SizedBox(width: 8),
                  Tooltip(
                    message: player.hasCycle
                        ? 'Looping this section — tap to mark a new one'
                        : player.awaitingCycleEnd
                        ? 'Tap where the loop should end'
                        : 'Tap where the loop should start',
                    child: TextButton.icon(
                      onPressed: controller.markCyclePoint,
                      icon: Icon(
                        player.hasCycle
                            ? Icons.all_inclusive
                            : (player.awaitingCycleEnd
                                  ? Icons.flag
                                  : Icons.flag_outlined),
                      ),
                      label: Text(cycleLabel),
                    ),
                  ),
                  if (player.hasCycle)
                    IconButton(
                      tooltip: 'Take the loop off',
                      onPressed: controller.clearCycle,
                      icon: const Icon(Icons.close),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
