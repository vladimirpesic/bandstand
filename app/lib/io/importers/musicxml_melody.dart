import 'package:xml/xml.dart';

import 'package:bandstand/domain/song/written_part.dart';

/// Reads a written part out of a MusicXML score (§5 of
/// `docs/rules/written-parts.md`).
///
/// Kept apart from the chord importer because they read different things from
/// the same file and share nothing but the tree: the chord importer reads
/// `<harmony>`, this reads `<note>`, and a bug in one has no business breaking
/// the other.
abstract final class MusicXmlMelody {
  /// A General MIDI flute — a clear, unobtrusive melody voice, and the default
  /// when the file does not say what the part is.
  static const int defaultProgram = 73;

  /// The written part in [root], or null when the score has no notes worth
  /// keeping.
  ///
  /// Takes the first part that has pitched notes and is not percussion: a
  /// piano-vocal score's vocal line, a lead sheet's melody, a horn chart's
  /// horn. Anything after the first is dropped, and [problems] says so — one
  /// part is what a chart carries, and choosing between three is the human's.
  /// Within the part it keeps, only voice 1 is read; the rest of a
  /// multi-voice texture is dropped with a report, not merged into the line.
  static WrittenPart? read(
    XmlElement root, {
    required String id,
    required List<String> problems,
  }) {
    final parts = root.findElements('part').toList();
    if (parts.isEmpty) {
      return null;
    }

    final withNotes = <XmlElement>[
      for (final part in parts)
        if (_hasPitchedNotes(part)) part,
    ];
    if (withNotes.isEmpty) {
      return null;
    }
    if (withNotes.length > 1) {
      final names = withNotes.map((part) => _nameOf(root, part)).join(', ');
      problems.add(
        'this score has more than one part with notes in it ($names); '
        'Bandstand kept the first',
      );
    }

    final chosen = withNotes.first;
    final notes = _readNotes(chosen, problems);
    if (notes.isEmpty) {
      return null;
    }

    return WrittenPart(
      id: id,
      displayName: _nameOf(root, chosen),
      notes: notes,
      program: _programOf(root, chosen),
    );
  }

  static bool _hasPitchedNotes(XmlElement part) {
    for (final measure in part.findElements('measure')) {
      for (final note in measure.findElements('note')) {
        if (note.findElements('pitch').isNotEmpty &&
            note.findElements('rest').isEmpty) {
          return true;
        }
      }
    }
    return false;
  }

  /// The part's name, from `<score-part>` in the header.
  static String _nameOf(XmlElement root, XmlElement part) {
    final id = part.getAttribute('id');
    if (id != null) {
      for (final scorePart in root.findAllElements('score-part')) {
        if (scorePart.getAttribute('id') != id) {
          continue;
        }
        final name = scorePart
            .findElements('part-name')
            .firstOrNull
            ?.innerText
            .trim();
        if (name != null && name.isNotEmpty) {
          return name;
        }
      }
    }
    return 'Melody';
  }

  /// The General MIDI program from `<midi-instrument>`, or the default.
  ///
  /// MusicXML numbers programs from 1 and MIDI from 0, which is a classic
  /// off-by-one; the file says 74 for the flute that MIDI calls 73.
  static int _programOf(XmlElement root, XmlElement part) {
    final id = part.getAttribute('id');
    if (id == null) {
      return defaultProgram;
    }
    for (final scorePart in root.findAllElements('score-part')) {
      if (scorePart.getAttribute('id') != id) {
        continue;
      }
      for (final instrument in scorePart.findElements('midi-instrument')) {
        final text = instrument
            .findElements('midi-program')
            .firstOrNull
            ?.innerText
            .trim();
        final program = int.tryParse(text ?? '');
        if (program != null && program >= 1 && program <= 128) {
          return program - 1;
        }
      }
    }
    return defaultProgram;
  }

