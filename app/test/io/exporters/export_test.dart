import 'dart:convert';
import 'dart:io';

import 'package:bandstand/domain/generation/drum_generator.dart';
import 'package:bandstand/domain/generation/drum_patterns.dart';
import 'package:bandstand/domain/generation/song_generator.dart';
import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:bandstand/domain/song/lead_sheet_item.dart';

import 'package:bandstand/domain/song/chord_leadsheet.dart';
import 'package:bandstand/domain/song/section.dart';
import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/domain/song/song_part.dart';
import 'package:bandstand/domain/song/song_structure.dart';
import 'package:bandstand/io/exporters/export_service.dart';
import 'package:bandstand/io/exporters/midi_export.dart';
import 'package:bandstand/io/exporters/musicxml_export.dart';
import 'package:bandstand/io/exporters/pdf_export.dart';
import 'package:bandstand/io/importers/musicxml_import.dart';
import 'package:bandstand/io/midi/midi_file.dart';
import 'package:bandstand/io/song_library.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../domain/harmony/harmony_test_support.dart';

/// §5.3's exporters, per `docs/rules/exporters.md`.
void main() {
  installTestHarmony();

  Song tune() {
    var sheet = ChordLeadSheet.empty(barCount: 8);
    const chords = <String>['Dm7', 'G7', 'Cmaj7', 'Cmaj7'];
    for (var bar = 0; bar < 8; bar++) {
      sheet = sheet.withItem(
        CliChordSymbol(
          Position(bar, 0),
          ExtChordSymbol.parse(chords[bar % chords.length]),
        ),
      );
    }
    // `ChordLeadSheet.empty` already opens with a section called A, so only
    // the second one is added here.
    sheet = sheet.withItem(CliSection(Section(name: 'B', startBar: 4)));
    return Song.blank(
      id: 'export',
      title: 'Test Tune',
      barCount: 8,
    ).copyWith(leadSheet: sheet, composer: 'A Composer');
  }

  GeneratedSong generatedTune() {
    final generators = SongGenerator(<DrumGenerator>[
      DrumGenerator(
        DrumPatternSet.fromJson(
          File('assets/drum_patterns.json').readAsStringSync(),
        ),
      ),
    ]);
    final song = tune();
    return generators.generate(
      song.copyWith(
        structure: SongStructure(<SongPart>[
          for (final part in song.structure.songParts)
            part.copyWith(rhythmId: 'drums'),
        ]),
      ),
    );
  }

  group('MIDI export (§2)', () {
    test('it writes a readable format-1 file', () {
      final bytes = MidiExporter.export(tune(), generatedTune());
      final read = MidiFileReader.read(bytes);
      expect(read.format, 1);
      expect(read.ticksPerQuarter, greaterThan(0));
      // A conductor track, then one per voice.
      expect(read.tracks.length, greaterThanOrEqualTo(2));
    });

    test(
      'the conductor track carries the tempo and a marker per song part',
      () {
        final song = tune();
        final bytes = MidiExporter.export(song, generatedTune());
        final conductor = MidiFileReader.read(bytes).tracks.first;

        final tempos = conductor.events
            .where((event) => event.tempoBpm != null)
            .toList();
        expect(tempos, isNotEmpty);
        expect(tempos.first.tempoBpm, closeTo(song.tempo.toDouble(), 0.5));

        // §5.3 asks for the markers by name: they are what makes an exported
        // file navigable in a DAW.
        const markerMeta = 0x06;
        final markers = conductor.events
            .where((event) => event.metaType == markerMeta)
            .toList();
        expect(markers, hasLength(song.structure.songParts.length));
      },
    );

    test('every voice gets a named track, a patch and its notes', () {
      final generated = generatedTune();
      final read = MidiFileReader.read(MidiExporter.export(tune(), generated));
      final voiceTracks = read.tracks.skip(1).toList();
      expect(voiceTracks, hasLength(generated.voices.length));

      for (final track in voiceTracks) {
        const trackNameMeta = 0x03;
        expect(
          track.events.any((event) => event.metaType == trackNameMeta),
          isTrue,
          reason: 'a track with no name is unusable in a DAW',
        );
        expect(
          track.events.any((event) => event.status == 0xC0),
          isTrue,
          reason: 'no program change, so it is silent without our soundbank',
        );
        expect(track.events.any((event) => event.isNoteOn), isTrue);
      }
    });

    test('the drum track is on the General MIDI percussion channel', () {
      final generated = generatedTune();
      final read = MidiFileReader.read(MidiExporter.export(tune(), generated));
      final drumIndex = generated.voices.indexWhere(
        (voice) => voice.voice.id == 'drums',
      );
      expect(drumIndex, isNot(-1));
      // The tracks after the conductor line up with the voices in order, so
      // the drum voice's track is the one to make the claim about — not the
      // file as a whole.
      final drumTrack = read.tracks[1 + drumIndex];
      final notes = drumTrack.events.where((event) => event.isNoteOn).toList();
      expect(notes, isNotEmpty);
      expect(
        notes.every((event) => event.channel == MidiExporter.drumChannel),
        isTrue,
      );
    });

    test('every note-off comes after its note-on', () {
      // A zero-length note is a note-off before its note-on, which some readers
      // drop and others treat as a stuck note.
      final read = MidiFileReader.read(
        MidiExporter.export(tune(), generatedTune()),
      );
      // Keyed by channel and pitch together: the same key struck on two
      // channels is two notes, and one of them sounding must not close the
      // other.
      final open = <({int channel, int pitch}), int>{};
      for (final event in read.allEvents) {
        if (event.isNoteOn) {
          open[(channel: event.channel, pitch: event.data1)] = event.tick;
        } else if (event.isNoteOff) {
          final started = open.remove((
            channel: event.channel,
            pitch: event.data1,
          ));
          if (started != null) {
            expect(event.tick, greaterThan(started));
          }
        }
      }
    });

    test('the same song and seed gives byte-identical files', () {
      // §11.2's determinism test, applied at the export boundary.
      final song = tune();
      final first = MidiExporter.export(song, generatedTune());
      final again = MidiExporter.export(song, generatedTune());
      expect(first, again);
    });
  });

  group('MusicXML export (§5)', () {
    test('it writes a partwise score with the work and the composer', () {
      final xml = MusicXmlExporter.export(tune());
      expect(xml, contains('<score-partwise version="4.0">'));
      expect(xml, contains('<work-title>Test Tune</work-title>'));
      expect(xml, contains('A Composer'));
      expect(xml, contains('</score-partwise>'));
    });

    test('one measure per written bar', () {
      final song = tune();
      final xml = MusicXmlExporter.export(song);
      final measures = RegExp('<measure number=').allMatches(xml).length;
      expect(measures, song.leadSheet.barCount);
    });

    test('chords are spelled, not reduced to pitch classes', () {
      // B flat is B with an alter of -1. Writing A sharp would be wrong in
      // exactly the way the spelling rules exist to prevent.
      var sheet = ChordLeadSheet.empty(barCount: 2)
          .withItem(CliChordSymbol(Position(0, 0), ExtChordSymbol.parse('Bb7')))
          .withItem(
            CliChordSymbol(Position(1, 0), ExtChordSymbol.parse('F#m7')),
          );
      final xml = MusicXmlExporter.export(
        Song.blank(
          id: 'x',
          title: 'Spelling',
          barCount: 2,
        ).copyWith(leadSheet: sheet),
      );
      expect(xml, contains('<root-step>B</root-step>'));
      expect(xml, contains('<root-alter>-1</root-alter>'));
      expect(xml, contains('<root-step>F</root-step>'));
      expect(xml, contains('<root-alter>1</root-alter>'));
    });

    test('a quality MusicXML has no kind for keeps its symbol in text', () {
      final sheet = ChordLeadSheet.empty(
        barCount: 1,
      ).withItem(CliChordSymbol(Position(0, 0), ExtChordSymbol.parse('C7alt')));
      final xml = MusicXmlExporter.export(
        Song.blank(
          id: 'x',
          title: 'Altered',
          barCount: 1,
        ).copyWith(leadSheet: sheet),
      );
      // Nothing is silently renamed.
      expect(xml, contains('text="7alt"'));
    });

    test('a slash chord keeps its bass', () {
      final sheet = ChordLeadSheet.empty(
        barCount: 1,
      ).withItem(CliChordSymbol(Position(0, 0), ExtChordSymbol.parse('C/G')));
      final xml = MusicXmlExporter.export(
        Song.blank(
          id: 'x',
          title: 'Slash',
          barCount: 1,
        ).copyWith(leadSheet: sheet),
      );
      expect(xml, contains('<bass-step>G</bass-step>'));
    });

    test('a repeat exports as a repeat, not as the bars played twice', () {
      final sheet = ChordLeadSheet.empty(barCount: 4)
          .withItem(CliChordSymbol(Position(0, 0), ExtChordSymbol.parse('C')))
          .withItem(CliRepeat(Position(0, 0), isStart: true))
          .withItem(CliRepeat(Position(3, 0), isStart: false, playCount: 2));
      final xml = MusicXmlExporter.export(
        Song.blank(
          id: 'x',
          title: 'Repeated',
          barCount: 4,
        ).copyWith(leadSheet: sheet),
      );
      // Four measures, not eight: the written page, not the flattened one.
      expect(RegExp('<measure number=').allMatches(xml).length, 4);
      expect(xml, contains('<repeat direction="forward"/>'));
      expect(xml, contains('direction="backward"'));
    });

    test('a section becomes a rehearsal mark', () {
      final xml = MusicXmlExporter.export(tune());
      expect(xml, contains('<rehearsal>A</rehearsal>'));
      expect(xml, contains('<rehearsal>B</rehearsal>'));
    });

    test('a chord offset counts the bar’s own beats', () {
      // `Position.beat` counts written beats, and a MusicXML `<offset>` counts
      // divisions per quarter: in 6/8 the chord on the third written beat is
      // one quarter into the bar, not two.
      final sheet = ChordLeadSheet.empty(
        barCount: 2,
        timeSignature: TimeSignature.sixEight,
      ).withItem(CliChordSymbol(Position(0, 2), ExtChordSymbol.parse('C7')));
      final xml = MusicXmlExporter.export(
        Song.blank(
          id: 'x',
          title: 'Six Eight',
          barCount: 2,
        ).copyWith(leadSheet: sheet),
      );
      expect(xml, contains('<offset>4</offset>'));
    });

    test('a meter change is written, and every bar keeps its own length', () {
      final sheet = ChordLeadSheet.empty(barCount: 8).withItem(
        CliSection(
          Section(
            name: 'B',
            startBar: 4,
            timeSignature: TimeSignature.threeFour,
          ),
        ),
      );
      final xml = MusicXmlExporter.export(
        Song.blank(
          id: 'x',
          title: 'Meter Change',
          barCount: 8,
        ).copyWith(leadSheet: sheet),
      );
      final measures = RegExp(
        '<measure number="(\\d+)">(.*?)\\n    </measure>',
        dotAll: true,
      ).allMatches(xml).map((match) => match.group(2)!).toList();
      expect(measures, hasLength(8));

      // The first bar carries the opening attributes, as it always did.
      expect(measures[0], contains('<beats>4</beats>'));
      expect(measures[0], contains('<beat-type>4</beat-type>'));
      expect(measures[0], contains('<duration>16</duration>'));

      // The bar the 3/4 section starts gets new time attributes, and its
      // whole-measure rest is three quarters long, not four.
      expect(measures[4], contains('<attributes>'));
      expect(measures[4], contains('<beats>3</beats>'));
      expect(measures[4], contains('<beat-type>4</beat-type>'));
      expect(measures[4], contains('<duration>12</duration>'));
    });

    test('first and second endings export as endings', () {
      final sheet = ChordLeadSheet.empty(barCount: 8)
          .withItem(CliChordSymbol(Position(0, 0), ExtChordSymbol.parse('C')))
          .withItem(CliRepeat(Position(0, 0), isStart: true))
          .withItem(CliEnding(Position(6), <int>{1}))
          .withItem(CliEnding(Position(7), <int>{2}))
          .withItem(CliRepeat(Position(7), isStart: false, playCount: 2));
      final xml = MusicXmlExporter.export(
        Song.blank(
          id: 'x',
          title: 'Endings',
          barCount: 8,
        ).copyWith(leadSheet: sheet),
      );
      expect(xml, contains('<ending number="1" type="start">'));
      expect(xml, contains('<ending number="2" type="start">'));
      expect(xml, contains('<ending number="1" type="stop"/>'));
      expect(xml, contains('<ending number="2" type="stop"/>'));
    });

    test('endings and repeats survive the round trip through the importer', () {
      final sheet = ChordLeadSheet.empty(barCount: 8)
          .withItem(CliChordSymbol(Position(0, 0), ExtChordSymbol.parse('C')))
          .withItem(CliRepeat(Position(0, 0), isStart: true))
          .withItem(CliEnding(Position(6), <int>{1}))
          .withItem(CliEnding(Position(7), <int>{2}))
          .withItem(CliRepeat(Position(7), isStart: false, playCount: 2));
      final song = Song.blank(
        id: 'x',
        title: 'Endings',
        barCount: 8,
      ).copyWith(leadSheet: sheet);

      final imported = MusicXmlImporter.parse(
        MusicXmlExporter.export(song),
        id: 'y',
      );
      final endings = imported.song.leadSheet.items
          .whereType<CliEnding>()
          .toList();
      expect(endings, hasLength(2));
      expect(endings.any((ending) => ending.passNumbers.contains(1)), isTrue);
      expect(endings.any((ending) => ending.passNumbers.contains(2)), isTrue);
      expect(
        imported.song.leadSheet.items.whereType<CliRepeat>(),
        hasLength(2),
      );
    });

    test('navigation marks export as directions', () {
      final sheet = ChordLeadSheet.empty(barCount: 8)
          .withItem(CliChordSymbol(Position(0, 0), ExtChordSymbol.parse('C')))
          .withItem(CliNavigation(Position(4), NavigationMark.segno))
          .withItem(CliNavigation(Position(7), NavigationMark.daCapoAlCoda));
      final xml = MusicXmlExporter.export(
        Song.blank(
          id: 'x',
          title: 'Road Signs',
          barCount: 8,
        ).copyWith(leadSheet: sheet),
      );
      // The written label for the reader, and the `<sound>` attributes
      // notation software follows when playing the jump.
      expect(xml, contains('<words>Segno</words>'));
      expect(xml, contains('<segno/>'));
      expect(xml, contains('<words>D.C. al Coda</words>'));
      expect(xml, contains('dacapo="yes"'));
      expect(xml, contains('tocoda="coda"'));
    });

    test('an annotation exports as words', () {
      final sheet = ChordLeadSheet.empty(barCount: 2)
          .withItem(CliAnnotation(Position(1), 'solo break'));
      final xml = MusicXmlExporter.export(
        Song.blank(
          id: 'x',
          title: 'Note',
          barCount: 2,
        ).copyWith(leadSheet: sheet),
      );
      expect(xml, contains('<words>solo break</words>'));
    });

    test(
      'the title is escaped, so a title with markup in it is not markup',
      () {
        final xml = MusicXmlExporter.export(
          Song.blank(id: 'x', title: 'Bell <&> Whistle', barCount: 1),
        );
        expect(xml, contains('Bell &lt;&amp;&gt; Whistle'));
        expect(xml, isNot(contains('Bell <&> Whistle')));
      },
    );
  });

  group('PDF export (§4)', () {
    // `testWidgets` rather than `test`, because rasterising the painter goes
    // through the engine and only the widget binding provides one — and every
    // call is wrapped in `runAsync`, because `Picture.toImage` is *real* async
    // work and `testWidgets` runs in a fake-async zone where it never
    // completes. The same trap M2 hit with filesystem futures, and it presents
    // as a hang rather than a failure.
    testWidgets('it writes a PDF a reader will open', (tester) async {
      final bytes = (await tester.runAsync(() => PdfExporter.export(tune())))!;
      expect(bytes.length, greaterThan(1000));
      // Every PDF begins with its version and ends with the end-of-file
      // marker; a truncated one has the first and not the second.
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      final tail = String.fromCharCodes(bytes.skip(bytes.length - 32));
      expect(tail, contains('%%EOF'));
    });

    testWidgets('the title and composer are in the document', (tester) async {
      final bytes = (await tester.runAsync(() => PdfExporter.export(tune())))!;
      // The strings are written into the Info dictionary as metadata, whether
      // or not a reader is here to draw them: a PDF with no title is one a
      // bandstand full of them cannot be sorted by.
      final document = String.fromCharCodes(bytes);
      expect(document, contains('/Title(Test Tune)'));
      expect(document, contains('/Author(A Composer)'));
    });

    testWidgets('the heading height is measured, not guessed', (tester) async {
      // The chart used to start at a fixed 150 px regardless of what the
      // heading actually measured, and a two-line heading (title + composer)
      // ran ~30 px past it into the first bar.
      const scale = PdfExporter.dpi / 72;
      final width =
          (PdfExporter.pageWidthPoints - PdfExporter.marginPoints * 2) * scale;
      final twoLines = (await tester.runAsync(
        () => PdfExporter.headingHeight(tune(), width, scale),
      ))!;
      expect(twoLines, greaterThan(150));
      final withoutComposer = tune().copyWith(composer: '');
      final oneLine = (await tester.runAsync(
        () => PdfExporter.headingHeight(withoutComposer, width, scale),
      ))!;
      expect(oneLine, lessThan(twoLines));
    });

    testWidgets('a transposed export is a different page', (tester) async {
      // The layout engine transposes, so the exported page is the tune in the
      // key asked for rather than the written one.
      final written = (await tester.runAsync(
        () => PdfExporter.export(tune()),
      ))!;
      final moved = (await tester.runAsync(
        () => PdfExporter.export(tune(), transposition: 3),
      ))!;
      expect(moved, isNot(written));
    });

    testWidgets('an empty chart still produces a page', (tester) async {
      // A tune someone has just created has no chords in it, and exporting it
      // should give a blank chart rather than an error.
      final bytes = (await tester.runAsync(
        () => PdfExporter.export(
          Song.blank(id: 'empty', title: 'Nothing Yet', barCount: 8),
        ),
      ))!;
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    });
  });

  group('where files go (§6)', () {
    late Directory root;
    late ExportService service;

    setUp(() async {
      root = Directory.systemTemp.createTempSync('bandstand-export');
      final library = SongLibrary(root);
      await library.ensureLayout();
      service = ExportService(library);
    });

    tearDown(() {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    });

    test('an export lands beside the library and says where', () async {
      final result = await service.exportMusicXml(tune());
      expect(result.file.existsSync(), isTrue);
      expect(result.file.path, contains('exports'));
      // The name carries the song's id, so two tunes with the same title
      // never overwrite each other (§6's "under the song's title", made safe).
      expect(result.name, 'Test Tune-export.musicxml');
      expect(result.bytes, greaterThan(0));
    });

    test('two songs with the same title do not overwrite each other', () async {
      final first = await service.exportMusicXml(tune());
      final other = tune();
      final second = await service.exportMusicXml(
        Song.blank(
          id: 'other',
          title: other.title,
          barCount: 8,
        ).copyWith(leadSheet: other.leadSheet),
      );
      expect(first.file.path, isNot(second.file.path));
      expect(first.file.existsSync(), isTrue);
      expect(second.file.existsSync(), isTrue);
      expect(service.exportsDirectory.listSync(), hasLength(2));
    });

    test('MIDI and MusicXML sit side by side', () async {
      final midi = await service.exportMidi(tune(), generatedTune());
      final xml = await service.exportMusicXml(tune());
      expect(midi.file.parent.path, xml.file.parent.path);
      expect(midi.name, endsWith('.mid'));
    });

    test('it leaves no temporary file behind', () async {
      await service.exportMusicXml(tune());
      final leftovers = service.exportsDirectory.listSync().where(
        (entry) => entry.path.endsWith('.tmp'),
      );
      expect(leftovers, isEmpty);
    });

    test('a title that is not a filename is made into one', () {
      // Titles have slashes and colons in them, and any of those makes a path
      // that either fails or lands somewhere unexpected.
      expect(ExportService.safeFileName('A/B Blues'), 'A-B Blues');
      expect(ExportService.safeFileName('Who: Me?'), 'Who- Me-');
      expect(ExportService.safeFileName('   '), 'Untitled');
      expect(ExportService.safeFileName('CON'), '_CON');
      expect(ExportService.safeFileName('x' * 200).length, 120);
    });

    test('a long name is cut by bytes, on a character boundary', () {
      // Filesystems and network shares count UTF-8 bytes, and a cut that
      // splits a surrogate pair produces bytes nothing reads back.
      final name = ExportService.safeFileName('♭' * 100);
      expect(utf8.encode(name).length, lessThanOrEqualTo(120));
      expect(name, '♭' * 40); // three UTF-8 bytes a character
      expect(ExportService.safeFileName('x' * 119 + '♭'), 'x' * 119);
    });

    test('exporting twice overwrites rather than accumulating', () async {
      final first = await service.exportMusicXml(tune());
      final second = await service.exportMusicXml(tune());
      expect(first.file.path, second.file.path);
      expect(service.exportsDirectory.listSync(), hasLength(1));
    });
  });

  group('MusicXML marks that sit at the end of a bar', () {
    /// A chart with `mark` written on its last bar.
    Song withMark(NavigationMark mark) {
      var sheet = ChordLeadSheet.empty(barCount: 4);
      for (var bar = 0; bar < 4; bar++) {
        sheet = sheet.withItem(
          CliChordSymbol(Position(bar, 0), ExtChordSymbol.parse('Cmaj7')),
        );
      }
      sheet = sheet.withItem(CliNavigation(Position(3), mark));
      return Song.blank(
        id: 'nav',
        title: 'Nav',
        barCount: 4,
      ).copyWith(leadSheet: sheet);
    }

    /// The text of measure `number` in `xml`.
    String measureText(String xml, int number) =>
        RegExp('<measure number="$number">[\\s\\S]*?</measure>')
            .firstMatch(xml)!
            .group(0)!;

    for (final mark in <NavigationMark>[
      NavigationMark.daCapo,
      NavigationMark.dalSegno,
      NavigationMark.toCoda,
      NavigationMark.fine,
    ]) {
      test('${mark.label} is written after the bar it fires on', () {
        // These are `BarAnchor.tail`: the jump happens once the bar has been
        // played. Writing the direction at the head of the measure told a
        // reader to jump before playing it, dropping a whole bar.
        expect(mark.anchor, BarAnchor.tail);
        final measure = measureText(MusicXmlExporter.export(withMark(mark)), 4);
        expect(
          measure.indexOf(mark.label),
          greaterThan(measure.indexOf('<note>')),
          reason: '${mark.label} was written at the head of its measure',
        );
      });
    }

    for (final mark in <NavigationMark>[
      NavigationMark.segno,
      NavigationMark.coda,
    ]) {
      test('${mark.label} is still written before the bar', () {
        // A place you jump *to*, so it belongs at the head.
        expect(mark.anchor, BarAnchor.head);
        final measure = measureText(MusicXmlExporter.export(withMark(mark)), 4);
        expect(
          measure.indexOf(mark.label),
          lessThan(measure.indexOf('<note>')),
        );
      });
    }

    test('an ending overhanging the last bar still closes', () {
      // An unclosed `<ending>` is not valid MusicXML: readers either refuse
      // the file or bracket the rest of the piece.
      var sheet = ChordLeadSheet.empty(barCount: 4);
      for (var bar = 0; bar < 4; bar++) {
        sheet = sheet.withItem(
          CliChordSymbol(Position(bar, 0), ExtChordSymbol.parse('Cmaj7')),
        );
      }
      sheet = sheet.withItem(CliEnding(Position(3), <int>{1}, barCount: 2));
      final xml = MusicXmlExporter.export(
        Song.blank(id: 'e', title: 'E', barCount: 4).copyWith(leadSheet: sheet),
      );
      final starts = RegExp('<ending[^>]*type="start"').allMatches(xml).length;
      final stops = RegExp('<ending[^>]*type="stop"').allMatches(xml).length;
      expect(starts, 1);
      expect(stops, starts, reason: 'the bracket was never closed');
    });
  });
}
