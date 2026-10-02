import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:bandstand/domain/song/lead_sheet_item.dart';
import 'package:bandstand/domain/song/navigation.dart';
import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/io/importers/ireal_import.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../domain/harmony/harmony_test_support.dart';

void main() {
  installTestHarmony();

  ImportedSong song(String chordString, {String title = 'Test'}) =>
      IRealImporter.parseSong(
        '$title=Tester Anne=Medium Swing=C=n=$chordString',
      );

  List<String> chordsOf(ImportedSong imported) => <String>[
    for (final item in imported.leadSheet.chordItems) item.chord.format(),
  ];

  group('the URL', () {
    test('reads a chart out of an irealbook URL', () {
      final result = IRealImporter.parseUrl(
        'irealbook://Blue%20Bossa=Dorham%20Kenny=Medium%20Bossa=Cm=n='
        '%7BT44Cm7%20%7CCm7%20%7CFm7%20%7CFm7%20%7D',
      );
      expect(result.songs, hasLength(1));
      final imported = result.songs.single;
      expect(imported.title, 'Blue Bossa');
      expect(imported.composer, 'Kenny Dorham');
      expect(imported.style, 'Medium Bossa');
      expect(imported.keyName, 'Cm');
      expect(imported.leadSheet.barCount, 4);
    });

    test('reads several charts and the playlist name', () {
      final result = IRealImporter.parseUrl(
        'irealbook://One=A B=Swing=C=n=|C |===Two=C D=Swing=F=n=|F |'
        '===My Gig',
      );
      expect(result.songs.map((s) => s.title), <String>['One', 'Two']);
      expect(result.name, 'My Gig');
      expect(result.isClean, isTrue);
    });

    test('recognises both schemes but only reads the plain one', () {
      expect(IRealImporter.looksLikeIReal('irealbook://x'), isTrue);
      expect(IRealImporter.looksLikeIReal('irealb://x'), isTrue);
      expect(IRealImporter.looksLikeIReal('https://example.com'), isFalse);
      expect(
        () => IRealImporter.parseUrl('irealb://scrambled'),
        throwsA(isA<IRealScramblingNotSupported>()),
      );
      expect(
        () => IRealImporter.parseUrl('https://example.com'),
        throwsA(isA<NotAnIRealUrl>()),
      );
    });

    test('a chunk with too few fields is reported, not dropped silently', () {
      final result = IRealImporter.parseUrl('irealbook://Broken=Thing');
      expect(result.songs, isEmpty);
      expect(result.problems, hasLength(1));
    });

    test('a malformed percent-escape is refused as not an iReal URL', () {
      expect(
        () => IRealImporter.parseUrl('irealbook://Blue%ZZBossa=Dorham%20Kenny'),
        throwsA(isA<NotAnIRealUrl>()),
      );
    });

    test('a composer with one or three names is left alone', () {
      expect(song('|C |', title: 'x').composer, 'Anne Tester');
      expect(
        IRealImporter.parseSong('x=Ellington=Swing=C=n=|C |').composer,
        'Ellington',
      );
      expect(
        IRealImporter.parseSong('x=Ray Noble Trio=Swing=C=n=|C |').composer,
        'Ray Noble Trio',
      );
    });
  });

  group('bars and chords', () {
    test('one chord fills its bar', () {
      final imported = song('|C |Dm7 |G7 |Cmaj7 |');
      expect(imported.leadSheet.barCount, 4);
      expect(chordsOf(imported), <String>['C', 'Dm7', 'G7', 'Cmaj7']);
      for (final item in imported.leadSheet.chordItems) {
        expect(item.position.beat, 0);
      }
    });

    test('two chords split the bar', () {
      final imported = song('|Dm7 G7 |');
      expect(imported.leadSheet.barCount, 1);
      expect(
        imported.leadSheet.chordItems.map((c) => c.position.beat),
        <double>[0, 2],
      );
    });

    test('four chords take a beat each', () {
      final imported = song('|C Dm7 Em7 F |');
      expect(
        imported.leadSheet.chordItems.map((c) => c.position.beat),
        <double>[0, 1, 2, 3],
      );
    });

    test('a hold gives the chord before it more of the bar', () {
      final imported = song('|C p Dm7 p |');
      expect(chordsOf(imported), <String>['C', 'Dm7']);
      expect(
        imported.leadSheet.chordItems.map((c) => c.position.beat),
        <double>[0, 2],
      );
    });

    test('a bar of holds carries the previous chord, writing nothing', () {
      final imported = song('|C |p |');
      expect(imported.leadSheet.barCount, 2);
      expect(chordsOf(imported), <String>['C']);
      // The chart still sounds C in bar two.
      expect(imported.leadSheet.chordAt(Position(1))!.format(), 'C');
    });

    test(
      'a hold at the head of a bar reserves the entering chord its share',
      () {
        // L-I3: `p G7` in one bar means the previous chord takes the first
        // half and G7 enters on the second — not G7 from beat 0 taking the
        // whole bar.
        final imported = song('|C |p G7 |');
        expect(chordsOf(imported), <String>['C', 'G7']);
        expect(
          imported.leadSheet.chordItems.map((c) => c.position.beat),
          <double>[0, 2],
        );
      },
    );

    test('iReal quality shorthand goes through the ordinary parser', () {
      final imported = song('|C^7 |D-7 |Eh7 |F#o7 |G7alt |Absus |Bb^9#11 |');
      expect(chordsOf(imported), <String>[
        'Cmaj7',
        'Dm7',
        'Em7b5',
        'F#o7',
        'G7alt',
        'Absus4',
        'Bbmaj9#11',
      ]);
    });

    test('slash chords survive', () {
      expect(chordsOf(song('|C/E |Dm7/G |')), <String>['C/E', 'Dm7/G']);
    });

    test('n is no chord', () {
      final imported = song('|n |C |');
      expect(imported.leadSheet.chordItems.first.chord.isNoChord, isTrue);
      expect(chordsOf(imported), <String>['N.C.', 'C']);
    });

    test('a chord that will not parse is reported with its bar', () {
      final imported = song('|C |Zzz |G7 |');
      expect(imported.isClean, isFalse);
      expect(imported.problems.first.bar, isNotNull);
      expect(imported.problems.first.toString(), contains('cannot read'));
      // The bars around it still read.
      expect(chordsOf(imported), contains('C'));
    });
  });

  group('structure', () {
    test('braces become repeat barlines', () {
      final imported = song('{C |Dm7 |G7 |C }');
      final repeats = imported.leadSheet.items.whereType<CliRepeat>().toList();
      expect(repeats, hasLength(2));
      expect(repeats.first.isStart, isTrue);
      expect(repeats.first.bar, 0);
      expect(repeats.last.isStart, isFalse);
      expect(repeats.last.bar, 3);
    });

    test('a repeat actually plays twice once resolved', () {
      final imported = song('{C |Dm7 }');
      final form = resolveNavigation(imported.leadSheet);
      expect(form.sourceBars, <int>[0, 1, 0, 1]);
    });

    test('numbered endings span to the next ending or the repeat', () {
      final imported = song('{C |Dm7 |N1 G7 |C }|N2 F |G7 |');
      final endings = imported.leadSheet.items.whereType<CliEnding>().toList();
      expect(endings, hasLength(2));
      expect(endings[0].passNumbers, <int>{1});
      expect(endings[0].bar, 2);
      expect(endings[0].barCount, 2);
      expect(endings[1].passNumbers, <int>{2});
      expect(endings[1].bar, 4);
    });

    test('section markers become sections', () {
      final imported = song('*A{C |Dm7 }|*BF |G7 |');
      expect(imported.leadSheet.sections.map((s) => s.name), <String>[
        'A',
        'B',
      ]);
      expect(imported.leadSheet.sections.first.startBar, 0);
      expect(imported.leadSheet.sections.last.startBar, 2);
    });

    test('intro and verse markers are named, not lettered', () {
      final imported = song('*iC |*vDm7 |*AG7 |');
      expect(imported.leadSheet.sections.map((s) => s.name), <String>[
        'Intro',
        'Verse',
        'A',
      ]);
    });

    test('a reused section letter gets a distinct name', () {
      final imported = song('*AC |*BDm7 |*AG7 |');
      expect(imported.leadSheet.sections.map((s) => s.name), <String>[
        'A',
        'B',
        'A2',
      ]);
    });

    test('S is a segno, the first Q is To Coda and the second is the Coda', () {
      final imported = song('|SC |QDm7 |G7 |QC |');
      final marks = imported.leadSheet.items
          .whereType<CliNavigation>()
          .map((item) => item.mark)
          .toList();
      expect(
        marks,
        containsAll(<NavigationMark>[
          NavigationMark.segno,
          NavigationMark.toCoda,
          NavigationMark.coda,
        ]),
      );
    });

    test('a time signature is read and applied', () {
      final imported = song('T34|C |Dm7 |');
      expect(imported.leadSheet.timeSignatureAt(0), TimeSignature.threeFour);
      // Three chords in a 3/4 bar take a beat each.
      final three = song('T34|C Dm7 G7 |');
      expect(three.leadSheet.chordItems.map((c) => c.position.beat), <double>[
        0,
        1,
        2,
      ]);
    });

    test('twelve-eight is written T12', () {
      expect(
        song('T12|C |').leadSheet.timeSignatureAt(0),
        const TimeSignature(12, 8),
      );
    });

    test('a mid-chart meter change with no section marker makes one', () {
      // L-I4: the sheet reads a bar's meter from the section governing it,
      // so a `T` without a `*` needs a section of its own, or the change is
      // written but never applied — the MusicXML importer does the same at
      // `_startMeterSection`.
      final imported = song('|C |Dm7 |T34 G7 |Am7 |');
      expect(imported.leadSheet.sectionAt(0)!.name, 'A');
      final meter = imported.leadSheet.sectionAt(2);
      expect(meter!.name, '3/4');
      expect(meter.timeSignature, TimeSignature.threeFour);
      // The synthesized section governs onward from its bar.
      expect(imported.leadSheet.timeSignatureAt(3), TimeSignature.threeFour);
    });

    test('x repeats the bar before it', () {
      final imported = song('|C |x |x |');
      expect(imported.leadSheet.barCount, 3);
      expect(chordsOf(imported), <String>['C', 'C', 'C']);
    });

    test('r repeats the two bars before it', () {
      final imported = song('|C |Dm7 |r |');
      expect(imported.leadSheet.barCount, 4);
      expect(chordsOf(imported), <String>['C', 'Dm7', 'C', 'Dm7']);
    });

    test('a bar repeat with nothing before it is reported', () {
      final imported = song('|x |C |');
      expect(imported.isClean, isFalse);
      expect(imported.problems.first.toString(), contains('nothing before it'));
    });
  });

  group('the noise iReal writes', () {
    test('fillers, spacers and size hints carry no meaning', () {
      final plain = song('|C |Dm7 |');
      final noisy = song('XyQ|sC ,Y |lDm7 f|XyQ');
      expect(chordsOf(noisy), chordsOf(plain));
      expect(noisy.leadSheet.barCount, plain.leadSheet.barCount);
    });

    test('angle brackets become annotations', () {
      final imported = song('|C <play twice> |Dm7 |');
      final notes = imported.leadSheet.items
          .whereType<CliAnnotation>()
          .map((item) => item.text)
          .toList();
      expect(notes, <String>['play twice']);
    });

    test('an alternate chord is kept as a note rather than played', () {
      final imported = song('|C (Am7) |Dm7 |');
      expect(chordsOf(imported), <String>['C', 'Dm7']);
      expect(
        imported.leadSheet.items.whereType<CliAnnotation>().single.text,
        '(Am7)',
      );
    });

    test(
      'an unclosed annotation is reported rather than swallowing the tune',
      () {
        final imported = song('|C <never closed |Dm7 |');
        expect(imported.isClean, isFalse);
      },
    );

    test('Z and U close the chart without adding bars', () {
      final imported = song('|C |Dm7 Z');
      expect(imported.leadSheet.barCount, 2);
      final ended = song('|C |Dm7 |U');
      expect(ended.leadSheet.barCount, 2);
    });
  });

  group('turning a chart into a song', () {
    test('carries the metadata the library shows', () {
      final imported = IRealImporter.parseSong(
        'Blue Bossa=Dorham Kenny=Medium Bossa=Cm=n=|Cm7 |Fm7 |'
        '=Medium Bossa=148=3',
      );
      final result = imported.toSong('an-id');
      expect(result.title, 'Blue Bossa');
      expect(result.composer, 'Kenny Dorham');
      expect(result.key.toString(), 'Cm');
      expect(result.tempo, 148);
      expect(result.meta['source'], 'ireal');
      expect(result.meta['irealStyle'], 'Medium Bossa');
      expect(result.meta['irealRepeats'], '3');
      expect(result.structure.songParts, isNotEmpty);
    });

    test('trailing metadata without the repeated style still aligns', () {
      // Exports disagree about how much trailing metadata they write; a
      // partial export must not shift tempo and repeats out of place.
      final bare = IRealImporter.parseSong('x=y=Swing=C=n=|C |=140');
      expect(bare.tempo, 140);
      expect(bare.repeats, isNull);

      final both = IRealImporter.parseSong('x=y=Swing=C=n=|C |=140=3');
      expect(both.tempo, 140);
      expect(both.repeats, 3);
    });

    test('an unparseable tempo is reported', () {
      final imported = IRealImporter.parseSong('x=y=Swing=C=n=|C |=quick=3');
      expect(imported.isClean, isFalse);
      expect(imported.problems.single.message, contains('not a tempo'));
      expect(imported.repeats, 3);
    });

    test('a chart with no sections still gets one, so it plays', () {
      // As ChordLeadSheet.empty guarantees: without a section the structure
      // points at a section that is not there and nothing plays.
      final imported = song('|C |Dm7 |');
      expect(imported.leadSheet.sections.map((s) => s.name), <String>['A']);
      expect(imported.leadSheet.sections.single.startBar, 0);
      expect(imported.toSong('id').structure.songParts, isNotEmpty);
    });

    test('a key iReal writes that Bandstand cannot read falls back to C', () {
      final imported = IRealImporter.parseSong('x=y=Swing=H#=n=|C |');
      expect(imported.toSong('id').key.toString(), 'C');
    });

    test('a tempo outside the model is clamped rather than refused', () {
      final imported = IRealImporter.parseSong(
        'x=y=Swing=C=n=|C |=Swing=9000=1',
      );
      expect(imported.toSong('id').tempo, maxTempo);
    });
  });

  test('a realistic chart reads with the right bar count and structure', () {
    // A thirty-two bar AABA with a repeat, two endings and a coda.
    final imported = song(
      '*A{T44C^7 |A7 |D-7 |G7 |C^7 |A7 |N1D-7 |G7 }|N2D-7 |G7 |'
      '*BF-7 |Bb7 |Eb^7 |Eb^7 |D-7 |QG7 |'
      '*AC^7 |A7 |D-7 |G7 |C^7 |A7 |D-7 |G7 QC^7 Z',
    );
    expect(imported.isClean, isTrue, reason: '${imported.problems}');
    expect(imported.leadSheet.sections.map((s) => s.name), <String>[
      'A',
      'B',
      'A2',
    ]);
    expect(imported.leadSheet.barCount, 24);

    final form = resolveNavigation(imported.leadSheet);
    // The repeat and its endings expand: eight bars, then bars 1-6 again with
    // the second ending.
    expect(form.sourceBars.take(8), <int>[0, 1, 2, 3, 4, 5, 6, 7]);
    expect(form.sourceBars.skip(8).take(8), <int>[0, 1, 2, 3, 4, 5, 8, 9]);
  });
}
