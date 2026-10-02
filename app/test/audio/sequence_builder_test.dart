import 'package:bandstand/audio/sequence_builder.dart';
import 'package:bandstand/bridge/api/audio.dart';
import 'package:bandstand/domain/generation/generation_context.dart';
import 'package:bandstand/domain/generation/music_generator.dart';
import 'package:bandstand/domain/generation/song_generator.dart';
import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:bandstand/domain/phrase/note_event.dart';
import 'package:bandstand/domain/phrase/phrase.dart';
import 'package:bandstand/domain/song/chord_leadsheet.dart';
import 'package:bandstand/domain/song/lead_sheet_item.dart';
import 'package:bandstand/domain/song/mixer_settings.dart';
import 'package:bandstand/domain/song/rhythm.dart';
import 'package:bandstand/domain/song/section.dart';
import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/domain/song/song_part.dart';
import 'package:bandstand/domain/song/song_chord_sequence.dart';
import 'package:bandstand/domain/song/song_structure.dart';
import 'package:bandstand/domain/song/ticks.dart';
import 'package:bandstand/io/exporters/midi_export.dart';
import 'package:bandstand/io/midi/midi_file.dart';
import 'package:flutter_test/flutter_test.dart';

import '../domain/harmony/harmony_test_support.dart';

/// The §3 boundary: a generated song becoming ticks.
///
/// This file exists because the conversion had no unit test at all, and the
/// bug it hid was audible — a 6/8 song played at half speed, and a song whose
/// meter changed played its bars in the wrong order. The engine and the MIDI
/// exporter are checked against the *same* expected ticks in every case here:
/// they read the same phrase, and they disagreed for a long time because
/// nothing compared them.
void main() {
  installTestHarmony();

  /// Writes one note on the downbeat of every bar of the context.
  ///
  /// In the context's own beats, which is what a generator deals in and
  /// exactly what makes the conversion worth testing.
  final voice = RhythmVoice(id: 'v', displayName: 'V', isDrums: false);
  final generator = _Downbeats(voice);
  final songGenerator = SongGenerator(<MusicGenerator>[generator]);

  /// One bar per meter, each its own section and its own song part.
  Song songOf(List<TimeSignature> meters) {
    final items = <LeadSheetItem>[];
    for (var bar = 0; bar < meters.length; bar++) {
      items
        ..add(
          CliSection(
            Section(name: 'S$bar', startBar: bar, timeSignature: meters[bar]),
          ),
        )
        ..add(CliChordSymbol(Position(bar), ExtChordSymbol.parse('Cmaj7')));
    }
    return Song(
      id: 'tune',
      title: 'Meters',
      leadSheet: ChordLeadSheet(barCount: meters.length, items: items),
      structure: SongStructure(<SongPart>[
        for (var bar = 0; bar < meters.length; bar++)
          SongPart(
            parentSectionName: 'S$bar',
            startBar: bar,
            barCount: 1,
            rhythmId: _Downbeats.rhythmId,
          ),
      ]),
      tempo: 120,
    );
  }

  List<int> engineNoteOns(GeneratedSong generated) =>
      generated
          .toSequence(MixerSettings.empty(), tempoBpm: 120)
          .events
          .where((event) => event.kind == MidiEventKind.noteOn)
          .map((event) => event.tick.toInt())
          .toList()
        ..sort();

  List<int> exportedNoteOns(Song song, GeneratedSong generated) =>
      MidiFileReader.read(MidiExporter.export(song, generated)).allEvents
          .where(
            (event) => !event.isMeta && event.status == 0x90 && event.data2 > 0,
          )
          .map((event) => event.tick)
          .toList()
        ..sort();

  group('a downbeat lands on the tick its bar starts at', () {
    // Every case is the same statement: tick == quarters × 960, where the
    // quarters are the ones the meter actually adds up to. 4/4 bars are four
    // quarters, 3/4 three, and a 6/8 bar is three — not six.
    const cases = <String, (List<TimeSignature>, List<int>)>{
      'four bars of 4/4': (
        <TimeSignature>[
          TimeSignature.fourFour,
          TimeSignature.fourFour,
          TimeSignature.fourFour,
          TimeSignature.fourFour,
        ],
        <int>[0, 3840, 7680, 11520],
      ),
      'four bars of 3/4': (
        <TimeSignature>[
          TimeSignature.threeFour,
          TimeSignature.threeFour,
          TimeSignature.threeFour,
          TimeSignature.threeFour,
        ],
        <int>[0, 2880, 5760, 8640],
      ),
      // The half-speed case: the beat is an eighth, so multiplying the beat
      // count by ticks-per-quarter put every downbeat at twice its tick.
      'four bars of 6/8': (
        <TimeSignature>[
          TimeSignature.sixEight,
          TimeSignature.sixEight,
          TimeSignature.sixEight,
          TimeSignature.sixEight,
        ],
        <int>[0, 2880, 5760, 8640],
      ),
      // The out-of-order case: each part was shifted into its own beat frame,
      // so bar 3 (a 4/4 bar at quarter 7) landed at tick 6720 and bar 2 (a 6/8
      // bar at quarter 4) at 7680 — the song played its bars out of order.
      'alternating 4/4 and 6/8': (
        <TimeSignature>[
          TimeSignature.fourFour,
          TimeSignature.sixEight,
          TimeSignature.fourFour,
          TimeSignature.sixEight,
        ],
        <int>[0, 3840, 6720, 10560],
      ),
    };

    cases.forEach((name, expectation) {
      final (meters, expected) = expectation;
      test(name, () {
        final song = songOf(meters);
        final generated = songGenerator.generate(song);

        expect(engineNoteOns(generated), expected);
        // The exporter reads the same phrase and must reach the same ticks.
        // It used to scale by the song's bar-0 beat length, which happened to
        // be right for a song wholly in 6/8 and wrong for a mixed one.
        expect(exportedNoteOns(song, generated), expected);
      });
    });
  });

  test('every note falls inside the sequence length', () {
    // `lengthTicks` is the loop end. It has always been quarters × ppq, so a
    // phrase measured in anything else ran past it: two of these four notes
    // used to be at or beyond the end of the sequence that contained them.
    for (final meters in <List<TimeSignature>>[
      List<TimeSignature>.filled(4, TimeSignature.sixEight),
      List<TimeSignature>.filled(4, TimeSignature.threeFour),
      <TimeSignature>[
        TimeSignature.fourFour,
        TimeSignature.sixEight,
        TimeSignature.fourFour,
        TimeSignature.sixEight,
      ],
    ]) {
      final song = songOf(meters);
      final generated = songGenerator.generate(song);
      final sequence = generated.toSequence(
        MixerSettings.empty(),
        tempoBpm: 120,
      );
      final length = sequence.lengthTicks.toInt();
      for (final event in sequence.events) {
        expect(
          event.tick.toInt(),
          lessThanOrEqualTo(length),
          reason: '$meters: an event at ${event.tick} past the end $length',
        );
      }
    }
  });

  test('a downbeat lands where the flattening says its bar starts', () {
    // The expectation comes from the domain rather than being written out, so
    // it cannot drift from what playback actually uses. This is the property a
    // listener hears: bar 3 must not sound before bar 2, whatever the meters.
    final song = songOf(<TimeSignature>[
      TimeSignature.fourFour,
      TimeSignature.sixEight,
      TimeSignature.threeFour,
      TimeSignature.sixEight,
      TimeSignature.fourFour,
    ]);
    final expected = <int>[
      for (final bar in SongChordSequence.of(song).bars)
        (bar.startQuarters * kTicksPerQuarter).round(),
    ];
    expect(expected, orderedEquals(<int>[...expected]..sort()));
    expect(engineNoteOns(songGenerator.generate(song)), expected);
  });

  group('the sequence a generated song builds', () {
    test('carries the mixer patch and the drum bank', () {
      final drums = RhythmVoice(id: 'd', displayName: 'D', isDrums: true);
      final song = songOf(<TimeSignature>[TimeSignature.fourFour]);
      final generated = SongGenerator(<MusicGenerator>[_Downbeats(drums)])
          .generate(song);
      final sequence = generated.toSequence(
        MixerSettings.empty(),
        tempoBpm: 120,
      );
      final program = sequence.events.singleWhere(
        (event) => event.kind == MidiEventKind.program,
      );
      // Bank 128 is where every soundfont keeps its kits, and a drum voice
      // must be on it whatever the mixer says.
      expect(program.data2, 128);
      expect(program.tick, BigInt.zero);
    });

    test('a muted voice is left out of the sequence entirely', () {
      // Silencing at the synth would still cost the voices.
      final song = songOf(<TimeSignature>[TimeSignature.fourFour]);
      final generated = songGenerator.generate(song);
      final mixer = MixerSettings.empty().withChannel(
        ChannelSettings(voiceId: voice.id, muted: true),
      );
      expect(generated.toSequence(mixer, tempoBpm: 120).events, isEmpty);
    });

    test('ppq is the resolution the whole app counts at', () {
      final song = songOf(<TimeSignature>[TimeSignature.fourFour]);
      final generated = songGenerator.generate(song);
      expect(generated.ppq, kTicksPerQuarter);
      expect(
        generated.toSequence(MixerSettings.empty(), tempoBpm: 120).ppq,
        kTicksPerQuarter,
      );
    });

    test('a note that rounds to nothing still sounds', () {
      // A duration below half a tick rounds to the same tick as its onset, and
      // a zero-length note is a note-off before its note-on — which some
      // readers drop and others leave hanging.
      final song = songOf(<TimeSignature>[TimeSignature.fourFour]);
      final generated = SongGenerator(<MusicGenerator>[
        _Downbeats(voice, duration: 0.0001),
      ]).generate(song);
      final sequence = generated.toSequence(
        MixerSettings.empty(),
        tempoBpm: 120,
      );
      final on = sequence.events.singleWhere(
        (event) => event.kind == MidiEventKind.noteOn,
      );
      final off = sequence.events.singleWhere(
        (event) => event.kind == MidiEventKind.noteOff,
      );
      expect(off.tick, greaterThan(on.tick));
    });
  });
}

