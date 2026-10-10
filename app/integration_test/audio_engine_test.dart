import 'package:bandstand/audio/playhead.dart';
import 'package:bandstand/bridge/api/audio.dart';
import 'package:bandstand/bridge/frb_generated.dart';
import 'package:bandstand/io/harmony_assets.dart';
import 'package:bandstand/ui/app.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'audio_support.dart';

/// M0 acceptance (§10): a sine wave through the real audio path, and the
/// position atomic readable from Dart.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await installHarmonyAssets();
    await RustLib.init();
  });

  tearDown(() async {
    await audioStop();
    await transportStop();
  });

  testWidgets('the app shell builds and reaches the audio screen', (
    tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: BandstandApp()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Library'), findsWidgets);
    expect(find.text('Sets'), findsWidgets);

    await tester.tap(find.text('Audio').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Reference tone'), findsOneWidget);
    expect(find.text('PLAYHEAD'), findsOneWidget);
  });

  testWidgets('the engine opens a device and renders audio blocks', (
    tester,
  ) async {
    final devices = await audioDevices();
    if (devices.isEmpty) {
      markTestSkipped('no audio output device on this machine');
      return;
    }

    final status = await audioStart(request: const AudioStreamRequest());
    expect(status.sampleRate, greaterThan(0));
    expect(status.channels, greaterThan(0));

    await setTestTone(enabled: true, frequencyHz: 440, amplitude: 0.125);
    await Future<void>.delayed(const Duration(milliseconds: 600));

    final after = await audioStatus();
    expect(after, isNotNull);
    expect(after!.blockCount, greaterThan(BigInt.zero));
    expect(after.frameCount, greaterThan(BigInt.zero));
    // §3: zero dropouts. Over half a second there is no excuse for one.
    expect(after.errorCount, BigInt.zero);

    await setTestTone(enabled: false, frequencyHz: 440, amplitude: 0.125);
  });

  /// Wait until the transport reports `state`, and return that reading.
  ///
  /// Commands land at the top of the next audio block, and the gap between
  /// blocks is a device property — microseconds on a desktop, far longer on an
  /// emulator. Polling for the state keeps these tests about the transport
  /// rather than about the buffer size.
  Future<PlayheadReading> settledAt(
    TransportState state, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final reading = Playhead.resolve(transportPosition());
      if (reading.state == state) {
        return reading;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    throw StateError('the transport never reached $state within $timeout');
  }

  testWidgets('the playhead advances and is readable from Dart', (
    tester,
  ) async {
    final devices = await audioDevices();
    if (devices.isEmpty) {
      markTestSkipped('no audio output device on this machine');
      return;
    }

    await audioStart(request: const AudioStreamRequest());
    await transportSetTempo(bpm: 120);
    await transportSeek(tick: 0);
    await transportPlay();

    await Future<void>.delayed(const Duration(milliseconds: 500));
    final moving = Playhead.resolve(transportPosition());
    expect(moving.state, TransportState.playing);
    // 120 bpm for half a second is one quarter note; allow generous slack for
    // scheduling, but it must clearly have moved.
    expect(moving.tick, greaterThan(300));

    // A transport command is applied at the top of the next audio block, so
    // how soon it is *visible* depends on the buffer size. A desktop callback
    // runs every few milliseconds and a fixed wait is invisible; the Android
    // emulator's runs far less often, and a 100 ms wait sampled a reading that
    // still said "playing" and was therefore extrapolated. Waiting for the
    // state the command asked for tests the invariant that actually matters —
    // once paused, the playhead holds — on any device.
    await transportPause();
    final paused = await settledAt(TransportState.paused);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final stillPaused = Playhead.resolve(transportPosition());
    expect(stillPaused.state, TransportState.paused);
    expect(stillPaused.tick, closeTo(paused.tick, 1e-6));

    await transportStop();
    final stopped = await settledAt(TransportState.stopped);
    expect(stopped.tick, 0);
  });

  testWidgets('the transport clock keeps time to within the §3 budget', (
    tester,
  ) async {
    final devices = await audioDevices();
    if (devices.isEmpty) {
      markTestSkipped('no audio output device on this machine');
      return;
    }

    await audioStart(request: const AudioStreamRequest());

    // §3's budget — 20 ms over 5 minutes — is 0.0067%, which is the order of
    // crystal drift and is a statement about real hardware. It cannot be
    // checked on a simulated audio path: the Android emulator negotiates a
    // 34 880-frame buffer, delivers it in bursts (358 ms of music arriving
    // 13 ms after the previous callback), and its software audio clock was
    // measured drifting 0.53% against the system clock over thirty seconds —
    // eighty times the budget. Nothing in the app can fix that and no result
    // from it means anything.
    //
    // A device with a buffer this large is not a real-time audio path, so the
    // test says so and stops rather than reporting a number about the
    // emulator's clock.
    if (!await isRealTimeAudioPath()) {
      markTestSkipped(await notRealTimeReason());
      await audioStop();
      return;
    }

    await transportSetTempo(bpm: 120);
    await transportSeek(tick: 0);
    await transportPlay();

    // Drift is a *rate* error, and §3 budgets it as one: "cursor drift under
    // 20 ms over 5 minutes". Two things make it easy to measure something else
    // instead, and both were measured doing so:
    //
    //  - Timing from the moment `transportPlay()` returns carries a start-up
    //    offset, because playback begins when the audio thread next takes a
    //    block. On a loaded desktop that offset alone reached 47 ms.
    //  - Sampling the playhead with our own timer quantises to the buffer. The
    //    Android emulator negotiates a 34 880-frame buffer — 727 ms — so a
    //    five-second sample carries up to 727 ms of quantisation and says
    //    nothing whatever about a 20 ms budget.
    //
    // So the comparison is between what the engine published and the clock it
    // published it on. Both come from the same place, there is no sampling in
    // it at all, and what is left is exactly the audio clock's rate against the
    // system's.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final first = transportPosition();
    await Future<void>.delayed(const Duration(seconds: 5));
    final last = transportPosition();

    expect(
      last.hostTimeNs,
      isNot(first.hostTimeNs),
      reason: 'the engine published no new block in five seconds',
    );
    final elapsedNs = (last.hostTimeNs - first.hostTimeNs).toDouble();
    final expectedTicks = elapsedNs * first.ticksPerNanosecond;
    final driftTicks = ((last.tick - first.tick) - expectedTicks).abs();
    final driftMs = driftTicks / (first.ticksPerNanosecond * 1e6);
    // §3 budgets drift as a rate — 20 ms over five minutes — and this window
    // is five seconds, so the same rate is 0.33 ms. A desktop's audio stack
    // resamples against its own clock and measures 0.4–0.8 ms over this
    // window here, so the budget is 2 ms: six times the rate, about three
    // times the worst measured figure — §3's own number is a statement about
    // dedicated hardware, and this test's job is to catch a broken clock.
    // (L-TQ11: the 20 ms this used to allow was sixty times the rate and
    // would have passed one.)
    expect(
      driftMs,
      lessThan(2),
      reason:
          'the clock ran ${driftMs.toStringAsFixed(2)} ms out over '
          '${(elapsedNs / 1e9).toStringAsFixed(1)} s',
    );

    await transportStop();
  });
}
