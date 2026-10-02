import 'package:bandstand/audio/sequence_builder.dart';
import 'package:bandstand/bridge/api/audio.dart';
import 'package:bandstand/domain/generation/song_generator.dart';
import 'package:bandstand/domain/song/mixer_settings.dart';
import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/io/generation_assets.dart';
import 'package:bandstand/state/library_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The generators this build ships with (§6.5).
final generatorsProvider = FutureProvider<SongGenerator>((ref) {
  return loadGenerators();
});

/// What generating and playing a song has produced.
class SongPlaybackState {
  /// Create a state.
  const SongPlaybackState({
    this.songId,
    this.noteCount = 0,
    this.voiceCount = 0,
    this.generationMs = 0,
    this.problems = const <String>[],
    this.seed = 0,
    this.busy = false,
    this.errorMessage,
  });

  /// Which song was generated.
  final String? songId;

  /// How many notes came out.
  final int noteCount;

  /// How many voices played.
  final int voiceCount;

  /// How long generating took, in milliseconds — the §3 budget, visible.
  final double generationMs;

  /// Anything the pipeline could not do.
  final List<String> problems;

  /// The seed the take was generated with; changing it is "reroll" (§6.2).
  final int seed;

  /// True while generating.
  final bool busy;

  /// The last failure, or null.
  final String? errorMessage;

  /// Whether there is something loaded to play.
  bool get hasSequence => noteCount > 0;

  /// A copy with some fields replaced.
  SongPlaybackState copyWith({
    String? songId,
    int? noteCount,
    int? voiceCount,
    double? generationMs,
    List<String>? problems,
    int? seed,
    bool? busy,
    String? errorMessage,
    bool clearError = false,
  }) => SongPlaybackState(
    songId: songId ?? this.songId,
    noteCount: noteCount ?? this.noteCount,
    voiceCount: voiceCount ?? this.voiceCount,
    generationMs: generationMs ?? this.generationMs,
    problems: problems ?? this.problems,
    seed: seed ?? this.seed,
    busy: busy ?? this.busy,
    errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
  );
}

/// Generates a song and hands it to the audio engine.
///
/// The whole §6.1 pipeline behind one call: flatten, generate, post-process,
/// assemble, convert, hand over. §3 gives it 100 ms, and [generationMs] on the
/// state says what it actually took.
class SongPlaybackController extends Notifier<SongPlaybackState> {
  @override
  SongPlaybackState build() {
    _disposed = false;
    ref.onDispose(() {
      _disposed = true;
      _inFlight = null;
    });
    return const SongPlaybackState();
  }

  /// Whether the provider has gone since the work in flight started.
  bool _disposed = false;

  /// The tail of the generation queue: at most one [generateAndLoad] runs at a
  /// time, and calls made while one is in flight wait their turn. Without
  /// this, two overlapping calls interleave their `await`s and the engine can
  /// end up playing song A while the state claims song B.
  Future<void>? _inFlight;

  /// Generate `song` and load it into the engine.
  Future<void> generateAndLoad(Song song, {int? seed}) {
    final run = (_inFlight ?? Future<void>.value()).then(
      (_) => _generateAndLoad(song, seed: seed),
    );
    _inFlight = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<void> _generateAndLoad(Song song, {int? seed}) async {
    // Guarded at the top and again after each await. A provider can be
    // disposed while a generation is in flight — closing the screen mid-edit
    // does exactly that — and this whole body runs off the back of the queue
    // in `generateAndLoad`, so even the first line can land after the
    // provider has gone. Writing `state` on a disposed notifier throws, and
    // for the fire-and-forget callers that reach here it throws into nothing.
    // `audio_engine.dart` guards its polling the same way.
    if (_disposed) {
      return;
    }
    state = state.copyWith(busy: true, clearError: true);
    try {
      final generators = await ref.read(generatorsProvider.future);
      final watch = Stopwatch()..start();
      final generated = generators.generate(song, seed: seed ?? state.seed);
      final sequence = generated.toSequence(song.mixer, tempoBpm: song.tempo);
      watch.stop();

      await transportStop();
      await loadSequence(
        events: sequence.events,
        ppq: sequence.ppq,
        lengthTicks: sequence.lengthTicks,
        tempoMarkers: sequence.tempoMarkers,
      );

      if (_disposed) {
        return;
      }
      state = state.copyWith(
        songId: song.id,
        noteCount: generated.noteCount,
        voiceCount: generated.voices.length,
        generationMs: watch.elapsedMicroseconds / 1000,
        problems: generated.problems,
        seed: seed ?? state.seed,
        busy: false,
      );
    } catch (error) {
      if (_disposed) {
        return;
      }
      state = state.copyWith(
        busy: false,
        errorMessage: error is String ? error : error.toString(),
      );
    }
  }

  /// Generate the same song again with a new seed — the "reroll" of §6.2.
  Future<void> reroll(Song song) => generateAndLoad(song, seed: state.seed + 1);

  /// Apply the mixer without regenerating anything.
  ///
  /// [channels] is the voiceId→MIDI-channel map of the generated sequence
  /// (each `GeneratedVoice.channel`), so every voice is mixed where the
  /// generator actually placed it — re-deriving channels by list index
  /// diverges as soon as a voice prefers a channel or the drums skip one.
  Future<void> applyMixer(
    MixerSettings mixer,
    Map<String, int> channels,
  ) async {
    for (final entry in channels.entries) {
      final settings = mixer.channelFor(entry.key);
      await setChannelMix(
        channel: entry.value,
        volume: mixer.effectiveVolume(entry.key),
        pan: settings.pan,
        muted: !mixer.isAudible(entry.key),
      );
    }
    await setMasterGain(gain: mixer.masterVolume);
  }

  /// Clear the displayed error.
  void dismissError() => state = state.copyWith(clearError: true);
}

/// Generates a song and hands it to the audio engine.
final songPlaybackProvider =
    NotifierProvider<SongPlaybackController, SongPlaybackState>(
      SongPlaybackController.new,
    );

/// Regenerate whenever the open song changes, so pressing play always plays
/// what is on the screen.
///
/// Deliberately *not* automatic on every keystroke: §3's 100 ms budget is for a
/// regeneration, not for one per character. The editor calls this when an edit
/// settles.
final autoRegenerateProvider = Provider<Future<void> Function()>((ref) {
  return () async {
    final song = ref.read(songEditorProvider);
    if (song == null) {
      return;
    }
    await ref.read(songPlaybackProvider.notifier).generateAndLoad(song);
  };
});
