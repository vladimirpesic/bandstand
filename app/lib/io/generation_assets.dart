import 'package:bandstand/domain/generation/bass/bass_corpus_codec.dart';
import 'package:bandstand/domain/generation/bass/walking_bass_generator.dart';
import 'package:bandstand/domain/generation/comping/comping_cells.dart';
import 'package:bandstand/domain/generation/comping/comping_generator.dart';
import 'package:bandstand/domain/generation/drum_generator.dart';
import 'package:bandstand/domain/generation/drum_patterns.dart';
import 'package:bandstand/domain/generation/ensemble_generator.dart';
import 'package:bandstand/domain/generation/music_generator.dart';
import 'package:bandstand/domain/generation/song_generator.dart';
import 'package:flutter/services.dart' show rootBundle;

/// Where the drum patterns are bundled.
const String drumPatternsAssetPath = 'assets/drum_patterns.json';

/// Where the walking-bass corpus is bundled (ADR 0008).
const String bassCorpusAssetPath = 'assets/bass_corpus.json';

/// Where the comping cells are bundled.
const String compingCellsAssetPath = 'assets/comping_cells.json';

/// Load the generators this build ships with.
///
/// The only code that knows the patterns are Flutter assets; the domain takes
/// their contents, never their paths (ADR 0006).
///
/// Throws [FormatException] if a data file is malformed — a corrupt pattern
/// table or corpus means the band would be wrong rather than absent, and
/// failing at startup is better than failing on stage.
Future<SongGenerator> loadGenerators() async {
  final patterns = await rootBundle.loadString(drumPatternsAssetPath);
  final corpus = await rootBundle.loadString(bassCorpusAssetPath);
  final cells = await rootBundle.loadString(compingCellsAssetPath);
  final drums = DrumGenerator(DrumPatternSet.fromJson(patterns));
  final bass = WalkingBassGenerator(BassCorpusCodec.decode(corpus));
  final piano = CompingGenerator(CompingCellSet.fromJson(cells));
  return SongGenerator(<MusicGenerator>[
    // Each instrument on its own, so a part can be heard in isolation — which
    // is how a generator is judged (§10 M6, §10 M7) and how it is debugged.
    drums,
    bass,
    piano,
    // And the bands, which is what a song normally plays.
    EnsembleGenerator(
      id: swingRhythmId,
      displayName: 'Swing trio',
      members: <MusicGenerator>[drums, bass, piano],
    ),
    EnsembleGenerator(
      id: rhythmSectionRhythmId,
      displayName: 'Bass and drums',
      members: <MusicGenerator>[drums, bass],
    ),
  ]);
}

/// The band a new song plays: drums, walking bass and comping piano.
const String swingRhythmId = 'swing';

/// The same without the piano, for practising with a rhythm section only.
const String rhythmSectionRhythmId = 'rhythm-section';
