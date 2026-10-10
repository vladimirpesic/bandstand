import 'dart:convert';
import 'dart:typed_data';

import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:bandstand/domain/song/lead_sheet_item.dart';
import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/io/exporters/musicxml_export.dart';
import 'package:bandstand/io/importers/musicxml_import.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../domain/harmony/harmony_test_support.dart';

/// §5.2 item 2, per `docs/rules/musicxml-import.md`.
void main() {
  installTestHarmony();

  String score(String body, {String header = ''}) =>
      '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<score-partwise version="4.0">$header'
      '<part-list><score-part id="P1"><part-name>C</part-name></score-part>'
      '</part-list><part id="P1">$body</part></score-partwise>';

  String measure(int number, String body, {String attributes = ''}) =>
      '<measure number="$number">$attributes$body</measure>';

  const fourFour =
      '<attributes><divisions>4</divisions>'
      '<time><beats>4</beats><beat-type>4</beat-type></time></attributes>';

  String harmony(String step, {int alter = 0, String kind = 'major'}) =>
      '<harmony><root><root-step>$step</root-step>'
      '${alter == 0 ? '' : '<root-alter>$alter</root-alter>'}</root>'
      '<kind>$kind</kind></harmony>';

  group('what it takes from a file (§1)', () {
    test('chords, bars, title and composer', () {
      final result = MusicXmlImporter.parse(
        score(
          measure(
                1,
                harmony('D', kind: 'minor-seventh'),
                attributes: fourFour,
              ) +
              measure(2, harmony('G', kind: 'dominant')) +
              measure(3, harmony('C', kind: 'major-seventh')),
          header:
              '<work><work-title>Autumn</work-title></work>'
              '<identification>'
              '<creator type="composer">V. Youmans</creator>'
              '</identification>',
        ),
        id: 'imported',
      );
      expect(result.song.title, 'Autumn');
      expect(result.song.composer, 'V. Youmans');
      expect(result.song.leadSheet.barCount, 3);

      final chords = result.song.leadSheet.items
          .whereType<CliChordSymbol>()
          .map((item) => item.chord.format())
          .toList();
      expect(chords, <String>['Dm7', 'G7', 'Cmaj7']);
      expect(result.problems, isEmpty);
    });

    test('a root keeps its spelling', () {
      // B with an alter of −1 is B flat and must not become A sharp.
      final result = MusicXmlImporter.parse(
        score(measure(1, harmony('B', alter: -1, kind: 'dominant'))),
        id: 'x',
      );
      final chord = result.song.leadSheet.items
          .whereType<CliChordSymbol>()
          .single
          .chord;
      expect(chord.format(), 'Bb7');
      expect(chord.root.toString(), 'Bb');
    });

    test('the time signature and the key come across', () {
      final result = MusicXmlImporter.parse(
        score(
          measure(
            1,
            harmony('E', alter: -1),
            attributes:
                '<attributes><divisions>2</divisions>'
                '<key><fifths>-3</fifths><mode>major</mode></key>'
                '<time><beats>3</beats><beat-type>4</beat-type></time>'
                '</attributes>',
          ),
        ),
        id: 'x',
      );
      expect(result.song.timeSignature.upper, 3);
      // Three flats is E flat major.
      expect(result.song.key.toString(), 'Eb');
    });

    test('an invalid time signature is reported, not installed', () {
      // The constructor only asserts, which a release build strips — a file
      // is read through tryParse, as the text importer does.
      final result = MusicXmlImporter.parse(
        score(
          measure(
            1,
            harmony('C'),
            attributes:
                '<attributes><divisions>4</divisions>'
                '<time><beats>4</beats><beat-type>5</beat-type></time>'
                '</attributes>',
          ),
        ),
        id: 'x',
      );
      expect(result.problems.join(), contains('time signature'));
      expect(result.song.timeSignature, TimeSignature.fourFour);
    });

    test('a minor key is read as one', () {
      final result = MusicXmlImporter.parse(
        score(
          measure(
            1,
            harmony('A', kind: 'minor'),
            attributes:
                '<attributes><divisions>1</divisions>'
                '<key><fifths>0</fifths><mode>minor</mode></key></attributes>',
          ),
        ),
        id: 'x',
      );
      expect(result.song.key.toString(), 'Am');
    });

    test('an offset places a chord inside the bar', () {
      // Four divisions to the quarter, so an offset of 8 is beat 3.
      final result = MusicXmlImporter.parse(
        score(
          measure(
            1,
            '${harmony('D', kind: 'minor-seventh')}'
            '<harmony><root><root-step>G</root-step></root>'
            '<kind>dominant</kind><offset>8</offset></harmony>',
            attributes: fourFour,
          ),
        ),
        id: 'x',
      );
      final chords =
          result.song.leadSheet.items.whereType<CliChordSymbol>().toList()
            ..sort((a, b) => a.position.compareTo(b.position));
      expect(chords, hasLength(2));
      expect(chords.first.position.beat, 0);
      expect(chords.last.position.beat, 2);
    });

    test('an offset past the bar end is held at the bar line, not drifted', () {
      // Four divisions to the quarter, so an offset of 20 is beat 5 — past
      // the last beat of a 4/4 bar, where it would convert into the next
      // bar's territory.
      final result = MusicXmlImporter.parse(
        score(
          measure(
            1,
            '${harmony('C')}'
            '<harmony><root><root-step>G</root-step></root>'
            '<kind>dominant</kind><offset>20</offset></harmony>',
            attributes: fourFour,
          ),
        ),
        id: 'x',
      );
      final chords =
          result.song.leadSheet.items.whereType<CliChordSymbol>().toList()
            ..sort((a, b) => a.position.compareTo(b.position));
      expect(chords.last.position.bar, 0);
      expect(chords.last.position.beat, 4);
      expect(result.problems.join(), contains('past the end'));
    });

    test('kind="none" is N.C.', () {
      final result = MusicXmlImporter.parse(
        score(measure(1, '<harmony><kind>none</kind></harmony>')),
        id: 'x',
      );
      expect(
        result.song.leadSheet.items
            .whereType<CliChordSymbol>()
            .single
            .chord
            .isNoChord,
        isTrue,
      );
    });

    test('a kind with a text attribute keeps the symbol as written', () {
      // How software records a symbol the fixed vocabulary cannot express.
      // Flattening `7alt` to `dominant` would lose the chord.
      final result = MusicXmlImporter.parse(
        score(
          measure(
            1,
            '<harmony><root><root-step>C</root-step></root>'
            '<kind text="7alt">dominant</kind></harmony>',
          ),
        ),
        id: 'x',
      );
      expect(
        result.song.leadSheet.items
            .whereType<CliChordSymbol>()
            .single
            .chord
            .format(),
        'C7alt',
      );
    });

    test('a degree alters the kind', () {
      final result = MusicXmlImporter.parse(
        score(
          measure(
            1,
            '<harmony><root><root-step>C</root-step></root>'
            '<kind>major-seventh</kind>'
            '<degree><degree-value>9</degree-value>'
            '<degree-alter>0</degree-alter>'
            '<degree-type>add</degree-type></degree></harmony>',
          ),
        ),
        id: 'x',
      );
      expect(
        result.song.leadSheet.items
            .whereType<CliChordSymbol>()
            .single
            .chord
            .format(),
        'Cmaj9',
      );
    });

    test('an added degree is not an extension', () {
      // `add 9` on a major triad names one extra note; writing `C9` would
      // read as a dominant ninth and drag in a seventh the file never had.
      final result = MusicXmlImporter.parse(
        score(
          measure(
            1,
            '<harmony><root><root-step>C</root-step></root>'
            '<kind>major</kind>'
            '<degree><degree-value>9</degree-value>'
            '<degree-alter>0</degree-alter>'
            '<degree-type>add</degree-type></degree></harmony>',
          ),
        ),
        id: 'x',
      );
      expect(
        result.song.leadSheet.items
            .whereType<CliChordSymbol>()
            .single
            .chord
            .format(),
        'Cadd9',
      );
      expect(result.problems, isEmpty);
    });

    test(
      'an added thirteenth on a major seventh keeps what the file wrote',
      () {
        final result = MusicXmlImporter.parse(
          score(
            measure(
              1,
              '<harmony><root><root-step>C</root-step></root>'
              '<kind>major-seventh</kind>'
              '<degree><degree-value>13</degree-value>'
              '<degree-alter>0</degree-alter>'
              '<degree-type>add</degree-type></degree></harmony>',
            ),
          ),
          id: 'x',
        );
        expect(
          result.song.leadSheet.items
              .whereType<CliChordSymbol>()
              .single
              .chord
              .format(),
          'Cmaj7add13',
        );
        expect(result.problems, isEmpty);
      },
    );

    test('an added degree with no faithful spelling is reported', () {
      final result = MusicXmlImporter.parse(
        score(
          measure(
            1,
            '<harmony><root><root-step>C</root-step></root>'
            '<kind>major</kind>'
            '<degree><degree-value>8</degree-value>'
            '<degree-alter>0</degree-alter>'
            '<degree-type>add</degree-type></degree></harmony>',
          ),
        ),
        id: 'x',
      );
      expect(
        result.song.leadSheet.items
            .whereType<CliChordSymbol>()
            .single
            .chord
            .format(),
        'C',
      );
      expect(result.problems.join(), contains('no Bandstand spelling'));
    });

    test('a doubly-altered degree is reported, not read as a single flat', () {
      // The degree vocabulary carries single accidentals; writing one `b`
      // for a double flat would name a different note.
      final result = MusicXmlImporter.parse(
        score(
          measure(
            1,
            '<harmony><root><root-step>C</root-step></root>'
            '<kind>dominant</kind>'
            '<degree><degree-value>9</degree-value>'
            '<degree-alter>-2</degree-alter>'
            '<degree-type>alter</degree-type></degree></harmony>',
          ),
        ),
        id: 'x',
      );
      expect(
        result.song.leadSheet.items
            .whereType<CliChordSymbol>()
            .single
            .chord
            .format(),
        'C7',
      );
      expect(result.problems.join(), contains('no Bandstand spelling'));
    });

    test('a slash chord keeps its bass', () {
      final result = MusicXmlImporter.parse(
        score(
          measure(
            1,
            '<harmony><root><root-step>C</root-step></root><kind>major</kind>'
            '<bass><bass-step>G</bass-step></bass></harmony>',
          ),
        ),
        id: 'x',
      );
      expect(
        result.song.leadSheet.items
            .whereType<CliChordSymbol>()
            .single
            .chord
            .format(),
        'C/G',
      );
    });
  });

  group('structure (§5)', () {
    test('repeats come across, with their play count', () {
      final result = MusicXmlImporter.parse(
        score(
          measure(
                1,
                '<barline location="left"><repeat direction="forward"/></barline>'
                '${harmony('C')}',
              ) +
              measure(
                2,
                '${harmony('G', kind: 'dominant')}<barline location="right">'
                '<repeat direction="backward" times="3"/></barline>',
              ),
        ),
        id: 'x',
      );
      final repeats =
          result.song.leadSheet.items.whereType<CliRepeat>().toList()
            ..sort((a, b) => a.position.compareTo(b.position));
      expect(repeats, hasLength(2));
      expect(repeats.first.isStart, isTrue);
      expect(repeats.last.isStart, isFalse);
      expect(repeats.last.playCount, 3);
    });

    test('an ending spans the bars it covers', () {
      final result = MusicXmlImporter.parse(
        score(
          measure(1, harmony('C')) +
              measure(
                2,
                '<barline location="left">'
                '<ending number="1,2" type="start"/></barline>'
                '${harmony('G', kind: 'dominant')}',
              ) +
              measure(
                3,
                '${harmony('C')}<barline location="right">'
                '<ending number="1,2" type="stop"/></barline>',
              ),
        ),
        id: 'x',
      );
      final ending = result.song.leadSheet.items.whereType<CliEnding>().single;
      expect(ending.position.bar, 1);
      expect(ending.barCount, 2);
      expect(ending.passNumbers, <int>{1, 2});
    });

    test('an ending that closes without opening is reported', () {
      final result = MusicXmlImporter.parse(
        score(
          measure(
            1,
            '${harmony('C')}<barline location="right">'
            '<ending number="1" type="stop"/></barline>',
          ),
        ),
        id: 'x',
      );
      expect(result.song.leadSheet.items.whereType<CliEnding>(), isEmpty);
      expect(result.problems.join(), contains('without opening'));
    });

    test('an ending left open at the end of the score is kept', () {
      // A bracket that simply stops is common in the wild; the bars it
      // covers are still worth having.
      final result = MusicXmlImporter.parse(
        score(
          measure(1, harmony('C')) +
              measure(
                2,
                '<barline location="left">'
                '<ending number="1" type="start"/></barline>'
                '${harmony('G', kind: 'dominant')}',
              ) +
              measure(3, harmony('C')),
        ),
        id: 'x',
      );
      final ending = result.song.leadSheet.items.whereType<CliEnding>().single;
      expect(ending.position.bar, 1);
      expect(ending.barCount, 2);
      expect(result.problems, isEmpty);
    });

    test('an ending opened inside another is reported', () {
      final result = MusicXmlImporter.parse(
        score(
          measure(
                1,
                '<barline location="left">'
                '<ending number="1" type="start"/></barline>'
                '${harmony('C')}',
              ) +
              measure(
                2,
                '<barline location="left">'
                '<ending number="2" type="start"/></barline>'
                '${harmony('G', kind: 'dominant')}',
              ),
        ),
        id: 'x',
      );
      expect(result.problems.join(), contains('opens before'));
    });

    test('navigation marks are read from either spelling', () {
      // Some software puts the mark in `direction-type`, some only in `sound`.
      final result = MusicXmlImporter.parse(
        score(
          measure(
                1,
                '<direction><direction-type><segno/></direction-type></direction>'
                '${harmony('C')}',
              ) +
              measure(
                2,
                '${harmony('G', kind: 'dominant')}'
                '<direction><sound dalsegno="1"/></direction>',
              ),
        ),
        id: 'x',
      );
      final marks = result.song.leadSheet.items
          .whereType<CliNavigation>()
          .map((item) => item.mark)
          .toSet();
      expect(marks, contains(NavigationMark.segno));
      expect(marks, contains(NavigationMark.dalSegno));
    });

    test('a rehearsal mark becomes a section', () {
      final result = MusicXmlImporter.parse(
        score(
          measure(1, harmony('C')) +
              measure(
                2,
                '<direction><direction-type><rehearsal>B</rehearsal>'
                '</direction-type></direction>${harmony('F')}',
              ),
        ),
        id: 'x',
      );
      expect(
        result.song.leadSheet.sections.map((section) => section.name),
        contains('B'),
      );
    });

    test('a rehearsal-marked section owns the meter it starts in', () {
      // A 6/8 score whose sections come from rehearsal marks: the second
      // section must not default to 4/4 from its first bar on.
      final result = MusicXmlImporter.parse(
        score(
          measure(
                1,
                '<direction><direction-type><rehearsal>A</rehearsal>'
                '</direction-type></direction>${harmony('C')}',
                attributes:
                    '<attributes><divisions>6</divisions>'
                    '<time><beats>6</beats><beat-type>8</beat-type></time>'
                    '</attributes>',
              ) +
              measure(
                2,
                '<direction><direction-type><rehearsal>B</rehearsal>'
                '</direction-type></direction>${harmony('F')}',
              ),
        ),
        id: 'x',
      );
      expect(result.song.leadSheet.timeSignatureAt(1), TimeSignature.sixEight);
      expect(result.problems, isEmpty);
    });

    test('a tempo is taken from sound', () {
      final result = MusicXmlImporter.parse(
        score(measure(1, '<sound tempo="152"/>${harmony('C')}')),
        id: 'x',
      );
      expect(result.song.tempo, 152);
    });

    test('a tempo outside the model is reported, not silently dropped', () {
      final result = MusicXmlImporter.parse(
        score(measure(1, '<sound tempo="600"/>${harmony('C')}')),
        id: 'x',
      );
      expect(result.problems.join(), contains('tempo'));
      expect(result.song.tempo, 120);
    });
  });

  group('files that are not what they claim', () {
    test('a timewise score is refused with a reason (§2)', () {
      expect(
        () => MusicXmlImporter.parse(
          '<?xml version="1.0"?><score-timewise/>',
          id: 'x',
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('timewise'),
          ),
        ),
      );
    });

    test('a document that is not a score at all', () {
      expect(
        () => MusicXmlImporter.parse('<html><body/></html>', id: 'x'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('not a MusicXML score'),
          ),
        ),
      );
    });

    test('malformed XML', () {
      expect(
        () => MusicXmlImporter.parse('<score-partwise><part>', id: 'x'),
        throwsFormatException,
      );
    });

    test('a score with no harmony imports its bars and says so (§3)', () {
      final result = MusicXmlImporter.parse(
        score(measure(1, '', attributes: fourFour) + measure(2, '')),
        id: 'x',
      );
      expect(result.song.leadSheet.barCount, 2);
      expect(result.problems.join(), contains('no chord symbols'));
    });

    test('the part with the most harmony wins (§3)', () {
      final result = MusicXmlImporter.parse(
        '<?xml version="1.0"?><score-partwise version="4.0">'
        '<part-list>'
        '<score-part id="P1"><part-name>Voice</part-name></score-part>'
        '<score-part id="P2"><part-name>Piano</part-name></score-part>'
        '</part-list>'
        '<part id="P1">${measure(1, '')}</part>'
        '<part id="P2">${measure(1, harmony('F', kind: 'major-seventh'))}</part>'
        '</score-partwise>',
        id: 'x',
      );
      expect(
        result.song.leadSheet.items
            .whereType<CliChordSymbol>()
            .single
            .chord
            .format(),
        'Fmaj7',
      );
    });
  });

  group('reading bytes', () {
    test('a plain UTF-8 document', () {
      final bytes = Uint8List.fromList(
        utf8.encode(score(measure(1, harmony('C')))),
      );
      final result = MusicXmlImporter.read(bytes, id: 'x');
      expect(
        result.song.leadSheet.items.whereType<CliChordSymbol>(),
        hasLength(1),
      );
    });

    test('a Latin-1 document is read rather than refused', () {
      // The declaration says UTF-8 and the bytes are sometimes Latin-1, and
      // the declaration is inside the document being decoded.
      final text = score(
        measure(1, harmony('C')),
        header:
            '<identification>'
            '<creator type="composer">Saint-Saëns</creator>'
            '</identification>',
      );
      final bytes = Uint8List.fromList(latin1.encode(text));
      final result = MusicXmlImporter.read(bytes, id: 'x');
      // 'Sa' would pass even if the ë were lossy-decoded to U+FFFD.
      expect(result.song.composer, contains('Saëns'));
    });
  });

  group('round-tripping our own export (§7)', () {
    test('a chart that goes out and comes back is the same chart', () {
      // Not byte equality — that is not a goal and would be a wrong one — but
      // the same chords in the same bars.
      final original = MusicXmlImporter.parse(
        score(
          measure(
                1,
                harmony('D', kind: 'minor-seventh'),
                attributes: fourFour,
              ) +
              measure(2, harmony('G', kind: 'dominant')) +
              measure(3, harmony('C', kind: 'major-seventh')) +
              measure(4, harmony('A', kind: 'dominant')),
          header: '<work><work-title>Round Trip</work-title></work>',
        ),
        id: 'first',
      ).song;

      final again = MusicXmlImporter.parse(
        MusicXmlExporter.export(original),
        id: 'second',
      ).song;

      expect(again.title, original.title);
      expect(again.leadSheet.barCount, original.leadSheet.barCount);
      List<String> chordsOf(Song song) =>
          (song.leadSheet.items.whereType<CliChordSymbol>().toList()
                ..sort((a, b) => a.position.compareTo(b.position)))
              .map((item) => item.chord.format())
              .toList();
      expect(chordsOf(again), chordsOf(original));
    });
  });

  group('meters (§4.6)', () {
    String meterAttrs(int beats, int type) =>
        '<attributes><divisions>4</divisions>'
        '<time><beats>$beats</beats><beat-type>$type</beat-type></time>'
        '</attributes>';
    String rehearsal(String name) =>
        '<direction><direction-type><rehearsal>$name</rehearsal>'
        '</direction-type></direction>';

    /// The meter every bar of `song` is played in.
    List<String> metersOf(ImportedMusicXml result) => <String>[
      for (var bar = 0; bar < result.song.leadSheet.barCount; bar++)
        '${result.song.leadSheet.timeSignatureAt(bar)}',
    ];

    test('the sheet opens in the first meter, not the last', () {
      // The reader keeps a running meter, and the sheet used to be seeded from
      // it after the whole score had been read — so a score that opens in 4/4
      // and moves to 3/4 was stamped 3/4 from bar 1.
      final result = MusicXmlImporter.parse(
        score(
          measure(1, harmony('C'), attributes: meterAttrs(4, 4)) +
              measure(2, harmony('F'), attributes: meterAttrs(3, 4)),
        ),
        id: 'imported',
      );
      expect(result.song.timeSignature, TimeSignature.fourFour);
      expect(metersOf(result), <String>['4/4', '3/4']);
    });

    test('a meter change with no rehearsal mark is kept', () {
      // A lead sheet reads its meter from the section governing a bar, and
      // importers only made sections at rehearsal marks — so a `<time>` that
      // changed mid-score had nowhere to live and vanished silently.
      final result = MusicXmlImporter.parse(
        score(
          measure(1, harmony('C'), attributes: meterAttrs(4, 4)) +
              measure(2, harmony('F')) +
              measure(3, harmony('G'), attributes: meterAttrs(3, 4)) +
              measure(4, harmony('C')),
        ),
        id: 'imported',
      );
      expect(metersOf(result), <String>['4/4', '4/4', '3/4', '3/4']);
      expect(result.problems, isEmpty);
    });

    test('alternating meters each keep their own section', () {
      // Sections synthesised for a meter change are named after the meter, so
      // a score that alternates produces the same name twice. A sheet refuses
      // two sections with one name, and every change after the second would
      // have been dropped.
      final result = MusicXmlImporter.parse(
        score(
          measure(1, harmony('C'), attributes: meterAttrs(4, 4)) +
              measure(2, harmony('F'), attributes: meterAttrs(6, 8)) +
              measure(3, harmony('G'), attributes: meterAttrs(4, 4)) +
              measure(4, harmony('C'), attributes: meterAttrs(6, 8)),
        ),
        id: 'imported',
      );
      expect(metersOf(result), <String>['4/4', '6/8', '4/4', '6/8']);
      expect(result.problems, isEmpty);
    });

    test('a meter change at a rehearsal mark makes one section, named for the '
        'mark', () {
      final result = MusicXmlImporter.parse(
        score(
          measure(
                1,
                rehearsal('A') + harmony('C'),
                attributes: meterAttrs(4, 4),
              ) +
              measure(2, harmony('F')) +
              measure(
                3,
                rehearsal('B') + harmony('G'),
                attributes: meterAttrs(6, 8),
              ) +
              measure(4, harmony('C')),
        ),
        id: 'imported',
      );
      final sections = result.song.leadSheet.items
          .whereType<CliSection>()
          .toList();
      expect(sections.map((item) => item.section.name), <String>['A', 'B']);
      expect(sections.last.section.timeSignature, TimeSignature.sixEight);
      expect(metersOf(result), <String>['4/4', '4/4', '6/8', '6/8']);
    });

    test('a returning rehearsal letter is suffixed, not dropped', () {
      // "A" again after "B" is how a chart marks the head coming back. The
      // sheet refuses the duplicate name, and the whole section used to be
      // lost to that error — taking its meter with it.
      final result = MusicXmlImporter.parse(
        score(
          measure(1, rehearsal('A') + harmony('C'), attributes: fourFour) +
              measure(2, rehearsal('B') + harmony('F')) +
              measure(3, rehearsal('A') + harmony('G')),
        ),
        id: 'imported',
      );
      expect(
        result.song.leadSheet.items.whereType<CliSection>().map(
          (item) => item.section.name,
        ),
        <String>['A', 'B', 'A (2)'],
      );
      expect(result.problems, isEmpty);
    });

    test('meters survive a round trip through the exporter', () {
      // The exporter already wrote per-bar `<time>`; the importer flattened
      // them. Exporting and reimporting therefore rewrote the meter of the
      // piece, which is the worst kind of lossy: silent and plausible.
      final imported = MusicXmlImporter.parse(
        score(
          measure(1, harmony('C'), attributes: meterAttrs(4, 4)) +
              measure(2, harmony('F')) +
              measure(3, harmony('G'), attributes: meterAttrs(6, 8)) +
              measure(4, harmony('C')),
        ),
        id: 'imported',
      );
      final again = MusicXmlImporter.parse(
        MusicXmlExporter.export(imported.song),
        id: 'again',
      );
      expect(metersOf(again), metersOf(imported));
      expect(metersOf(again), <String>['4/4', '4/4', '6/8', '6/8']);
    });
  });

  group('harmony a file writes that used to be changed in silence', () {
    test('an alter of zero is the natural degree, not a flat one', () {
      // The accidental is `alter > 0 ? "#" : "b"`, which has no case for zero
      // — so `<degree-type>alter</degree-type>` with `<degree-alter>0</…>`
      // wrote a flat and turned a plain ninth into a flat ninth.
      final result = MusicXmlImporter.parse(
        score(
          measure(
            1,
            '<harmony><root><root-step>C</root-step></root>'
            '<kind>dominant</kind><degree><degree-value>9</degree-value>'
            '<degree-alter>0</degree-alter>'
            '<degree-type>alter</degree-type></degree></harmony>',
            attributes: fourFour,
          ),
        ),
        id: 'imported',
      );
      final chord = result.song.leadSheet.items
          .whereType<CliChordSymbol>()
          .single;
      expect(chord.chord.format(), isNot(contains('b9')));
      expect(chord.chord.type.degrees.join(' '), contains('9'));
    });

    test('a second chord on one beat is reported', () {
      // `withItem` keeps the later one, which is right for the editor and
      // wrong for an importer: it is a chord the file contained and the chart
      // will not show. The comment at the call site claimed the sheet refused
      // it, and the sheet does no such thing.
      final result = MusicXmlImporter.parse(
        score(measure(1, harmony('C') + harmony('F'), attributes: fourFour)),
        id: 'imported',
      );
      expect(result.problems.join(), contains('same beat'));
      expect(
        result.song.leadSheet.items.whereType<CliChordSymbol>(),
        hasLength(1),
      );
    });

    test('one chord a bar is not reported', () {
      final result = MusicXmlImporter.parse(
        score(
          measure(1, harmony('C'), attributes: fourFour) +
              measure(2, harmony('F')),
        ),
        id: 'imported',
      );
      expect(result.problems, isEmpty);
    });
  });
}
