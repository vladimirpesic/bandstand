import 'package:bandstand/bridge/api/audio.dart';
import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/state/generation_state.dart';
import 'package:bandstand/state/platform_audio.dart';
import 'package:bandstand/state/playback_state.dart';
import 'package:bandstand/ui/screens/mixer_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Generate the open song, play it, and say what happened.
///
/// This is the §10 M5 acceptance in one strip: press play on a chart and hear
/// time, and see that regenerating took less than the §3 budget.
class SongTransportBar extends ConsumerWidget {
  const SongTransportBar({required this.song, super.key});

  /// The song on screen.
  final Song song;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playback = ref.watch(songPlaybackProvider);
    final controller = ref.read(songPlaybackProvider.notifier);
    final audio = ref.watch(playbackProvider);
    final theme = Theme.of(context);

    final needsBank = audio.bank == null;
    final ready = playback.hasSequence && playback.songId == song.id;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (needsBank)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              'Load a soundbank on the Audio screen to hear anything.',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        if (playback.errorMessage != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    playback.errorMessage!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
                IconButton(
                  onPressed: controller.dismissError,
                  icon: const Icon(Icons.close),
                  tooltip: 'Dismiss',
                ),
              ],
            ),
          ),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            FilledButton.icon(
              onPressed: playback.busy
                  ? null
                  : () async {
                      await controller.generateAndLoad(song);
                      final loaded = ref.read(songPlaybackProvider);
                      if (loaded.errorMessage != null ||
                          loaded.songId != song.id) {
                        // Generation failed, and the engine may still hold a
                        // different song's sequence. The banner above says
                        // why; playing or seeking here would start the wrong
                        // music.
                        return;
                      }
                      await transportSeek(tick: 0);
                      // Through the platform controller, so Android takes
                      // audio focus and starts the foreground service before
                      // anything sounds (docs/rules/android-audio.md §2, §3).
                      await ref
                          .read(platformAudioProvider.notifier)
                          .play(title: song.title);
                    },
              icon: const Icon(Icons.play_arrow),
              label: Text(ready ? 'Play' : 'Generate and play'),
            ),
            OutlinedButton.icon(
              onPressed: () => ref.read(platformAudioProvider.notifier).pause(),
              icon: const Icon(Icons.pause),
              label: const Text('Pause'),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                await ref.read(platformAudioProvider.notifier).stop();
                await allNotesOff();
              },
              icon: const Icon(Icons.stop),
              label: const Text('Stop'),
            ),
            OutlinedButton.icon(
              onPressed: playback.busy ? null : () => controller.reroll(song),
              icon: const Icon(Icons.casino_outlined),
              label: const Text('Reroll'),
            ),
            OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const MixerScreen()),
              ),
              icon: const Icon(Icons.tune),
              label: const Text('Mixer'),
            ),
          ],
        ),
        if (ready) ...<Widget>[
          const SizedBox(height: 12),
          Text(
            '${playback.noteCount} notes across ${playback.voiceCount} '
            'voice${playback.voiceCount == 1 ? '' : 's'}  ·  '
            'generated in ${playback.generationMs.toStringAsFixed(1)} ms  ·  '
            'take ${playback.seed + 1}',
            style: theme.textTheme.bodySmall,
          ),
        ],
        if (playback.problems.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          for (final problem in playback.problems)
            Text(
              '• $problem',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
        ],
      ],
    );
  }
}
