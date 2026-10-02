import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:bandstand/domain/song/lead_sheet_item.dart';
import 'package:bandstand/io/importers/text_import.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../domain/harmony/harmony_test_support.dart';

/// §5.2 item 3, per `docs/rules/text-import.md`.
void main() {
  installTestHarmony();

  ImportedText read(String source) => TextImporter.parse(source, id: 'typed');

  List<({int bar, double beat, String chord})> chordsOf(ImportedText result) =>
      (result.song.leadSheet.items.whereType<CliChordSymbol>().toList()
            ..sort((a, b) => a.position.compareTo(b.position)))
          .map(
            (item) => (
              bar: item.position.bar,
              beat: item.position.beat,
              chord: item.chord.format(),
            ),
          )
          .toList();

  group('the shape (§1)', () {
    test('headers, sections and bars', () {
      final result = read('''
Title: Blue Bossa
Composer: Kenny Dorham
Key: Cm
Tempo: 150
Time: 4/4

A:
| Cm7 | Cm7 | Fm7 | Fm7 |
B:
| Dm7b5 | G7 | Cm7 | Cm7 |
''');
      expect(result.song.title, 'Blue Bossa');
      expect(result.song.composer, 'Kenny Dorham');
      expect(result.song.key.toString(), 'Cm');
      expect(result.song.tempo, 150);
      expect(result.song.leadSheet.barCount, 8);
      expect(
        result.song.leadSheet.sections.map((section) => section.name),
        contains('B'),
      );
      expect(result.problems, isEmpty);
    });

    test('leading and trailing pipes are optional', () {
      expect(chordsOf(read('C | Am')).length, 2);
      expect(chordsOf(read('| C | Am |')).length, 2);
      expect(read('C | Am').song.leadSheet.barCount, 2);
    });

    test('whitespace is free', () {
      final aligned = read('| Cm7   | Fm7 |');
      final not = read('|Cm7|Fm7|');
      expect(chordsOf(aligned), chordsOf(not));
    });

    test('a comment runs to end of line', () {
      final result = read('| C | Am |  # the first four\n| Dm7 | G7 |');
      expect(result.song.leadSheet.barCount, 4);
      expect(result.problems, isEmpty);
    });

    test('a sharp in a chord is not a comment', () {
      // `#` only starts a comment at the start of a line or after
      // whitespace; inside a token it is the chord's sharp (§1).
      final result = read('| F#7 | B7 |');
      expect(chordsOf(result).map((chord) => chord.chord), <String>[
        'F#7',
        'B7',
      ]);
      expect(result.song.leadSheet.barCount, 2);
      expect(result.problems, isEmpty);
    });

    test('headers are optional and order does not matter', () {
      final result = read('Tempo: 200\nTitle: Fast\n\n| C |');
      expect(result.song.title, 'Fast');
      expect(result.song.tempo, 200);
    });

    test('with no headers at all it is still a chart', () {
      final result = read('| C | Am | Dm7 | G7 |');
      expect(result.song.title, 'Untitled');
      expect(result.song.key.toString(), 'C');
      expect(result.song.leadSheet.barCount, 4);
    });
  });

  group('chords in a bar (§2)', () {
    test('two chords divide the bar evenly', () {
      final chords = chordsOf(read('| Dm7 G7 |'));
      expect(chords, hasLength(2));
      expect(chords[0].beat, 0);
      expect(chords[1].beat, 2);
    });

    test('four chords are a beat each', () {
      final chords = chordsOf(read('| C Am Dm G |'));
      expect(chords.map((c) => c.beat), <double>[0, 1, 2, 3]);
    });

    test('a slash is a beat of the chord before it', () {
      // `| C / G / |` is two beats each, and the repeat is not written twice.
      final chords = chordsOf(read('| C / G / |'));
      expect(chords, hasLength(2));
      expect(chords[0].chord, 'C');
      expect(chords[0].beat, 0);
      expect(chords[1].chord, 'G');
      expect(chords[1].beat, 2);
    });

    test('a bar of slashes is one chord', () {
      final chords = chordsOf(read('| C / / / |'));
      expect(chords, hasLength(1));
      expect(chords.single.chord, 'C');
    });

    test('a percent repeats the previous bar', () {
      final chords = chordsOf(read('| Dm7 G7 | % |'));
      expect(chords, hasLength(4));
      expect(chords[2].bar, 1);
      expect(chords[2].chord, 'Dm7');
      expect(chords[3].chord, 'G7');
    });

    test('an empty bar carries no chord', () {
      final result = read('| C | | Am |');
      expect(result.song.leadSheet.barCount, 3);
      final chords = chordsOf(result);
      expect(chords, hasLength(2));
      expect(chords[1].bar, 2);
    });

    test('the meter decides the division', () {
      final chords = chordsOf(read('Time: 3/4\n\n| C G |'));
      expect(chords[1].beat, 1.5);
    });

    test('N.C. is a chord', () {
      final result = read('| N.C. | C |');
      expect(
        result.song.leadSheet.items
            .whereType<CliChordSymbol>()
            .first
            .chord
            .isNoChord,
        isTrue,
      );
    });
  });

  group('structure (§3)', () {
    test('repeat marks come across', () {
      final result = read('|: C | Am | Dm7 | G7 :|');
      final repeats =
          result.song.leadSheet.items.whereType<CliRepeat>().toList()
            ..sort((a, b) => a.position.compareTo(b.position));
      expect(repeats, hasLength(2));
      expect(repeats.first.isStart, isTrue);
      expect(repeats.first.position.bar, 0);
      expect(repeats.last.isStart, isFalse);
      expect(repeats.last.position.bar, 3);
    });

    test('a play count is honoured', () {
      final result = read('|: C | Am :|x3');
      final close = result.song.leadSheet.items
          .whereType<CliRepeat>()
          .firstWhere((item) => !item.isStart);
      expect(close.playCount, 3);
    });

    test('endings close at the next ending', () {
      final result = read('|: C | Am |1. Dm7 | G7 |2. C | C :|');
      final endings =
          result.song.leadSheet.items.whereType<CliEnding>().toList()
            ..sort((a, b) => a.position.compareTo(b.position));
      expect(endings, hasLength(2));
      expect(endings.first.passNumbers, <int>{1});
      expect(endings.first.position.bar, 2);
      expect(endings.first.barCount, 2);
      expect(endings.last.passNumbers, <int>{2});
    });

    test('a section starts at the next bar', () {
      final result = read('| C |\nB:\n| Am |\n');
      final section = result.song.leadSheet.sections.firstWhere(
        (candidate) => candidate.name == 'B',
      );
      expect(section.startBar, 1);
    });

    test('a section declared on the first chart line names the default', () {
      // The doc's own example: `A:` as the first chart line must not vanish.
      final result = read('\nIntro:\n| C | Am |\n');
      final sections = result.song.leadSheet.sections;
      expect(sections, hasLength(1));
      expect(sections.single.name, 'Intro');
      expect(sections.single.startBar, 0);
      expect(result.problems, isEmpty);
    });

    test('a chart in 6/8 gives its sections the meter, not a 4/4 default', () {
      final result = read('Time: 6/8\n\nA:\n| C | Am |\nB:\n| G7 | C |\n');
      expect(result.song.leadSheet.timeSignatureAt(2), TimeSignature.sixEight);
      expect(result.problems, isEmpty);
    });

    test('two section lines with no bars between them are reported', () {
      final result = read('\nA:\nB:\n| C |\n');
      expect(
        result.song.leadSheet.sections.map((section) => section.name),
        <String>['A'],
      );
      expect(result.problems.single, contains('already named'));
    });
  });

  group('failures name their line and keep going (§4)', () {
    test('a bad chord loses its bar, not the chart', () {
      final result = read('| C | Am |\n| Zx9 | G7 |');
      expect(result.song.leadSheet.barCount, 4);
      expect(result.problems, hasLength(1));
      expect(result.problems.single, contains('line 2'));
      expect(result.problems.single, contains('Zx9'));
      // The other three are still there.
      expect(chordsOf(result), hasLength(3));
    });

    test('a bad header is reported and defaulted', () {
      final result = read('Tempo: quick\nKey: H\n\n| C |');
      expect(result.problems, hasLength(2));
      expect(result.song.tempo, 120);
      expect(result.song.key.toString(), 'C');
    });

    test('a bad time signature is reported and defaulted', () {
      final result = read('Time: 4/5\n\n| C |');
      expect(result.problems.join(), contains('time signature'));
      expect(result.song.timeSignature, TimeSignature.fourFour);
    });

    test('a document with no bars is not a lead sheet', () {
      expect(
        () => read('Title: Nothing\nComposer: Nobody\n'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('no bars'),
          ),
        ),
      );
    });

    test('a bar starting with a slash is reported', () {
      final result = read('| / C |');
      expect(result.problems.join(), contains('starts with "/"'));
    });
  });

  group('a real tune', () {
    test('a 32-bar AABA reads end to end', () {
      final result = read('''
Title: Test Standard
Key: F
Tempo: 180

A:
| Fmaj7 | D7 | Gm7 | C7 |
| Fmaj7 | D7 | Gm7 C7 | Fmaj7 |
B:
| Cm7 | F7 | Bbmaj7 | Bbmaj7 |
| Am7 | D7 | Gm7 | C7 |
''');
      expect(result.problems, isEmpty);
      expect(result.song.leadSheet.barCount, 16);
      expect(result.song.key.toString(), 'F');
      // The bar with two chords divides evenly.
      final split = chordsOf(result).where((c) => c.bar == 6).toList();
      expect(split, hasLength(2));
      expect(split[1].beat, 2);
      // And it makes a playable song.
      expect(result.song.structure.songParts, isNotEmpty);
    });
  });

  group('bad input is reported, never thrown', () {
    // `parse` signals trouble with a `FormatException` and a `problems` list.
    // These three escaped as `ArgumentError`s from deep inside the domain and
    // crashed the import screen, which catches the documented type.
    test('an empty Title: header leaves the song untitled', () {
      // `headers['title'] ?? 'Untitled'` never fired, because an empty header
      // leaves an empty string rather than a null, and `Song` refuses one.
      final result = TextImporter.parse('Title:\n| Dm7 | G7 |\n', id: 'x');
      expect(result.song.title, 'Untitled');
    });

    test('a whitespace-only Title: header leaves the song untitled', () {
      final result = TextImporter.parse('Title:   \n| Dm7 | G7 |\n', id: 'x');
      expect(result.song.title, 'Untitled');
    });

    test('a real title still wins', () {
      final result = TextImporter.parse('Title: Blues\n| Dm7 |\n', id: 'x');
      expect(result.song.title, 'Blues');
    });

    test('a dangling ending marker is reported, not thrown', () {
      // `|2.` with no bar after it closes before it starts, and `CliEnding`
      // refuses that — from outside the catch that handles every other bad
      // item.
      final result = TextImporter.parse('| Dm7 | G7 |\n|2.\n', id: 'x');
      expect(result.song.leadSheet.barCount, 2);
      expect(result.problems, isNotEmpty);
      expect(result.problems.join(), contains('names no bars'));
    });

    test('a section line after the last bar is reported, not dropped', () {
      // The duplicate-section case was reported and this one was not, which
      // meant a chart could lose its coda marking in silence.
      final result = TextImporter.parse('A:\n| Dm7 | G7 |\nCoda:\n', id: 'x');
      expect(result.problems.join(), contains('after the last bar'));
    });
  });
}
