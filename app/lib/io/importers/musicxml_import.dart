import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:bandstand/domain/harmony/harmony.dart';
import 'package:bandstand/domain/song/chord_leadsheet.dart';
import 'package:bandstand/domain/song/lead_sheet_item.dart';
import 'package:bandstand/domain/song/section.dart';
import 'package:bandstand/domain/song/song.dart';
import 'package:bandstand/domain/generation/written_part_placer.dart';
import 'package:bandstand/domain/song/mixer_settings.dart';
import 'package:bandstand/domain/song/song_structure.dart';
import 'package:bandstand/domain/song/written_part.dart';
import 'package:bandstand/io/importers/musicxml_melody.dart';
import 'package:xml/xml.dart';

/// A chart read out of a MusicXML file, with anything odd about it.
class ImportedMusicXml {
  /// Create a result.
  ImportedMusicXml({required this.song, required List<String> problems})
    : problems = List<String>.unmodifiable(problems);

  /// The tune.
  final Song song;

  /// Anything the file said that could not be carried across.
  ///
  /// Reported rather than swallowed: a chart that silently lost its endings is
  /// a chart that plays wrong on the second chorus.
  final List<String> problems;
}

/// Reads MusicXML into Bandstand's song model.
///
/// Rules: `docs/rules/musicxml-import.md`. Written from the MusicXML 4.0
/// specification, not from any other implementation (§1, §14.2).
abstract final class MusicXmlImporter {
  /// Read a `.musicxml`, `.xml` or `.mxl` file.
  ///
  /// Throws [FormatException] on a document that is not MusicXML at all, or on
  /// a timewise score — a shape nothing produces, and one that would otherwise
  /// import as an empty chart with no explanation (§2).
  static ImportedMusicXml read(
    Uint8List bytes, {
    required String id,
    ChordTypeDatabase? database,
  }) => parse(_textOf(bytes), id: id, database: database);

  /// Read a document that is already text.
  static ImportedMusicXml parse(
    String source, {
    required String id,
    ChordTypeDatabase? database,
  }) {
    final types = database ?? Harmony.chordTypes;
    final XmlDocument document;
    try {
      document = XmlDocument.parse(source);
    } on XmlException catch (error) {
      throw FormatException('not valid XML: ${error.message}');
    }

    final root = document.rootElement;
    if (root.name.local == 'score-timewise') {
      throw const FormatException(
        'this is a timewise MusicXML score; Bandstand reads partwise ones, '
        'which is what every editor writes',
      );
    }
    if (root.name.local != 'score-partwise') {
      throw FormatException(
        'not a MusicXML score: the document element is "${root.name.local}"',
      );
    }

    final problems = <String>[];
    final part = _chordPart(root, problems);
    final measures = part == null
        ? const <XmlElement>[]
        : part.findElements('measure').toList();

    final reader = _Reader(types, problems, root);
    for (final (index, measure) in measures.indexed) {
      reader.readMeasure(index, measure);
    }
    if (measures.isNotEmpty) {
      reader.closeEnding(measures.length - 1);
    }

    final barCount = measures.isEmpty ? 32 : measures.length;
    var sheet = ChordLeadSheet.empty(
      barCount: barCount,
      // The meter the score *opens* in. `reader.timeSignature` is the running
      // value, which by now holds the last meter the file named — so a score
      // that begins in 4/4 and moves to 3/4 used to be stamped 3/4 throughout.
      timeSignature: reader.initialTimeSignature ?? TimeSignature.fourFour,
    );
    if (reader.items.any(
      (item) => item is CliSection && item.section.startBar == 0,
    )) {
      // The file names its own first bar: the empty sheet's default 'A' is
      // a stand-in for a file with no sections, and the two would collide.
      sheet = sheet.withoutWhere(
        (item) => item is CliSection && item.section.startBar == 0,
      );
    }
    final chordPositions = <Position>{};
    for (final item in reader.items) {
      // Two chords on one beat: `withItem` keeps the later one, which is right
      // for the editor (writing a chord over another is how you replace it)
      // and wrong for an importer, where it is a chord the file contained and
      // the chart will not show. Reported here rather than left to the sheet,
      // which does not refuse it however much the comment here used to claim
      // it did.
      if (item is CliChordSymbol && !chordPositions.add(item.position)) {
        problems.add(
          'bar ${item.position.bar + 1}: two chords are written on the same '
          'beat; the later one was kept',
        );
      }
      // A file can also name the same section twice, and the sheet *does*
      // refuse that. One bad measure must not lose the rest of the chart.
      try {
        sheet = sheet.withItem(item);
      } on ArgumentError catch (error) {
        problems.add('bar ${item.position.bar + 1}: ${error.message}');
      }
    }

    if (reader.chordCount == 0) {
      problems.add('this file has no chord symbols in it');
    }

    // The notes, which until §9's written parts had nowhere to go. Read from
    // the whole score rather than from the chord part: the chords are usually
    // on the piano staff and the melody on the vocal one.
    final melody = MusicXmlMelody.read(root, id: 'melody', problems: problems);

    final song = Song(
      id: id,
      title: reader.title ?? 'Untitled',
      composer: reader.composer ?? '',
      tempo: reader.tempo ?? 120,
      key: reader.key ?? KeySignature.cMajor(),
      leadSheet: sheet,
      structure: SongStructure.fromLeadSheet(sheet, rhythmId: defaultRhythmId),
      writtenParts: <WrittenPart>[?melody],
      // Seed the mixer with the sound the part was written for, so an imported
      // horn part sounds like a horn without the player hunting for a slider.
      // It is a starting point, not a fact: the mixer owns it from here.
      mixer: melody == null
          ? MixerSettings.empty()
          : MixerSettings(
              channels: <ChannelSettings>[
                ChannelSettings(
                  voiceId: WrittenPartPlacer.voiceFor(melody).id,
                  midiProgram: melody.program,
                ),
              ],
            ),
    );
    return ImportedMusicXml(song: song, problems: problems);
  }

