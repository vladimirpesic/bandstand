import 'dart:async';
import 'dart:io';

import 'package:bandstand/audio/audio_engine.dart';
import 'package:bandstand/bridge/api/audio.dart';
import 'package:bandstand/io/library/manifest.dart';
import 'package:bandstand/state/library.dart';
import 'package:bandstand/state/platform_audio.dart';
import 'package:bandstand/state/player.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The player behind its seams: decode lifecycle, the focus handshake before
/// any transport move, the cycle state machine, and the end-of-track stop —
/// none of which needs a running engine (the bridge throws until
/// `RustLib.init()` has run, which is why [PlayerBridge] exists).

/// A programmable [PlayerBridge]: answers what the test arranges, records
/// every call the controller made.
class _FakePlayerBridge extends PlayerBridge {
  /// Paths the controller asked to decode, in order.
  final List<String> loadPaths = <String>[];

  /// Channel-gain matrices pushed, in order.
  final List<List<double>> mixes = <List<double>>[];

  /// Seeks pushed, in milliseconds.
  final List<double> seeks = <double>[];

  /// Loop regions pushed, as `(start, end, enabled)`.
  final List<(int, int, bool)> loops = <(int, int, bool)>[];

  /// When set, the next load waits on it before answering — the seam for a
  /// superseded open.
  Completer<TrackInfo>? gate;

  /// Set to make the next load throw (once).
  Object? loadError;

  /// What `readPosition` says; `null` host/read distance so [Playhead.resolve]
  /// extrapolates nothing.
  TransportPosition position = _published(0, TransportState.stopped);

  /// Set to make `readPosition` throw.
  Object? positionError;

  @override
  Future<TrackInfo> loadTrack(String path) async {
    loadPaths.add(path);
    final pending = gate;
    if (pending != null) {
      gate = null;
      await pending.future;
    }
    final error = loadError;
    if (error != null) {
      loadError = null;
      throw error;
    }
    return _theTrack;
  }

  @override
  Future<void> setChannelMix({
    required double leftFromLeft,
    required double leftFromRight,
    required double rightFromLeft,
    required double rightFromRight,
  }) async {
    mixes.add(<double>[
      leftFromLeft,
      leftFromRight,
      rightFromLeft,
      rightFromRight,
    ]);
  }

  @override
  Future<void> seekMs(double milliseconds) async => seeks.add(milliseconds);

  @override
  Future<void> setLoopRegion(
    int startMs,
    int endMs, {
    required bool enabled,
  }) async => loops.add((startMs, endMs, enabled));

  @override
  TransportPosition readPosition() {
    final error = positionError;
    if (error != null) {
      throw error;
    }
    return position;
  }
}

/// The one track the fake bridge decodes: thirty seconds, like a ii-V lick
/// played far too slowly.
final TrackInfo _theTrack = TrackInfo(
  durationMs: BigInt.from(30000),
  sampleRate: 48000,
);

TransportPosition _published(double tick, TransportState state) =>
    TransportPosition(
      tick: tick,
      hostTimeNs: BigInt.zero,
      readAtNs: BigInt.zero,
      state: state,
      loopGeneration: 0,
      ticksPerNanosecond: 1e-6,
      bpm: 120,
      ppq: 480,
    );

/// The engine, already happy to open: the player's own contract is the focus
/// handshake, and that is what these tests watch — not the stream itself.
class _EngineBridge extends AudioEngineBridge {
  /// Requests the controller made to open the stream.
  final List<AudioStreamRequest> startCalls = <AudioStreamRequest>[];

  /// Set to make `start` throw (every time, until cleared).
  Object? startError;

  @override
  Future<AudioStreamStatus> start({required AudioStreamRequest request}) async {
    startCalls.add(request);
    final error = startError;
    if (error != null) {
      throw error;
    }
    return AudioStreamStatus(
      deviceName: 'fake',
      sampleRate: 48000,
      channels: 2,
      sampleFormat: 'f32',
      errorCount: BigInt.zero,
      blockCount: BigInt.zero,
      frameCount: BigInt.zero,
    );
  }

