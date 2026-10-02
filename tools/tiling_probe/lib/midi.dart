import 'dart:typed_data';

/// Ticks per quarter note in the files this writer produces.
const int ticksPerQuarter = 480;

/// One MIDI event at an absolute tick.
class _TimedEvent {
  _TimedEvent(this.tick, this.order, this.bytes);

  final int tick;

  /// Tie-break within a tick: note-offs (0) before program changes (1) before
  /// note-ons (2), so a repeated pitch is released before it is restruck.
  final int order;

  final List<int> bytes;
}

/// A single track being assembled.
class MidiTrack {
  MidiTrack(this.name);

  /// Track name, written as a meta event.
  final String name;

  final List<_TimedEvent> _events = <_TimedEvent>[];

  /// Set the tempo, in beats per minute, at `tick`.
  void tempo(double bpm, {int tick = 0}) {
    final microsecondsPerQuarter = (60000000 / bpm).round();
    _events.add(
      _TimedEvent(tick, 1, <int>[
        0xFF,
        0x51,
        0x03,
        (microsecondsPerQuarter >> 16) & 0xFF,
        (microsecondsPerQuarter >> 8) & 0xFF,
        microsecondsPerQuarter & 0xFF,
      ]),
    );
  }

  /// Set the time signature at `tick`.
  void timeSignature(int upper, int lower, {int tick = 0}) {
    var denominatorPower = 0;
    var value = lower;
    while (value > 1) {
      value >>= 1;
      denominatorPower++;
    }
    _events.add(
      _TimedEvent(tick, 1, <int>[
        0xFF,
        0x58,
        0x04,
        upper,
        denominatorPower,
        24,
        8,
      ]),
    );
  }

  /// Write a marker meta event, used to label song sections.
  void marker(String text, {required int tick}) {
    final bytes = <int>[0xFF, 0x06, ..._lengthPrefixed(text)];
    _events.add(_TimedEvent(tick, 1, bytes));
  }

  /// Select a General MIDI program on `channel`.
  void program(int channel, int program, {int tick = 0}) {
    _events.add(_TimedEvent(tick, 1, <int>[0xC0 | (channel & 0x0F), program]));
  }

  /// Add a note.
  void note({
    required int channel,
    required int pitch,
    required int velocity,
    required int startTick,
    required int durationTicks,
  }) {
    final safePitch = pitch.clamp(0, 127);
    final safeVelocity = velocity.clamp(1, 127);
    _events
      ..add(
        _TimedEvent(startTick, 2, <int>[
          0x90 | (channel & 0x0F),
          safePitch,
          safeVelocity,
        ]),
      )
      ..add(
        _TimedEvent(startTick + durationTicks.clamp(1, 1 << 24), 0, <int>[
          0x80 | (channel & 0x0F),
          safePitch,
          0,
        ]),
      );
  }

  Uint8List _encode() {
    final body = BytesBuilder();
    body
      ..add(_variableLength(0))
      ..add(<int>[0xFF, 0x03, ..._lengthPrefixed(name)]);

    final ordered = <_TimedEvent>[..._events]
      ..sort((a, b) {
        final byTick = a.tick.compareTo(b.tick);
        return byTick != 0 ? byTick : a.order.compareTo(b.order);
      });

    var previousTick = 0;
    for (final event in ordered) {
      body
        ..add(_variableLength(event.tick - previousTick))
        ..add(event.bytes);
      previousTick = event.tick;
    }
    body
      ..add(_variableLength(0))
      ..add(<int>[0xFF, 0x2F, 0x00]);

    final bytes = body.toBytes();
    final chunk = BytesBuilder()
      ..add(<int>[0x4D, 0x54, 0x72, 0x6B]) // "MTrk"
      ..add(_uint32(bytes.length))
      ..add(bytes);
    return chunk.toBytes();
  }
}

/// A Standard MIDI File, format 1.
class MidiFile {
  /// The tracks, in order. Track 0 is conventionally tempo and meta only.
  final List<MidiTrack> tracks = <MidiTrack>[];

  /// Add a track and return it.
  MidiTrack addTrack(String name) {
    final track = MidiTrack(name);
    tracks.add(track);
    return track;
  }

  /// Encode the whole file.
  Uint8List encode() {
    final out = BytesBuilder()
      ..add(<int>[0x4D, 0x54, 0x68, 0x64]) // "MThd"
      ..add(_uint32(6))
      ..add(<int>[0x00, 0x01]) // format 1
      ..add(<int>[(tracks.length >> 8) & 0xFF, tracks.length & 0xFF])
      ..add(<int>[(ticksPerQuarter >> 8) & 0xFF, ticksPerQuarter & 0xFF]);
    for (final track in tracks) {
      out.add(track._encode());
    }
    return out.toBytes();
  }
}

List<int> _uint32(int value) => <int>[
  (value >> 24) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 8) & 0xFF,
  value & 0xFF,
];

/// MIDI variable-length quantity.
List<int> _variableLength(int value) {
  if (value < 0) {
    throw ArgumentError.value(value, 'value', 'delta times cannot be negative');
  }
  final bytes = <int>[value & 0x7F];
  var remaining = value >> 7;
  while (remaining > 0) {
    bytes.insert(0, (remaining & 0x7F) | 0x80);
    remaining >>= 7;
  }
  return bytes;
}

List<int> _lengthPrefixed(String text) {
  final bytes = text.codeUnits.where((c) => c < 128).toList();
  return <int>[..._variableLength(bytes.length), ...bytes];
}
