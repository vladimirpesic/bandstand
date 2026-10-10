import 'dart:async';

import 'package:bandstand/audio/audio_engine.dart';
import 'package:bandstand/audio/playhead.dart';
import 'package:bandstand/bridge/api/audio.dart';
import 'package:bandstand/io/library/manifest.dart';
import 'package:bandstand/state/library.dart';
import 'package:bandstand/state/platform_audio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether, and how far, a track repeats when it reaches its end (ADR
/// 0012). All three are one loop region in the transport — the whole
/// track, [0, duration] — and the difference is how long the region stays.
enum TrackRepeat {
  /// Play through once, then stop.
  off,

  /// Play through once, then once more, then stop — the second pass begins
  /// at the wrap, and that is the moment the loop takes itself off.
  once,

  /// Wrap to the top for as long as the player runs.
  forever,
}

/// The isolation control at the heart of the player (ADR 0012): the
/// recordings put the bass in the left channel and the piano in the right,
/// so the practice moves are the full trio, the bass alone, or the piano
/// alone. Should a volume ever swap the convention, its labels lie — flip
/// to the other side until the manifest learns per-volume sides.
enum ChannelMode {
  /// The trio as recorded: bass and piano, both sides.
  both,

  /// The bass — the left side, on both speakers.
  left,

  /// The piano — the right side, on both speakers.
  right;

  /// The 2×2 gains, row-major by output — `[left←left, left←right,
  /// right←left, right←right]`.
  ///
  /// These mirror `MIX_BOTH`/`MIX_LEFT`/`MIX_RIGHT` in `rust/src/player.rs`:
  /// the engine takes raw gains, so the presets are stated once per language
  /// and the Rust tests hold the definition.
  List<double> get matrix => switch (this) {
    ChannelMode.both => const <double>[1, 0, 0, 1],
    ChannelMode.left => const <double>[1, 0, 1, 0],
    ChannelMode.right => const <double>[0, 1, 0, 1],
  };
}

/// What the player screen is showing and driving.
class PlayerState {
  /// Create the state.
  const PlayerState({
    this.volumeId,
    this.entryId,
    this.trackName = '',
    this.info,
    this.loading = false,
    this.loadError,
    this.playError,
    this.mix = ChannelMode.both,
    this.repeatMode = TrackRepeat.off,
    this.cycleStartMs,
    this.cycleEndMs,
    this.positionMs = 0,
    this.transport = TransportState.stopped,
  });

  /// The volume the loaded track belongs to, for re-resolution on rebuild.
  final String? volumeId;

  /// The loaded (or loading) entry's id.
  final String? entryId;

  /// The track's name as a person reads it.
  final String trackName;

  /// The decoded track, null until the decode answers (or after a failure).
  final TrackInfo? info;

  /// True while the decode is running.
  final bool loading;

  /// Why the decode failed, in words.
  final String? loadError;

  /// Why the last play could not start, in words.
  final String? playError;

  /// The isolation in force. Kept across tracks: it is a listening
  /// preference, and the engine's matrix survives a load by design
  /// ("an unload is not a mix move").
  final ChannelMode mix;

  /// The repeat in force when the track reaches its end.
  final TrackRepeat repeatMode;

  /// The cycle region's first mark, when marking has begun.
  final int? cycleStartMs;

  /// The cycle region's second mark; with [cycleStartMs] set, the loop is
  /// engaged in the engine.
  final int? cycleEndMs;

  /// The playhead in milliseconds — on the file timeline a tick *is* a
  /// millisecond (`docs/rules/transport-clock.md` §6).
  final double positionMs;

  /// What the transport is doing.
  final TransportState transport;

  /// Whether the transport is moving — what a play/pause button and the
  /// screen wakelock key off.
  bool get isPlaying => transport == TransportState.playing;

  /// Whether both cycle marks have landed and the loop is engaged.
  bool get hasCycle => cycleStartMs != null && cycleEndMs != null;

  /// Whether one mark is in and the next closes the region.
  bool get awaitingCycleEnd => cycleStartMs != null && cycleEndMs == null;

  /// The track's length in milliseconds, or null until decoded.
  ///
  /// FRB maps the Rust `u64` to [BigInt] (`durationMs`); tracks are minutes,
  /// so the int narrowing here is total in practice and is the one place it
  /// happens.
  int? get durationMs => info?.durationMs.toInt();

