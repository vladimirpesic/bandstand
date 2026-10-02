import 'package:bandstand/bridge/api/audio.dart';
import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/io/exporters/export_service.dart';
import 'package:bandstand/state/generation_state.dart';
import 'package:bandstand/state/library_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What Bandstand can write out (§5.3).
enum ExportFormat {
  /// The performance, as a Standard MIDI File.
  midi('MIDI', 'What the band played, for a DAW'),

  /// The performance, as audio.
  audio('Audio (WAV)', 'What the band sounded like'),

  /// The written chart, for notation software.
  musicXml('MusicXML', 'The chart as written, for notation software'),

  /// The written chart, for a music stand or a printer.
  pdf('PDF', 'The chart as it is drawn, for printing');

  const ExportFormat(this.displayName, this.description);

  /// What the menu calls it.
  final String displayName;

  /// The line under it, which says what survives the export.
  final String description;
}

/// How an export went.
class ExportState {
  /// Create a state.
  const ExportState({this.busy = false, this.lastPath, this.errorMessage});

  /// True while writing.
  final bool busy;

  /// Where the last export went. An export the user cannot find has not
  /// happened (`docs/rules/exporters.md` §6).
  final String? lastPath;

  /// Why the last export failed, or null.
  final String? errorMessage;
}

/// Writes songs out.
///
/// Rules: `docs/rules/exporters.md`. MIDI and audio export what Bandstand
/// **played**, so they generate first; MusicXML exports what the player
/// **wrote** and does not.
class ExportController extends Notifier<ExportState> {
  @override
  ExportState build() => const ExportState();

  /// Write `song` in `format`.
  Future<void> export(Song song, ExportFormat format) async {
    state = const ExportState(busy: true);
    try {
      final library = await ref.read(songLibraryProvider.future);
      final service = ExportService(library);

      final path = switch (format) {
        ExportFormat.musicXml => (await service.exportMusicXml(song)).file.path,
        ExportFormat.pdf => (await service.exportPdf(song)).file.path,
        ExportFormat.midi => await _exportMidi(service, song),
        ExportFormat.audio => await _exportAudio(service, song),
      };
      state = ExportState(lastPath: path);
    } catch (error) {
      state = ExportState(errorMessage: error.toString());
    }
  }

  Future<String> _exportMidi(ExportService service, Song song) async {
    final generators = await ref.read(generatorsProvider.future);
    final generated = generators.generate(
      song,
      seed: ref.read(songPlaybackProvider).seed,
    );
    final result = await service.exportMidi(song, generated);
    return result.file.path;
  }

  /// Render through the engine, so what is exported is what was heard (§3).
  ///
  /// The sequence has to be loaded first: the offline renderer bounces
  /// whatever the transport is holding, which is the same synth and the same
  /// notes playback uses.
  Future<String> _exportAudio(ExportService service, Song song) async {
    await ref.read(songPlaybackProvider.notifier).generateAndLoad(song);
    final playback = ref.read(songPlaybackProvider);
    if (playback.errorMessage != null || playback.songId != song.id) {
      // Generation failed — or was superseded by a newer one — and the engine
      // still holds whatever sequence it had, possibly another song's.
      // Bouncing that as this take would export the wrong music, so refuse
      // and let the export's error state say why.
      throw StateError(
        playback.errorMessage ?? 'generation did not produce this song',
      );
    }
    final destination = await service.audioDestination(song);
    final result = await renderOffline(
      path: destination.path,
      sampleRate: 48000,
    );
    if (result.frames == BigInt.zero) {
      throw StateError('the render produced no audio');
    }
    return destination.path;
  }
}

/// The exporter.
final exportProvider = NotifierProvider<ExportController, ExportState>(
  ExportController.new,
);
