import 'dart:typed_data';

import 'package:bandstand/io/json_support.dart' show SongFormatException;

/// A note, control change or meta event read from a Standard MIDI File.
///
/// Deliberately close to the file format rather than to Bandstand's own event
/// model: converting is a separate, testable step, and keeping the two apart
/// means a malformed file is diagnosed here rather than three layers down.
class MidiFileEvent implements Comparable<MidiFileEvent> {
  /// Create an event.
  const MidiFileEvent({
    required this.tick,
    required this.status,
    required this.channel,
    required this.data1,
    required this.data2,
    this.metaType,
    this.bytes,
  });

  /// Absolute position, in the file's own ticks.
  final int tick;

  /// The status nibble: 0x80 note off, 0x90 note on, and so on. 0xFF is meta.
  final int status;

  /// MIDI channel, 0–15. Meaningless for meta events.
  final int channel;

  /// First data byte: the key, the controller number, the program.
  final int data1;

  /// Second data byte: the velocity, the controller value.
  final int data2;

  /// Which meta event, when [status] is 0xFF.
  final int? metaType;

  /// The payload of a meta or system-exclusive event.
  final Uint8List? bytes;

  /// Whether this starts a note. A note on with zero velocity does not.
  bool get isNoteOn => status == 0x90 && data2 > 0;

  /// Whether this ends a note, either kind.
  bool get isNoteOff => status == 0x80 || (status == 0x90 && data2 == 0);

  /// Whether this is a meta event.
  bool get isMeta => status == 0xFF;

  /// The tempo this event sets, in beats per minute, or null.
  double? get tempoBpm {
    if (!isMeta || metaType != 0x51 || bytes == null || bytes!.length < 3) {
      return null;
    }
    final microseconds = (bytes![0] << 16) | (bytes![1] << 8) | bytes![2];
    return microseconds == 0 ? null : 60000000 / microseconds;
  }

  /// The time signature this event sets, or null.
  ///
  /// A denominator exponent past 15 is not a meter anyone writes; the event
  /// is noise, not something to shift 1 by.
  ({int upper, int lower})? get timeSignature {
    if (!isMeta || metaType != 0x58 || bytes == null || bytes!.length < 2) {
      return null;
    }
    if (bytes![1] > 15) {
      return null;
    }
    return (upper: bytes![0], lower: 1 << bytes![1]);
  }

  /// The text of a meta event that carries any: a track name, a marker.
  String? get text {
    if (!isMeta || bytes == null) {
      return null;
    }
    const textual = <int>{0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07};
    if (!textual.contains(metaType)) {
      return null;
    }
    return String.fromCharCodes(
      bytes!.where((byte) => byte >= 32 || byte == 10),
    );
  }

  @override
  int compareTo(MidiFileEvent other) => tick.compareTo(other.tick);

  @override
  String toString() =>
      'MidiFileEvent(tick $tick, status 0x${status.toRadixString(16)}, '
      'ch $channel, $data1, $data2)';
}

/// One track of a Standard MIDI File.
class MidiTrackData {
  /// Create a track.
  MidiTrackData({required this.name, required List<MidiFileEvent> events})
    : events = List<MidiFileEvent>.unmodifiable(events);

  /// The track's name, from its meta event, or an empty string.
  final String name;

  /// Its events, in tick order.
  final List<MidiFileEvent> events;

  /// The last tick anything happens at.
  int get lengthTicks => events.isEmpty
      ? 0
      : events.map((e) => e.tick).reduce((a, b) => a > b ? a : b);
}

/// A Standard MIDI File, read.
///
/// Format 0, 1 and 2 are all accepted; format 2's tracks are independent
/// sequences, and reading them as one is wrong, so it is rejected rather than
/// silently mangled.
class MidiFileData {
  /// Create a file.
  MidiFileData({
    required this.format,
    required this.ticksPerQuarter,
    required List<MidiTrackData> tracks,
  }) : tracks = List<MidiTrackData>.unmodifiable(tracks);

  /// 0 (one track), 1 (parallel tracks) or 2 (independent sequences).
  final int format;

  /// The file's tick resolution.
  final int ticksPerQuarter;