  /// The part carrying the chords (§3).
  ///
  /// A score has parts and a chart has one, so the one with the most
  /// `<harmony>` elements wins: the piano in a piano-vocal score, the guitar in
  /// a big-band chart, and the only part there is in a lead sheet.
  static XmlElement? _chordPart(XmlElement root, List<String> problems) {
    final parts = root.findElements('part').toList();
    if (parts.isEmpty) {
      problems.add('this score has no parts');
      return null;
    }
    if (parts.length == 1) {
      return parts.first;
    }
    var best = parts.first;
    var bestCount = -1;
    for (final part in parts) {
      final count = part.findAllElements('harmony').length;
      if (count > bestCount) {
        bestCount = count;
        best = part;
      }
    }
    if (bestCount > 0) {
      problems.add(
        'this score has ${parts.length} parts; the chords were taken from '
        '"${best.getAttribute("id") ?? "the first one with harmony"}"',
      );
    }
    return best;
  }

  /// A `.mxl` archive's contents, or the bytes as text.
  ///
  /// `.mxl` is a zip holding the score plus a `META-INF/container.xml` naming
  /// it, and it is what most software actually saves (§2).
  static String _textOf(Uint8List bytes) {
    if (bytes.length > 4 &&
        bytes[0] == 0x50 &&
        bytes[1] == 0x4B &&
        bytes[2] == 0x03 &&
        bytes[3] == 0x04) {
      final archive = ZipDecoder().decodeBytes(bytes);
      final named = _namedInContainer(archive);
      for (final candidate in <String?>[named, null]) {
        for (final file in archive.files) {
          if (!file.isFile) {
            continue;
          }
          final name = file.name;
          if (candidate != null ? name == candidate : _looksLikeScore(name)) {
            return _decode(file.content as List<int>);
          }
        }
      }
      throw const FormatException('this .mxl archive has no score in it');
    }
    return _decode(bytes);
  }

  /// The score named by `META-INF/container.xml`, if it says.
  static String? _namedInContainer(Archive archive) {
    for (final file in archive.files) {
      if (file.name != 'META-INF/container.xml' || !file.isFile) {
        continue;
      }
      try {
        final container = XmlDocument.parse(_decode(file.content as List<int>));
        return container
            .findAllElements('rootfile')
            .map((element) => element.getAttribute('full-path'))
            .whereType<String>()
            .firstOrNull;
      } on XmlException {
        return null;
      }
    }
    return null;
  }

