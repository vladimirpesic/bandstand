import 'dart:convert';
import 'dart:typed_data';

import 'package:bandstand/io/json_support.dart';
import 'package:bandstand/io/midi/midi_file.dart';
import 'package:bandstand/io/midi/midi_writer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Uint8List writeSimple() => MidiFileWriter.write(
    ticksPerQuarter: 480,
    tracks: <List<MidiWriteEvent>>[
      <MidiWriteEvent>[
        MidiWriteEvent.trackName('Conductor'),
        MidiWriteEvent.tempo(0, 132),
        MidiWriteEvent.timeSignature(0, 3, 4),
        MidiWriteEvent.marker(480, 'A'),
      ],
      <MidiWriteEvent>[
        MidiWriteEvent.trackName('Piano'),
        MidiWriteEvent.program(0, 0, 4),
        MidiWriteEvent.noteOn(0, 0, 60, 100),
        MidiWriteEvent.noteOff(480, 0, 60),
        MidiWriteEvent.noteOn(480, 0, 64, 90),
        MidiWriteEvent.noteOff(960, 0, 64),
      ],
    ],
  );

  group('round trips', () {
    test('what is written reads back', () {
      final file = MidiFileReader.read(writeSimple());
      expect(file.format, 1);
      expect(file.ticksPerQuarter, 480);
      expect(file.tracks, hasLength(2));
      expect(file.tracks[0].name, 'Conductor');
      expect(file.tracks[1].name, 'Piano');
    });

    test('notes come back with their keys, velocities and ticks', () {
      final file = MidiFileReader.read(writeSimple());
      final notes = file.tracks[1].events.where((e) => e.isNoteOn).toList();
      expect(notes, hasLength(2));
      expect(notes[0].tick, 0);
      expect(notes[0].data1, 60);
      expect(notes[0].data2, 100);
      expect(notes[1].tick, 480);
      expect(notes[1].data1, 64);
    });

    test('note offs are recognised in both spellings', () {
      final bytes = MidiFileWriter.write(
        ticksPerQuarter: 480,
        tracks: <List<MidiWriteEvent>>[
          <MidiWriteEvent>[
            MidiWriteEvent.noteOn(0, 0, 60, 100),
            // A note on with zero velocity: half the files in the world.
            MidiWriteEvent.noteOn(480, 0, 60, 0),
            MidiWriteEvent.noteOff(960, 0, 62),
          ],
        ],
      );
      final events = MidiFileReader.read(bytes).allEvents;
      expect(events.where((e) => e.isNoteOn), hasLength(1));
      expect(events.where((e) => e.isNoteOff), hasLength(2));
    });

    test('the tempo and the meter come back', () {
      final file = MidiFileReader.read(writeSimple());
      expect(file.initialTempoBpm, closeTo(132, 0.01));
      expect(file.tempoChanges, hasLength(1));
      expect(file.tempoChanges.single.tick, 0);

      final meter = file.allEvents
          .firstWhere((e) => e.timeSignature != null)
          .timeSignature!;
      expect(meter.upper, 3);
      expect(meter.lower, 4);
    });

    test('markers and names come back as text', () {
      final file = MidiFileReader.read(writeSimple());
      final marker = file.allEvents.firstWhere((e) => e.metaType == 0x06);
      expect(marker.text, 'A');
      expect(marker.tick, 480);
    });

    test('a program change carries only one data byte', () {
      final file = MidiFileReader.read(writeSimple());
      final program = file.tracks[1].events.firstWhere((e) => e.status == 0xC0);
      expect(program.data1, 4);
    });

    test('events across tracks merge in tick order', () {
      final file = MidiFileReader.read(writeSimple());
      final ticks = file.allEvents.map((e) => e.tick).toList();
      for (var i = 1; i < ticks.length; i++) {
        expect(ticks[i], greaterThanOrEqualTo(ticks[i - 1]));
      }
      expect(file.lengthTicks, 960);
    });
  });

  group('running status', () {
    test('is read as the specification requires', () {
      // Three note ons in a row sharing one status byte.
      final body = <int>[
        0x00, 0x90, 60, 100, //
        0x10, 62, 100, //
        0x10, 64, 100, //
        0x00, 0xFF, 0x2F, 0x00,
      ];
      final bytes = _rawFile(480, <List<int>>[body]);
      final events = MidiFileReader.read(bytes).allEvents;
      final notes = events.where((e) => e.isNoteOn).toList();
      expect(notes, hasLength(3));
      expect(notes.map((e) => e.data1), <int>[60, 62, 64]);
      expect(notes.map((e) => e.tick), <int>[0, 16, 32]);
    });

    test('is cancelled by a meta event, as the specification requires', () {
      // A status byte may not be implied across a meta event: the `62` after
      // the track name is data with no status, and the file is refused rather
      // than read as a note that was never struck.
      final body = <int>[
        0x00, 0x90, 60, 100, //
        0x10, 0xFF, 0x03, 0x01, 0x41, // track name "A"
        0x10, 62, 100, //
        0x00, 0xFF, 0x2F, 0x00,
      ];
      expect(
        () => MidiFileReader.read(_rawFile(480, <List<int>>[body])),
        throwsA(isA<SongFormatException>()),
      );
    });

    test('is cancelled by system exclusive, as the specification requires', () {
      final body = <int>[
        0x00, 0x90, 60, 100, //
        0x10, 0xF0, 0x03, 0x41, 0x42, 0xF7, //
        0x10, 62, 100, //
        0x00, 0xFF, 0x2F, 0x00,
      ];
      expect(
        () => MidiFileReader.read(_rawFile(480, <List<int>>[body])),
        throwsA(isA<SongFormatException>()),
      );
    });

    test('a track that starts with data and no status is refused', () {
      final bytes = _rawFile(480, <List<int>>[
        <int>[0x00, 60, 100, 0x00, 0xFF, 0x2F, 0x00],
      ]);
      expect(
        () => MidiFileReader.read(bytes),
        throwsA(isA<SongFormatException>()),
      );
    });
  });

  group('system common messages', () {
    test('a one-byte message does not eat the next status byte', () {
      // MIDI Time Code is 0xF1 plus one data byte; a reader that takes two
      // bytes swallows the note-on status that follows.
      final body = <int>[
        0x00, 0xF1, 0x01, //
        0x00, 0x90, 60, 100, //
        0x00, 0xFF, 0x2F, 0x00,
      ];
      final events = MidiFileReader.read(_rawFile(480, <List<int>>[body]))
          .allEvents;
      expect(events.where((e) => e.isNoteOn), hasLength(1));
    });

    test('a two-byte message is stepped over', () {
      // Song Position Pointer is 0xF2 plus two data bytes.
      final body = <int>[
        0x00, 0xF2, 0x10, 0x00, //
        0x00, 0x90, 60, 100, //
        0x00, 0xFF, 0x2F, 0x00,
      ];
      final events = MidiFileReader.read(_rawFile(480, <List<int>>[body]))
          .allEvents;
      expect(events.where((e) => e.isNoteOn), hasLength(1));
    });
  });

  group('text encoding', () {
    test('latin-1 text round-trips', () {
      final bytes = MidiFileWriter.write(
        ticksPerQuarter: 480,
        tracks: <List<MidiWriteEvent>>[
          <MidiWriteEvent>[MidiWriteEvent.trackName('Café')],
        ],
      );
      expect(MidiFileReader.read(bytes).tracks.single.name, 'Café');
    });

    test('a character outside latin-1 is dropped, not fatal', () {
      // The flat sign has no latin-1 spelling; the export still succeeds and
      // keeps what it can.
      final bytes = MidiFileWriter.write(
        ticksPerQuarter: 480,
        tracks: <List<MidiWriteEvent>>[
          <MidiWriteEvent>[MidiWriteEvent.trackName('Blues in B♭')],
        ],
      );
      expect(MidiFileReader.read(bytes).tracks.single.name, 'Blues in B');
    });
  });

  group('time signatures', () {
    test('a denominator exponent past 15 is noise, not a shift by 2^127', () {
      final bytes = MidiFileWriter.write(
        ticksPerQuarter: 480,
        tracks: <List<MidiWriteEvent>>[
          <MidiWriteEvent>[MidiWriteEvent.timeSignature(0, 4, 4)],
        ],
      );
      // Rewrite the exponent byte by hand: the writer only emits sane ones.
      //
      // Located by the meta header `FF 58 04` rather than by the first 0x58
      // anywhere in the file. 0x58 is 'X' and a perfectly ordinary tick,
      // length or text byte, so `indexOf(0x58)` was one track name away from
      // silently rewriting something else and asserting nothing.
      final header = <int>[0xFF, 0x58, 0x04];
      var at = -1;
      for (var i = 0; i + header.length <= bytes.length; i++) {
        if (bytes[i] == header[0] &&
            bytes[i + 1] == header[1] &&
            bytes[i + 2] == header[2]) {
          at = i;
          break;
        }
      }
      expect(at, isNonNegative, reason: 'no time-signature meta was written');
      // FF 58 04 <numerator> <denominator> <clocks> <32nds>
      bytes[at + 4] = 20;
      final event = MidiFileReader.read(bytes).allEvents
          .firstWhere((e) => e.metaType == 0x58);
      expect(event.timeSignature, isNull);
    });
  });

  group('files that will not read', () {
    test('anything that is not a MIDI file is refused', () {
      expect(
        () => MidiFileReader.read(Uint8List.fromList(<int>[1, 2, 3])),
        throwsA(isA<SongFormatException>()),
      );
      expect(
        () =>
            MidiFileReader.read(Uint8List.fromList(List<int>.filled(20, 0x41))),
        throwsA(isA<SongFormatException>()),
      );
    });

    test('format 2 is refused rather than mangled', () {
      final bytes = _rawFile(480, <List<int>>[], format: 2);
      expect(
        () => MidiFileReader.read(bytes),
        throwsA(
          isA<SongFormatException>().having(
            (e) => e.message,
            'message',
            contains('independent sequences'),
          ),
        ),
      );
    });

    test('SMPTE timing is refused', () {
      final bytes = _rawFile(0xE728, <List<int>>[]);
      expect(
        () => MidiFileReader.read(bytes),
        throwsA(
          isA<SongFormatException>().having(
            (e) => e.message,
            'message',
            contains('SMPTE'),
          ),
        ),
      );
    });

    test('a division of zero is refused', () {
      expect(
        () => MidiFileReader.read(_rawFile(0, <List<int>>[])),
        throwsA(isA<SongFormatException>()),
      );
    });

    test('a truncated track fails with a message, not a range error', () {
      final bytes = _rawFile(480, <List<int>>[
        <int>[0x00, 0x90, 60], // ends mid-event
      ]);
      expect(
        () => MidiFileReader.read(bytes),
        throwsA(isA<SongFormatException>()),
      );
    });

    test('a file claiming more tracks than it holds reads what is there', () {
      final one = <int>[0x00, 0x90, 60, 100, 0x00, 0xFF, 0x2F, 0x00];
      final bytes = _rawFile(480, <List<int>>[one], declaredTracks: 5);
      final file = MidiFileReader.read(bytes);
      expect(file.tracks, hasLength(1));
    });
  });

  group('what the format allows and Bandstand ignores', () {
    test('an unknown chunk between tracks is skipped', () {
      final track = <int>[0x00, 0x90, 60, 100, 0x00, 0xFF, 0x2F, 0x00];
      final out = <int>[
        ...'MThd'.codeUnits, 0, 0, 0, 6, 0, 1, 0, 2, (480 >> 8), 480 & 0xFF,
        ...'XYZQ'.codeUnits, 0, 0, 0, 3, 1, 2, 3, //
        ...'MTrk'.codeUnits,
        (track.length >> 24) & 0xFF,
        (track.length >> 16) & 0xFF,
        (track.length >> 8) & 0xFF,
        track.length & 0xFF,
        ...track,
      ];
      final file = MidiFileReader.read(Uint8List.fromList(out));
      expect(file.tracks, hasLength(1));
      expect(file.allEvents.where((e) => e.isNoteOn), hasLength(1));
    });

    test('system exclusive is read past', () {
      final body = <int>[
        0x00, 0xF0, 0x03, 0x41, 0x42, 0xF7, //
        0x00, 0x90, 60, 100, //
        0x00, 0xFF, 0x2F, 0x00,
      ];
      final file = MidiFileReader.read(_rawFile(480, <List<int>>[body]));
      expect(file.allEvents.where((e) => e.isNoteOn), hasLength(1));
    });

    test('a long header is read past', () {
      final track = <int>[0x00, 0x90, 60, 100, 0x00, 0xFF, 0x2F, 0x00];
      final out = <int>[
        ...'MThd'.codeUnits, 0, 0, 0, 8, 0, 1, 0, 1, 1, 224, 9, 9, //
        ...'MTrk'.codeUnits, 0, 0, 0, track.length, ...track,
      ];
      final file = MidiFileReader.read(Uint8List.fromList(out));
      expect(file.ticksPerQuarter, 480);
      expect(file.allEvents.where((e) => e.isNoteOn), hasLength(1));
    });
  });

  test('a file with no tempo reports the default', () {
    final bytes = MidiFileWriter.write(
      ticksPerQuarter: 480,
      tracks: <List<MidiWriteEvent>>[
        <MidiWriteEvent>[MidiWriteEvent.noteOn(0, 0, 60, 100)],
      ],
    );
    expect(MidiFileReader.read(bytes).initialTempoBpm, 120);
  });

  group('bytes the reader used to trip over', () {
    test('system real-time status bytes do not desync the track', () {
      // 0xF8–0xFE (clock, start, continue, stop, active sensing) carry no
      // data. They used to fall through to the channel-event path, where
      // `status & 0xF0` made them look like a note and two bytes belonging to
      // the *next* event were eaten — so everything after one was misread.
      final tail = <int>[
        0x00, 0x90, 60, 100, // note on
        0x00, 0x80, 60, 0, // note off
        0x00, 0xFF, 0x2F, 0x00, // end of track
      ];
      for (final realTime in <int>[0xF8, 0xFA, 0xFB, 0xFC, 0xFE]) {
        final track = <int>[0x00, realTime, ...tail];
        final bytes = Uint8List.fromList(<int>[
          0x4D, 0x54, 0x68, 0x64, // MThd
          0x00, 0x00, 0x00, 0x06,
          0x00, 0x00, // format 0
          0x00, 0x01, // one track
          0x01, 0xE0, // 480 ppq
          0x4D, 0x54, 0x72, 0x6B, // MTrk
          (track.length >> 24) & 0xFF,
          (track.length >> 16) & 0xFF,
          (track.length >> 8) & 0xFF,
          track.length & 0xFF,
          ...track,
        ]);
        final events = MidiFileReader.read(bytes).allEvents
            .where((event) => !event.isMeta)
            .toList();
        expect(events.map((event) => event.status), <int>[
          0x90,
          0x80,
        ], reason: 'a 0x${realTime.toRadixString(16)} desynced the track');
        expect(events.first.data1, 60);
        expect(events.first.data2, 100);
      }
    });
  });

  group('meta text that latin-1 cannot hold', () {
    /// The payload of the first meta event of `metaType` in `bytes`.
    List<int> metaPayload(List<int> bytes, int metaType) {
      for (var i = 0; i + 2 < bytes.length; i++) {
        if (bytes[i] == 0xFF && bytes[i + 1] == metaType) {
          final length = bytes[i + 2];
          return bytes.sublist(i + 3, i + 3 + length);
        }
      }
      return const <int>[];
    }

    test('one unrepresentable character does not cost the others', () {
      // The fallback dropped to ASCII for the *whole* string, so a single
      // character latin-1 cannot hold took every accented one with it:
      // "Caf\u00e9 \u266d" came out "Caf " rather than "Caf\u00e9 ".
      final bytes = MidiFileWriter.write(
        ticksPerQuarter: 480,
        tracks: <List<MidiWriteEvent>>[
          <MidiWriteEvent>[MidiWriteEvent.trackName('Caf\u00e9 \u266d')],
        ],
      );
      expect(latin1.decode(metaPayload(bytes, 0x03)), 'Caf\u00e9 ');
    });

    test('a name latin-1 can hold survives whole', () {
      final bytes = MidiFileWriter.write(
        ticksPerQuarter: 480,
        tracks: <List<MidiWriteEvent>>[
          <MidiWriteEvent>[MidiWriteEvent.trackName('Caf\u00e9')],
        ],
      );
      expect(latin1.decode(metaPayload(bytes, 0x03)), 'Caf\u00e9');
    });
  });
}

/// Build a file byte by byte, for the cases the writer cannot produce.
Uint8List _rawFile(
  int division,
  List<List<int>> tracks, {
  int format = 1,
  int? declaredTracks,
}) {
  final out = <int>[
    ...'MThd'.codeUnits,
    0, 0, 0, 6, //
    (format >> 8) & 0xFF, format & 0xFF,
    ((declaredTracks ?? tracks.length) >> 8) & 0xFF,
    (declaredTracks ?? tracks.length) & 0xFF,
    (division >> 8) & 0xFF, division & 0xFF,
  ];
  for (final track in tracks) {
    out.addAll(<int>[
      ...'MTrk'.codeUnits,
      (track.length >> 24) & 0xFF,
      (track.length >> 16) & 0xFF,
      (track.length >> 8) & 0xFF,
      track.length & 0xFF,
      ...track,
    ]);
  }
  return Uint8List.fromList(out);
}