  /// Its tracks.
  final List<MidiTrackData> tracks;

  /// Every event from every track, in tick order.
  List<MidiFileEvent> get allEvents {
    final all = <MidiFileEvent>[for (final track in tracks) ...track.events]
      ..sort();
    return all;
  }

  /// The last tick anything happens at.
  int get lengthTicks => tracks.isEmpty
      ? 0
      : tracks.map((t) => t.lengthTicks).reduce((a, b) => a > b ? a : b);

  /// The tempo the file starts at, or 120 if it says nothing.
  double get initialTempoBpm {
    for (final event in allEvents) {
      final tempo = event.tempoBpm;
      if (tempo != null) {
        return tempo;
      }
    }
    return 120;
  }

  /// Every tempo change, as `(tick, bpm)`, in order.
  List<({int tick, double bpm})> get tempoChanges => <({int tick, double bpm})>[
    for (final event in allEvents)
      if (event.tempoBpm case final double bpm) (tick: event.tick, bpm: bpm),
  ];
}

/// Reads Standard MIDI Files.
///
/// Written by hand for the reasons in ADR 0001: the format is small, finished
/// and fully specified, and Bandstand needs both directions of it (§5.2 item 4,
/// §5.3).
abstract final class MidiFileReader {
  /// Read a Standard MIDI File.
  ///
  /// Throws [SongFormatException] if the bytes are not one, or are one this
  /// build cannot read.
  static MidiFileData read(Uint8List bytes) {
    final reader = _ByteReader(bytes);
    if (bytes.length < 14) {
      throw const SongFormatException('too short to be a MIDI file');
    }
    if (reader.tag() != 'MThd') {
      throw const SongFormatException('not a MIDI file: no MThd header');
    }
    final headerLength = reader.uint32();
    if (headerLength < 6) {
      throw const SongFormatException('the MThd header is too short');
    }
    final format = reader.uint16();
    final trackCount = reader.uint16();
    final division = reader.uint16();
    // Anything the header declares beyond the six bytes we understand.
    reader.skip(headerLength - 6);

    if (format > 2) {
      throw SongFormatException('unknown MIDI file format $format');
    }
    if (format == 2) {
      throw const SongFormatException(
        'format 2 files hold independent sequences, which Bandstand does not '
        'read as one song',
      );
    }
    if (division & 0x8000 != 0) {
      throw const SongFormatException(
        'SMPTE-timed MIDI files are not supported; this one is not in ticks '
        'per quarter note',
      );
    }
    if (division == 0) {
      throw const SongFormatException('the file claims zero ticks per quarter');
    }

    final tracks = <MidiTrackData>[];
    for (var index = 0; index < trackCount; index++) {
      if (reader.remaining < 8) {
        // A file that claims more tracks than it holds: read what is there.
        break;
      }
      final tag = reader.tag();
      final length = reader.uint32();
      if (tag != 'MTrk') {
        // Unknown chunks are skipped, as the specification requires.
        reader.skip(length);
        continue;
      }
      tracks.add(_readTrack(reader, length));
    }

    return MidiFileData(
      format: format,
      ticksPerQuarter: division,
      tracks: tracks,
    );
  }