  static bool _looksLikeScore(String name) =>
      !name.startsWith('META-INF/') &&
      (name.endsWith('.xml') || name.endsWith('.musicxml'));

  /// Decode as UTF-8, falling back to Latin-1.
  ///
  /// The declaration says UTF-8 and the bytes are sometimes Latin-1, and the
  /// declaration is inside the document being decoded (ADR 0011). A file that
  /// will not decode is worth reading with the wrong accents rather than not
  /// at all.
  static String _decode(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return latin1.decode(bytes, allowInvalid: true);
    }
  }
}

/// Walks the measures, collecting what Bandstand's model holds.
///
/// Kept apart from [MusicXmlImporter] so the per-measure state — divisions, the
/// running time signature, the ending currently open — lives in one object
/// rather than being threaded through a dozen static calls.
class _Reader {
  _Reader(this._types, this._problems, XmlElement root) {
    _readHeader(root);
  }

  final ChordTypeDatabase _types;
  final List<String> _problems;

  /// What the chart is made of, in the order it was read.
  final List<LeadSheetItem> items = <LeadSheetItem>[];

  /// Title, composer, tempo and key, if the file said.
  String? title;
  String? composer;
  int? tempo;
  KeySignature? key;

  /// The meter in force as the read walks the measures.
  TimeSignature timeSignature = TimeSignature.fourFour;

  /// The meter the score *opens* in.
  ///
  /// Distinct from [timeSignature], which by the end of the read holds the
  /// last meter the file named. The sheet is seeded from this one: seeding it
  /// from the running value gave a score that opens in 4/4 and moves to 3/4 a
  /// sheet-level meter of 3/4, so bar 1 was barred wrongly.
  TimeSignature? initialTimeSignature;

  /// Section names already used, so a synthesised one cannot collide.
  final Set<String> _sectionNames = <String>{};

  /// Bars that already begin a section, so a meter change at a rehearsal mark
  /// does not add a second section at the same bar.
  final Set<int> _sectionBars = <int>{};

  /// How many chords were found, so a file with none can say so.
  int chordCount = 0;

  /// Divisions per quarter note, from `<attributes>`. Chord offsets are in
  /// these, and a file may change them mid-score.
  int _divisions = 1;

  /// The bar an ending opened at, and the passes it covers.
  int? _endingStart;
  Set<int> _endingPasses = <int>{};

  /// Read one measure.
  void readMeasure(int bar, XmlElement measure) {
    // Attributes first, so a rehearsal mark in this measure is built with the
    // meter this measure establishes rather than the previous one.
    final before = timeSignature;
    for (final attributes in measure.findElements('attributes')) {
      _readAttributes(attributes);
    }
    initialTimeSignature ??= timeSignature;

    for (final child in measure.childElements) {
      switch (child.name.local) {
        case 'harmony':
          _readHarmony(bar, child);
        case 'direction':
          _readDirection(bar, child);
        case 'barline':
          _readBarline(bar, child);
        case 'sound':
          _readSound(bar, child);
      }
    }

    // Last, once the directions have had their say: a measure that changes
    // meter *and* carries a rehearsal mark needs one section, not two, and the
    // rehearsal mark's own name is the better one. The sheet sorts its items,
    // so adding this after the measure's chords costs nothing.
    if (timeSignature != before) {
      _startMeterSection(bar);
    }
  }

  /// Carry a mid-score meter change into the sheet, as a section.
  ///
  /// A lead sheet reads the meter from the section governing a bar, so a
  /// `<time>` that changes mid-score with no rehearsal mark beside it had
  /// nowhere to live: playback, generation, layout and re-export all went on
  /// seeing the opening meter, and the change vanished without a word. The
  /// exporter writes per-bar `<time>` correctly, so the round trip used to be
  /// asymmetric — exporting and reimporting flattened the meters.
  ///
  /// Nothing is added where the file already names a section at this bar: that
  /// section carries the new meter itself (it is built from `timeSignature`).
  void _startMeterSection(int bar) {
    if (_sectionBars.contains(bar)) {
      return;
    }
    // Named for the meter, because that is what the section *is* — there is no
    // rehearsal letter to borrow. Suffixed on collision, as the iReal importer
    // does: a sheet refuses two sections with one name, and a score that
    // alternates meters would otherwise lose every change after the second.
    _add(
      CliSection(
        Section(
          name: _uniqueSectionName('$timeSignature'),
          startBar: bar,
          timeSignature: timeSignature,
        ),
      ),
    );
  }

