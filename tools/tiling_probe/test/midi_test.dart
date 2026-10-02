import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:tiling_probe/corpus.dart';
import 'package:tiling_probe/midi.dart';
import 'package:tiling_probe/render.dart';
import 'package:tiling_probe/tiler.dart';

/// Just enough of a Standard MIDI File reader to prove the writer emits one.
///
/// Reading back what you wrote is the only way to know a binary format is
/// right; a file that a DAW silently refuses to open would otherwise look like
/// a tiling bug.
class _Reader {
  _Reader(this.bytes);

  final Uint8List bytes;
  int offset = 0;

  int byte() => bytes[offset++];

  int uint16() => (byte() << 8) | byte();

  int uint32() => (byte() << 24) | (byte() << 16) | (byte() << 8) | byte();

  String tag() => String.fromCharCodes(<int>[byte(), byte(), byte(), byte()]);

  int variableLength() {
    var value = 0;
    while (true) {
      final b = byte();
      value = (value << 7) | (b & 0x7F);
      if (b & 0x80 == 0) {
        return value;
      }
    }
  }
}

class _ParsedFile {
  _ParsedFile(this.format, this.division, this.tracks);
  final int format;
  final int division;
  final List<List<_ParsedEvent>> tracks;
}

class _ParsedEvent {
  _ParsedEvent(this.tick, this.status, this.data);
  final int tick;
  final int status;
  final List<int> data;
}

_ParsedFile _parseSmf(Uint8List bytes) {
  final reader = _Reader(bytes);
  expect(reader.tag(), 'MThd');
  expect(reader.uint32(), 6);
  final format = reader.uint16();
  final trackCount = reader.uint16();
  final division = reader.uint16();

  final tracks = <List<_ParsedEvent>>[];
  for (var t = 0; t < trackCount; t++) {
    expect(reader.tag(), 'MTrk');
    final length = reader.uint32();
    final end = reader.offset + length;
    final events = <_ParsedEvent>[];
    var tick = 0;
    var running = 0;
    var sawEndOfTrack = false;
    while (reader.offset < end) {
      tick += reader.variableLength();
      var status = reader.byte();
      if (status < 0x80) {
        reader.offset--;
        status = running;
      } else if (status < 0xF0) {
        running = status;
      }
      if (status == 0xFF) {
        final type = reader.byte();
        final dataLength = reader.variableLength();
        final data = <int>[for (var i = 0; i < dataLength; i++) reader.byte()];
        events.add(_ParsedEvent(tick, 0xFF00 | type, data));
        if (type == 0x2F) {
          sawEndOfTrack = true;
        }
      } else {
        final dataLength = switch (status & 0xF0) {
          0xC0 || 0xD0 => 1,
          _ => 2,
        };
        final data = <int>[for (var i = 0; i < dataLength; i++) reader.byte()];
        events.add(_ParsedEvent(tick, status, data));
      }
    }
    expect(sawEndOfTrack, isTrue, reason: 'track $t has no end-of-track');
    expect(reader.offset, end, reason: 'track $t length is wrong');
    tracks.add(events);
  }
  expect(
    reader.offset,
    bytes.length,
    reason: 'trailing bytes after the tracks',
  );
  return _ParsedFile(format, division, tracks);
}

void main() {
  Progression form() => Progression('short', <String>[
    'Cmaj7', 'A7', 'Dm7', 'G7', //
  ]);

  Uint8List render({RenderOptions options = const RenderOptions()}) {
    final progression = form().repeated(2);
    final tiling = Tiler(probeCorpus()).tile(progression);
    return renderTiling(
      tiling: tiling,
      progression: progression,
      formBars: 4,
      options: options,
    ).encode();
  }

  test('writes a well-formed format 1 file that reads back', () {
    final parsed = _parseSmf(render());
    expect(parsed.format, 1);
    expect(parsed.division, ticksPerQuarter);
    // Conductor, bass, guide.
    expect(parsed.tracks, hasLength(3));
  });

  test('the conductor track carries tempo, meter and chorus markers', () {
    final conductor = _parseSmf(render()).tracks.first;
    expect(conductor.any((e) => e.status == 0xFF51), isTrue, reason: 'tempo');
    expect(conductor.any((e) => e.status == 0xFF58), isTrue, reason: 'meter');
    expect(conductor.where((e) => e.status == 0xFF06), hasLength(2));
  });

  test('every note-on is matched by a note-off', () {
    for (final track in _parseSmf(render()).tracks) {
      final open = <int, int>{};
      for (final event in track) {
        final kind = event.status & 0xF0;
        if (kind == 0x90 && event.data[1] > 0) {
          open[event.data[0]] = (open[event.data[0]] ?? 0) + 1;
        } else if (kind == 0x80 || (kind == 0x90 && event.data[1] == 0)) {
          open[event.data[0]] = (open[event.data[0]] ?? 0) - 1;
        }
      }
      for (final entry in open.entries) {
        expect(entry.value, 0, reason: 'pitch ${entry.key} left hanging');
      }
    }
  });

  test('a released note precedes a restrike at the same tick', () {
    for (final track in _parseSmf(render()).tracks) {
      final sounding = <int>{};
      for (final event in track) {
        final kind = event.status & 0xF0;
        if (kind == 0x90 && event.data[1] > 0) {
          expect(
            sounding.contains(event.data[0]),
            isFalse,
            reason: 'pitch ${event.data[0]} restruck while sounding',
          );
          sounding.add(event.data[0]);
        } else if (kind == 0x80 || (kind == 0x90 && event.data[1] == 0)) {
          sounding.remove(event.data[0]);
        }
      }
    }
  });

  test('deltas never go backwards', () {
    for (final track in _parseSmf(render()).tracks) {
      var previous = 0;
      for (final event in track) {
        expect(event.tick, greaterThanOrEqualTo(previous));
        previous = event.tick;
      }
    }
  });

  test('the bass is on the acoustic bass program', () {
    final bass = _parseSmf(render()).tracks[1];
    final program = bass.firstWhere((e) => e.status & 0xF0 == 0xC0);
    expect(program.data.first, 32);
  });

  test('the click and guide tracks appear only when asked for', () {
    expect(
      _parseSmf(render(options: const RenderOptions(guideChords: false)))
          .tracks,
      hasLength(2),
    );
    expect(
      _parseSmf(render(options: const RenderOptions(click: true))).tracks,
      hasLength(4),
    );
  });

  test('humanisation is deterministic for a seed', () {
    const options = RenderOptions(humanize: true, seed: 7);
    expect(render(options: options), render(options: options));
    expect(
      render(options: options),
      isNot(render(options: const RenderOptions(humanize: true, seed: 8))),
    );
  });
}