/// Writes one note on the downbeat of each bar, in the context's own beats.
class _Downbeats implements MusicGenerator {
  _Downbeats(this.voice, {this.duration = 1.0});

  /// The rhythm id every song in this file names.
  static const String rhythmId = 'downbeats';

  final RhythmVoice voice;
  final double duration;

  @override
  String get id => rhythmId;

  @override
  String get displayName => rhythmId;

  @override
  List<RhythmVoice> get voices => <RhythmVoice>[voice];

  @override
  List<RhythmParameterSpec> get parameters => <RhythmParameterSpec>[];

  @override
  Rhythm get rhythm => Rhythm(
    id: rhythmId,
    displayName: displayName,
    timeSignature: TimeSignature.fourFour,
    voices: voices,
    parameters: parameters,
  );

  @override
  GeneratedPart generate(GenerationContext context) {
    final beatsPerBar = context.timeSignature.upper.toDouble();
    final notes = <NoteEvent>[];
    for (var beat = 0.0; beat < context.beatRange.end; beat += beatsPerBar) {
      notes.add(
        NoteEvent(pitch: 60, positionInBeats: beat, beatDuration: duration),
      );
    }
    return GeneratedPart(<RhythmVoice, SizedPhrase>{
      voice: SizedPhrase(
        channel: 0,
        beatRange: context.beatRange,
        timeSignature: context.timeSignature,
        notes: notes,
      ),
    });
  }
}
