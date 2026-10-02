import 'dart:io';

import 'package:bandstand/bridge/api/audio.dart';
import 'package:bandstand/bridge/frb_generated.dart';
import 'package:bandstand/state/platform_audio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'audio_support.dart';

/// §10's M8 acceptance, in the three parts that do not need a tablet.
///
/// *"A 90-minute set, screen locked and unlocked repeatedly, no audio
/// interruption"* — see `docs/rules/android-audio.md` §7 for what an emulator
/// can and cannot settle. Battery drain is the fourth part and needs real
/// hardware; nothing here pretends otherwise.
///
/// Duration is a parameter so this can run in a change loop:
///
/// ```sh
/// just soak                 # a few minutes, thirty screen cycles
/// just soak 90              # the full set
/// ```
/// Counts the lifecycle transitions a screen lock causes.
///
/// The screen is cycled from the **host** — an app cannot lock its own
/// screen, and this test runs on the device, where `adb` does not exist.
/// `just soak` drives it.
///
/// Watching the lifecycle is better than trusting the host loop ran: a
/// screen lock pauses the activity, so counting `paused` and `resumed` is
/// direct evidence that the thing under test actually happened. A soak that
/// saw no transitions proved nothing, and says so rather than passing.
///
/// This is also the observer that makes the *point* of the test: the audio
/// must keep running while the app is paused, which is what a foreground
/// service is for.
class _Lifecycle with WidgetsBindingObserver {
  int paused = 0;
  int resumed = 0;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      paused++;
    } else if (state == AppLifecycleState.resumed) {
      resumed++;
    }
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// How long to play for, in minutes.
  const minutes = int.fromEnvironment(
    'BANDSTAND_SOAK_MINUTES',
    defaultValue: 3,
  );

  /// How often to lock or unlock the screen, in seconds.
  ///
  /// Twenty seconds: thirty lock/unlock transitions prove far more about the
  /// foreground service than five thousand seconds of nothing happening.
  const cycleSeconds = int.fromEnvironment(
    'BANDSTAND_SOAK_CYCLE_SECONDS',
    defaultValue: 20,
  );

  if (cycleSeconds <= 0) {
    // An explicit zero or negative would otherwise surface as a division by
    // zero deep in the test, far from the flag that caused it.
    throw ArgumentError.value(
      cycleSeconds,
      'BANDSTAND_SOAK_CYCLE_SECONDS',
      'must be positive',
    );
  }

  setUpAll(() async {
    await RustLib.init();
  });

  testWidgets('a set survives the screen being locked and unlocked', (
    tester,
  ) async {
    if (!Platform.isAndroid) {
      markTestSkipped('the screen-lock half of §10 M8 is an Android question');
      return;
    }
    final bank = findSoundbank();
    if (bank == null || (await audioDevices()).isEmpty) {
      markTestSkipped('no soundfont or no audio device');
      return;
    }
    await loadSoundbank(path: bank);
    await audioStart(request: const AudioStreamRequest());

    // A minute of music, looped: the transport wraps, so a long set does not
    // need a long sequence.
    const ppq = 960;
    final events = <MidiEvent>[
      MidiEvent(
        tick: BigInt.zero,
        channel: 0,
        kind: MidiEventKind.program,
        data1: 0,
        data2: 0,
      ),
      for (var bar = 0; bar < 32; bar++)
        for (final (index, key) in <int>[
          48,
          52,
          55,
          59,
        ].indexed) ...<MidiEvent>[
          MidiEvent(
            tick: BigInt.from((bar * 4 + index) * ppq),
            channel: 0,
            kind: MidiEventKind.noteOn,
            data1: key,
            data2: 90,
          ),
          MidiEvent(
            tick: BigInt.from((bar * 4 + index) * ppq + ppq ~/ 2),
            channel: 0,
            kind: MidiEventKind.noteOff,
            data1: key,
            data2: 0,
          ),
        ],
    ];
    await loadSequence(
      events: events,
      ppq: ppq,
      lengthTicks: BigInt.from(32 * 4 * ppq),
      tempoMarkers: <TempoMarker>[TempoMarker(tick: BigInt.zero, bpm: 120)],
    );
    await transportSetLoop(
      enabled: true,
      startTick: BigInt.zero,
      endTick: BigInt.from(32 * 4 * ppq),
    );

    // Takes audio focus and starts the foreground service, which is the thing
    // being tested. Straight through `PlatformAudio` rather than the
    // controller: a Riverpod notifier only has state inside a container, and
    // none of the focus *policy* is exercised here — the screen locking is.
    final platform = PlatformAudio();
    expect(
      await platform.startPlayback(title: 'Soak test'),
      isTrue,
      reason: 'the system refused audio focus',
    );
    await transportSeek(tick: 0);
    await transportPlay();
    await Future<void>.delayed(const Duration(seconds: 2));

    final lifecycle = _Lifecycle();
    WidgetsBinding.instance.addObserver(lifecycle);
    addTearDown(() => WidgetsBinding.instance.removeObserver(lifecycle));

    final cycles = (minutes * 60) ~/ cycleSeconds;
    var lastTick = transportPosition().tick;
    var lastGeneration = transportPosition().loopGeneration;
    var lastBlocks = (await audioStatus())!.blockCount;

    for (var cycle = 1; cycle <= cycles; cycle++) {
      // The host is cycling the screen underneath us; this only watches.
      await Future<void>.delayed(Duration(seconds: cycleSeconds));

      final where = 'paused ${lifecycle.paused}x';
      final position = transportPosition();
      final status = (await audioStatus())!;
      // ignore: avoid_print
      print(
        'SOAK cycle $cycle: tick ${position.tick.toStringAsFixed(0)} '
        '(+${(position.tick - lastTick).toStringAsFixed(0)}) '
        'state ${position.state.name} '
        'blocks ${status.blockCount} (+${status.blockCount - lastBlocks}) '
        'errors ${status.errorCount} '
        'paused ${lifecycle.paused} resumed ${lifecycle.resumed}',
      );

      expect(
        position.state,
        TransportState.playing,
        reason: 'cycle $cycle ($where): the transport stopped',
      );
      // A stream whose callbacks stopped publishes a frozen tick, which is
      // what a killed service looks like from Dart. The set loops, so the tick
      // legitimately goes *backwards* at the wrap — which is what the loop
      // generation is for, and asserting on the tick alone failed at the first
      // wrap for a transport that was working perfectly.
      final wrapped = position.loopGeneration != lastGeneration;
      expect(
        wrapped || position.tick > lastTick,
        isTrue,
        reason: 'cycle $cycle ($where): the playhead did not advance',
      );
      expect(
        status.blockCount,
        greaterThan(lastBlocks),
        reason: 'cycle $cycle ($where): no audio blocks were rendered',
      );
      // §3: zero dropouts, for the whole set.
      expect(
        status.errorCount,
        BigInt.zero,
        reason: 'cycle $cycle ($where): ${status.errorCount} dropouts',
      );

      lastTick = position.tick;
      lastGeneration = position.loopGeneration;
      lastBlocks = status.blockCount;
    }

    final status = (await audioStatus())!;
    // ignore: avoid_print
    print(
      'SOAK $minutes min: ${status.blockCount} blocks, '
      '${status.errorCount} dropouts, '
      '${lifecycle.paused} pauses, ${lifecycle.resumed} resumes',
    );

    // A soak that never saw the app backgrounded proved nothing about the
    // foreground service, which is the whole point. Fail rather than pass
    // quietly.
    expect(
      lifecycle.paused,
      greaterThan(0),
      reason: 'the screen was never locked — is `just soak` driving it?',
    );
    expect(
      lifecycle.resumed,
      greaterThan(0),
      reason: 'the screen was never unlocked again',
    );

    await transportStop();
    await platform.stopPlayback();
    await audioStop();
  });
}