  /// Every note of the part's first voice, positioned by written bar and
  /// beat. A part written in more than one voice is reported, not merged:
  /// one line is what a chart carries.
  static List<WrittenNote> _readNotes(XmlElement part, List<String> problems) {
    final notes = <WrittenNote>[];
    // Ties in progress, by written pitch and voice: MusicXML writes a note
    // tied across a bar line as two notes, and what sounds is one (§5).
    // The written pitch is the key, not the shifted and clamped MIDI key —
    // two written pitches that clamp together are different notes and tie
    // independently.
    final tied = <({int pitch, int voice}), int>{};

    var divisions = 1;
    var beatType = 4;
    // Semitones from written to sounding, from `<transpose>`. A B flat tenor
    // part written in D sounds in C, and what Bandstand stores is what sounds.
    var chromatic = 0;
    var octaveChange = 0;
    var droppedVoices = 0;
    var outOfRange = 0;

    for (final (bar, measure) in part.findElements('measure').indexed) {
      for (final attributes in measure.findElements('attributes')) {
        final parsed = int.tryParse(
          attributes.findElements('divisions').firstOrNull?.innerText.trim() ??
              '',
        );
        if (parsed != null && parsed > 0) {
          divisions = parsed;
        }
        final beats = attributes.findElements('time').firstOrNull;
        final parsedType = int.tryParse(
          beats?.findElements('beat-type').firstOrNull?.innerText.trim() ?? '',
        );
        if (parsedType != null && parsedType > 0) {
          beatType = parsedType;
        }
        final transpose = attributes.findElements('transpose').firstOrNull;
        if (transpose != null) {
          chromatic =
              int.tryParse(
                transpose
                        .findElements('chromatic')
                        .firstOrNull
                        ?.innerText
                        .trim() ??
                    '',
              ) ??
              0;
          octaveChange =
              int.tryParse(
                transpose
                        .findElements('octave-change')
                        .firstOrNull
                        ?.innerText
                        .trim() ??
                    '',
              ) ??
              0;
        }
      }
      final shift = chromatic + octaveChange * 12;

      // A quarter note is `divisions` units; a beat is a `beatType` note, so in
      // 6/8 a beat is half a quarter and the conversion is not the identity.
      final unitsPerBeat = divisions * 4 / beatType;
      var units = 0.0;
      var previousStart = 0.0;
      var previousVoice = 1;

      for (final element in measure.childElements) {
        switch (element.name.local) {
          case 'note':
            final duration = _durationOf(element);
            final isChord = element.findElements('chord').isNotEmpty;
            final start = isChord ? previousStart : units;
            if (!isChord) {
              previousStart = units;
            }
            // A `<chord/>` note shares the voice of the note it sounds with.
            final voice = isChord
                ? previousVoice
                : int.tryParse(
                        element
                                .findElements('voice')
                                .firstOrNull
                                ?.innerText
                                .trim() ??
                            '',
                      ) ??
                      1;
            if (!isChord) {
              previousVoice = voice;
            }

            if (element.findElements('grace').isNotEmpty) {
              // No duration to place it in, and where it lands is an
              // interpretation rather than a fact (§5).
              continue;
            }
            if (element.findElements('rest').isNotEmpty) {
              units += duration;
              continue;
            }
            final pitch = _pitchOf(element);
            if (pitch.outOfRange) {
              // A written pitch no synth can sound. Its time still passes,
              // and it is counted and said rather than silently dropped
              // alongside the unpitched cues (L-I9).
              outOfRange++;
              if (!isChord) {
                units += duration;
              }
              continue;
            }
            if (pitch.key == null) {
              // An unpitched note in a part that is otherwise melodic: a
              // percussion cue mixed into a horn line. Its time still passes.
              units += duration;
              continue;
            }
            if (voice != 1) {
              // Voice 1 is the line; anything else is dropped, and its time
              // still passes, or the positions after a `<backup>` would slip.
              droppedVoices++;
              if (!isChord) {
                units += duration;
              }
              continue;
            }
            final key = (pitch.key! + shift).clamp(0, 127);
            final beats = duration / unitsPerBeat;
            final ties = _tiesOf(element);
            final tieKey = (pitch: pitch.key!, voice: voice);

            if (ties.stops && tied.containsKey(tieKey)) {
              // Lengthen the note this one continues, rather than starting a
              // second: what sounds is one note.
              final index = tied[tieKey]!;
              notes[index] = notes[index].copyWith(
                durationBeats: notes[index].durationBeats + beats,
              );
              if (!ties.starts) {
                tied.remove(tieKey);
              }
            } else {
              if (ties.starts && tied.containsKey(tieKey)) {
                problems.add(
                  'a note starts a tie on a pitch whose earlier tie never '
                  'ended; the earlier note sounds as written',
                );
              }
              notes.add(
                WrittenNote(
                  bar: bar,
                  beat: start / unitsPerBeat,
                  key: key,
                  durationBeats: beats <= 0 ? 0.25 : beats,
                  velocity: _velocityOf(element),
                ),
              );
              if (ties.starts) {
                tied[tieKey] = notes.length - 1;
              }
            }
            if (!isChord) {
              units += duration;
            }

          case 'backup':
            units -= _valueOf(element, 'duration');
            if (units < 0) {
              units = 0;
            }
            previousStart = units;

          case 'forward':
            units += _valueOf(element, 'duration');
            previousStart = units;
        }
      }
    }

    if (tied.isNotEmpty) {
      problems.add(
        '${tied.length} note${tied.length == 1 ? '' : 's'} start a tie that '
        'never ends; they sound for as long as they were written',
      );
    }
    if (droppedVoices > 0) {
      problems.add(
        'this part has more than one voice; $droppedVoices note'
        '${droppedVoices == 1 ? '' : 's'} outside voice 1 were dropped',
      );
    }
    if (outOfRange > 0) {
      problems.add(
        '$outOfRange note${outOfRange == 1 ? '' : 's'} written outside MIDI '
        '0–127 ${outOfRange == 1 ? 'was' : 'were'} dropped; nothing can '
        'sound ${outOfRange == 1 ? 'it' : 'them'}',
      );
    }
    return notes;
  }

