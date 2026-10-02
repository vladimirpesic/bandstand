import 'dart:io';
import 'dart:typed_data';

import 'package:bandstand/audio/sequence_builder.dart';
import 'package:bandstand/audio/soundbank_library.dart';
import 'package:bandstand/bridge/api/audio.dart';
import 'package:bandstand/domain/song/ticks.dart';
import 'package:bandstand/io/midi/midi_file.dart';
import 'package:bandstand/state/library_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The soundbanks this machine has.
final soundbanksProvider = FutureProvider<List<SoundbankFile>>((ref) async {
  final library = await ref.watch(songLibraryProvider.future);
  return SoundbankLibrary.scan(library.soundbanksDirectory);
});

/// What the playback panel is showing.
class PlaybackState {
  /// Create a state.
  const PlaybackState({
    this.bank,
    this.sequenceName,
    this.eventCount = 0,
    this.lengthTicks = 0,
    this.ppq = kTicksPerQuarter,
    this.tempoBpm = 120,
    this.busy = false,
    this.errorMessage,
  });

  /// The bank loaded into the engine, if any.
  final SoundBankInfo? bank;

  /// What the loaded sequence is called.
  final String? sequenceName;

  /// How many events it holds.
  final int eventCount;

  /// How long it lasts, in ticks.
  final int lengthTicks;

  /// Its tick resolution.
  final int ppq;

  /// The tempo it starts at.
  final double tempoBpm;

  /// True while a load is in flight.
  final bool busy;

  /// The last failure, or null.
  final String? errorMessage;

  /// Whether there is something to play.
  bool get canPlay => bank != null && eventCount > 0;

  /// How long the sequence lasts, in seconds at its starting tempo.
  double get durationSeconds =>
      ppq == 0 || tempoBpm <= 0 ? 0 : lengthTicks / ppq * 60 / tempoBpm;

  /// A copy with some fields replaced.
  PlaybackState copyWith({
    SoundBankInfo? bank,
    bool clearBank = false,
    String? sequenceName,
    bool clearSequence = false,
    int? eventCount,
    int? lengthTicks,
    int? ppq,
    double? tempoBpm,
    bool? busy,
    String? errorMessage,
    bool clearError = false,
  }) => PlaybackState(
    bank: clearBank ? null : (bank ?? this.bank),
    sequenceName: clearSequence ? null : (sequenceName ?? this.sequenceName),
    eventCount: clearSequence ? 0 : (eventCount ?? this.eventCount),
    lengthTicks: clearSequence ? 0 : (lengthTicks ?? this.lengthTicks),
    ppq: ppq ?? this.ppq,
    tempoBpm: tempoBpm ?? this.tempoBpm,
    busy: busy ?? this.busy,
    errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
  );
}

/// Loads soundbanks and sequences into the audio engine.
class PlaybackController extends Notifier<PlaybackState> {
  @override
  PlaybackState build() => const PlaybackState();

  /// Load a soundbank into the engine (§7.2).
  Future<void> loadBank(String path) async {
    state = state.copyWith(busy: true, clearError: true);
    try {
      final info = await loadSoundbank(path: path);
      state = state.copyWith(bank: info, busy: false);
    } catch (error) {
      state = state.copyWith(
        busy: false,
        clearBank: true,
        errorMessage: error is String ? error : error.toString(),
      );
    }
  }

  /// Unload the bank, so nothing plays.
  Future<void> unloadBank() async {
    await unloadSoundbank();
    state = state.copyWith(clearBank: true);
  }

  /// Read a Standard MIDI File and hand it to the engine.
  Future<void> loadMidiFile(File file) async {
    state = state.copyWith(busy: true, clearError: true);
    try {
      final bytes = await file.readAsBytes();
      await loadMidiBytes(bytes, name: file.uri.pathSegments.last);
    } catch (error) {
      state = state.copyWith(
        busy: false,
        clearSequence: true,
        errorMessage: error is String ? error : error.toString(),
      );
    }
  }

  /// Hand the engine a sequence read from MIDI bytes.
  Future<void> loadMidiBytes(Uint8List bytes, {required String name}) async {
    final parsed = MidiFileReader.read(bytes);
    final built = MidiSequenceBuilder.fromMidiFile(parsed);
    await transportStop();
    await loadSequence(
      events: built.events,
      ppq: built.ppq,
      lengthTicks: built.lengthTicks,
      tempoMarkers: built.tempoMarkers,
    );
    state = state.copyWith(
      sequenceName: name,
      eventCount: built.length,
      // A file claiming a length past what an int holds is broken, not
      // wrap-around: clamp rather than let toInt() silently truncate.
      lengthTicks: built.lengthTicks.isValidInt
          ? built.lengthTicks.toInt()
          : (1 << 63) - 1,
      ppq: built.ppq,
      tempoBpm: built.initialTempoBpm,
      busy: false,
    );
  }

  /// Forget the sequence.
  Future<void> clear() async {
    await transportStop();
    await clearSequence();
    state = state.copyWith(clearSequence: true);
  }

  /// Clear the displayed error.
  void dismissError() {
    state = state.copyWith(clearError: true);
  }
}

/// Loads soundbanks and sequences into the audio engine.
final playbackProvider = NotifierProvider<PlaybackController, PlaybackState>(
  PlaybackController.new,
);