  /// [name], or [name] with a suffix if the sheet already has a section by it.
  String _uniqueSectionName(String name) {
    var unique = name;
    var suffix = 2;
    while (_sectionNames.contains(unique)) {
      unique = '$name ($suffix)';
      suffix++;
    }
    _sectionNames.add(unique);
    return unique;
  }

  /// Title and composer, which sit outside the parts.
  void _readHeader(XmlElement root) {
    title = root
        .findAllElements('work-title')
        .map((element) => element.innerText.trim())
        .where((text) => text.isNotEmpty)
        .firstOrNull;
    title ??= root
        .findAllElements('movement-title')
        .map((element) => element.innerText.trim())
        .where((text) => text.isNotEmpty)
        .firstOrNull;
    composer = root
        .findAllElements('creator')
        .where((element) => element.getAttribute('type') == 'composer')
        .map((element) => element.innerText.trim())
        .where((text) => text.isNotEmpty)
        .firstOrNull;
  }

  void _readAttributes(XmlElement attributes) {
    final divisions = attributes.findElements('divisions').firstOrNull;
    final parsed = int.tryParse(divisions?.innerText.trim() ?? '');
    if (parsed != null && parsed > 0) {
      _divisions = parsed;
    }

    final time = attributes.findElements('time').firstOrNull;
    if (time != null) {
      final upper = int.tryParse(
        time.findElements('beats').firstOrNull?.innerText.trim() ?? '',
      );
      final lower = int.tryParse(
        time.findElements('beat-type').firstOrNull?.innerText.trim() ?? '',
      );
      if (upper != null && lower != null) {
        // Through tryParse, which validates: the constructor only asserts,
        // and an assert is stripped in a release build — so constructing from
        // a file directly would accept 4/5 in the shipping app and throw
        // only in a test (the text importer's _meterOf does the same).
        final meter = TimeSignature.tryParse('$upper/$lower');
        if (meter == null) {
          _problems.add('the time signature $upper/$lower is not one');
        } else {
          timeSignature = meter;
        }
      }
    }

    final keyElement = attributes.findElements('key').firstOrNull;
    if (keyElement != null) {
      final fifths = int.tryParse(
        keyElement.findElements('fifths').firstOrNull?.innerText.trim() ?? '',
      );
      final mode = keyElement
          .findElements('mode')
          .firstOrNull
          ?.innerText
          .trim();
      if (fifths != null) {
        key = _keyFromFifths(fifths, mode);
      }
    }
  }

  /// A key signature from its accidental count.
  ///
  /// Fifths is the number of sharps, negative for flats — the circle of fifths,
  /// which is exactly what a key signature is.
  KeySignature? _keyFromFifths(int fifths, String? mode) {
    if (fifths < -7 || fifths > 7) {
      _problems.add('a key of $fifths accidentals is not one');
      return null;
    }
    const majors = <String>[
      'Cb', 'Gb', 'Db', 'Ab', 'Eb', 'Bb', 'F', //
      'C', 'G', 'D', 'A', 'E', 'B', 'F#', 'C#',
    ];
    const minors = <String>[
      'Abm', 'Ebm', 'Bbm', 'Fm', 'Cm', 'Gm', 'Dm', //
      'Am', 'Em', 'Bm', 'F#m', 'C#m', 'G#m', 'D#m', 'A#m',
    ];
    final isMinor = mode != null && mode.toLowerCase() == 'minor';
    final names = isMinor ? minors : majors;
    return KeySignature.tryParse(names[fifths + 7]);
  }

