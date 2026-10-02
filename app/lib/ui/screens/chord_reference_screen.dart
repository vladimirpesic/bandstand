import 'package:bandstand/domain/harmony/diagrams/chord_diagram.dart';
import 'package:bandstand/domain/harmony/diagrams/chord_diagram_library.dart';
import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/domain/song/song_chord_sequence.dart';
import 'package:bandstand/io/harmony_assets.dart';
import 'package:bandstand/render/chord_diagram_painter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Everything the harmony core knows about the chords in a tune (§9, M8).
///
/// Three things a player looks *down* at while working a tune out: how to play
/// each chord, what to play over it, and what the chord is in the key. None of
/// them belongs on the stand — the chart is what goes there — so this is its
/// own screen and is sized for reading at arm's length.
class ChordReferenceScreen extends ConsumerStatefulWidget {
  /// Create the screen for a song.
  const ChordReferenceScreen({required this.song, super.key});

  /// The tune.
  final Song song;

  @override
  ConsumerState<ChordReferenceScreen> createState() =>
      _ChordReferenceScreenState();
}

class _ChordReferenceScreenState extends ConsumerState<ChordReferenceScreen> {
  String _instrument = 'guitar';
  bool _nashville = false;

  /// The distinct chords of the tune, in the order they are first played.
  ///
  /// A tune has thirty chords and six distinct ones; showing the thirty would
  /// be showing the same diagram five times.
  List<ExtChordSymbol> get _chords {
    final seen = <String>{};
    final chords = <ExtChordSymbol>[];
    for (final event in SongChordSequence.of(widget.song).chords) {
      if (event.chord.isNoChord) {
        continue;
      }
      if (seen.add(event.chord.format())) {
        chords.add(event.chord);
      }
    }
    return chords;
  }

  @override
  Widget build(BuildContext context) {
    final diagrams = ref.watch(chordDiagramsProvider);
    final chords = _chords;

    return Scaffold(
      appBar: AppBar(
        title: Text('Chords — ${widget.song.title}'),
        actions: <Widget>[
          Row(
            children: <Widget>[
              const Text('Numbers'),
              Switch(
                value: _nashville,
                onChanged: (on) => setState(() => _nashville = on),
              ),
            ],
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: switch (diagrams) {
        AsyncData(:final value) => _Body(
          library: value,
          chords: chords,
          song: widget.song,
          instrument: _instrument,
          nashville: _nashville,
          onInstrument: (id) => setState(() => _instrument = id),
        ),
        AsyncError(:final error) => Center(
          child: Text('The chord shapes did not load: $error'),
        ),
        _ => const Center(child: Text('Loading…')),
      },
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.library,
    required this.chords,
    required this.song,
    required this.instrument,
    required this.nashville,
    required this.onInstrument,
  });

  final ChordDiagramLibrary library;
  final List<ExtChordSymbol> chords;
  final Song song;
  final String instrument;
  final bool nashville;
  final ValueChanged<String> onInstrument;

  @override
  Widget build(BuildContext context) {
    if (chords.isEmpty) {
      return const Center(child: Text('This chart has no chords yet.'));
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        SegmentedButton<String>(
          segments: <ButtonSegment<String>>[
            for (final entry in library.instruments)
              ButtonSegment<String>(
                value: entry.id,
                label: Text(entry.displayName),
              ),
          ],
          selected: <String>{instrument},
          onSelectionChanged: (selection) => onInstrument(selection.first),
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 24,
          runSpacing: 24,
          children: <Widget>[
            for (final chord in chords)
              _ChordCard(
                chord: chord,
                shape: library.shapeFor(instrument, chord.plain),
                song: song,
                nashville: nashville,
              ),
          ],
        ),
      ],
    );
  }
}

class _ChordCard extends StatelessWidget {
  const _ChordCard({
    required this.chord,
    required this.shape,
    required this.song,
    required this.nashville,
  });

  final ExtChordSymbol chord;
  final ChordShape? shape;
  final Song song;
  final bool nashville;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = nashville
        ? Nashville.format(chord.plain, song.key)
        : chord.format();
    final outside = !Nashville.isDiatonic(chord.plain, song.key);
    final scales = Harmony.scales.fitting(chord.type).take(3).toList();
    final drawing = shape;

    return SizedBox(
      width: 190,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Text(label, style: theme.textTheme.titleMedium),
                  if (outside) ...<Widget>[
                    const SizedBox(width: 6),
                    // The chords worth looking at twice.
                    Icon(
                      Icons.star_outline,
                      size: 14,
                      color: theme.colorScheme.tertiary,
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              Center(
                child: drawing == null
                    ? SizedBox(
                        height: 120,
                        child: Center(
                          child: Text(
                            'No shape for this chord',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      )
                    : ChordDiagramView(shape: drawing),
              ),
              const SizedBox(height: 8),
              Text(
                'Play over it',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              for (final scale in scales)
                Text(scale.aliases.first, style: theme.textTheme.bodySmall),
              if (scales.isEmpty) Text('—', style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}
