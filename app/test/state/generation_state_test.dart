import 'dart:async';

import 'package:bandstand/domain/generation/music_generator.dart';
import 'package:bandstand/domain/generation/song_generator.dart';
import 'package:bandstand/domain/song/practice_session.dart';
import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/state/generation_state.dart';
import 'package:bandstand/state/practice_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The playback and practice controllers' own behaviour: queueing, failure
/// reporting, and the guards around in-flight work.
///
/// Plain `test`, not `testWidgets`: there is no widget tree and the failures
/// these exercise are async, not visual. The generators are fakes; the engine
/// calls downstream of a successful generation throw without a native library,
/// which the pipeline reports on the state — exactly what these tests assert.
void main() {
  Song tune(String id) => Song.blank(id: id, title: id);

  group('SongPlaybackController', () {
    test('overlapping generateAndLoad calls run one at a time', () async {
      final fake = _RecordingGenerator();
      final container = ProviderContainer(
        overrides: [
          // Already resolved: both calls overlap at the generators await, the
          // way two rapid edits do, with nothing else deciding the timing.
          generatorsProvider.overrideWith(
            (ref) => Future<SongGenerator>.value(fake),
          ),
        ],
      );
      addTearDown(container.dispose);

      final controller = container.read(songPlaybackProvider.notifier);
      final first = controller.generateAndLoad(tune('a'));
      // Still in flight: the second call queues behind it.
      final second = controller.generateAndLoad(tune('b'));

      await first;

      // The second call was queued, not interleaved: by the time the first
      // call's future completes, the second has already taken the state over
      // (busy again, the first call's failure cleared). Without the queue the
      // two calls overlap at the generators await and the first call's
      // completion — its failure on the state — is what a reader sees here,
      // with the engine able to end up playing one song while the state
      // claims the other.
      final midFlight = container.read(songPlaybackProvider);
      expect(midFlight.busy, isTrue);
      expect(fake.generated, <String>['a']);

      await second;
      expect(fake.generated, <String>['a', 'b']);
    });
  });

  group('PracticeController', () {
    test('a chorus plan failure is reported, not thrown', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final controller = container.read(practiceProvider.notifier);

      await controller.start(_ExplodingSession(), tune('s'));

      // The plan blew up before the engine was touched; the failure belongs on
      // the state, not in the caller's face.
      final state = container.read(practiceProvider);
      expect(state.errorMessage, contains('plan blew up'));
      expect(state.busy, isFalse);
      // And the session is over rather than half-started. `start` sets
      // `running` before working the plan out, so a plan that throws on chorus
      // 0 used to leave a session the UI showed as under way and could not
      // describe — running, with no plan at all.
      expect(state.running, isFalse);
      expect(state.plan, isNull);
    });

    test('stopping puts the written tempo back after a tempo ramp', () async {
      // §3.4 — the song is left exactly as it was written. The restore was
      // guarded on the session having transposed, but `_applyChorus` sets the
      // tempo on *every* chorus, so a plain tempo ramp left the transport at
      // the last chorus's tempo. That is the commonest practice session there
      // is, and the one case the guard was blind to.
      final transport = _RecordingTransport();
      final container = ProviderContainer(
        overrides: [
          practiceProvider.overrideWith(
            () => PracticeController(transport: transport),
          ),
        ],
      );
      addTearDown(container.dispose);

      final song = tune('s').copyWith(tempo: 140);
      await container.read(practiceProvider.notifier).stop(song);

      expect(transport.tempos, <double>[140]);
      expect(transport.loopEnabled, <bool>[false]);
    });

    test('advance and goTo wait out an in-flight chorus application', () async {
      final completer = Completer<SongGenerator>();
      final container = ProviderContainer(
        overrides: [generatorsProvider.overrideWith((ref) => completer.future)],
      );
      addTearDown(container.dispose);
      final controller = container.read(practiceProvider.notifier);
      final song = tune('s');

      // start regenerates the first chorus, and the generator never answers.
      final starting = controller.start(
        PracticeSession(startingTempo: 120),
        song,
      );
      expect(container.read(practiceProvider).busy, isTrue);

      await controller.advance(song);
      await controller.goTo(3, song);
      expect(container.read(practiceProvider).chorus, 0);

      completer.complete(_RecordingGenerator());
      await starting;

      // Neither move was applied: both were asked for while a chorus
      // application was still running, and each would have kicked a second
      // regeneration loose on the engine.
      expect(container.read(practiceProvider).chorus, 0);
    });
  });

  test('a generation in flight across dispose writes nothing', () async {
    // Every write in `_generateAndLoad` happens after an await, and closing
    // a screen mid-edit disposes the provider. Writing `state` on a disposed
    // notifier throws, and for the fire-and-forget callers that reach here
    // it throws into nothing. `audio_engine` guards its polling the same
    // way; this did not.
    final completer = Completer<SongGenerator>();
    final container = ProviderContainer(
      overrides: [generatorsProvider.overrideWith((ref) => completer.future)],
    );
    final controller = container.read(songPlaybackProvider.notifier);

    final running = controller.generateAndLoad(tune('s'));
    container.dispose();
    completer.complete(_RecordingGenerator());
    await running;

    // Nothing to assert on the state — it is gone. What matters is that
    // getting here took no unhandled error with it.
    await Future<void>.delayed(Duration.zero);
  });
}

/// Records which songs were generated, then fails: enough to observe ordering
/// without building a real take.
class _RecordingGenerator extends SongGenerator {
  _RecordingGenerator() : super(const <MusicGenerator>[]);

  final List<String> generated = <String>[];

  @override
  GeneratedSong generate(Song song, {int seed = 0, int ppq = 960}) {
    generated.add(song.id);
    throw StateError('boom ${song.id}');
  }
}

/// A session whose plan cannot be computed — the error path of
/// `PracticeSession.planFor` however it is reached.
class _ExplodingSession extends PracticeSession {
  _ExplodingSession() : super(startingTempo: 120);

  @override
  ChorusPlan planFor(int chorus, {int? formBars}) =>
      throw StateError('plan blew up');
}

/// Records what a practice session asked of the transport.
///
/// The real one throws until `RustLib.init()` has run, so without this seam
/// none of `stop`'s behaviour could be reached from a unit test at all.
class _RecordingTransport extends PracticeTransport {
  _RecordingTransport();

  final List<double> tempos = <double>[];
  final List<bool> loopEnabled = <bool>[];
  final List<double> seeks = <double>[];

  @override
  Future<void> setTempo({required double bpm}) async => tempos.add(bpm);

  @override
  Future<void> setLoop({
    required bool enabled,
    required BigInt startTick,
    required BigInt endTick,
  }) async => loopEnabled.add(enabled);

  @override
  Future<void> seek({required double tick}) async => seeks.add(tick);
}