  /// A copy with some fields replaced.
  PlayerState copyWith({
    String? volumeId,
    String? entryId,
    String? trackName,
    TrackInfo? info,
    bool clearInfo = false,
    bool? loading,
    String? loadError,
    bool clearLoadError = false,
    String? playError,
    bool clearPlayError = false,
    ChannelMode? mix,
    TrackRepeat? repeatMode,
    int? cycleStartMs,
    bool clearCycleStart = false,
    int? cycleEndMs,
    bool clearCycleEnd = false,
    double? positionMs,
    TransportState? transport,
  }) => PlayerState(
    volumeId: volumeId ?? this.volumeId,
    entryId: entryId ?? this.entryId,
    trackName: trackName ?? this.trackName,
    info: clearInfo ? null : (info ?? this.info),
    loading: loading ?? this.loading,
    loadError: clearLoadError ? null : (loadError ?? this.loadError),
    playError: clearPlayError ? null : (playError ?? this.playError),
    mix: mix ?? this.mix,
    repeatMode: repeatMode ?? this.repeatMode,
    cycleStartMs: clearCycleStart ? null : (cycleStartMs ?? this.cycleStartMs),
    cycleEndMs: clearCycleEnd ? null : (cycleEndMs ?? this.cycleEndMs),
    positionMs: positionMs ?? this.positionMs,
    transport: transport ?? this.transport,
  );
}

/// The player FFI surface the controller drives.
///
/// The same shape as [PlatformTransport]: one seam rather than top-level
/// calls, so the controller's own logic — decode failure handling, the cycle
/// state machine, the end-of-track decision — is testable without a running
/// engine (the bridge throws until `RustLib.init()` has run).
class PlayerBridge {
  /// The real bridge, over flutter_rust_bridge.
  const PlayerBridge();

  /// Decode a file and make it the thing the transport plays.
  Future<TrackInfo> loadTrack(String path) => playerLoad(path: path);

  /// Set the channel-gain matrix; the gains ramp, so a move never clicks.
  Future<void> setChannelMix({
    required double leftFromLeft,
    required double leftFromRight,
    required double rightFromLeft,
    required double rightFromRight,
  }) => playerSetChannelMix(
    leftFromLeft: leftFromLeft,
    leftFromRight: leftFromRight,
    rightFromLeft: rightFromLeft,
    rightFromRight: rightFromRight,
  );

  /// Move the playhead; on the file timeline the tick is the millisecond.
  Future<void> seekMs(double milliseconds) => transportSeek(tick: milliseconds);

  /// Set — or, with `enabled: false`, take off — the loop region.
  Future<void> setLoopRegion(int startMs, int endMs, {required bool enabled}) =>
      transportSetLoop(
        startTick: BigInt.from(startMs),
        endTick: BigInt.from(endMs),
        enabled: enabled,
      );

  /// Read the playhead. Cheap enough to call for every position display.
  TransportPosition readPosition() => transportPosition();
}

/// One track under the transport: decode, play through the platform's focus
/// handshake, isolate channels, cycle a region, and decide when the track is
/// over — the one thing the engine deliberately leaves to the caller
/// (`rust/src/player.rs` reads silence past the last frame rather than
/// garbage).
class PlayerController extends Notifier<PlayerState> {
  /// Create the controller, optionally over a stand-in bridge.
  PlayerController({PlayerBridge? bridge})
    : _bridge = bridge ?? const PlayerBridge();

  /// The player surface this controller drives. Replaced in tests.
  final PlayerBridge _bridge;

  /// How often the position display refreshes.
  ///
  /// [Playhead.resolve] extrapolates to the instant it is asked about, so
  /// what moves between polls is only the sub-cadence fraction of a second.
  static const Duration positionCadence = Duration(milliseconds: 200);

  /// The shortest cycle the UI will engage.
  ///
  /// The transport suspends wrapping for a degenerate loop span — a silent
  /// non-feature — so a double-tap on "mark" declines to build a region
  /// rather than appearing to loop nothing.
  static const int minimumCycleMs = 1000;

  Timer? _positionTimer;

  /// The entry the decode currently in flight is for; a late answer for
  /// anything else is dropped.
  String? _openingFor;

  /// Guards the end-of-track stop against re-entering itself through its
  /// own position refresh.
  bool _stoppingAtEnd = false;

  @override
  PlayerState build() {
    _positionTimer = Timer.periodic(positionCadence, (_) => refreshPosition());
    ref.onDispose(() {
      _positionTimer?.cancel();
      _positionTimer = null;
    });
    return const PlayerState();
  }

