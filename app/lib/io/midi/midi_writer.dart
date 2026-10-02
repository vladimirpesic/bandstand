import 'dart:convert';
import 'dart:typed_data';

/// One event to write, at an absolute tick.
class MidiWriteEvent {
  /// Create an event.
  const MidiWriteEvent({
    required this.tick,
    required this.bytes,
    this.order = 1,
  });

  /// A note on.
  factory MidiWriteEvent.noteOn(int tick, int channel, int key, int velocity) =>
      MidiWriteEvent(
        tick: tick,
        bytes: <int>[0x90 | (channel & 0x0F), key & 0x7F, velocity & 0x7F],
        order: 2,
      );

  /// A note off.
  factory MidiWriteEvent.noteOff(int tick, int channel, int key) =>
      MidiWriteEvent(
        tick: tick,
        bytes: <int>[0x80 | (channel & 0x0F), key & 0x7F, 0],
      );

  /// A program change.
  factory MidiWriteEvent.program(int tick, int channel, int program) =>
      MidiWriteEvent(
        tick: tick,
        bytes: <int>[0xC0 | (channel & 0x0F), program & 0x7F],
      );

  /// A control change.
  factory MidiWriteEvent.control(
    int tick,
    int channel,
    int controller,
    int value,
  ) => MidiWriteEvent(
    tick: tick,
    bytes: <int>[0xB0 | (channel & 0x0F), controller & 0x7F, value & 0x7F],
  );

  /// A tempo, in beats per minute.
  factory MidiWriteEvent.tempo(int tick, double bpm) {
    final microseconds = (60000000 / bpm).round().clamp(1, 0xFFFFFF);
    return MidiWriteEvent(
      tick: tick,
      bytes: <int>[
        0xFF,
        0x51,
        0x03,
        (microseconds >> 16) & 0xFF,
        (microseconds >> 8) & 0xFF,
        microseconds & 0xFF,
      ],
      order: 0,
    );
  }

  /// A time signature.
  factory MidiWriteEvent.timeSignature(int tick, int upper, int lower) {
    var power = 0;
    var value = lower;
    while (value > 1) {
      value >>= 1;
      power++;
    }
    return MidiWriteEvent(
      tick: tick,
      bytes: <int>[0xFF, 0x58, 0x04, upper, power, 24, 8],
      order: 0,
    );
  }

  /// A marker, for labelling song parts (§5.3).
  factory MidiWriteEvent.marker(int tick, String text) =>
      MidiWriteEvent(tick: tick, bytes: _text(0x06, text), order: 0);

  /// A track name.
  factory MidiWriteEvent.trackName(String text) =>
      MidiWriteEvent(tick: 0, bytes: _text(0x03, text), order: 0);

  /// Meta-event text is latin-1 in the file format. A character that fits
  /// (é, ü) survives the round trip; one that does not (♭) is dropped rather
  /// than making the export fail.
  ///
  /// The fallback keeps everything latin-1 *can* hold. It used to fall back to
  /// ASCII for the whole string, so one unrepresentable character cost every
  /// accented one beside it: "Café ♭" was written "Caf " rather than "Café ".
  static List<int> _text(int metaType, String text) {
    List<int> payload;
    try {
      payload = latin1.encode(text);
    } on ArgumentError {
      payload = text.codeUnits.where((unit) => unit < 256).toList();
    }
    return <int>[
      0xFF,
      metaType,
      ..._variableLength(payload.length),
      ...payload,
    ];
  }

  /// Where it happens.
  final int tick;

  /// The bytes to write, status included.
  final List<int> bytes;

  /// How events at the same tick are ordered: meta first, then controllers and
  /// note offs, then note ons — so a note is let go before the same key is
  /// struck again.
  final int order;
}

/// Writes Standard MIDI Files (§5.3).
abstract final class MidiFileWriter {
  /// Write a format 1 file: one conductor track, then one per channel given.
  ///
  /// Events are sorted, so callers can build them in whatever order suits.
  static Uint8List write({
    required int ticksPerQuarter,
    required List<List<MidiWriteEvent>> tracks,
  }) {
    final out = BytesBuilder()
      ..add(<int>[0x4D, 0x54, 0x68, 0x64]) // MThd
      ..add(_uint32(6))
      ..add(_uint16(1)) // format 1
      ..add(_uint16(tracks.length))
      ..add(_uint16(ticksPerQuarter));
    for (final track in tracks) {
      out.add(_track(track));
    }
    return out.toBytes();
  }

  static Uint8List _track(List<MidiWriteEvent> events) {
    final sorted = <MidiWriteEvent>[...events]
      ..sort((a, b) {
        final byTick = a.tick.compareTo(b.tick);
        return byTick != 0 ? byTick : a.order.compareTo(b.order);
      });

    final body = BytesBuilder();
    var previous = 0;
    for (final event in sorted) {
      body
        ..add(_variableLength(event.tick - previous))
        ..add(event.bytes);
      previous = event.tick;
    }
    body
      ..add(_variableLength(0))
      ..add(<int>[0xFF, 0x2F, 0x00]); // end of track

    final bytes = body.toBytes();
    return (BytesBuilder()
          ..add(<int>[0x4D, 0x54, 0x72, 0x6B]) // MTrk
          ..add(_uint32(bytes.length))
          ..add(bytes))
        .toBytes();
  }

  static List<int> _uint16(int value) => <int>[
    (value >> 8) & 0xFF,
    value & 0xFF,
  ];

  static List<int> _uint32(int value) => <int>[
    (value >> 24) & 0xFF,
    (value >> 16) & 0xFF,
    (value >> 8) & 0xFF,
    value & 0xFF,
  ];
}

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