  /// A note's `<duration>` in divisions, or zero when it has none.
  static double _durationOf(XmlElement note) => _valueOf(note, 'duration');

  static double _valueOf(XmlElement element, String child) =>
      double.tryParse(
        element.findElements(child).firstOrNull?.innerText.trim() ?? '',
      ) ??
      0;

  /// The MIDI key of a `<pitch>`: `key` is null when there is none or it
  /// does not parse, and `outOfRange` marks a written pitch outside MIDI
  /// 0–127 — the importer's problem to report, not the player's (L-I9).
  static ({int? key, bool outOfRange}) _pitchOf(XmlElement note) {
    final pitch = note.findElements('pitch').firstOrNull;
    if (pitch == null) {
      return (key: null, outOfRange: false);
    }
    final step = pitch.findElements('step').firstOrNull?.innerText.trim();
    final octave = int.tryParse(
      pitch.findElements('octave').firstOrNull?.innerText.trim() ?? '',
    );
    if (step == null || octave == null) {
      return (key: null, outOfRange: false);
    }
    // `<alter>` is a number of semitones and may be fractional in microtonal
    // files; rounding is the only thing a 12-tone synth can do with a quarter
    // tone, and dropping the note would be worse.
    final alter =
        double.tryParse(
          pitch.findElements('alter').firstOrNull?.innerText.trim() ?? '',
        ) ??
        0;
    const semitones = <String, int>{
      'C': 0,
      'D': 2,
      'E': 4,
      'F': 5,
      'G': 7,
      'A': 9,
      'B': 11,
    };
    final natural = semitones[step.toUpperCase()];
    if (natural == null) {
      return (key: null, outOfRange: false);
    }
    // MusicXML octave 4 is the one containing middle C, which is MIDI 60.
    final key = (octave + 1) * 12 + natural + alter.round();
    if (key < 0 || key > 127) {
      return (key: null, outOfRange: true);
    }
    return (key: key, outOfRange: false);
  }

  /// Whether this note starts or stops a tie.
  ///
  /// `<tie>` is the sounding tie and `<tied>` is the drawn slur-like mark;
  /// files in the wild write one, the other, or both, so either counts.
  static ({bool starts, bool stops}) _tiesOf(XmlElement note) {
    var starts = false;
    var stops = false;
    for (final tie in note.findElements('tie')) {
      final type = tie.getAttribute('type');
      starts |= type == 'start';
      stops |= type == 'stop';
    }
    for (final notations in note.findElements('notations')) {
      for (final tied in notations.findElements('tied')) {
        final type = tied.getAttribute('type');
        starts |= type == 'start';
        stops |= type == 'stop';
      }
    }
    return (starts: starts, stops: stops);
  }

  /// `<note dynamics="…">` is a percentage of velocity 90, per the spec.
  static int _velocityOf(XmlElement note) {
    final dynamics = double.tryParse(note.getAttribute('dynamics') ?? '');
    if (dynamics == null) {
      return 80;
    }
    return (dynamics * 0.9).round().clamp(1, 127);
  }
}