  static MidiTrackData _readTrack(_ByteReader reader, int length) {
    final end = reader.offset + length;
    final events = <MidiFileEvent>[];
    var tick = 0;
    var runningStatus = 0;
    var name = '';

    while (reader.offset < end && reader.remaining > 0) {
      tick += reader.variableLength();
      var status = reader.byte();
      if (status < 0x80) {
        // Running status: the byte is data, and the last status still applies.
        reader.rewind(1);
        status = runningStatus;
        if (status == 0) {
          throw const SongFormatException(
            'a track begins with data and no status byte',
          );
        }
      } else if (status < 0xF0) {
        runningStatus = status;
      }

      if (status == 0xFF) {
        // A meta event cancels any running status, as the specification
        // requires: the next event carries its own status byte.
        runningStatus = 0;
        final metaType = reader.byte();
        final metaLength = reader.variableLength();
        final payload = reader.take(metaLength);
        if (metaType == 0x03 && name.isEmpty) {
          name = String.fromCharCodes(payload.where((byte) => byte >= 32));
        }
        events.add(
          MidiFileEvent(
            tick: tick,
            status: 0xFF,
            channel: 0,
            data1: 0,
            data2: 0,
            metaType: metaType,
            bytes: payload,
          ),
        );
        if (metaType == 0x2F) {
          break; // End of track.
        }
        continue;
      }

      if (status == 0xF0 || status == 0xF7) {
        // System exclusive: read past it. Bandstand has no use for it, and a
        // file full of them must still open. Like a meta event, it cancels
        // any running status.
        runningStatus = 0;
        reader.skip(reader.variableLength());
        continue;
      }

      if (status >= 0xF1 && status <= 0xFE) {
        // System common and system real-time, with data lengths fixed by the
        // specification. Carried past like sysex — Bandstand has no use for
        // them — but the bytes must be stepped over exactly or everything
        // after desyncs.
        //
        // 0xF8–0xFE (clock, start, continue, stop, active sensing) used to
        // fall through to the channel-event path below, where `status & 0xF0`
        // made them look like a note and two bytes belonging to the *next*
        // event were eaten. They carry no data at all.
        //
        // System real-time does not clear running status — it may be
        // interleaved anywhere, including inside another message — while
        // system common does.
        const dataBytes = <int, int>{
          0xF1: 1, // MIDI Time Code
          0xF2: 2, // Song Position Pointer
          0xF3: 1, // Song Select
          0xF4: 0, // reserved
          0xF5: 0, // reserved
          0xF6: 0, // Tune Request
          0xF8: 0, // Timing Clock
          0xF9: 0, // reserved
          0xFA: 0, // Start
          0xFB: 0, // Continue
          0xFC: 0, // Stop
          0xFD: 0, // reserved
          0xFE: 0, // Active Sensing
        };
        if (status <= 0xF6) {
          runningStatus = 0;
        }
        reader.skip(dataBytes[status]!);
        continue;
      }

      final kind = status & 0xF0;
      final channel = status & 0x0F;
      final data1 = reader.byte();
      final data2 = (kind == 0xC0 || kind == 0xD0) ? 0 : reader.byte();
      events.add(
        MidiFileEvent(
          tick: tick,
          status: kind,
          channel: channel,
          data1: data1,
          data2: data2,
        ),
      );
    }

    // Skip any bytes the track declared but did not use.
    if (reader.offset < end) {
      reader.skip(end - reader.offset);
    }
    return MidiTrackData(name: name, events: events);
  }
}

/// A cursor over bytes, which fails with a message rather than a range error.
class _ByteReader {
  _ByteReader(this.bytes);

  final Uint8List bytes;
  int offset = 0;

  int get remaining => bytes.length - offset;

  void _need(int count) {
    if (offset + count > bytes.length) {
      throw SongFormatException(
        'the file ends in the middle of a structure: $count more bytes needed, '
        '$remaining left',
      );
    }
  }

  int byte() {
    _need(1);
    return bytes[offset++];
  }

  void rewind(int count) => offset -= count;

  void skip(int count) {
    if (count <= 0) {
      return;
    }
    offset = (offset + count).clamp(0, bytes.length);
  }

  Uint8List take(int count) {
    _need(count);
    final slice = Uint8List.sublistView(bytes, offset, offset + count);
    offset += count;
    return slice;
  }

  String tag() {
    _need(4);
    final text = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    offset += 4;
    return text;
  }

  int uint16() {
    _need(2);
    final value = (bytes[offset] << 8) | bytes[offset + 1];
    offset += 2;
    return value;
  }

  int uint32() {
    _need(4);
    final value =
        (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
    offset += 4;
    return value;
  }

  /// A MIDI variable-length quantity: seven bits a byte, high bit continues.
  int variableLength() {
    var value = 0;
    for (var read = 0; read < 4; read++) {
      final byte = this.byte();
      value = (value << 7) | (byte & 0x7F);
      if (byte & 0x80 == 0) {
        return value;
      }
    }
    throw const SongFormatException(
      'a variable-length quantity is longer than four bytes',
    );
  }
}