  /// A chord symbol (§4).
  void _readHarmony(int bar, XmlElement harmony) {
    final kind = harmony.findElements('kind').firstOrNull;
    final beat = _beatOf(harmony, bar);

    if (kind?.innerText.trim() == 'none') {
      _add(CliChordSymbol(Position(bar, beat), ExtChordSymbol.noChord()));
      chordCount++;
      return;
    }

    final root = harmony.findElements('root').firstOrNull;
    if (root == null) {
      // A `<harmony>` with a `<function>` instead of a root is Roman-numeral
      // analysis, which is a different notation for a different purpose.
      return;
    }
    final step = root.findElements('root-step').firstOrNull?.innerText.trim();
    if (step == null || step.isEmpty) {
      return;
    }
    final alter =
        int.tryParse(
          root.findElements('root-alter').firstOrNull?.innerText.trim() ?? '',
        ) ??
        0;

    final symbol = _symbolFor(kind, harmony, bar);
    final bass = _bassOf(harmony);
    final text = '${_spell(step, alter)}$symbol${bass ?? ''}';
    final chord = ExtChordSymbol.tryParse(text, database: _types);
    if (chord == null) {
      _problems.add('bar ${bar + 1}: could not read the chord "$text"');
      return;
    }
    _add(CliChordSymbol(Position(bar, beat), chord));
    chordCount++;
  }

  /// The quality, as Bandstand writes it.
  ///
  /// §4: where a `<kind>` carries a `text` attribute — which is how software
  /// records a symbol the fixed vocabulary cannot express — the text wins. That
  /// is what round-trips Bandstand's own exports and what preserves `7alt`
  /// rather than flattening it to `dominant`.
  String _symbolFor(XmlElement? kind, XmlElement harmony, int bar) {
    final text = kind?.getAttribute('text');
    if (text != null && text.trim().isNotEmpty) {
      final candidate = text.trim();
      if (_types.typeFor(candidate) != null) {
        return candidate;
      }
    }
    final base = _kindNames[kind?.innerText.trim() ?? 'major'] ?? '';
    return '$base${_degreesOf(harmony, bar)}';
  }

  /// `<degree>` elements, applied as modifiers (§4).
  ///
  /// A degree of type `add` names one note the chord otherwise lacks, so it
  /// maps to Bandstand's `addN` modifiers: appending the bare number would
  /// read as an extension and pull in notes the file never wrote — `major`
  /// with `add 9` is not a dominant ninth. Where no faithful spelling exists,
  /// the chord is reported rather than written as a different one.
  String _degreesOf(XmlElement harmony, int bar) {
    final out = StringBuffer();
    for (final degree in harmony.findElements('degree')) {
      final value = int.tryParse(
        degree.findElements('degree-value').firstOrNull?.innerText.trim() ?? '',
      );
      final alter =
          int.tryParse(
            degree.findElements('degree-alter').firstOrNull?.innerText.trim() ??
                '',
          ) ??
          0;
      final type =
          degree.findElements('degree-type').firstOrNull?.innerText.trim() ??
          'add';
      if (value == null || type == 'subtract') {
        continue;
      }
      if (type == 'add' && alter == 0) {
        const added = <int, String>{
          2: 'add9',
          4: 'add11',
          6: '6',
          9: 'add9',
          11: 'add11',
          13: 'add13',
        };
        final modifier = added[value];
        if (modifier == null) {
          _problems.add(
            'bar ${bar + 1}: an added $value has no Bandstand spelling; '
            'the chord without it was kept',
          );
          continue;
        }
        out.write(modifier);
        continue;
      }
      if (alter == 0) {
        // A degree "altered" by nothing is the natural degree. The accidental
        // chosen below is `alter > 0 ? '#' : 'b'`, which has no case for zero
        // and so wrote a flat: a plain ninth became a flat ninth and the
        // chord changed, silently.
        const naturals = <int, String>{
          2: '9',
          4: '11',
          6: '6',
          9: '9',
          11: '11',
          13: '13',
        };
        final modifier = naturals[value];
        if (modifier != null) {
          out.write(modifier);
        }
        // 1, 3, 5 and 7 unaltered say nothing the core chord does not already
        // say, so there is nothing to write and nothing to report.
        continue;
      }
      if (alter.abs() > 1) {
        // The degree vocabulary carries single accidentals; writing one of
        // them for a double alteration would name a different note.
        _problems.add(
          'bar ${bar + 1}: a degree altered by ${alter.abs()} semitones has '
          'no Bandstand spelling; the chord without it was kept',
        );
        continue;
      }
      final accidental = alter > 0 ? '#' : 'b';
      out.write('$accidental$value');
    }
    return out.toString();
  }