  /// Make [entry] the loaded track: decode it, park the transport at the
  /// top, and reset the cycle to nothing.
  ///
  /// Idempotent per entry — re-entering the screen for the track already
  /// loaded is a no-op, while a retry after a failure (where `info` is null)
  /// re-runs the decode. The channel mix is deliberately *not* reset.
  Future<void> open(LibraryVolume volume, LibraryEntry entry) async {
    if (state.entryId == entry.id && state.info != null) {
      return;
    }
    state = state.copyWith(
      volumeId: volume.id,
      entryId: entry.id,
      trackName: entry.displayName,
      clearInfo: true,
      loading: true,
      clearLoadError: true,
      clearPlayError: true,
      clearCycleStart: true,
      clearCycleEnd: true,
      repeatMode: TrackRepeat.off,
      positionMs: 0,
      transport: TransportState.stopped,
    );
    // Loading stops the transport at the top of the new track and clears any
    // loop left from the previous one (the FFI's own contract), so the Dart
    // state above is not a hope but a mirror.
    final token = entry.id;
    _openingFor = token;
    try {
      final path = ref
          .read(libraryProvider.notifier)
          .localFileFor(volume, entry)
          .path;
      final info = await _bridge.loadTrack(path);
      if (_openingFor != token) {
        return; // A newer open superseded this one.
      }
      _openingFor = null;
      state = state.copyWith(info: info, loading: false);
    } catch (error) {
      if (_openingFor != token) {
        return;
      }
      _openingFor = null;
      state = state.copyWith(
        loading: false,
        loadError: error is String ? error : error.toString(),
      );
    }
  }

  /// Start playing — through the focus handshake, which is the only way
  /// playback starts anywhere in the app (`docs/rules/android-audio.md` §2):
  /// the output stream opens first, then the platform grants or refuses
  /// focus, and only then does the transport move.
  ///
  /// The screen does not auto-play on entry: a player read from a stand
  /// gets its isolation and cycle set *before* it makes a sound, not after.
  Future<void> play() async {
    if (state.info == null) {
      return;
    }
    final engine = ref.read(audioEngineProvider.notifier);
    if (!engine.state.isRunning && !engine.state.busy) {
      await engine.start();
    }
    // `busy` here means an open is already in flight: the transport runs
    // without a stream until it lands, so press on rather than refuse.
    if (!engine.state.isRunning && !engine.state.busy) {
      state = state.copyWith(
        playError:
            engine.state.errorMessage ?? 'the output device would not open',
      );
      return;
    }
    final audio = ref.read(platformAudioProvider.notifier);
    if (!await audio.play(title: state.trackName)) {
      state = state.copyWith(
        playError: 'the system would not give up the audio; nothing played',
      );
      return;
    }
    state = state.copyWith(clearPlayError: true);
  }

  /// Pause, keeping focus — "hold on", not "finished".
  Future<void> pause() async {
    await ref.read(platformAudioProvider.notifier).pause();
  }

  /// Stop, rewinding to the top and giving the platform its focus back.
  Future<void> stop() async {
    await ref.read(platformAudioProvider.notifier).stop();
  }

  /// Move the playhead, in milliseconds, clamped to the track.
  Future<void> seekTo(double milliseconds) async {
    final duration = state.durationMs;
    if (duration == null) {
      return;
    }
    final clamped = milliseconds < 0
        ? 0.0
        : (milliseconds > duration ? duration.toDouble() : milliseconds);
    await _bridge.seekMs(clamped);
    state = state.copyWith(positionMs: clamped);
  }

  /// Set the isolation. The engine ramps the matrix, so the move is
  /// click-free whatever the transport is doing.
  Future<void> setMix(ChannelMode mode) async {
    state = state.copyWith(mix: mode);
    final gains = mode.matrix;
    await _bridge.setChannelMix(
      leftFromLeft: gains[0],
      leftFromRight: gains[1],
      rightFromLeft: gains[2],
      rightFromRight: gains[3],
    );
  }

  /// Walk the repeat modes — off, once, forever, back to off. Mutually
  /// exclusive with a marked loop: the transport carries one loop region,
  /// so whichever was set last is the one in force. Both repeating modes
  /// are the same whole-track region; "once" takes it off at the wrap
  /// ([_endRepeatOnceAfterWrap]), "forever" never does.
  Future<void> cycleRepeatMode() async {
    final duration = state.durationMs;
    if (duration == null) {
      return;
    }
    final next = switch (state.repeatMode) {
      TrackRepeat.off => TrackRepeat.once,
      TrackRepeat.once => TrackRepeat.forever,
      TrackRepeat.forever => TrackRepeat.off,
    };
    state = state.copyWith(
      repeatMode: next,
      clearCycleStart: true,
      clearCycleEnd: true,
    );
    await _bridge.setLoopRegion(0, duration, enabled: next != TrackRepeat.off);
  }

