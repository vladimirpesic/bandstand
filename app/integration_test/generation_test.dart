import 'package:bandstand/audio/sequence_builder.dart';
import 'package:bandstand/bridge/api/audio.dart';
import 'package:bandstand/bridge/frb_generated.dart';
import 'package:bandstand/domain/generation/song_generator.dart';
import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:bandstand/domain/song/chord_leadsheet.dart';
import 'package:bandstand/domain/song/lead_sheet_item.dart';
import 'package:bandstand/domain/song/mixer_settings.dart';
import 'package:bandstand/domain/song/section.dart';
import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/domain/song/song_part.dart';
import 'package:bandstand/domain/song/song_structure.dart';
import 'package:bandstand/io/generation_assets.dart';
import 'package:bandstand/io/harmony_assets.dart';
import 'package:bandstand/io/importers/ireal_import.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'audio_support.dart';

/// M5 acceptance (§10): press play on an imported chart and hear time, and
/// regenerate after an edit inside the §3 budget.
///
/// M6 acceptance in the part a machine can take: the walking bass generates
/// over an imported chart and reaches a real audio device. Whether the line
/// *sounds* like a bass player is a listening test and is the human's (§15) —
/// `just audition` writes the file for it.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late SongGenerator pipeline;

  setUpAll(() async {
    await installHarmonyAssets();
    await RustLib.init();
    pipeline = await loadGenerators();
  });

  tearDown(() async {
    await transportStop();
    await clearSequence();
    await audioStop();
  });

  /// A 32-bar chart, imported the way a user would get one.
  Song importedChart() {
    const url =
        'irealbook://Test%20Tune=Composer%20A=Medium%20Swing=C=n='
        '[T44Dm7 G7 |C^7 |Dm7 G7 |C^7 |Dm7 G7 |C^7 |Dm7 G7 |C^7 ]';
    final imported = IRealImporter.parseUrl(url);
    expect(imported.songs, isNotEmpty, reason: 'the chart did not import');
    final song = imported.songs.first.toSong('imported', rhythmId: 'drums');
    return song.copyWith(
      structure: SongStructure(<SongPart>[
        for (final section in song.leadSheet.sections)
          SongPart(
            parentSectionName: section.name,
            startBar: 0,
            barCount: song.leadSheet.sectionEndBar(section) - section.startBar,
            rhythmId: 'drums',
            parameterValues: const <String, Object>{'intensity': 60},
          ),
      ]),
    );
  }

  testWidgets('an imported chart generates drums', (tester) async {
    final song = importedChart();
    final generated = pipeline.generate(song);
    expect(generated.problems, isEmpty);
    expect(generated.noteCount, greaterThan(20));
    expect(generated.voices.single.channel, 9);
  });

  /// The same chart, played by a different band.
  Song chartPlayedBy(String rhythmId) {
    final song = importedChart();
    return song.copyWith(
      structure: SongStructure(<SongPart>[
        for (final part in song.structure.songParts)
          part.copyWith(
            rhythmId: rhythmId,
            parameterValues: const <String, Object>{},
          ),
      ]),
    );
  }

  testWidgets('an imported chart is comped', (tester) async {
    final generated = pipeline.generate(chartPlayedBy('comping'));
    expect(generated.problems, isEmpty);
    final piano = generated.voices.single;
    expect(piano.voice.id, 'piano');
    expect(piano.channel, isNot(9));
    // Chords, not a line: several notes share an onset.
    final byPosition = <double, int>{};
    for (final note in piano.phrase.notes) {
      byPosition[note.positionInBeats] =
          (byPosition[note.positionInBeats] ?? 0) + 1;
    }
    // L-TQ12: `every` over an empty map is vacuously true, so say first that
    // the comping produced onsets at all.
    expect(byPosition, isNotEmpty);
    expect(byPosition.values.every((count) => count >= 3), isTrue);
  });

  testWidgets('a rhythm section without the piano is available too', (
    tester,
  ) async {
    final generated = pipeline.generate(chartPlayedBy('rhythm-section'));
    expect(generated.problems, isEmpty);
    expect(generated.voices.map((voice) => voice.voice.id).toSet(), <String>{
      'drums',
      'bass',
    });
  });

  testWidgets('an imported chart generates a walking bass', (tester) async {
    final generated = pipeline.generate(chartPlayedBy('walking-bass'));
    expect(generated.problems, isEmpty);
    // A walking line is a note a beat, and in 4/4 a beat is a quarter — so the
    // count follows the form's length rather than a number written here.
    expect(generated.noteCount, generated.totalQuarters.round());
    expect(generated.noteCount, greaterThan(16));
    final bass = generated.voices.single;
    expect(bass.voice.id, 'bass');
    expect(bass.channel, isNot(9), reason: 'the bass is not a drum');
    for (final note in bass.phrase.notes) {
      expect(note.pitch, inInclusiveRange(28, 55), reason: 'in the instrument');
    }
  });

  testWidgets('the whole band plays the same chart', (tester) async {
    final generated = pipeline.generate(chartPlayedBy('swing'));
    expect(generated.problems, isEmpty);
    expect(generated.voices.map((voice) => voice.voice.id).toSet(), <String>{
      'drums',
      'bass',
      'piano',
    }, reason: 'the trio of M5, M6 and M7 on the same stand');
    // Each voice on its own channel, and the drums on 9.
    final channels = generated.voices.map((voice) => voice.channel).toList();
    expect(channels.toSet().length, channels.length);
    expect(generated.voices.firstWhere((v) => v.voice.isDrums).channel, 9);
  });

  testWidgets('press play and hear the band, not just time', (tester) async {
    final path = findSoundbank();
    if (path == null || (await audioDevices()).isEmpty) {
      markTestSkipped('no soundfont or no audio device');
      return;
    }

    await loadSoundbank(path: path);
    await audioStart(request: const AudioStreamRequest());

    final song = chartPlayedBy('swing');
    final generated = pipeline.generate(song);
    final sequence = generated.toSequence(song.mixer, tempoBpm: song.tempo);
    await loadSequence(
      events: sequence.events,
      ppq: sequence.ppq,
      lengthTicks: sequence.lengthTicks,
      tempoMarkers: sequence.tempoMarkers,
    );

    await transportSeek(tick: 0);
    await transportPlay();
    await Future<void>.delayed(const Duration(seconds: 3));

    final status = await audioStatus();
    expect(status, isNotNull);
    expect(status!.blockCount, greaterThan(BigInt.zero));
    // §3: zero dropouts, with two generators' worth of notes to render.
    expect(status.errorCount, BigInt.zero);
    expect(transportPosition().state, TransportState.playing);
  });

  testWidgets('press play on an imported chart and hear time', (tester) async {
    final path = findSoundbank();
    if (path == null || (await audioDevices()).isEmpty) {
      markTestSkipped('no soundfont or no audio device');
      return;
    }

    await loadSoundbank(path: path);
    await audioStart(request: const AudioStreamRequest());

    final song = importedChart();
    final generated = pipeline.generate(song);
    final sequence = generated.toSequence(song.mixer, tempoBpm: song.tempo);
    await loadSequence(
      events: sequence.events,
      ppq: sequence.ppq,
      lengthTicks: sequence.lengthTicks,
      tempoMarkers: sequence.tempoMarkers,
    );
    expect(sequenceStatus().eventCount, greaterThan(40));

    await transportSeek(tick: 0);
    await transportPlay();
    await Future<void>.delayed(const Duration(seconds: 3));

    final status = await audioStatus();
    expect(status, isNotNull);
    expect(status!.blockCount, greaterThan(BigInt.zero));
    // §3: zero dropouts.
    expect(status.errorCount, BigInt.zero);
    expect(transportPosition().state, TransportState.playing);
  });

  testWidgets('regeneration after a chord edit is inside the §3 budget', (
    tester,
  ) async {
    final song = importedChart();
    // Warm the paths, so this measures the pipeline rather than the first run.
    for (var i = 0; i < 3; i++) {
      pipeline.generate(song);
    }

    final edited = song.copyWith(
      leadSheet: song.leadSheet.withItem(
        CliChordSymbol(Position(4), ExtChordSymbol.parse('Ab7')),
      ),
    );

    final watch = Stopwatch()..start();
    final generated = pipeline.generate(edited);
    final sequence = generated.toSequence(edited.mixer, tempoBpm: edited.tempo);
    watch.stop();

    expect(generated.noteCount, greaterThan(0));
    expect(sequence.events, isNotEmpty);
    // §3: 100 ms target, 300 ms hard limit. CI hosts vary; the target stays
    // visible in the output, the assertion enforces the limit.
    expect(
      watch.elapsedMilliseconds,
      lessThan(300),
      reason:
          '${watch.elapsedMilliseconds} ms to regenerate '
          '(100 ms target)',
    );
  });

  testWidgets('the same song generates the same take, and reroll changes it', (
    tester,
  ) async {
    final song = importedChart();
    final first = pipeline.generate(song, seed: 4);
    final again = pipeline.generate(song, seed: 4);
    final rerolled = pipeline.generate(song, seed: 5);

    String fingerprint(GeneratedSong generated) => generated.allNotes
        .map(
          (e) =>
              '${e.note.positionInBeats}:${e.note.pitch}:${e.note.beatDuration}:${e.note.velocity}',
        )
        .join(',');

    expect(fingerprint(first), fingerprint(again));
    expect(fingerprint(first), isNot(fingerprint(rerolled)));
  });

  testWidgets('a muted voice is left out of the sequence entirely', (
    tester,
  ) async {
    final song = importedChart();
    final generated = pipeline.generate(song);
    final heard = generated.toSequence(song.mixer, tempoBpm: song.tempo);

    final silenced = song.copyWith(
      mixer: song.mixer.withChannel(
        ChannelSettings(voiceId: 'drums', muted: true),
      ),
    );
    final muted = generated.toSequence(silenced.mixer, tempoBpm: song.tempo);

    expect(heard.events.length, greaterThan(muted.events.length));
    expect(muted.events.where((e) => e.kind == MidiEventKind.noteOn), isEmpty);
    // No program change either: the voice is absent, not silenced. A program
    // event for a voice with no notes still arms the channel at the synth.
    expect(muted.events.where((e) => e.kind == MidiEventKind.program), isEmpty);
  });

  testWidgets('a hand-built song with several parts plays end to end', (
    tester,
  ) async {
    final sheet = ChordLeadSheet(
      barCount: 16,
      items: <LeadSheetItem>[
        CliSection(Section(name: 'A', startBar: 0)),
        CliSection(Section(name: 'B', startBar: 8)),
        CliChordSymbol(Position(0), ExtChordSymbol.parse('Cmaj7')),
        CliChordSymbol(Position(8), ExtChordSymbol.parse('Fmaj7')),
      ],
    );
    final song = Song(
      id: 'multi',
      title: 'Multi',
      leadSheet: sheet,
      structure: SongStructure(<SongPart>[
        SongPart(
          parentSectionName: 'A',
          startBar: 0,
          barCount: 8,
          rhythmId: 'drums',
        ),
        SongPart(
          parentSectionName: 'B',
          startBar: 0,
          barCount: 8,
          rhythmId: 'drums',
        ),
      ]),
      tempo: 180,
    );

    final generated = pipeline.generate(song);
    expect(generated.totalQuarters, 64);
    // Both parts wrote notes: the second half is not silent.
    final late = generated.allNotes
        .where((e) => e.note.positionInBeats >= 32)
        .toList();
    expect(late, isNotEmpty, reason: 'the second part is silent');
  });
}
