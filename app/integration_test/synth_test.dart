import 'dart:io';
import 'dart:typed_data';

import 'package:bandstand/audio/playhead.dart';
import 'package:bandstand/bridge/api/audio.dart';
import 'package:bandstand/bridge/frb_generated.dart';
import 'package:bandstand/io/harmony_assets.dart';
import 'package:bandstand/io/midi/midi_file.dart';
import 'package:bandstand/io/midi/midi_writer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'audio_support.dart';

/// M4 acceptance (§10): the sampler, the sequencer and the transport, through
/// a real audio device.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// A ii–V–I, four beats a chord, at 120 bpm.
  Uint8List progression() => MidiFileWriter.write(
    ticksPerQuarter: 480,
    tracks: <List<MidiWriteEvent>>[
      <MidiWriteEvent>[MidiWriteEvent.tempo(0, 120)],
      <MidiWriteEvent>[
        MidiWriteEvent.program(0, 0, 0),
        for (final (index, chord) in <List<int>>[
          <int>[50, 57, 60, 65],
          <int>[43, 47, 53, 57],
          <int>[48, 52, 55, 59],
        ].indexed) ...<MidiWriteEvent>[
          for (final key in chord) ...<MidiWriteEvent>[
            MidiWriteEvent.noteOn(index * 1920, 0, key, 96),
            MidiWriteEvent.noteOff(index * 1920 + 1800, 0, key),
          ],
        ],
      ],
    ],
  );

  setUpAll(() async {
    await installHarmonyAssets();
    await RustLib.init();
  });

  tearDown(() async {
    await transportStop();
    await clearSequence();
    await audioStop();
  });

  testWidgets('a soundbank loads and reports what is in it', (tester) async {
    final path = findSoundbank();
    if (path == null) {
      markTestSkipped('no General MIDI soundfont on this machine');
      return;
    }
    final info = await loadSoundbank(path: path);
    expect(info.presetCount, greaterThanOrEqualTo(128));
    expect(info.sampleCount, greaterThan(0));
    expect(info.name, isNotEmpty);
    expect(await loadedSoundbank(), isNotNull);

    await unloadSoundbank();
    expect(await loadedSoundbank(), isNull);
  });

  testWidgets('a file that is not a soundfont is refused', (tester) async {
    // Past every size check, so the refusal comes from the RIFF header read
    // and names what the file is not.
    final bogus = File('${Directory.systemTemp.path}/bandstand-not-a-bank.sf2')
      ..writeAsBytesSync(Uint8List.fromList('NOTASOUNDFONT!!!'.codeUnits));
    addTearDown(() => bogus.deleteSync());
    await expectLater(
      loadSoundbank(path: bogus.path),
      throwsA(contains('not a SoundFont')),
    );
  });

  testWidgets('a sequence loads and reports its length', (tester) async {
    final parsed = progression();
    // The bytes are what the rest of the test assumes: 480 ppq, three chords
    // on bar starts, these voicings. Read back through the reader a user's
    // file would take rather than asserting only that some bytes came out.
    final file = MidiFileReader.read(parsed);
    expect(file.ticksPerQuarter, 480);
    final onsets = <int, List<int>>{};
    for (final event in file.tracks[1].events) {
      if (event.status == 0x90) {
        onsets.putIfAbsent(event.tick, () => <int>[]).add(event.data1);
      }
    }
    final ticks = onsets.keys.toList()..sort();
    expect(ticks, <int>[0, 1920, 3840]);
    expect(onsets[0], <int>[50, 57, 60, 65]);
    expect(onsets[1920], <int>[43, 47, 53, 57]);
    expect(onsets[3840], <int>[48, 52, 55, 59]);

    await loadSequence(
      events: <MidiEvent>[
        MidiEvent(
          tick: BigInt.zero,
          channel: 0,
          kind: MidiEventKind.noteOn,
          data1: 60,
          data2: 100,
        ),
        MidiEvent(
          tick: BigInt.from(960),
          channel: 0,
          kind: MidiEventKind.noteOff,
          data1: 60,
          data2: 0,
        ),
      ],
      ppq: 960,
      lengthTicks: BigInt.from(960),
      tempoMarkers: <TempoMarker>[TempoMarker(tick: BigInt.zero, bpm: 120)],
    );
    final status = sequenceStatus();
    expect(status.eventCount, 2);
    expect(status.lengthTicks, BigInt.from(960));

    await clearSequence();
    expect(sequenceStatus().eventCount, 0);
  });

  testWidgets('the engine plays a General MIDI sequence through a device', (
    tester,
  ) async {
    final path = findSoundbank();
    if (path == null || (await audioDevices()).isEmpty) {
      markTestSkipped('no soundfont or no audio device');
      return;
    }

    await loadSoundbank(path: path);
    await audioStart(request: const AudioStreamRequest());
    await loadSequence(
      events: <MidiEvent>[
        MidiEvent(
          tick: BigInt.zero,
          channel: 0,
          kind: MidiEventKind.program,
          data1: 0,
          data2: 0,
        ),
        for (final key in <int>[60, 64, 67, 71])
          MidiEvent(
            tick: BigInt.zero,
            channel: 0,
            kind: MidiEventKind.noteOn,
            data1: key,
            data2: 100,
          ),
        for (final key in <int>[60, 64, 67, 71])
          MidiEvent(
            tick: BigInt.from(1800),
            channel: 0,
            kind: MidiEventKind.noteOff,
            data1: key,
            data2: 0,
          ),
      ],
      ppq: 960,
      lengthTicks: BigInt.from(1920),
      tempoMarkers: <TempoMarker>[TempoMarker(tick: BigInt.zero, bpm: 120)],
    );

    await transportSeek(tick: 0);
    await transportPlay();
    await Future<void>.delayed(const Duration(milliseconds: 800));

    final status = await audioStatus();
    expect(status, isNotNull);
    expect(status!.blockCount, greaterThan(BigInt.zero));
    // §3: zero dropouts.
    expect(status.errorCount, BigInt.zero);

    final playhead = Playhead.resolve(transportPosition());
    expect(playhead.state, TransportState.playing);
    expect(playhead.tick, greaterThan(500));
  });

  testWidgets('the cursor keeps time to within the §3 budget', (tester) async {
    if ((await audioDevices()).isEmpty) {
      markTestSkipped('no audio device');
      return;
    }
    await audioStart(request: const AudioStreamRequest());
    if (!await isRealTimeAudioPath()) {
      markTestSkipped(await notRealTimeReason());
      await audioStop();
      return;
    }
    await transportSetTempo(bpm: 120);
    await transportSeek(tick: 0);
    await transportPlay();

    // Against the engine's own clock rather than our sampling of it: both come
    // from the same publication, so there is no buffer quantisation in the
    // figure and what is left is the audio clock's rate against the system's.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final first = transportPosition();
    await Future<void>.delayed(const Duration(seconds: 10));
    final last = transportPosition();
    expect(
      last.hostTimeNs,
      isNot(first.hostTimeNs),
      reason: 'the engine published no new block in ten seconds',
    );

    final elapsedNs = (last.hostTimeNs - first.hostTimeNs).toDouble();
    final expectedTicks = elapsedNs * first.ticksPerNanosecond;
    final driftTicks = ((last.tick - first.tick) - expectedTicks).abs();
    final driftMs = driftTicks / (first.ticksPerNanosecond * 1e6);
    // §3 allows 20 ms over five minutes; this window is ten seconds, so the
    // same rate is 0.67 ms — measured under that on a desktop's real clock.
    // The budget is 1 ms: one and a half times the rate, room for a CI host
    // without the three-times-the-rate slack this used to carry (L-TQ11).
    expect(driftMs, lessThan(1), reason: 'drift ${driftMs}ms');
  });

  testWidgets('a minute at a 256-frame buffer produces no dropouts', (
    tester,
  ) async {
    final path = findSoundbank();
    if (path == null || (await audioDevices()).isEmpty) {
      markTestSkipped('no soundfont or no audio device');
      return;
    }
    await loadSoundbank(path: path);
    await audioStart(
      request: const AudioStreamRequest(bufferFrames: 256, sampleRate: 48000),
    );

    // A chord every half second for a minute: enough voices to be work, and
    // long enough that a buffer that is too small will fail.
    final events = <MidiEvent>[
      MidiEvent(
        tick: BigInt.zero,
        channel: 0,
        kind: MidiEventKind.program,
        data1: 0,
        data2: 0,
      ),
    ];
    for (var bar = 0; bar < 120; bar++) {
      final tick = BigInt.from(bar * 960);
      for (final offset in <int>[0, 4, 7, 11]) {
        events
          ..add(
            MidiEvent(
              tick: tick,
              channel: 0,
              kind: MidiEventKind.noteOn,
              data1: 48 + offset + (bar % 12),
              data2: 90,
            ),
          )
          ..add(
            MidiEvent(
              tick: tick + BigInt.from(900),
              channel: 0,
              kind: MidiEventKind.noteOff,
              data1: 48 + offset + (bar % 12),
              data2: 0,
            ),
          );
      }
    }
    await loadSequence(
      events: events,
      ppq: 960,
      lengthTicks: BigInt.from(120 * 960),
      tempoMarkers: <TempoMarker>[TempoMarker(tick: BigInt.zero, bpm: 120)],
    );

    await transportSeek(tick: 0);
    await transportPlay();
    await Future<void>.delayed(const Duration(seconds: 60));

    final status = (await audioStatus())!;
    // §3's requirement is zero dropouts, and that holds whatever the device
    // decided to hand us.
    expect(
      status.errorCount,
      BigInt.zero,
      reason: 'the backend reported ${status.errorCount} dropouts',
    );

    // Whether the *requested* 256 frames was honoured is a separate question,
    // and one only a real-time backend answers yes to. ALSA and WASAPI take
    // the request; Android's Oboe decides for itself and handed the emulator
    // 34 880 frames. Asserting the number unconditionally tested the platform's
    // willingness rather than Bandstand's behaviour.
    final frames = status.bufferFrames;
    if (frames != null && frames > 0 && frames <= realTimeBufferLimit) {
      // A real-time backend may still round the request: 256 asked, 512
      // delivered is a healthy path, not a fault (L-TQ13). What is asserted
      // is that the renderer was driven in blocks of the size the platform
      // actually negotiated — a minute at 48 kHz is 2 880 000 frames, and a
      // stream that delivered fewer than 80% of the blocks of that size was
      // not running the path it reports.
      final blocksExpected = 48_000 * 60 / frames;
      expect(
        status.blockCount,
        greaterThan(BigInt.from((blocksExpected * 0.8).floor())),
        reason:
            'a minute at $frames frames a block is about '
            '${blocksExpected.toStringAsFixed(0)} blocks',
      );
    } else {
      // A 727 ms buffer produces about 83 blocks a minute, not 11 000, but it
      // must still have produced them.
      expect(status.blockCount, greaterThan(BigInt.from(10)));
    }
  });

  testWidgets('a bounce writes a playable file', (tester) async {
    final path = findSoundbank();
    if (path == null) {
      markTestSkipped('no soundfont');
      return;
    }
    await loadSoundbank(path: path);
    await loadSequence(
      events: <MidiEvent>[
        MidiEvent(
          tick: BigInt.zero,
          channel: 0,
          kind: MidiEventKind.program,
          data1: 0,
          data2: 0,
        ),
        MidiEvent(
          tick: BigInt.zero,
          channel: 0,
          kind: MidiEventKind.noteOn,
          data1: 60,
          data2: 100,
        ),
        MidiEvent(
          tick: BigInt.from(1800),
          channel: 0,
          kind: MidiEventKind.noteOff,
          data1: 60,
          data2: 0,
        ),
      ],
      ppq: 960,
      lengthTicks: BigInt.from(1920),
      tempoMarkers: <TempoMarker>[TempoMarker(tick: BigInt.zero, bpm: 120)],
    );

    final out = File('${Directory.systemTemp.path}/bandstand-bounce.wav');
    addTearDown(() {
      if (out.existsSync()) {
        out.deleteSync();
      }
    });

    final result = await renderOffline(path: out.path, sampleRate: 48000);
    expect(result.frames, greaterThan(BigInt.zero));
    expect(result.seconds, greaterThan(1.0));
    expect(result.clippedSamples, BigInt.zero);
    expect(out.existsSync(), isTrue);
    expect(out.lengthSync(), greaterThan(44));
  });
}
