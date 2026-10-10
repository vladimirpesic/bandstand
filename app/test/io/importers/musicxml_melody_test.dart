import 'package:bandstand/io/importers/musicxml_melody.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

/// The written-part reader, per `docs/rules/written-parts.md` §5.
void main() {
  String score(String part) =>
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<score-partwise version="4.0">'
      '<part-list><score-part id="P1"><part-name>Lead</part-name>'
      '</score-part></part-list>'
      '<part id="P1">$part</part></score-partwise>';

  XmlElement rootOf(String part) => XmlDocument.parse(score(part)).rootElement;

  /// One sounding note, tied across the bar line the way MusicXML writes it.
  String tiedNote(
    String step, {
    int alter = 0,
    int octave = 4,
    int duration = 1,
    required bool start,
    required bool stop,
    int voice = 1,
  }) =>
      '<note><pitch><step>$step</step>'
      '${alter == 0 ? '' : '<alter>$alter</alter>'}'
      '<octave>$octave</octave></pitch>'
      '<duration>$duration</duration><voice>$voice</voice>'
      '${stop ? '<tie type="stop"/>' : ''}'
      '${start ? '<tie type="start"/>' : ''}'
      '<notations>'
      '${stop ? '<tied type="stop"/>' : ''}'
      '${start ? '<tied type="start"/>' : ''}'
      '</notations></note>';

  const attributes =
      '<attributes><divisions>1</divisions>'
      '<time><beats>4</beats><beat-type>4</beat-type></time>'
      '<transpose><chromatic>-24</chromatic></transpose></attributes>';

  group('ties', () {
    test('written pitches that clamp together still tie independently', () {
      // A part written two octaves above where it sounds: written C-1 and
      // C#-1 both shift below MIDI range and clamp to key 0. They are
      // different notes, and each tie must find its own note.
      final problems = <String>[];
      final part = MusicXmlMelody.read(
        rootOf(
          '<measure number="1">$attributes'
          '${tiedNote('C', octave: -1, start: true, stop: false)}'
          '${tiedNote('C', alter: 1, octave: -1, start: true, stop: false)}'
          '</measure>'
          '<measure number="2">'
          '${tiedNote('C', octave: -1, start: false, stop: true)}'
          '${tiedNote('C', alter: 1, octave: -1, start: false, stop: true)}'
          '</measure>',
        ),
        id: 'melody',
        problems: problems,
      )!;
      expect(part.notes, hasLength(2));
      for (final note in part.notes) {
        expect(note.durationBeats, 2);
      }
      expect(problems, isEmpty);
    });

    test('a second tie on an open pitch is reported', () {
      final problems = <String>[];
      final part = MusicXmlMelody.read(
        rootOf(
          '<measure number="1">$attributes'
          '${tiedNote('C', start: true, stop: false)}'
          '${tiedNote('C', start: true, stop: false)}'
          '</measure>',
        ),
        id: 'melody',
        problems: problems,
      )!;
      expect(part.notes, hasLength(2));
      expect(problems.join(), contains('earlier tie never ended'));
    });
  });

  group('voices', () {
    const noTranspose =
        '<attributes><divisions>1</divisions>'
        '<time><beats>4</beats><beat-type>4</beat-type></time></attributes>';

    test('only voice 1 is kept, and the drop is reported', () {
      final problems = <String>[];
      final part = MusicXmlMelody.read(
        rootOf(
          '<measure number="1">$noTranspose'
          '<note><pitch><step>D</step><octave>4</octave></pitch>'
          '<duration>2</duration><voice>1</voice></note>'
          '<note><pitch><step>E</step><octave>4</octave></pitch>'
          '<duration>1</duration><voice>2</voice></note>'
          '<note><pitch><step>F</step><octave>4</octave></pitch>'
          '<duration>1</duration><voice>2</voice></note>'
          '</measure>',
        ),
        id: 'melody',
        problems: problems,
      )!;
      expect(part.notes, hasLength(1));
      expect(part.notes.single.key, 62);
      expect(part.notes.single.durationBeats, 2);
      expect(problems.join(), contains('more than one voice'));
    });
  });

  group('range', () {
    const noTranspose =
        '<attributes><divisions>1</divisions>'
        '<time><beats>4</beats><beat-type>4</beat-type></time></attributes>';

    test('a written pitch outside MIDI 0-127 is dropped and said', () {
      // L-I9: B in octave 10 is key 143. It used to vanish into the same
      // bucket as an unpitched percussion cue — no note, no word.
      final problems = <String>[];
      final part = MusicXmlMelody.read(
        rootOf(
          '<measure number="1">$noTranspose'
          '<note><pitch><step>C</step><octave>4</octave></pitch>'
          '<duration>1</duration></note>'
          '<note><pitch><step>B</step><octave>10</octave></pitch>'
          '<duration>1</duration></note>'
          '<note><pitch><step>D</step><octave>4</octave></pitch>'
          '<duration>1</duration></note>'
          '</measure>',
        ),
        id: 'melody',
        problems: problems,
      )!;
      expect(part.notes.map((note) => note.key), <int>[60, 62]);
      // The dropped note's time still passes: D lands a beat later.
      expect(part.notes.map((note) => note.beat), <double>[0, 2]);
      expect(problems.join(), contains('outside MIDI 0–127'));
    });
  });
}