  @override
  Future<void> stop() async {}

  @override
  Future<AudioStreamStatus?> status() async => null;

  @override
  Future<void> setTestTone({
    required bool enabled,
    required double frequencyHz,
    required double amplitude,
  }) async {}
}

/// The platform binding as a knob: focus granted or refused, playback
/// beginnings and ends recorded.
class _FakePlatformAudio extends PlatformAudio {
  /// Titles the player asked to start playback with.
  final List<String> startedTitles = <String>[];

  /// How many times playback was fully given back.
  int stopCalls = 0;

  /// What the next `startPlayback` answers.
  bool grantFocus = true;

  @override
  void listen(void Function(AudioFocusEvent) onFocus) {}

  @override
  void dispose() {}

  @override
  Future<bool> startPlayback({required String title}) async {
    if (!grantFocus) {
      return false;
    }
    startedTitles.add(title);
    return true;
  }

  @override
  Future<void> stopPlayback() async => stopCalls++;
}

/// The library as a shelf: a path per entry, no bootstrap, no network.
class _StubLibrary extends LibraryController {
  @override
  LibraryPhase build() => const LibraryStarting();

  @override
  File localFileFor(LibraryVolume volume, LibraryEntry entry) =>
      File('/mirror/${volume.id}/${entry.name}');
}

LibraryVolume _volume() => LibraryVolume(
  id: 'v1',
  name: '001_how_to_play_and_improvise_jazz',
  entries: const <LibraryEntry>[],
);