  String? _bassOf(XmlElement harmony) {
    final bass = harmony.findElements('bass').firstOrNull;
    if (bass == null) {
      return null;
    }
    final step = bass.findElements('bass-step').firstOrNull?.innerText.trim();
    if (step == null || step.isEmpty) {
      return null;
    }
    final alter =
        int.tryParse(
          bass.findElements('bass-alter').firstOrNull?.innerText.trim() ?? '',
        ) ??
        0;
    return '/${_spell(step, alter)}';
  }

  static String _spell(String step, int alter) {
    final accidental = alter > 0 ? '#' * alter : 'b' * -alter;
    return '${step.toUpperCase()}$accidental';
  }

  /// Where in the bar a chord sits, from `<offset>` in divisions (§4).
  ///
  /// An offset past the bar end would drift into later bars once converted
  /// to quarters, so it is held at the bar line and reported.
  double _beatOf(XmlElement harmony, int bar) {
    final offset = double.tryParse(
      harmony.findElements('offset').firstOrNull?.innerText.trim() ?? '',
    );
    if (offset == null || _divisions <= 0) {
      return 0;
    }
    final quarters = offset / _divisions;
    final beat = quarters / timeSignature.beatDurationInQuarters;
    if (!beat.isFinite || beat < 0) {
      return 0;
    }
    if (beat >= timeSignature.upper) {
      _problems.add(
        'bar ${bar + 1}: a chord sits past the end of its bar; it was '
        'placed at the bar line',
      );
      return timeSignature.upper.toDouble();
    }
    return beat;
  }

  /// Rehearsal marks and navigation directions (§5).
  void _readDirection(int bar, XmlElement direction) {
    for (final type in direction.findElements('direction-type')) {
      for (final child in type.childElements) {
        switch (child.name.local) {
          case 'rehearsal':
            final name = child.innerText.trim();
            if (name.isNotEmpty) {
              // The section owns the meter in force where it starts;
              // leaving it out would default it to 4/4 from here on.
              //
              // A returning letter — "A" again after "B", which is how a chart
              // marks the head coming back — is suffixed rather than dropped.
              // A sheet refuses two sections with one name, and the whole
              // section used to be lost to that error, taking its meter with
              // it. The iReal importer suffixes for the same reason.
              _add(
                CliSection(
                  Section(
                    name: _uniqueSectionName(name),
                    startBar: bar,
                    timeSignature: timeSignature,
                  ),
                ),
              );
            }
          case 'segno':
            _add(CliNavigation(Position(bar), NavigationMark.segno));
          case 'coda':
            _add(CliNavigation(Position(bar), NavigationMark.coda));
        }
      }
    }
    for (final sound in direction.findElements('sound')) {
      _readSound(bar, sound);
    }
  }

  /// `<sound>` carries tempo and the navigation attributes (§5).
  void _readSound(int bar, XmlElement sound) {
    final beats = double.tryParse(sound.getAttribute('tempo') ?? '');
    if (beats != null) {
      if (beats >= minTempo && beats <= maxTempo) {
        tempo ??= beats.round();
      } else {
        _problems.add(
          'bar ${bar + 1}: the tempo $beats is not between $minTempo and '
          '$maxTempo',
        );
      }
    }
    // Both spellings are read, because software disagrees about which to
    // write: some put the mark in `<direction-type>`, some only here.
    if (sound.getAttribute('segno') != null) {
      _add(CliNavigation(Position(bar), NavigationMark.segno));
    }
    if (sound.getAttribute('coda') != null) {
      _add(CliNavigation(Position(bar), NavigationMark.coda));
    }
    if (sound.getAttribute('tocoda') != null) {
      _add(CliNavigation(Position(bar), NavigationMark.toCoda));
    }
    if (sound.getAttribute('fine') != null) {
      _add(CliNavigation(Position(bar), NavigationMark.fine));
    }
    final dacapo = sound.getAttribute('dacapo');
    if (dacapo != null) {
      _add(CliNavigation(Position(bar), NavigationMark.daCapo));
    }
    final dalsegno = sound.getAttribute('dalsegno');
    if (dalsegno != null) {
      _add(CliNavigation(Position(bar), NavigationMark.dalSegno));
    }
  }

