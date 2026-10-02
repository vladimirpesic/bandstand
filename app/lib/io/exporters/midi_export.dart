import 'dart:typed_data';

import 'package:bandstand/domain/generation/song_generator.dart';
import 'package:bandstand/domain/harmony/time_signature.dart';
import 'package:bandstand/domain/song/mixer_settings.dart';
import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/domain/song/song_chord_sequence.dart';
import 'package:bandstand/io/midi/midi_writer.dart';

/// Writes a generated song as a Standard MIDI File.
///
/// Rules: `docs/rules/exporters.md` §2. This exports what Bandstand **played**,
/// not what the player wrote: rerolling the bass gives a different file, and
/// that is correct.
abstract final class MidiExporter {
  /// The General MIDI percussion channel.
  static const int drumChannel = 9;

  /// Write `generated` as a format-1 file.
  ///
  /// A conductor track carries the tempo, the meter and a marker per song part;
  /// then one track per voice, named, with its program at the top so the file
  /// sounds like something opened without Bandstand's soundbank.
  static Uint8List export(Song song, GeneratedSong generated) {
    final ppq = generated.ppq;
    // The same flattening playback uses, so the markers and the meters land on
    // the bars the notes were actually written against. Deriving them from
    // `song.timeSignature` and a bar number assumed every bar was the length
    // of the first one, which put every mark after a meter change in the wrong
    // place.
    final sequence = SongChordSequence.of(song);

    return MidiFileWriter.write(
      ticksPerQuarter: ppq,
      tracks: <List<MidiWriteEvent>>[
        _conductor(song, sequence, ppq),
        for (final voice in generated.voices)
          _voiceTrack(voice, song.mixer, ppq),
      ],
    );
  }

  /// Tempo, meter, and a marker where each song part begins.
  ///
  /// §5.3 asks for the markers by name, and they are what makes an exported
  /// file navigable in a DAW rather than four minutes of undifferentiated
  /// notes.
  static List<MidiWriteEvent> _conductor(
    Song song,
    SongChordSequence sequence,
    int ppq,
  ) {
    final events = <MidiWriteEvent>[
      MidiWriteEvent.trackName(song.title),
      MidiWriteEvent.tempo(0, song.tempo.toDouble()),
    ];

    // A meter event wherever the meter changes, not one global one: a DAW
    // reading a single 4/4 at tick 0 bars a 6/8 passage wrongly for the rest
    // of the file.
    TimeSignature? running;
    for (final bar in sequence.bars) {
      if (bar.timeSignature == running) {
        continue;
      }
      running = bar.timeSignature;
      events.add(
        MidiWriteEvent.timeSignature(
          (bar.startQuarters * ppq).round(),
          running.upper,
          running.lower,
        ),
      );
    }
    if (running == null) {
      // No bars at all — an empty arrangement still needs a meter.
      events.add(
        MidiWriteEvent.timeSignature(
          0,
          song.timeSignature.upper,
          song.timeSignature.lower,
        ),
      );
    }

    for (var index = 0; index < song.structure.songParts.length; index++) {
      final bars = sequence.barsOfPart(index);
      if (bars.isEmpty) {
        continue;
      }
      events.add(
        MidiWriteEvent.marker(
          (bars.first.startQuarters * ppq).round(),
          song.structure.songParts[index].displayName,
        ),
      );
    }
    return events;
  }

  /// One voice's notes, with its name and its patch.
  static List<MidiWriteEvent> _voiceTrack(
    GeneratedVoice voice,
    MixerSettings mixer,
    int ppq,
  ) {
    final settings = mixer.channelFor(voice.voice.id);
    final channel = voice.channel;
    final events = <MidiWriteEvent>[
      MidiWriteEvent.trackName(voice.voice.displayName),
      // Bank first, then program: a bank select after a program change selects
      // nothing until the next one.
      MidiWriteEvent.control(0, channel, 0, settings.midiBank >> 7),
      MidiWriteEvent.control(0, channel, 32, settings.midiBank & 0x7F),
      MidiWriteEvent.program(0, channel, settings.midiProgram),
    ];

    for (final note in voice.phrase.notes) {
      // The phrase is already in quarter notes (`GeneratedVoice.phrase`), so
      // there is no meter in this conversion at all. Scaling by the song's
      // bar-0 beat length used to be how a 6/8 song came out right and a
      // mixed-meter one came out wrong.
      final start = (note.positionInBeats * ppq).round();
      final end = (note.endInBeats * ppq).round();
      // A note that rounds to nothing still has to sound: a zero-length note is
      // a note-off before its note-on, which some readers drop and others
      // treat as a stuck note.
      final off = end > start ? end : start + 1;
      final pitch = (note.pitch + settings.transpose).clamp(0, 127);
      events
        ..add(MidiWriteEvent.noteOn(start, channel, pitch, note.velocity))
        ..add(MidiWriteEvent.noteOff(off, channel, pitch));
    }
    return events;
  }
}