LibraryEntry _track(String id, String name) => LibraryEntry(
  id: id,
  name: name,
  kind: LibraryEntryKind.track,
  sizeBytes: 1024,
  checksum: '',
  modifiedUtc: DateTime.utc(2024, 1, 1),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakePlayerBridge bridge;
  late _EngineBridge engineBridge;
  late _FakePlatformAudio platform;
  late List<String> transportCalls;
  late ProviderContainer container;
  late PlayerController controller;

  setUp(() {
    bridge = _FakePlayerBridge();
    engineBridge = _EngineBridge();
    platform = _FakePlatformAudio();
    final transport = _RecordingTransport()..calls.clear();
    transportCalls = transport.calls;
    container = ProviderContainer(
      overrides: [
        libraryProvider.overrideWith(_StubLibrary.new),
        audioEngineProvider.overrideWith(
          () => AudioEngineController(bridge: engineBridge),
        ),
        platformAudioProvider.overrideWith(
          () =>
              PlatformAudioController(transport: transport, platform: platform),
        ),
        playerProvider.overrideWith(() => PlayerController(bridge: bridge)),
      ],
    );
    addTearDown(container.dispose);
    controller = container.read(playerProvider.notifier);
  });

  test(
    'opening a track decodes it through the mirror and lands it ready',
    () async {
      await controller.open(_volume(), _track('e1', '001_track_a.wav'));

      expect(bridge.loadPaths, <String>['/mirror/v1/001_track_a.wav']);
      final state = container.read(playerProvider);
      expect(state.loading, isFalse);
      expect(state.loadError, isNull);
      expect(state.trackName, 'Track A.wav');
      expect(state.info, _theTrack);
      // The BigInt duration narrows once, here.
      expect(state.durationMs, 30000);
      expect(state.transport, TransportState.stopped);
    },
  );

  test('a failed decode says so, and a retry runs again', () async {
    bridge.loadError = 'corrupt mp3: no frames';
    final volume = _volume();
    final entry = _track('e1', '001_track_a.wav');
    await controller.open(volume, entry);

    var state = container.read(playerProvider);
    expect(state.info, isNull);
    expect(state.loading, isFalse);
    expect(state.loadError, contains('corrupt'));

    // Nothing is loaded, so play is politely nothing at all.
    await controller.play();
    expect(platform.startedTitles, isEmpty);
    expect(transportCalls, isEmpty);

    await controller.open(volume, entry);
    state = container.read(playerProvider);
    expect(bridge.loadPaths, hasLength(2));
    expect(state.info, _theTrack);
    expect(state.loadError, isNull);
  });

  test(
    'an open superseded mid-decode is dropped when it finally answers',
    () async {
      final volume = _volume();
      final slow = _track('slow', '001_track_a.wav');
      final quick = _track('quick', '002_track_b.wav');

      final held = Completer<TrackInfo>();
      bridge.gate = held;
      final opening = controller.open(volume, slow);
      // The quick open runs while the slow one is still decoding.
      final finished = controller.open(volume, quick);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(playerProvider).entryId, 'quick');

      await finished;
      expect(container.read(playerProvider).info, _theTrack);
      expect(bridge.loadPaths, hasLength(2));

      // The slow decode lands late — for an entry nobody is waiting on.
      held.complete(_theTrack);
      await opening;
      expect(container.read(playerProvider).entryId, 'quick');
      expect(container.read(playerProvider).loading, isFalse);
    },
  );

  test(
    'play starts the engine, then the handshake, then the transport',
    () async {
      await controller.open(_volume(), _track('e1', '001_track_a.wav'));
      await controller.play();

      expect(engineBridge.startCalls, hasLength(1));
      expect(platform.startedTitles, <String>['Track A.wav']);
      expect(transportCalls, contains('play'));
      expect(container.read(playerProvider).playError, isNull);
    },
  );

  test('a refused focus request stops the band before it starts', () async {
    await controller.open(_volume(), _track('e1', '001_track_a.wav'));
    platform.grantFocus = false;

    await controller.play();

    // §2: nothing may play into a focus the system did not grant.
    expect(platform.startedTitles, isEmpty);
    expect(transportCalls, isNot(contains('play')));
    final state = container.read(playerProvider);
    expect(state.playError, contains('audio'));
    expect(state.isPlaying, isFalse);
  });

  test('a stream that will not open explains itself without playing', () async {
    engineBridge.startError = 'device busy';
    await controller.open(_volume(), _track('e1', '001_track_a.wav'));

    await controller.play();

    expect(platform.startedTitles, isEmpty);
    expect(transportCalls, isEmpty);
    expect(container.read(playerProvider).playError, contains('device busy'));
  });

  test('isolation sets the matrix, and outlives a load', () async {
    final volume = _volume();
    await controller.open(volume, _track('e1', '001_track_a.wav'));

    await controller.setMix(ChannelMode.left);
    expect(bridge.mixes, <List<double>>[ChannelMode.left.matrix]);
    expect(container.read(playerProvider).mix, ChannelMode.left);

    // An unload is not a mix move.
    await controller.open(volume, _track('e2', '002_track_b.wav'));
    expect(bridge.mixes, hasLength(1));
    expect(container.read(playerProvider).mix, ChannelMode.left);
  });

  test('a seek clamps to the track, wherever it is asked to go', () async {
    await controller.open(_volume(), _track('e1', '001_track_a.wav'));

    await controller.seekTo(-500);
    expect(bridge.seeks, <double>[0]);
    expect(container.read(playerProvider).positionMs, 0);

    await controller.seekTo(31000);
    expect(bridge.seeks, <double>[0, 30000]);
    expect(container.read(playerProvider).positionMs, 30000);

    await controller.seekTo(1500.5);
    expect(bridge.seeks, <double>[0, 30000, 1500.5]);
  });

  test(
    'two marks make a cycle, in either order, if far enough apart',
    () async {
      await controller.open(_volume(), _track('e1', '001_track_a.wav'));

      // Forward.
      await controller.seekTo(5000);
      await controller.markCyclePoint();
      var state = container.read(playerProvider);
      expect(state.awaitingCycleEnd, isTrue);
      expect(bridge.loops.last, (0, 30000, false));

      await controller.seekTo(20000);
      await controller.markCyclePoint();
      state = container.read(playerProvider);
      expect(state.hasCycle, isTrue);
      expect(state.cycleStartMs, 5000);
      expect(state.cycleEndMs, 20000);
      expect(bridge.loops.last, (5000, 20000, true));

      // A third mark begins a new region, not a fourth wall.
      await controller.seekTo(10000);
      await controller.markCyclePoint();
      state = container.read(playerProvider);
      expect(state.awaitingCycleEnd, isTrue);
      expect(bridge.loops.last, (0, 30000, false));

      // Backward: the earlier mark is the start either way. The mark at 10000
      // above left a region open, so 4000 closes it — from the earlier side.
      await controller.seekTo(4000);
      await controller.markCyclePoint();
      state = container.read(playerProvider);
      expect(state.cycleStartMs, 4000);
      expect(state.cycleEndMs, 10000);
      expect(bridge.loops.last, (4000, 10000, true));
    },
  );

  test('a span too short to hear declines to become a cycle', () async {
    await controller.open(_volume(), _track('e1', '001_track_a.wav'));

    await controller.seekTo(5000);
    await controller.markCyclePoint();
    final engaged = bridge.loops.length;

    await controller.seekTo(5500); // 500 ms later: a stumble, not a region.
    await controller.markCyclePoint();

    final state = container.read(playerProvider);
    expect(state.awaitingCycleEnd, isTrue, reason: 'the start mark stands');
    expect(state.cycleStartMs, 5000);
    expect(bridge.loops, hasLength(engaged), reason: 'nothing was engaged');
  });

  test('the repeat modes and a marked loop displace each other', () async {
    await controller.open(_volume(), _track('e1', '001_track_a.wav'));

    // Off → once: the whole track loops for one more pass.
    await controller.cycleRepeatMode();
    expect(container.read(playerProvider).repeatMode, TrackRepeat.once);
    expect(bridge.loops.last, (0, 30000, true));

    // A first loop mark takes the repeat off before it opens a region.
    await controller.seekTo(8000);
    await controller.markCyclePoint();
    final state = container.read(playerProvider);
    expect(state.repeatMode, TrackRepeat.off);
    expect(state.cycleStartMs, 8000);
    expect(bridge.loops.last, (0, 30000, false));

    await controller.seekTo(21000);
    await controller.markCyclePoint();
    expect(bridge.loops.last, (8000, 21000, true));

    // Repeat takes over again and the marks go: once, then forever —
    // the same region either way.
    await controller.cycleRepeatMode();
    final afterOnce = container.read(playerProvider);
    expect(afterOnce.repeatMode, TrackRepeat.once);
    expect(afterOnce.hasCycle, isFalse);
    expect(afterOnce.cycleStartMs, isNull);
    expect(afterOnce.cycleEndMs, isNull);
    expect(bridge.loops.last, (0, 30000, true));
    await controller.cycleRepeatMode();
    expect(container.read(playerProvider).repeatMode, TrackRepeat.forever);
    expect(bridge.loops.last, (0, 30000, true));

    // And back to off takes the loop off with it.
    await controller.cycleRepeatMode();
    expect(container.read(playerProvider).repeatMode, TrackRepeat.off);
    expect(bridge.loops.last, (0, 30000, false));

    // Clearing a loop also takes any repeat off.
    await controller.cycleRepeatMode();
    await controller.markCyclePoint();
    await controller.markCyclePoint();
    await controller.clearCycle();
    final cleared = container.read(playerProvider);
    expect(cleared.repeatMode, TrackRepeat.off);
    expect(cleared.hasCycle, isFalse);
    expect(bridge.loops.last, (0, 30000, false));
  });

  test('repeat-once wraps once, then takes itself off', () async {
    await controller.open(_volume(), _track('e1', '001_track_a.wav'));
    await controller.cycleRepeatMode();
    expect(container.read(playerProvider).repeatMode, TrackRepeat.once);
    expect(bridge.loops, hasLength(1));

    // Near the end: still the first pass.
    bridge.position = _published(29500, TransportState.playing);
    await controller.refreshPosition();
    expect(container.read(playerProvider).repeatMode, TrackRepeat.once);
    expect(bridge.loops, hasLength(1));

    // The wrap — back at the top while playing — begins the second pass,
    // and with it the loop's work is done.
    bridge.position = _published(250, TransportState.playing);
    await controller.refreshPosition();
    final state = container.read(playerProvider);
    expect(state.repeatMode, TrackRepeat.off);
    expect(state.positionMs, 250);
    expect(bridge.loops.last, (0, 30000, false));

    // The second pass reaches the end and stops like any other.
    bridge.position = _published(30000, TransportState.playing);
    await controller.refreshPosition();
    expect(transportCalls, contains('stop'));
  });

  test('repeat-forever wraps without taking itself off', () async {
    await controller.open(_volume(), _track('e1', '001_track_a.wav'));
    await controller.cycleRepeatMode();
    await controller.cycleRepeatMode();
    expect(container.read(playerProvider).repeatMode, TrackRepeat.forever);

    // The region from the two mode walks is still the one in force: no
    // disable was ever pushed, and the wrap changes nothing.
    bridge.position = _published(29900, TransportState.playing);
    await controller.refreshPosition();
    bridge.position = _published(100, TransportState.playing);
    await controller.refreshPosition();

    expect(container.read(playerProvider).repeatMode, TrackRepeat.forever);
    expect(bridge.loops.last, (0, 30000, true));
    expect(bridge.loops, isNot(contains((0, 30000, false))));
    expect(transportCalls, isNot(contains('stop')));
  });

  test('reaching the end of the track stops it and gives focus back', () async {
    await controller.open(_volume(), _track('e1', '001_track_a.wav'));

    // Just short: still going.
    bridge.position = _published(29999, TransportState.playing);
    await controller.refreshPosition();
    expect(transportCalls, isNot(contains('stop')));
    expect(platform.stopCalls, 0);

    // Past the last frame — the engine plays silence here by design, so the
    // watcher is the one who calls it. The stop rewinds to the top, which
    // the next position read reports.
    bridge.position = _published(30100, TransportState.playing);
    await controller.refreshPosition();
    expect(transportCalls, contains('stop'));
    expect(platform.stopCalls, 1);
    bridge.position = _published(0, TransportState.stopped);
    await controller.refreshPosition();
    final state = container.read(playerProvider);
    expect(state.isPlaying, isFalse);
    expect(state.positionMs, 0);
  });

  test('a parked playhead past the end is not a stop condition', () async {
    await controller.open(_volume(), _track('e1', '001_track_a.wav'));

    // Paused at the end: hold on, not stop.
    bridge.position = _published(30000, TransportState.paused);
    await controller.refreshPosition();
    expect(transportCalls, isNot(contains('stop')));
    expect(container.read(playerProvider).positionMs, 30000);
  });

  test('a throwing position read stops the poll without a crash', () async {
    await controller.open(_volume(), _track('e1', '001_track_a.wav'));
    await controller.seekTo(12000);

    bridge.positionError = StateError('the cell is gone');
    await controller.refreshPosition();

    // The last known position stands, and the controller still works.
    expect(container.read(playerProvider).positionMs, 12000);
    bridge.positionError = null;
    bridge.position = _published(12500, TransportState.playing);
    await controller.refreshPosition();
    expect(container.read(playerProvider).positionMs, 12500);
    expect(container.read(playerProvider).isPlaying, isTrue);
  });

  test('a negative playhead reads as the top of the track', () async {
    await controller.open(_volume(), _track('e1', '001_track_a.wav'));

    bridge.position = _published(-3, TransportState.playing);
    await controller.refreshPosition();

    expect(container.read(playerProvider).positionMs, 0);
  });

  test('the clock reads the way a transport does', () {
    expect(PlayerController.describeClock(0), '0:00');
    expect(PlayerController.describeClock(999), '0:01');
    expect(PlayerController.describeClock(59999), '1:00');
    expect(PlayerController.describeClock(61000), '1:01');
  });
}

/// What the focus policy asked of the transport, in order — the same fake
/// shape as `platform_audio_test.dart`.
class _RecordingTransport extends PlatformTransport {
  final List<String> calls = <String>[];

  @override
  Future<void> play() async => calls.add('play');

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<void> applyGain({required double gain}) async {}

  @override
  TransportPosition position() => _published(0, TransportState.stopped);
}