  /// Repeats and endings (§5).
  void _readBarline(int bar, XmlElement barline) {
    for (final repeat in barline.findElements('repeat')) {
      final direction = repeat.getAttribute('direction');
      if (direction == 'forward') {
        _add(CliRepeat(Position(bar), isStart: true));
      } else if (direction == 'backward') {
        final times = int.tryParse(repeat.getAttribute('times') ?? '') ?? 2;
        _add(
          CliRepeat(
            Position(bar),
            isStart: false,
            playCount: times < 1 ? 2 : times,
          ),
        );
      }
    }

    for (final ending in barline.findElements('ending')) {
      final type = ending.getAttribute('type');
      final passes = _passesOf(ending);
      if (type == 'start') {
        if (_endingStart != null) {
          _problems.add(
            'bar ${bar + 1}: an ending opens before the last one closed',
          );
        }
        _endingStart = bar;
        _endingPasses = passes;
      } else if (type == 'stop' || type == 'discontinue') {
        final start = _endingStart;
        if (start == null) {
          _problems.add('bar ${bar + 1}: an ending closes without opening');
          continue;
        }
        _add(
          CliEnding(
            Position(start),
            _endingPasses.isEmpty ? <int>{1} : _endingPasses,
            barCount: bar - start + 1,
          ),
        );
        _endingStart = null;
        _endingPasses = <int>{};
      }
    }
  }

  /// `number="1,2"` — a comma-separated list, and a first-and-third ending is
  /// legal (§5).
  Set<int> _passesOf(XmlElement ending) => <int>{
    for (final part in (ending.getAttribute('number') ?? '').split(','))
      if (int.tryParse(part.trim()) case final int pass) pass,
  };

  /// Close an ending the score left open at its last bar, as the text
  /// importer does: a bracket that simply stops is common enough in the
  /// wild, and the bars it covers are still worth keeping (§5).
  void closeEnding(int lastBar) {
    final start = _endingStart;
    if (start == null) {
      return;
    }
    _add(
      CliEnding(
        Position(start),
        _endingPasses.isEmpty ? <int>{1} : _endingPasses,
        barCount: lastBar - start + 1,
      ),
    );
    _endingStart = null;
    _endingPasses = <int>{};
  }

  void _add(LeadSheetItem item) {
    if (item is CliSection) {
      _sectionBars.add(item.section.startBar);
    }
    items.add(item);
  }

  /// The `<kind>` vocabulary, mapped to Bandstand's symbols (§4).
  ///
  /// Fixed by the format and smaller than Bandstand's, which is why a `text`
  /// attribute wins over it where one is given.
  static const Map<String, String> _kindNames = <String, String>{
    'major': '',
    'minor': 'm',
    'augmented': '+',
    'diminished': 'o',
    'dominant': '7',
    'major-seventh': 'maj7',
    'minor-seventh': 'm7',
    'diminished-seventh': 'o7',
    'augmented-seventh': '7#5',
    'half-diminished': 'm7b5',
    'major-minor': 'mMaj7',
    'major-sixth': '6',
    'minor-sixth': 'm6',
    'dominant-ninth': '9',
    'major-ninth': 'maj9',
    'minor-ninth': 'm9',
    'dominant-11th': '11',
    'major-11th': 'maj11',
    'minor-11th': 'm11',
    'dominant-13th': '13',
    'major-13th': 'maj13',
    'minor-13th': 'm13',
    'suspended-second': 'sus2',
    'suspended-fourth': 'sus4',
    'power': '5',
  };
}