  /// Drop a loop mark: the first call opens a region at the playhead, the
  /// second closes it and the loop engages — in either order, the earlier
  /// mark is the start. A span shorter than [minimumCycleMs] leaves the
  /// first mark standing rather than engaging. Closing a finished region
  /// begins a new one, and beginning one takes the old loop off first.
  Future<void> markCyclePoint() async {
    final duration = state.durationMs;
    if (duration == null) {
      return;
    }
    final position = state.positionMs.round();
    final start = state.cycleStartMs;
    final end = state.cycleEndMs;
    if (start == null || end != null) {
      state = state.copyWith(
        repeatMode: TrackRepeat.off,
        cycleStartMs: position,
        clearCycleEnd: true,
      );
      await _bridge.setLoopRegion(0, duration, enabled: false);
      return;
    }
    if ((position - start).abs() < minimumCycleMs) {
      return; // Too short to be a loop; the start mark stands.
    }
    final from = start < position ? start : position;
    final to = start < position ? position : start;
    state = state.copyWith(
      repeatMode: TrackRepeat.off,
      cycleStartMs: from,
      cycleEndMs: to,
    );
    await _bridge.setLoopRegion(from, to, enabled: true);
  }

  /// Take the loop off — marks and repeat both.
  Future<void> clearCycle() async {
    final duration = state.durationMs;
    if (duration == null) {
      return;
    }
    state = state.copyWith(
      repeatMode: TrackRepeat.off,
      clearCycleStart: true,
      clearCycleEnd: true,
    );
    await _bridge.setLoopRegion(0, duration, enabled: false);
  }

  /// Read the playhead, resolve it to now ([Playhead]), and act on the one
  /// thing the engine will not decide for itself: the end of the track.
  ///
  /// Past the last decoded frame the engine plays silence by design — the
  /// playhead runs on precisely so this watcher can see it pass the
  /// duration, stop (which rewinds to the top) and give the platform its
  /// focus back.
  Future<void> refreshPosition() async {
    final TransportPosition published;
    try {
      published = _bridge.readPosition();
    } catch (_) {
      // A throwing position read would otherwise repeat as an unhandled
      // error every cadence. Stop polling; the screen keeps the last
      // position, and the transport controls still work.
      _positionTimer?.cancel();
      _positionTimer = null;
      return;
    }
    final reading = Playhead.resolve(published);
    final resolvedTick = (reading.tick < 0 ? 0 : reading.tick).toDouble();
    final previousTick = state.positionMs;
    state = state.copyWith(positionMs: resolvedTick, transport: reading.state);
    await _endRepeatOnceAfterWrap(previousTick, resolvedTick, reading.state);
    await _stopIfPastEnd();
  }

  /// How close to the end a reading still counts as "at the end" — the
  /// window in which a whole-track loop can wrap.
  static const double repeatWrapWindowMs = 1500;

  /// "Repeat once" ends itself: with a whole-track loop in force, the wrap
  /// — the playhead falling from the end back to the top while playing —
  /// is the moment the second pass begins. The loop region comes off right
  /// there, so this pass is the last, and its end stops like any other.
  Future<void> _endRepeatOnceAfterWrap(
    double previousMs,
    double currentMs,
    TransportState transport,
  ) async {
    final duration = state.durationMs;
    if (duration == null ||
        state.repeatMode != TrackRepeat.once ||
        transport != TransportState.playing ||
        previousMs < duration - repeatWrapWindowMs ||
        currentMs > previousMs - repeatWrapWindowMs) {
      return;
    }
    state = state.copyWith(repeatMode: TrackRepeat.off);
    await _bridge.setLoopRegion(0, duration, enabled: false);
  }

  Future<void> _stopIfPastEnd() async {
    final duration = state.durationMs;
    if (_stoppingAtEnd || duration == null || duration <= 0) {
      return;
    }
    if (state.transport != TransportState.playing ||
        state.positionMs < duration) {
      return;
    }
    _stoppingAtEnd = true;
    try {
      await stop();
    } finally {
      _stoppingAtEnd = false;
    }
  }

  /// Milliseconds the way a transport reads them: `m:ss`.
  static String describeClock(int milliseconds) {
    final seconds = (milliseconds / 1000).round();
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }
}

/// The player.
final playerProvider = NotifierProvider<PlayerController, PlayerState>(
  PlayerController.new,
);
