import 'package:bandstand/bridge/api/audio.dart';
import 'package:bandstand/domain/generation/song_generator.dart';
import 'package:bandstand/domain/song/mixer_settings.dart';
import 'package:bandstand/io/midi/midi_file.dart';

/// A sequence ready to hand to the audio engine.
class BuiltSequence {
  /// Create a built sequence.
  const BuiltSequence({
    required this.events,
    required this.ppq,
    required this.lengthTicks,
    required this.tempoMarkers,
    required this.initialTempoBpm,
  });

  /// The events, in whatever order they were built; Rust sorts them.
  final List<MidiEvent> events;

  /// Ticks per quarter note.
  final int ppq;

  /// How long the sequence lasts, in ticks.
  final BigInt lengthTicks;

  /// The tempo map, as markers.
  final List<TempoMarker> tempoMarkers;

  /// The tempo it starts at.
  final double initialTempoBpm;

  /// How many events there are.
  int get length => events.length;
}

/// Turns a Standard MIDI File into something the engine can play.
///
/// This is the Dart half of the §3 boundary: Dart builds the whole sequence,
/// Rust plays it. Nothing here knows about samples, and nothing in Rust knows
/// about files.
abstract final class MidiSequenceBuilder {
  /// The controller number for channel volume.
  static const int volumeController = 7;

  /// The controller number for pan.
  static const int panController = 10;

  /// The controller number for expression.
  static const int expressionController = 11;

  /// The controller number for the sustain pedal.
  static const int sustainController = 64;

  /// The controller number for "all notes off".
  static const int allNotesOffController = 123;

  /// Build a sequence from a read MIDI file.
  static BuiltSequence fromMidiFile(MidiFileData file) {
    final events = <MidiEvent>[];

    for (final event in file.allEvents) {
      final kind = _kindOf(event);
      if (kind == null) {
        continue;
      }
      events.add(
        MidiEvent(
          tick: BigInt.from(event.tick),
          channel: event.channel,
          kind: kind,
          data1: _data1(event, kind),
          data2: _data2(event, kind),
        ),
      );
    }

    final markers = <TempoMarker>[
      for (final change in file.tempoChanges)
        TempoMarker(tick: BigInt.from(change.tick), bpm: change.bpm),
    ];
    if (markers.isEmpty || markers.first.tick != BigInt.zero) {
      markers.insert(
        0,
        TempoMarker(tick: BigInt.zero, bpm: file.initialTempoBpm),
      );
    }

    return BuiltSequence(
      events: events,
      ppq: file.ticksPerQuarter,
      lengthTicks: BigInt.from(file.lengthTicks),
      tempoMarkers: markers,
      initialTempoBpm: file.initialTempoBpm,
    );
  }

  static MidiEventKind? _kindOf(MidiFileEvent event) {
    if (event.isMeta) {
      return null;
    }
    switch (event.status) {
      case 0x90:
        // A note on with zero velocity is a note off, and saying so here means
        // nothing downstream has to know that.
        return event.data2 == 0 ? MidiEventKind.noteOff : MidiEventKind.noteOn;
      case 0x80:
        return MidiEventKind.noteOff;
      case 0xC0:
        return MidiEventKind.program;
      case 0xE0:
        return MidiEventKind.pitchBend;
      case 0xB0:
        return switch (event.data1) {
          volumeController => MidiEventKind.volume,
          panController => MidiEventKind.pan,
          expressionController => MidiEventKind.expression,
          sustainController => MidiEventKind.sustain,
          allNotesOffController => MidiEventKind.allNotesOff,
          // Every other controller is one Bandstand's synth has no answer for;
          // dropping it is better than pretending.
          _ => null,
        };
      default:
        return null;
    }
  }

  static int _data1(MidiFileEvent event, MidiEventKind kind) => switch (kind) {
    MidiEventKind.noteOn || MidiEventKind.noteOff => event.data1,
    // A program change carries the program in data1 and the bank in data2;
    // bank select is a controller pair Bandstand does not read, so a file's
    // drum track is placed by its channel instead (§ General MIDI).
    MidiEventKind.program => event.data1,
    MidiEventKind.pitchBend => 0,
    _ => event.data1,
  };

  static int _data2(MidiFileEvent event, MidiEventKind kind) => switch (kind) {
    MidiEventKind.noteOn || MidiEventKind.noteOff => event.data2,
    // General MIDI puts percussion on channel 10, and every soundfont keeps
    // its kits in bank 128.
    MidiEventKind.program => event.channel == 9 ? 128 : 0,
    // Pitch bend is fourteen bits, low seven then high seven.
    MidiEventKind.pitchBend => (event.data2 << 7) | event.data1,
    _ => event.data2,
  };
}

/// Turns a generated song into a sequence for the engine.
///
/// The other half of the §3 boundary: the domain writes phrases in quarter
/// notes, and this converts them to ticks and MIDI. Nothing in the domain knows
/// what a MIDI channel is for; nothing here knows what a chord is.
extension GeneratedSongSequence on GeneratedSong {
  /// Build a sequence, taking each voice's instrument from the mixer.
  BuiltSequence toSequence(MixerSettings mixer, {required int tempoBpm}) {
    final events = <MidiEvent>[];

    for (final voice in voices) {
      if (!mixer.isAudible(voice.voice.id)) {
        // Muted and soloed-out voices are left out of the sequence entirely:
        // silencing them at the synth would still cost the voices.
        continue;
      }
      final settings = mixer.channelFor(voice.voice.id);
      events.add(
        MidiEvent(
          tick: BigInt.zero,
          channel: voice.channel,
          kind: MidiEventKind.program,
          data1: settings.midiProgram,
          data2: voice.voice.isDrums ? 128 : settings.midiBank,
        ),
      );
      for (final note in voice.phrase.notes) {
        // `GeneratedVoice.phrase` is in quarter notes, and `ppq` is ticks per
        // quarter note, so this is the whole conversion. It is only true
        // because `SongGenerator` converted each part out of its own meter's
        // beats on the way in — multiplying a 6/8 part's eighth-note positions
        // by ticks-per-*quarter* played it at half speed.
        final start = _tick(note.positionInBeats, ppq);
        final end = _tick(note.endInBeats, ppq);
        events
          ..add(
            MidiEvent(
              tick: BigInt.from(start),
              channel: voice.channel,
              kind: MidiEventKind.noteOn,
              data1: note.pitch,
              data2: note.velocity,
            ),
          )
          ..add(
            MidiEvent(
              tick: BigInt.from(end > start ? end : start + 1),
              channel: voice.channel,
              kind: MidiEventKind.noteOff,
              data1: note.pitch,
              data2: 0,
            ),
          );
      }
    }

    return BuiltSequence(
      events: events,
      ppq: ppq,
      lengthTicks: BigInt.from(lengthTicks),
      tempoMarkers: <TempoMarker>[
        TempoMarker(tick: BigInt.zero, bpm: tempoBpm.toDouble()),
      ],
      initialTempoBpm: tempoBpm.toDouble(),
    );
  }

  /// `quarters` as a tick count at `ppq` ticks per quarter note.
  static int _tick(double quarters, int ppq) => (quarters * ppq).round();
}
