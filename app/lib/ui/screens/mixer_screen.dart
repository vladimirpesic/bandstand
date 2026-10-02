import 'package:bandstand/domain/song/mixer_settings.dart';
import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/domain/song/song_commands.dart';
import 'package:bandstand/state/generation_state.dart';
import 'package:bandstand/state/library_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Per-voice volume, pan, mute, solo and instrument (§8.2).
///
/// Edits go through the command stack like every other change to a song, so
/// the mixer is undoable and is saved with the tune.
class MixerScreen extends ConsumerWidget {
  const MixerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final song = ref.watch(songEditorProvider);
    final editor = ref.read(songEditorProvider.notifier);
    final generators = ref.watch(generatorsProvider);

    if (song == null) {
      return const Scaffold(body: Center(child: Text('No song is open.')));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text('Mixer — ${song.title}'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Clear every solo',
            onPressed: song.mixer.hasSolo
                ? () => editor.run(
                    SongCommands.setMixer(song.mixer.withoutSolos()),
                  )
                : null,
            icon: const Icon(Icons.layers_clear_outlined),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: generators.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('$error')),
        data: (pipeline) {
          final voices = <({String id, String name, bool isDrums})>[
            for (final generator in pipeline.generators)
              for (final voice in generator.voices)
                (id: voice.id, name: voice.displayName, isDrums: voice.isDrums),
          ];
          if (voices.isEmpty) {
            return const Center(
              child: Text('No generators are installed, so there is no mixer.'),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              _MasterStrip(song: song, editor: editor),
              const Divider(height: 32),
              for (final voice in voices)
                _VoiceStrip(
                  song: song,
                  editor: editor,
                  voiceId: voice.id,
                  name: voice.name,
                  isDrums: voice.isDrums,
                ),
            ],
          );
        },
      ),
    );
  }
}

class _MasterStrip extends StatelessWidget {
  const _MasterStrip({required this.song, required this.editor});

  final Song song;
  final SongEditor editor;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        SizedBox(
          width: 120,
          child: Text('Master', style: Theme.of(context).textTheme.titleMedium),
        ),
        Expanded(
          child: Slider(
            value: song.mixer.masterVolume,
            onChanged: (value) => editor.run(
              SongCommands.setMixer(song.mixer.withMasterVolume(value)),
            ),
          ),
        ),
        SizedBox(
          width: 56,
          child: Text(
            '${(song.mixer.masterVolume * 100).round()}',
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }
}

class _VoiceStrip extends StatelessWidget {
  const _VoiceStrip({
    required this.song,
    required this.editor,
    required this.voiceId,
    required this.name,
    required this.isDrums,
  });

  final Song song;
  final SongEditor editor;
  final String voiceId;
  final String name;
  final bool isDrums;

  @override
  Widget build(BuildContext context) {
    final channel = song.mixer.channelFor(voiceId);
    final audible = song.mixer.isAudible(voiceId);

    void update(ChannelSettings updated) =>
        editor.run(SongCommands.setMixer(song.mixer.withChannel(updated)));

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              SizedBox(
                width: 120,
                child: Text(
                  name,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: audible
                        ? null
                        : Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              IconButton(
                tooltip: channel.muted ? 'Unmute' : 'Mute',
                isSelected: channel.muted,
                onPressed: () =>
                    update(channel.copyWith(muted: !channel.muted)),
                icon: const Icon(Icons.volume_off_outlined),
                selectedIcon: const Icon(Icons.volume_off),
              ),
              IconButton(
                tooltip: channel.soloed ? 'Unsolo' : 'Solo',
                isSelected: channel.soloed,
                onPressed: () =>
                    update(channel.copyWith(soloed: !channel.soloed)),
                icon: const Icon(Icons.headphones_outlined),
                selectedIcon: const Icon(Icons.headphones),
              ),
              Expanded(
                child: Slider(
                  value: channel.volume,
                  onChanged: (value) => update(channel.copyWith(volume: value)),
                ),
              ),
              SizedBox(
                width: 56,
                child: Text(
                  '${(channel.volume * 100).round()}',
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
          Row(
            children: <Widget>[
              const SizedBox(width: 120),
              const Text('Pan'),
              Expanded(
                child: Slider(
                  value: channel.pan,
                  min: -1,
                  max: 1,
                  onChanged: (value) => update(channel.copyWith(pan: value)),
                ),
              ),
              SizedBox(
                width: 56,
                child: Text(
                  channel.pan.abs() < 0.02
                      ? 'C'
                      : '${channel.pan < 0 ? 'L' : 'R'}'
                            '${(channel.pan.abs() * 100).round()}',
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
          if (!isDrums)
            Row(
              children: <Widget>[
                const SizedBox(width: 120),
                const Text('Program'),
                const SizedBox(width: 12),
                Expanded(
                  child: Slider(
                    value: channel.midiProgram.toDouble(),
                    max: 127,
                    divisions: 127,
                    label: '${channel.midiProgram}',
                    onChanged: (value) =>
                        update(channel.copyWith(midiProgram: value.round())),
                  ),
                ),
                SizedBox(
                  width: 56,
                  child: Text(
                    '${channel.midiProgram}',
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
